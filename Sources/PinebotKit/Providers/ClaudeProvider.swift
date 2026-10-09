import AppKit

public enum ClaudeAuthMode: String, Sendable {
    case officialAccount = "official_account"
    case apiKey = "api_key"
}

/// Anthropic Claude provider adhering to official compliance guidelines.
/// Supports official unmodified Claude Code CLI login via ACP (primary)
/// and optional direct Anthropic API Key (collapsed under Advanced).
public final class ClaudeProvider: LLMProvider, @unchecked Sendable {
    public let type: ProviderType = .claude
    
    private let keychain: KeychainHelper
    private let defaults: UserDefaults
    private let apiKeyStorageKey: String
    private let authModeKey: String
    private let officialActiveKey: String
    
    private let lock = NSLock()
    private var _discoveredModels: [ModelInfo] = []
    private var _isConnected: Bool = false
    private var _statusDescription: String = "Disconnected"
    private var _currentMode: ClaudeAuthMode = .officialAccount
    
    private var codeSession: ClaudeCodeSession?
    private var activeSessionGeneration: UUID = UUID()
    private var activeTeardownTask: Task<Void, Never>?
    
    private var onModelsUpdated: (@Sendable ([ModelInfo], String?) -> Void)?
    
    public init(
        codeSession: ClaudeCodeSession? = nil,
        defaults: UserDefaults = .standard,
        keychain: KeychainHelper = .shared,
        keyPrefix: String = "com.pinebot.claude"
    ) {
        self.codeSession = codeSession
        self.defaults = defaults
        self.keychain = keychain
        self.apiKeyStorageKey = "\(keyPrefix).api_key"
        self.authModeKey = "\(keyPrefix).auth_mode"
        self.officialActiveKey = "\(keyPrefix).official_active"
        
        let savedMode = defaults.string(forKey: authModeKey)
        if savedMode == ClaudeAuthMode.apiKey.rawValue {
            _currentMode = .apiKey
            _statusDescription = "Saved API Key"
        } else if defaults.bool(forKey: officialActiveKey) {
            _currentMode = .officialAccount
            _statusDescription = "Claude Account (Official CLI)"
        }
    }
    
    /// Restores saved Claude connection asynchronously in background without SecurityAgent popups.
    public func restoreConnection() async {
        let isOfficial = defaults.bool(forKey: officialActiveKey)
        let savedMode = defaults.string(forKey: authModeKey)
        
        if isOfficial {
            lock.withLock {
                _currentMode = .officialAccount
                _statusDescription = "Claude Account (Official CLI)"
            }
        } else if savedMode == ClaudeAuthMode.apiKey.rawValue {
            let res = keychain.loadResult(key: apiKeyStorageKey, allowUI: false)
            lock.withLock {
                switch res {
                case .success:
                    _currentMode = .apiKey
                    _statusDescription = "Saved API Key"
                    _isConnected = true
                case .interactionRequired:
                    _currentMode = .apiKey
                    _statusDescription = "Claude Key (Locked in Keychain - Click Connect)"
                    _isConnected = false
                case .itemNotFound, .failed:
                    _isConnected = false
                    _statusDescription = "Disconnected"
                }
            }
        }
    }
    
    public func setOnModelsUpdatedHandler(_ handler: (@Sendable ([ModelInfo], String?) -> Void)?) {
        lock.withLock {
            self.onModelsUpdated = handler
        }
    }
    
    private func setupSessionCallbacks(_ session: ClaudeCodeSession, generation: UUID) async {
        await session.setOnModelsUpdatedHandler { [weak self, weak session] updatedModels, currentModelId in
            self?.handleSessionModelsUpdated(updatedModels, currentModelId: currentModelId, generation: generation, from: session)
        }
    }
    
    private func handleSessionModelsUpdated(
        _ updatedModels: [ModelInfo],
        currentModelId: String?,
        generation: UUID,
        from session: ClaudeCodeSession?
    ) {
        let callback = lock.withLock { () -> (@Sendable ([ModelInfo], String?) -> Void)? in
            guard self.activeSessionGeneration == generation,
                  self._currentMode == .officialAccount,
                  self.codeSession === session else {
                return nil
            }
            self._discoveredModels = updatedModels
            if self._isConnected && updatedModels.isEmpty {
                self._statusDescription = "Connected (No models available)"
            }
            return self.onModelsUpdated
        }
        callback?(updatedModels, currentModelId)
    }
    
    public var isConfigured: Bool {
        return defaults.bool(forKey: officialActiveKey) ||
               defaults.string(forKey: authModeKey) == ClaudeAuthMode.apiKey.rawValue
    }
    
