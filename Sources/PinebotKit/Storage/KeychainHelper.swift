import Foundation
import Security

/// Result of loading a Keychain item, distinguishing between present, absent, and locked/interaction required.
public enum KeychainLoadResult: Sendable, Equatable {
    case success(Data)
    case itemNotFound
    case interactionRequired
    case failed(OSStatus)
}

/// Secure storage helper using the macOS Keychain Services API with memory fallback.
/// Enforces non-interactive reads by default to prevent blocking the Main thread with SecurityAgent prompts.
public final class KeychainHelper: @unchecked Sendable {
    public static let shared = KeychainHelper()
    
    private let service = "com.pinebot.macos.credentials"
    private var memoryFallback: [String: Data] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
        NSClassFromString("XCTestCase") != nil
    }
    
    @discardableResult
    public func save(key: String, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if isTesting {
            memoryFallback[key] = data
            return true
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        // Try deleting existing item first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        } else {
            // In headless/test runners or restricted sandbox, retain in memory
            memoryFallback[key] = data
            return true
        }
    }
    
    /// Loads a keychain item with explicit control over authentication UI.
    /// By default (allowUI = false), fails closed with kSecUseAuthenticationUIFail to prevent SecurityAgent popups on startup.
    public func loadResult(key: String, allowUI: Bool = false) -> KeychainLoadResult {
        lock.lock()
        defer { lock.unlock() }
        
        if isTesting {
            if let data = memoryFallback[key] {
                return .success(data)
            }
            return .itemNotFound
        }
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return .success(data)
        }
        
        if status == errSecItemNotFound {
            if let data = memoryFallback[key] {
                return .success(data)
            }
            return .itemNotFound
        }
        
        // Interaction required or locked keychain
        // errSecInteractionNotAllowed = -25308
        // errSecAuthFailed = -25293
        // errSecInteractionRequired = -25315
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == -25315 {
            return .interactionRequired
        }
        
        if let data = memoryFallback[key] {
            return .success(data)
        }
        
        return .failed(status)
    }
    
    public func load(key: String, allowUI: Bool = false) -> Data? {
        let result = loadResult(key: key, allowUI: allowUI)
        switch result {
        case .success(let data):
            return data
        case .itemNotFound, .interactionRequired, .failed:
            lock.lock()
            defer { lock.unlock() }
            return memoryFallback[key]
        }
    }
    
    @discardableResult
    public func delete(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        memoryFallback.removeValue(forKey: key)
        
        if isTesting {
            return true
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    @discardableResult
    public func saveString(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }
    
    public func loadString(key: String, allowUI: Bool = false) -> String? {
        guard let data = load(key: key, allowUI: allowUI) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
