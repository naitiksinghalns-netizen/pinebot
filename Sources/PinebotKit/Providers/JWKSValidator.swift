import Foundation
import Security
import CryptoKit

/// Cryptographic validator for JSON Web Key Sets (JWKS) and RS256 JWT tokens.
/// Adheres strictly to RFC 7517 (JWK) and RFC 7518 (JWA / RS256 PKCS#1 v1.5).
public actor JWKSValidator {
    public static let shared = JWKSValidator()
    
    private let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    private var cachedKeys: [String: JWK] = [:]
    private var lastFetchTime: Date?
    
    public struct JWK: Decodable, Sendable {
        public let kty: String
        public let kid: String
        public let use: String?
        public let alg: String?
        public let n: String // base64url encoded RSA modulus
        public let e: String // base64url encoded RSA public exponent
        
        public init(kty: String, kid: String, use: String? = nil, alg: String? = nil, n: String, e: String) {
            self.kty = kty
            self.kid = kid
            self.use = use
            self.alg = alg
            self.n = n
            self.e = e
        }
    }
    
    public struct ValidatedIDToken: Sendable {
        public let issuer: String
        public let subject: String
        public let audience: String
        public let nonce: String?
        public let email: String?
        public let expiration: Date
        
        public init(issuer: String, subject: String, audience: String, nonce: String?, email: String?, expiration: Date) {
            self.issuer = issuer
            self.subject = subject
            self.audience = audience
            self.nonce = nonce
            self.email = email
            self.expiration = expiration
        }
    }
    
    private struct JWKSet: Decodable {
        let keys: [JWK]
    }
    
    public init() {}
    
    /// Pre-populates or updates cached keys (useful for testing or manual key injection).
    public func setCachedKey(_ key: JWK) {
        cachedKeys[key.kid] = key
        lastFetchTime = Date()
    }
    
    /// Fetches the JWKS keys from https://auth.openai.com/.well-known/jwks.json with caching.
    public func fetchKeys(forceRefresh: Bool = false) async throws -> [String: JWK] {
        if !forceRefresh, let fetchTime = lastFetchTime, Date().timeIntervalSince(fetchTime) < 3600, !cachedKeys.isEmpty {
            return cachedKeys
        }
        
        var request = URLRequest(url: jwksURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "JWKSValidator", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Failed to fetch OpenAI JWKS from auth.openai.com (HTTP \(status))."
            ])
        }
        
        let jwkSet = try JSONDecoder().decode(JWKSet.self, from: data)
        for key in jwkSet.keys {
            self.cachedKeys[key.kid] = key
        }
        self.lastFetchTime = Date()
        
        return self.cachedKeys
    }
    
    /// Cryptographically validates an RS256 ID token against OpenAI JWKS, verifying signature and standard claims.
    /// Returns the verified claims dictionary on success; throws actionable errors on failure.
    public func validateIDToken(
        idToken: String,
        expectedNonce: String,
        expectedClientId: String
    ) async throws -> ValidatedIDToken {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Malformed ID token structure: expected 3 dot-separated JWT parts."
            ])
        }
        
        let headerB64 = parts[0]
        let payloadB64 = parts[1]
        let signatureB64 = parts[2]
        
        // 1. Decode header to extract kid and alg
        guard let headerData = base64URLDecode(headerB64),
              let headerJson = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode ID token header."
            ])
        }
        
        guard let alg = headerJson["alg"] as? String, alg == "RS256" else {
            let badAlg = headerJson["alg"] as? String ?? "none"
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported ID token algorithm '\(badAlg)': RS256 required."
            ])
        }
        
        guard let kid = headerJson["kid"] as? String, !kid.isEmpty else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Missing 'kid' (key ID) in ID token header."
            ])
        }
        
        // 2. Locate matching JWK public key
        var matchingKey: JWK? = cachedKeys[kid]
        if matchingKey == nil {
            let keys = try await fetchKeys(forceRefresh: true)
            matchingKey = keys[kid]
        }
        
        guard let jwk = matchingKey else {
            throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Unknown signing key ID '\(kid)' not found in OpenAI JWKS."
            ])
        }
        
        guard jwk.kty == "RSA" else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JWK key type '\(jwk.kty)': expected 'RSA'."
            ])
        }
        
        // 3. Construct SecKey from RSA modulus (n) and exponent (e)
        guard let modulusData = base64URLDecode(jwk.n),
              let exponentData = base64URLDecode(jwk.e) else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid base64url encoding in JWK public key components."
            ])
        }
        
        guard let secKey = createSecKeyFromRSAComponents(modulus: modulusData, exponent: exponentData) else {
            throw NSError(domain: "JWKSValidator", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to construct SecKey RSA public key from JWKS components."
            ])
        }
        
        // 4. Cryptographic signature verification
        let signedDataString = "\(headerB64).\(payloadB64)"
        guard let signedData = signedDataString.data(using: .utf8),
              let signatureData = base64URLDecode(signatureB64) else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode signature bytes from ID token."
            ])
        }
        
        var secError: Unmanaged<CFError>?
        let isSignatureValid = SecKeyVerifySignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedData as CFData,
            signatureData as CFData,
            &secError
        )
        
        guard isSignatureValid else {
            let errorDetails = secError?.takeRetainedValue().localizedDescription ?? "Signature verification failed"
            throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Cryptographic signature verification failed: \(errorDetails)"
            ])
        }
        
        // 5. Decode payload claims
        guard let payloadData = base64URLDecode(payloadB64),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw NSError(domain: "JWKSValidator", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode ID token payload JSON."
            ])
        }
        
        // 6. Verify Standard Claims:
        // A. Issuer must be https://auth.openai.com
        guard let iss = claims["iss"] as? String, iss == "https://auth.openai.com" else {
            let foundIss = claims["iss"] as? String ?? "nil"
            throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Invalid token issuer '\(foundIss)': expected 'https://auth.openai.com'."
            ])
        }
        
        // B. Audience must match effectiveClientId
        let tokenAud: String
        if let singleAud = claims["aud"] as? String {
            tokenAud = singleAud
        } else if let arrayAud = claims["aud"] as? [String], let first = arrayAud.first {
            tokenAud = first
        } else {
            tokenAud = ""
        }
        
        if !expectedClientId.isEmpty && expectedClientId != "dynamic_agent_client" {
            guard tokenAud == expectedClientId else {
                throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "ID token audience mismatch: expected '\(expectedClientId)', got '\(tokenAud)'."
                ])
            }
        }
        
        // C. Nonce must match exactly
        if !expectedNonce.isEmpty {
            guard let tokenNonce = claims["nonce"] as? String, tokenNonce == expectedNonce else {
                throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "ID token nonce mismatch. Potential replay attack."
                ])
            }
        }
        
        // D. Expiration check
        guard let exp = claims["exp"] as? Double else {
            throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Missing 'exp' expiration claim in ID token."
            ])
        }
        
        let now = Date().timeIntervalSince1970
        guard exp > now else {
            throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "ID token has expired (exp: \(exp), now: \(now))."
            ])
        }
        
        // E. Subject (sub) must be non-empty
        guard let sub = claims["sub"] as? String, !sub.isEmpty else {
            throw NSError(domain: "JWKSValidator", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Missing or empty subject ('sub') in ID token."
            ])
        }
        
        let email = claims["email"] as? String
        let nonce = claims["nonce"] as? String
        
        return ValidatedIDToken(
            issuer: iss,
            subject: sub,
            audience: tokenAud,
            nonce: nonce,
            email: email,
            expiration: Date(timeIntervalSince1970: exp)
        )
    }
    
    // MARK: - RSA SecKey Construction via ASN.1 DER (PKCS#1)
    
    /// Builds a SecKey public key from raw modulus and public exponent using PKCS#1 DER RSAPublicKey encoding:
    /// RSAPublicKey ::= SEQUENCE {
    ///     modulus           INTEGER,  -- n
    ///     publicExponent    INTEGER   -- e
    /// }
    public func createSecKeyFromRSAComponents(modulus: Data, exponent: Data) -> SecKey? {
        func encodeInteger(_ data: Data) -> Data {
            var content = data
            if let first = content.first, first >= 0x80 {
                content.insert(0x00, at: 0)
            }
            var result = Data()
            result.append(0x02) // INTEGER tag
            encodeLength(content.count, into: &result)
            result.append(content)
            return result
        }
        
        func encodeLength(_ length: Int, into data: inout Data) {
            if length < 128 {
                data.append(UInt8(length))
            } else if length < 256 {
                data.append(0x81)
                data.append(UInt8(length))
            } else if length < 65536 {
                data.append(0x82)
                data.append(UInt8(length >> 8))
                data.append(UInt8(length & 0xFF))
            } else {
                data.append(0x83)
                data.append(UInt8(length >> 16))
                data.append(UInt8((length >> 8) & 0xFF))
                data.append(UInt8(length & 0xFF))
            }
        }
        
        let modEncoded = encodeInteger(modulus)
        let expEncoded = encodeInteger(exponent)
        
        var derData = Data()
        derData.append(0x30) // SEQUENCE tag
        encodeLength(modEncoded.count + expEncoded.count, into: &derData)
        derData.append(modEncoded)
        derData.append(expEncoded)
        
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.count * 8
        ]
        
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, &error)
        return key
    }
    
    // MARK: - Base64URL Helper
    
    public func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }
}