    public var isConnected: Bool {
        lock.withLock { _isConnected }
    }
    
    public var statusDescription: String {
        lock.withLock { _statusDescription }
    }
    
    public var discoveredModels: [ModelInfo] {
        lock.withLock { _discoveredModels }
    }
    
    public var currentMode: ClaudeAuthMode {
        lock.withLock { _currentMode }
    }
    
    private func getOrCreateSession() async -> ClaudeCodeSession {
        let (session, gen) = lock.withLock { () -> (ClaudeCodeSession, UUID) in
            if let session = codeSession {
                return (session, activeSessionGeneration)
            }
            self.activeSessionGeneration = UUID()
            let newGen = self.activeSessionGeneration
            let newSession = ClaudeCodeSession()
            self.codeSession = newSession
            return (newSession, newGen)
        }
        await setupSessionCallbacks(session, generation: gen)
        return session
    }
    
    // MARK: - Official Account Authentication (ACP)
    
    /// Connects via official Anthropic Claude account using unmodified Claude Code CLI.
    @discardableResult
    public func startOfficialAccountAuth(
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> [ModelInfo] {
        try Task.checkCancellation()
        
        lock.withLock {
            self.activeSessionGeneration = UUID()
        }
        let session = await getOrCreateSession()
        
        // 1. Check if already authenticated in CLI
        onStatusUpdate?("Checking Claude authentication status...")
        var status = try await session.checkOfficialAuthStatus()
        
        // 2. If not authenticated, initiate official interactive browser login
        if !status.loggedIn {
            onStatusUpdate?("Opening Claude sign-in in browser...")
            status = try await session.startOfficialLogin(timeout: 180.0, onStatusUpdate: onStatusUpdate)
        }
        
        guard status.loggedIn else {
            throw ClaudeCodeError.authFailed("Authentication not completed.")
        }
        
        // 3. Connect ACP session and discover models
        onStatusUpdate?("Starting Claude ACP session...")
        let models = try await session.createNewSession()
        
        let accountSummary: String
        if let email = status.email, !email.isEmpty {
            accountSummary = "Claude Account (\(email))"
        } else {
            accountSummary = "Claude Account (Official CLI)"
        }
        
        updateState(
            connected: true,
            description: accountSummary,
            models: models,
            mode: .officialAccount
        )
        
        defaults.set(true, forKey: officialActiveKey)
        defaults.set(ClaudeAuthMode.officialAccount.rawValue, forKey: authModeKey)
        
        return models
    }
    
    /// Cancels any active official Claude authentication or session handshake.
    public func cancelAuth() {
        activeSessionGeneration = UUID()
        let session = lock.withLock { () -> ClaudeCodeSession? in
            let s = codeSession
            codeSession = nil
            return s
        }
        if let s = session {
            Task {
                await s.cancelLogin()
                await s.close()
            }
        }
        updateState(connected: false, description: "Disconnected", models: [], mode: .officialAccount)
    }
    
    // MARK: - Direct API Key Configuration (Advanced)
    
    @discardableResult
    public func configureWithAPIKey(_ apiKey: String) async throws -> [ModelInfo] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ClaudeProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Claude API Key cannot be empty."])
        }
        
        keychain.saveString(key: apiKeyStorageKey, value: trimmed)
        defaults.set(ClaudeAuthMode.apiKey.rawValue, forKey: authModeKey)
        defaults.set(false, forKey: officialActiveKey)
        
        lock.withLock {
            _currentMode = .apiKey
        }
        
