import AppKit
import CryptoKit
import Network
import Combine

public typealias LoopbackResponder = @Sendable (Bool, String?) -> Void

private final class OAuthCallbackCoordinator: @unchecked Sendable {
    private var isResumed = false
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(code: String, clientId: String, state: String, responder: LoopbackResponder), Error>?
    private var pendingResult: Result<(code: String, clientId: String, state: String, responder: LoopbackResponder), Error>?
    
    func setContinuation(_ cont: CheckedContinuation<(code: String, clientId: String, state: String, responder: LoopbackResponder), Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let res = pendingResult {
            isResumed = true
            switch res {
            case .success(let val): cont.resume(returning: val)
            case .failure(let err): cont.resume(throwing: err)
            }
        } else {
            continuation = cont
        }
    }
    
    func complete(with result: Result<(code: String, clientId: String, state: String, responder: LoopbackResponder), Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed else { return }
        if let cont = continuation {
            isResumed = true
            continuation = nil
            switch result {
            case .success(let val): cont.resume(returning: val)
            case .failure(let err): cont.resume(throwing: err)
            }
        } else {
            pendingResult = result
        }
    }
}

/// Official Sign in with ChatGPT (SIWC) OAuth PKCE & Responses API Provider.
/// Compliant with OpenAI developer documentation for token-sharing open-source apps.
public final class OpenAIProvider: LLMProvider, @unchecked Sendable {
    public let type: ProviderType = .openai
    
    private let keychain: KeychainHelper
    private let defaults: UserDefaults
    private let hostIdKey: String
    private let tokenKey: String
    private let refreshTokenKey: String
    private let idTokenKey: String
    private let clientIdKey: String
    private let tokenExpiryKey: String
    private let apiKeyStorageKey: String
    private let authTypeKey: String // "oauth" or "apikey"
    private let sharingEnabledKey: String
    private let userEmailKey: String
    
    private let lock = NSLock()
    private var _discoveredModels: [ModelInfo] = []
    private var _isConnected: Bool = false
    private var _statusDescription: String = "Disconnected"
    private var _userEmail: String?
    private var _hasPlanSharing: Bool = false
    
    private var loopbackListener: NWListener?
    
    public init(
        userDefaults: UserDefaults = .standard,
        keychain: KeychainHelper = .shared,
        keyPrefix: String = "com.pinebot.openai"
    ) {
        self.defaults = userDefaults
        self.keychain = keychain
        self.hostIdKey = "\(keyPrefix).host_id"
        self.tokenKey = "\(keyPrefix).access_token"
        self.refreshTokenKey = "\(keyPrefix).refresh_token"
        self.idTokenKey = "\(keyPrefix).id_token"
        self.clientIdKey = "\(keyPrefix).client_id"
        self.tokenExpiryKey = "\(keyPrefix).token_expiry"
        self.apiKeyStorageKey = "\(keyPrefix).api_key"
        self.authTypeKey = "\(keyPrefix).auth_type"
        self.sharingEnabledKey = "\(keyPrefix).sharing_enabled"
        self.userEmailKey = "\(keyPrefix).user_email"
        
        // Fast init: populate metadata from UserDefaults without blocking Keychain calls
        if let authType = defaults.string(forKey: authTypeKey) {
            if authType == "oauth" {
                _userEmail = defaults.string(forKey: userEmailKey)
                _hasPlanSharing = defaults.bool(forKey: sharingEnabledKey)
                _statusDescription = _hasPlanSharing ? "ChatGPT Plan Active" : "ChatGPT Connected"
            } else if authType == "apikey" {
                _statusDescription = "OpenAI API Key Active"
            }
        }
    }
    