        return try await validateAndDiscoverModels()
    }
    
    @discardableResult
    public func configure(apiKey: String) async throws -> [ModelInfo] {
        return try await configureWithAPIKey(apiKey)
    }
    
    // MARK: - Validation & Discovery
    
    public func validateAndDiscoverModels() async throws -> [ModelInfo] {
        let mode = lock.withLock { _currentMode }
        
        switch mode {
        case .officialAccount:
            let session = await getOrCreateSession()
            let status = try await session.checkOfficialAuthStatus()
            guard status.loggedIn else {
                updateState(connected: false, description: "Not Signed In", models: [])
                throw ClaudeCodeError.notSignedIn
            }
            
            let models = try await session.createNewSession()
            let accountSummary: String
            if let email = status.email, !email.isEmpty {
                accountSummary = "Claude Account (\(email))"
            } else {
                accountSummary = "Claude Account (Official CLI)"
            }
            updateState(connected: true, description: accountSummary, models: models, mode: .officialAccount)
            return models
            
        case .apiKey:
            guard let key = keychain.loadString(key: apiKeyStorageKey) else {
                throw NSError(domain: "ClaudeProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Claude API key not configured."])
            }
            
            let url = URL(string: "https://api.anthropic.com/v1/messages")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let pingBody: [String: Any] = [
                "model": "claude-3-5-haiku-20241022",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: pingBody)
            
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Authentication check failed"
                updateState(connected: false, description: "Authentication Failed")
                throw NSError(domain: "ClaudeProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Claude verification failed: \(msg)"])
            }
            
            let models = [
                ModelInfo(
                    id: "claude-3-7-sonnet-20250219",
                    displayName: "Claude 3.7 Sonnet (Hybrid Reasoning)",
                    provider: .claude,
                    tier: .frontierReasoning,
                    supportsVision: true,
                    supportsTools: true
                ),
                ModelInfo(
                    id: "claude-3-5-sonnet-20241022",
                    displayName: "Claude 3.5 Sonnet (Balanced)",
                    provider: .claude,
                    tier: .frontierReasoning,
                    supportsVision: true,
                    supportsTools: true
                ),
                ModelInfo(
                    id: "claude-3-5-haiku-20241022",
                    displayName: "Claude 3.5 Haiku (Fast)",
                    provider: .claude,
                    tier: .cheapFast,
                    supportsVision: true,
                    supportsTools: true
                )
            ]
            
            updateState(connected: true, description: "Connected via Anthropic API Key", models: models, mode: .apiKey)
            return models
        }
    }
    
    private func updateState(connected: Bool, description: String, models: [ModelInfo]? = nil, mode: ClaudeAuthMode? = nil) {
        lock.withLock {
            _isConnected = connected
            _statusDescription = description
            if let m = models {
                _discoveredModels = m
            }
            if let md = mode {
                _currentMode = md
            }
        }
    }
    
    // MARK: - Completion Generation
    
    public func generateCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String {
        let mode = lock.withLock { _currentMode }
        
        switch mode {
        case .officialAccount:
            let session = await getOrCreateSession()
            let fullPrompt: String
            if let sys = systemPrompt, !sys.isEmpty {
                fullPrompt = "\(sys)\n\n\(prompt)"
            } else {
                fullPrompt = prompt
            }
            return try await session.sendPrompt(
                text: fullPrompt,
                model: model,
                image: image,
                timeout: 120.0
            )
            
        case .apiKey:
            guard let key = keychain.loadString(key: apiKeyStorageKey) else {
                throw NSError(domain: "ClaudeProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Claude API key not found in Keychain."])
            }
            
            let url = URL(string: "https://api.anthropic.com/v1/messages")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            var contentBlocks: [[String: Any]] = []
            
            if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                let base64 = jpeg.base64EncodedString()
                contentBlocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64
                    ]
                ])
            }
            
            contentBlocks.append([
                "type": "text",
                "text": prompt
            ])
            
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 4096,
                "messages": [
                    ["role": "user", "content": contentBlocks]
                ]
            ]
            
            if let system = systemPrompt {
                body["system"] = system
            }
            
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Claude request error"
                throw NSError(domain: "ClaudeProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Claude API Error: \(msg)"])
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let contentList = json["content"] as? [[String: Any]] {
                let fullText = contentList.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !fullText.isEmpty {
                    return fullText
                }
            }
            
            return "Completed without response text."
        }
    }
    
    // MARK: - Cancellation & Teardown
    
    /// Cancels active in-flight prompt turn. Crucially does NOT disconnect or log the user out.
    public func cancelGeneration() async {
        let session = lock.withLock { codeSession }
        if let s = session {
            try? await s.cancelCurrentPrompt()
        }
    }
    
    public func openClaudeAppOrWeb() {
        if let url = URL(string: "https://claude.ai") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func openOfficialApp() {
        openClaudeAppOrWeb()
    }
    
    /// Disconnects provider in Pinebot without touching official Claude Code CLI credentials.
    public func disconnect() {
        activeSessionGeneration = UUID()
        let session = lock.withLock { () -> ClaudeCodeSession? in
            _isConnected = false
            _statusDescription = "Disconnected"
            _discoveredModels = []
            let s = codeSession
            codeSession = nil
            return s
        }
        
        defaults.removeObject(forKey: officialActiveKey)
        defaults.removeObject(forKey: authModeKey)
        keychain.delete(key: apiKeyStorageKey)
        
        if let s = session {
            Task {
                await s.close()
            }
        }
    }
}