    public var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: authTypeKey) != nil || _isConnected
    }
    
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }
    
    public var statusDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return _statusDescription
    }
    
    public var discoveredModels: [ModelInfo] {
        lock.lock()
        defer { lock.unlock() }
        return _discoveredModels
    }
    
    public var userEmail: String? {
        lock.lock()
        defer { lock.unlock() }
        return _userEmail
    }
    
    public var hasPlanSharing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hasPlanSharing
    }
    
    /// Asynchronously restores saved connection in the background using non-interactive Keychain reads.
    public func restoreConnection() async {
        var authType = defaults.string(forKey: authTypeKey)
        if authType == nil {
            if keychain.loadString(key: tokenKey, allowUI: false) != nil {
                authType = "oauth"
                defaults.set("oauth", forKey: authTypeKey)
            } else if keychain.loadString(key: apiKeyStorageKey, allowUI: false) != nil {
                authType = "apikey"
                defaults.set("apikey", forKey: authTypeKey)
            }
        }
        
        if authType == "oauth" {
            let res = keychain.loadResult(key: tokenKey, allowUI: false)
            lock.withLock {
                switch res {
                case .success:
                    _userEmail = defaults.string(forKey: userEmailKey)
                    _hasPlanSharing = defaults.bool(forKey: sharingEnabledKey)
                    _statusDescription = _hasPlanSharing ? "ChatGPT Plan Active" : "ChatGPT Connected (Plan Use Disabled)"
                    _isConnected = true
                case .interactionRequired:
                    _userEmail = defaults.string(forKey: userEmailKey)
                    _statusDescription = "ChatGPT (Locked in Keychain - Click Connect)"
                    _isConnected = false
                case .itemNotFound, .failed:
                    _isConnected = false
                    _statusDescription = "Disconnected"
                }
            }
        } else if authType == "apikey" {
            let res = keychain.loadResult(key: apiKeyStorageKey, allowUI: false)
            lock.withLock {
                switch res {
                case .success:
                    _statusDescription = "OpenAI API Key Active"
                    _isConnected = true
                case .interactionRequired:
                    _statusDescription = "API Key (Locked in Keychain - Click Connect)"
                    _isConnected = false
                case .itemNotFound, .failed:
                    _isConnected = false
                    _statusDescription = "Disconnected"
                }
            }
        }
    }
    
    public func getHostId() -> String {
        if let existing = defaults.string(forKey: hostIdKey) {
            return existing
        }
        let newId = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(newId, forKey: hostIdKey)
        return newId
    }
    
    // MARK: - Direct API Key Configuration
    
    public func configureWithAPIKey(_ apiKey: String) async throws -> [ModelInfo] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "OpenAIProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "API key cannot be empty."])
        }
        
        keychain.saveString(key: apiKeyStorageKey, value: trimmed)
        defaults.set("apikey", forKey: authTypeKey)
        
        return try await validateAndDiscoverModels()
    }
    
    // MARK: - Sign in with ChatGPT (SIWC) OAuth PKCE Flow
    
    public func startChatGPTAuth(
        onAuthURLGenerated: @escaping @Sendable (URL) -> Void
    ) async throws -> [ModelInfo] {
        let hostId = getHostId()
        
        // 1. Generate PKCE verifier, challenge, state, and nonce
        let verifier = generateRandomString(length: 64)
        let challenge = generatePKCEChallenge(from: verifier)
        let state = generateRandomString(length: 32)
        let nonce = generateRandomString(length: 32)
        
        // 2. Start loopback listener strictly bound to 127.0.0.1
        let coordinator = OAuthCallbackCoordinator()
        let port: UInt16 = 14555
        try startLoopbackListener(port: port, expectedState: state, coordinator: coordinator)
        let redirectUri = "http://127.0.0.1:\(port)/auth/callback"
        
        // 3. Check for existing issued client ID and ID token hint (returning user)
        let savedClientId = keychain.loadString(key: clientIdKey)
        let isReturning = savedClientId != nil && !(savedClientId?.isEmpty ?? true) && savedClientId != "dynamic_agent_client"
        let clientId = isReturning ? savedClientId! : "dynamic_agent_client"
        let savedIdToken = keychain.loadString(key: idTokenKey)
        
        // 4. Construct Authorization URL
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "ext_agent_host_id", value: hostId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        
        if !isReturning {
            // First time dynamic registration sends agent_name_hint
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: "Pinebot"))
        } else {
            // Returning registration can send id_token_hint for frictionless reauthorization
            if let hint = savedIdToken, !hint.isEmpty {
                queryItems.append(URLQueryItem(name: "id_token_hint", value: hint))
            }
            if let email = defaults.string(forKey: userEmailKey), !email.isEmpty {
                queryItems.append(URLQueryItem(name: "login_hint", value: email))
            }
        }
        
        components.queryItems = queryItems
        guard let authURL = components.url else {
            throw NSError(domain: "OpenAIProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to construct OAuth URL."])
        }
        
        // Open browser
        onAuthURLGenerated(authURL)
        
        // 5. Wait for callback from browser loopback server
        let (authCode, issuedClientId, callbackState, responder) = try await withCheckedThrowingContinuation { continuation in
            coordinator.setContinuation(continuation)
        }
        
        guard callbackState == state else {
            responder(false, "Security error: OAuth state mismatch.")
            throw NSError(domain: "OpenAIProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Security error: OAuth state mismatch."])
        }
        
        // Ensure issued client ID is valid: dynamic registration MUST return an issued client ID
        let effectiveClientId: String
        if !issuedClientId.isEmpty && issuedClientId != "dynamic_agent_client" {
            effectiveClientId = issuedClientId
        } else if let saved = savedClientId, !saved.isEmpty, saved != "dynamic_agent_client" {
            effectiveClientId = saved
        } else {
            let errorMsg = "Missing issued client ID from registration callback. Registration is incomplete."
            responder(false, errorMsg)
            throw NSError(domain: "OpenAIProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 6. Exchange code for tokens
        let tokenResponse: TokenResponse
        do {
            tokenResponse = try await exchangeCodeForToken(
                code: authCode,
                clientId: effectiveClientId,
                verifier: verifier,
                redirectUri: redirectUri
            )
        } catch {
            responder(false, error.localizedDescription)
            throw error
        }
        
        // 7. Cryptographically validate ID Token against OpenAI JWKS
        var validatedEmail: String?
        if let idToken = tokenResponse.idToken {
            do {
                let validated = try await JWKSValidator.shared.validateIDToken(
                    idToken: idToken,
                    expectedNonce: nonce,
                    expectedClientId: effectiveClientId
                )
                validatedEmail = validated.email
            } catch {
                responder(false, "ID token cryptographic validation failed: \(error.localizedDescription)")
                throw error
            }
        }
        
        // 8. Check granted scopes for plan usage permission
        let hasDirectTokenUse = tokenResponse.scopes.contains("chatgpt.tokens.use.direct")
        
        // 9. Send success response to browser now that all tokens and cryptography are verified
        responder(true, nil)
        
        // 10. Persist credentials securely
        keychain.saveString(key: tokenKey, value: tokenResponse.accessToken)
        if let refresh = tokenResponse.refreshToken {
            keychain.saveString(key: refreshTokenKey, value: refresh)
        }
        if let idTok = tokenResponse.idToken {
            keychain.saveString(key: idTokenKey, value: idTok)
        }
        keychain.saveString(key: clientIdKey, value: effectiveClientId)
        
        let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        defaults.set(expiryDate.timeIntervalSince1970, forKey: tokenExpiryKey)
        defaults.set("oauth", forKey: authTypeKey)
        defaults.set(hasDirectTokenUse, forKey: sharingEnabledKey)
        if let email = validatedEmail {
            defaults.set(email, forKey: userEmailKey)
        }
        
        updateProfile(email: validatedEmail, hasPlanSharing: hasDirectTokenUse)
        
        // 11. Fetch model catalog
        return try await validateAndDiscoverModels()
    }
    
    private func updateProfile(email: String?, hasPlanSharing: Bool) {
        lock.lock()
        _userEmail = email
        _hasPlanSharing = hasPlanSharing
        lock.unlock()
    }
    
    private func startLoopbackListener(port: UInt16, expectedState: String, coordinator: OAuthCallbackCoordinator) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        
        let listener = try NWListener(using: params)
        self.loopbackListener = listener
        
        listener.newConnectionHandler = { [weak self, coordinator] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, coordinator, connection] data, _, _, _ in
                guard let data = data, let req = String(data: data, encoding: .utf8) else {
                    return
                }
                
                guard let firstLine = req.components(separatedBy: "\r\n").first,
                      let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
                      let url = URL(string: "http://127.0.0.1:\(port)\(pathPart)"),
                      let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                    return
                }
                
                let state = queryItems.first(where: { $0.name == "state" })?.value ?? ""
                let error = queryItems.first(where: { $0.name == "error" })?.value
                
                // Validate state FIRST before processing
                if state != expectedState {
                    let errHtml = """
                    HTTP/1.1 400 Bad Request\r
                    Content-Type: text/html\r
                    Connection: close\r
                    \r
                    <!DOCTYPE html><html><body style="font-family:system-ui;padding:40px;text-align:center;">
                    <h2>Authentication Error</h2><p>State mismatch. Please try signing in again from Pinebot.</p>
                    </body></html>
                    """
                    connection.send(content: errHtml.data(using: .utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                    }))
                    coordinator.complete(with: .failure(NSError(domain: "OpenAIProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid OAuth state returned."])))
                    return
                }
                
                if let err = error {
                    let desc = queryItems.first(where: { $0.name == "error_description" })?.value ?? err
                    let errHtml = """
                    HTTP/1.1 200 OK\r
                    Content-Type: text/html\r
                    Connection: close\r
                    \r
                    <!DOCTYPE html><html><body style="font-family:system-ui;padding:40px;text-align:center;background:#FFFBF5;color:#1C1917;">
                    <h2>Sign in Cancelled</h2><p>\(desc)</p><p>You can return to Pinebot.</p>
                    </body></html>
                    """
                    connection.send(content: errHtml.data(using: .utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                        self?.stopLoopbackListener()
                    }))
                    coordinator.complete(with: .failure(NSError(domain: "OpenAIProvider", code: 403, userInfo: [NSLocalizedDescriptionKey: "Sign in was cancelled or denied: \(desc)"])))
                    return
                }
                
                let code = queryItems.first(where: { $0.name == "code" })?.value ?? ""
                let clientId = queryItems.first(where: { $0.name == "client_id" })?.value ?? ""
                
                // Hold connection open until token exchange and cryptographic verification succeed
                let responder: LoopbackResponder = { [weak self, connection] success, errorMessage in
                    let html: String
                    if success {
                        html = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html; charset=utf-8\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html>
                        <html>
                        <head>
                          <title>Connected to Pinebot</title>
                          <meta name="viewport" content="width=device-width, initial-scale=1">
                          <style>
                            body {
                              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                              background: #FDFBF7;
                              color: #1C1917;
                              display: flex;
                              align-items: center;
                              justify-content: center;
                              height: 100vh;
                              margin: 0;
                            }
                            .card {
                              text-align: center;
                              padding: 40px;
                              background: #FFFFFF;
                              border-radius: 20px;
                              box-shadow: 0 10px 25px rgba(0,0,0,0.06);
                              border: 1px solid #E7E5E4;
                              max-width: 400px;
                            }
                            .hero { font-size: 54px; margin-bottom: 12px; }
                            h2 { margin: 0 0 10px; font-weight: 700; color: #D97706; }
                            p { color: #57534E; font-size: 14px; line-height: 1.5; margin: 0; }
                          </style>
                        </head>
                        <body>
                          <div class="card">
                            <div class="hero">🍍</div>
                            <h2>Connected to Pinebot!</h2>
                            <p>Your ChatGPT account is now securely linked. You can close this tab and return to Pinebot.</p>
                          </div>
                        </body>
                        </html>
                        """
                    } else {
                        let msg = errorMessage ?? "Authentication failed."
                        html = """
                        HTTP/1.1 400 Bad Request\r
                        Content-Type: text/html; charset=utf-8\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html>
                        <html>
                        <head>
                          <title>Authentication Failed</title>
                          <meta name="viewport" content="width=device-width, initial-scale=1">
                          <style>
                            body { font-family: -apple-system, sans-serif; padding: 40px; text-align: center; background: #FFFBF5; color: #1C1917; }
                            .card { max-width: 400px; margin: 40px auto; padding: 30px; background: white; border-radius: 16px; border: 1px solid #E7E5E4; }
                            h2 { color: #DC2626; margin-bottom: 12px; }
                            p { color: #57534E; font-size: 14px; line-height: 1.5; }
                          </style>
                        </head>
                        <body>
                          <div class="card">
                            <h2>Authentication Error</h2>
                            <p>\(msg)</p>
                            <p>Please return to Pinebot to try again.</p>
                          </div>
                        </body>
                        </html>
                        """
                    }
                    connection.send(content: html.data(using: .utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                        self?.stopLoopbackListener()
                    }))
                }
                
                coordinator.complete(with: .success((code: code, clientId: clientId, state: state, responder: responder)))
            }
        }
        
        listener.stateUpdateHandler = { [weak coordinator] state in
            if case .failed(let err) = state {
                coordinator?.complete(with: .failure(err))
            }
        }
        
        listener.start(queue: .main)
    }
    
    private func stopLoopbackListener() {
        lock.lock()
        loopbackListener?.cancel()
        loopbackListener = nil
        lock.unlock()
    }
    
    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: Int
        let scopes: [String]
    }
    
    private func exchangeCodeForToken(
        code: String,
        clientId: String,
        verifier: String,
        redirectUri: String
    ) async throws -> TokenResponse {
        let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParams = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectUri,
            "resource": "https://api.openai.com/v1"
        ]
        
        let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errString = String(data: data, encoding: .utf8) ?? "Unknown token exchange failure"
            throw NSError(domain: "OpenAIProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Token exchange failed: \(errString)"])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "OpenAIProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Malformed token response from OpenAI."])
        }
        
        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let scopeString = json["scope"] as? String ?? ""
        let scopes = scopeString.components(separatedBy: " ")
        
        return TokenResponse(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken, expiresIn: expiresIn, scopes: scopes)
    }
    
    // MARK: - Token Refresh
    
    private func refreshTokenIfNeeded() async throws -> String {
        // Auto-detect authType from Keychain to recover gracefully if UserDefaults was reset
        var authType = defaults.string(forKey: authTypeKey)
        if authType == nil {
            if keychain.loadString(key: tokenKey) != nil {
                authType = "oauth"
                defaults.set("oauth", forKey: authTypeKey)
            } else if keychain.loadString(key: apiKeyStorageKey) != nil {
                authType = "apikey"
                defaults.set("apikey", forKey: authTypeKey)
            }
        }
        
        if authType == "apikey" {
            guard let key = keychain.loadString(key: apiKeyStorageKey) else {
                throw NSError(domain: "OpenAIProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API Key missing."])
            }
            return key
        }
        
        guard let accessToken = keychain.loadString(key: tokenKey) else {
            throw NSError(domain: "OpenAIProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sign in with ChatGPT required."])
        }
        
        let expiryTimestamp = defaults.double(forKey: tokenExpiryKey)
        let isExpired = expiryTimestamp > 0 && Date().timeIntervalSince1970 > (expiryTimestamp - 60.0) // 60s safety buffer
        
        guard isExpired, let refreshToken = keychain.loadString(key: refreshTokenKey), let clientId = keychain.loadString(key: clientIdKey) else {
            return accessToken
        }
        
        // Refresh grant
        let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParams = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
            "resource": "https://api.openai.com/v1"
        ]
        
        let bodyString = bodyParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            // Check if refresh token was invalid or revoked
            if let http = response as? HTTPURLResponse, (400...499).contains(http.statusCode) {
                throw NSError(domain: "OpenAIProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "ChatGPT session expired. Please sign in again."])
            }
            return accessToken
        }
        
        keychain.saveString(key: tokenKey, value: newAccessToken)
        if let newRefresh = json["refresh_token"] as? String {
            keychain.saveString(key: refreshTokenKey, value: newRefresh)
        }
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let newExpiry = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970
        defaults.set(newExpiry, forKey: tokenExpiryKey)
        
        return newAccessToken
    }
    
    // MARK: - Model Discovery & Validation
    
    public func validateAndDiscoverModels() async throws -> [ModelInfo] {
        let token = try await refreshTokenIfNeeded()
        let authType = defaults.string(forKey: authTypeKey) ?? "apikey"
        let isBearerOAuth = (authType == "oauth")
        
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Authentication check failed"
            updateState(connected: false, description: "Connection Failed")
            throw NSError(domain: "OpenAIProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI authentication failed: \(msg)"])
        }
        
        var models: [ModelInfo] = []
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawModels = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) {
            
            for item in rawModels {
                let id = (item["slug"] as? String) ?? (item["id"] as? String) ?? ""
                let displayName = (item["display_name"] as? String) ?? id
                let visibility = item["visibility"] as? String
                
                // Per official docs: keep models intended for display (visibility: "list")
                if let vis = visibility, vis != "list" {
                    continue
                }
                
                guard !id.isEmpty else { continue }
                
                // Determine capabilities honestly based on model architecture
                let supportsVision: Bool
                let supportsTools: Bool
                let tier: ModelTier
                
                let lowerId = id.lowercased()
                if lowerId.contains("gpt-4o") || lowerId.contains("gpt-4.5") || lowerId.contains("gpt-6") {
                    supportsVision = true
                    supportsTools = true
                    tier = (lowerId.contains("mini") || lowerId.contains("luna")) ? .cheapFast : .frontierReasoning
                } else if lowerId.contains("o1") {
                    supportsVision = true
                    supportsTools = true
                    tier = .frontierReasoning
                } else if lowerId.contains("o3-mini") {
                    supportsVision = false // o3-mini is text/code reasoning without vision
                    supportsTools = true
                    tier = .frontierReasoning
                } else if lowerId.contains("dall-e") || lowerId.contains("tts") || lowerId.contains("whisper") || lowerId.contains("embedding") {
                    continue // Exclude non-conversational specialized endpoints
                } else {
                    supportsVision = false
                    supportsTools = lowerId.contains("turbo") || lowerId.contains("gpt-4")
                    tier = .balanced
                }
                
                models.append(ModelInfo(
                    id: id,
                    displayName: isBearerOAuth ? "\(displayName) (ChatGPT Plan)" : displayName,
                    provider: .openai,
                    tier: tier,
                    supportsVision: supportsVision,
                    supportsTools: supportsTools,
                    isLocal: false
                ))
            }
        }
        
        // Never invent fake fallback models: if no listable models exist, throw actionable error
        if models.isEmpty {
            updateState(connected: false, description: "No Models Available")
            throw NSError(domain: "OpenAIProvider", code: 404, userInfo: [NSLocalizedDescriptionKey: "No conversational models are available for this account."])
        }
        
        let desc = isBearerOAuth ? (_hasPlanSharing ? "Connected via ChatGPT Subscription" : "Connected (Plan Usage Disabled)") : "Connected via OpenAI API Key"
        updateState(connected: true, description: desc, models: models)
        
        return models
    }
    
    private func updateState(connected: Bool, description: String, models: [ModelInfo]? = nil) {
        lock.lock()
        _isConnected = connected
        _statusDescription = description
        if let m = models {
            _discoveredModels = m
        }
        lock.unlock()
    }
    
    // MARK: - Text & Task Generation
    
    public func generateCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String {
        let token = try await refreshTokenIfNeeded()
        let authType = defaults.string(forKey: authTypeKey) ?? "apikey"
        
        if authType == "oauth" {
            guard _hasPlanSharing else {
                throw NSError(domain: "OpenAIProvider", code: 403, userInfo: [NSLocalizedDescriptionKey: "ChatGPT plan usage is not enabled for this connection. Please reconnect with plan permissions granted."])
            }
            return try await callResponsesAPI(prompt: prompt, systemPrompt: systemPrompt, image: image, model: model, token: token)
        } else {
            return try await callChatCompletionsAPI(prompt: prompt, systemPrompt: systemPrompt, image: image, model: model, token: token)
        }
    }
    
    // MARK: - Responses API Call (SIWC Plan Usage with Streaming SSE)
    
    private func callResponsesAPI(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String,
        token: String
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        
        var userContentList: [[String: Any]] = []
        userContentList.append(["type": "input_text", "text": prompt])
        
        if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let base64 = jpeg.base64EncodedString()
            userContentList.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(base64)"
            ])
        }
        
        var inputItems: [[String: Any]] = []
        if let system = systemPrompt, !system.isEmpty {
            inputItems.append(["role": "system", "content": system])
        }
        inputItems.append(["role": "user", "content": userContentList])
        
        // store: false and stream: true per official documentation
        let body: [String: Any] = [
            "model": model,
            "input": inputItems,
            "store": false,
            "stream": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid network response from Responses API."])
        }
        
        if !(200...299).contains(http.statusCode) {
            // Read error body from async stream
            var errBody = ""
            for try await line in asyncBytes.lines {
                errBody += line
            }
            if let errJson = try? JSONSerialization.jsonObject(with: errBody.data(using: .utf8) ?? Data()) as? [String: Any],
               let errObj = errJson["error"] as? [String: Any],
               let errCode = errObj["code"] as? String {
                if errCode == "subscription_sharing_usage_limit_exceeded" || errCode == "subscription_sharing_usage_unavailable" {
                    throw NSError(domain: "OpenAIProvider", code: 429, userInfo: [NSLocalizedDescriptionKey: "ChatGPT plan usage limit reached. Manage your limits at https://chatgpt.com/settings/usage."])
                }
            }
            throw NSError(domain: "OpenAIProvider", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Responses API HTTP \(http.statusCode): \(errBody)"])
        }
        
        var accumulatedText = ""
        var isCompleted = false
        var currentEvent: String?
        
        for try await line in asyncBytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                currentEvent = nil
                continue
            }
            
            if trimmed.hasPrefix("event:") {
                currentEvent = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            
            if trimmed.hasPrefix("data:") {
                let dataString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if dataString == "[DONE]" {
                    break
                }
                
                guard let jsonData = dataString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }
                
                let eventType = (json["type"] as? String) ?? currentEvent ?? ""
                
                if eventType == "response.output_text.delta" {
                    if let delta = json["delta"] as? String {
                        accumulatedText += delta
                    }
                } else if eventType == "response.completed" {
                    isCompleted = true
                    if let respObj = json["response"] as? [String: Any] {
                        if let directText = respObj["output_text"] as? String, accumulatedText.isEmpty {
                            accumulatedText = directText
                        }
                    }
                } else if eventType == "response.failed" {
                    let errObj = json["error"] as? [String: Any]
                    let errCode = errObj?["code"] as? String ?? ""
                    let errMsg = errObj?["message"] as? String ?? "Task failed on server."
                    
                    if errCode == "subscription_sharing_usage_limit_exceeded" || errCode == "subscription_sharing_usage_unavailable" {
                        throw NSError(domain: "OpenAIProvider", code: 429, userInfo: [NSLocalizedDescriptionKey: "ChatGPT plan usage limit reached. Manage your limits at https://chatgpt.com/settings/usage."])
                    } else {
                        throw NSError(domain: "OpenAIProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Responses API failed: \(errMsg)"])
                    }
                }
            }
        }
        
        if !accumulatedText.isEmpty {
            return accumulatedText
        }
        if isCompleted {
            return "Completed without response text."
        }
        throw NSError(domain: "OpenAIProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Responses stream completed with no text output."])
    }
    
    // MARK: - Chat Completions API (Direct API Key)
    
    private func callChatCompletionsAPI(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String,
        token: String
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var messages: [[String: Any]] = []
        if let system = systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        
        if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let base64 = jpeg.base64EncodedString()
            messages.append([
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                ]
            ])
        } else {
            messages.append(["role": "user", "content": prompt])
        }
        
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let err = String(data: data, encoding: .utf8) ?? "Chat completions error"
            throw NSError(domain: "OpenAIProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "OpenAI error: \(err)"])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let msg = first["message"] as? [String: Any],
           let content = msg["content"] as? String {
            return content
        }
        
        return "Completed without response text."
    }
    
    public func openManageUsage() {
        if let url = URL(string: "https://chatgpt.com/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func disconnect() {
        lock.lock()
        _isConnected = false
        _statusDescription = "Disconnected"
        _discoveredModels = []
        _userEmail = nil
        _hasPlanSharing = false
        lock.unlock()
        
        keychain.delete(key: tokenKey)
        keychain.delete(key: refreshTokenKey)
        keychain.delete(key: idTokenKey)
        keychain.delete(key: clientIdKey)
        keychain.delete(key: apiKeyStorageKey)
        defaults.removeObject(forKey: authTypeKey)
        defaults.removeObject(forKey: tokenExpiryKey)
        defaults.removeObject(forKey: sharingEnabledKey)
        defaults.removeObject(forKey: userEmailKey)
    }
    
    // MARK: - Helpers
    
    private func generateRandomString(length: Int) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
    
    private func generatePKCEChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hashed = SHA256.hash(data: data)
        return Data(hashed)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
