import AppKit

public enum GeminiAuthMode: String, Sendable {
    case officialAccount = "official_account"
    case apiKey = "api_key"
}

/// Google Gemini provider supporting both official Google Account login via ACP (Gemini CLI)
/// and direct Gemini API Key fallback.
public final class GeminiProvider: LLMProvider, @unchecked Sendable {
    public let type: ProviderType = .gemini
    
    private let keychain: KeychainHelper
    private let defaults: UserDefaults
    private let apiKeyStorageKey: String
    private let authModeKey: String
    private let officialActiveKey: String
    
    private let lock = NSLock()
    private var _discoveredModels: [ModelInfo] = []
    private var _isConnected: Bool = false
    private var _statusDescription: String = "Disconnected"
    private var _currentMode: GeminiAuthMode = .officialAccount
    
    private var agentSession: GeminiAgentSession?
    private var activeSessionGeneration: UUID = UUID()
    private var activeTeardownTask: Task<Void, Never>?
    
    public init(
        agentSession: GeminiAgentSession? = nil,
        defaults: UserDefaults = .standard,
        keychain: KeychainHelper = .shared,
        keyPrefix: String = "com.pinebot.gemini"
    ) {
        self.agentSession = agentSession
        self.defaults = defaults
        self.keychain = keychain
        self.apiKeyStorageKey = "\(keyPrefix).api_key"
        self.authModeKey = "\(keyPrefix).auth_mode"
        self.officialActiveKey = "\(keyPrefix).official_active"
        
        let savedMode = defaults.string(forKey: authModeKey)
        if savedMode == GeminiAuthMode.apiKey.rawValue {
            _currentMode = .apiKey
            _statusDescription = "Saved API Key"
        } else if defaults.bool(forKey: officialActiveKey) {
            _currentMode = .officialAccount
            _statusDescription = "Google Account (Personal)"
        }
    }
    
    /// Restores saved Gemini connection asynchronously in background without SecurityAgent popups.
    public func restoreConnection() async {
        let isOfficial = defaults.bool(forKey: officialActiveKey)
        let savedMode = defaults.string(forKey: authModeKey)
        
        if isOfficial {
            lock.withLock {
                _currentMode = .officialAccount
                _statusDescription = "Google Account (Personal)"
            }
        } else if savedMode == GeminiAuthMode.apiKey.rawValue {
            let res = keychain.loadResult(key: apiKeyStorageKey, allowUI: false)
            lock.withLock {
                switch res {
                case .success:
                    _currentMode = .apiKey
                    _statusDescription = "Saved API Key"
                    _isConnected = true
                case .interactionRequired:
                    _currentMode = .apiKey
                    _statusDescription = "Gemini Key (Locked in Keychain - Click Connect)"
                    _isConnected = false
                case .itemNotFound, .failed:
                    _isConnected = false
                    _statusDescription = "Disconnected"
                }
            }
        }
    }
    
    private var onModelsUpdated: (@Sendable ([ModelInfo], String?) -> Void)?
    
    public func setOnModelsUpdatedHandler(_ handler: (@Sendable ([ModelInfo], String?) -> Void)?) {
        lock.withLock {
            self.onModelsUpdated = handler
        }
    }
    
    private func setupSessionCallbacks(_ session: GeminiAgentSession, generation: UUID) async {
        await session.setOnModelsUpdatedHandler { [weak self, weak session] updatedModels, currentModelId in
            self?.handleSessionModelsUpdated(updatedModels, currentModelId: currentModelId, generation: generation, from: session)
        }
    }
    
    private func handleSessionModelsUpdated(
        _ updatedModels: [ModelInfo],
        currentModelId: String?,
        generation: UUID,
        from session: GeminiAgentSession?
    ) {
        let callback = lock.withLock { () -> (@Sendable ([ModelInfo], String?) -> Void)? in
            guard self.activeSessionGeneration == generation,
                  self._currentMode == .officialAccount,
                  self.agentSession === session else {
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
               defaults.string(forKey: authModeKey) == GeminiAuthMode.apiKey.rawValue
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
    
    public var currentMode: GeminiAuthMode {
        lock.withLock { _currentMode }
    }
    
    private func getOrCreateSession() async -> GeminiAgentSession {
        let (session, gen) = lock.withLock { () -> (GeminiAgentSession, UUID) in
            if let session = agentSession {
                return (session, activeSessionGeneration)
            }
            self.activeSessionGeneration = UUID()
            let newGen = self.activeSessionGeneration
            let newSession = GeminiAgentSession()
            self.agentSession = newSession
            return (newSession, newGen)
        }
        await setupSessionCallbacks(session, generation: gen)
        return session
    }
    
    // MARK: - Official Account Authentication (ACP)
    
    /// Connects via personal Google Account using ACP and official Gemini CLI.
    @discardableResult
    public func startOfficialAccountAuth(
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> [ModelInfo] {
        try Task.checkCancellation()
        
        // Ensure any prior session teardown has completed before starting new session
        let priorTeardown: Task<Void, Never>? = lock.withLock {
            self.activeTeardownTask
        }
        
        if let teardown = priorTeardown {
            _ = await teardown.result
            lock.withLock {
                if self.activeTeardownTask == priorTeardown {
                    self.activeTeardownTask = nil
                }
            }
        }
        
        try Task.checkCancellation()
        
        lock.withLock {
            self.activeSessionGeneration = UUID()
        }
        let session = await getOrCreateSession()
        
        onStatusUpdate?("Starting Google client...")
        _ = try await session.startAndInitialize()
        try Task.checkCancellation()
        
        onStatusUpdate?("Waiting for Google sign-in...")
        try await session.authenticate(methodId: "oauth-personal", onStatusUpdate: onStatusUpdate)
        try Task.checkCancellation()
        
        onStatusUpdate?("Discovering available Gemini models...")
        let models = try await session.createNewSession()
        try Task.checkCancellation()
        
        defaults.set(true, forKey: officialActiveKey)
        defaults.set(GeminiAuthMode.officialAccount.rawValue, forKey: authModeKey)
        
        updateState(
            connected: true,
            description: "Connected with Google Account",
            mode: .officialAccount,
            models: models
        )
        return models
    }
    
    public func cancelAuth() {
        lock.withLock {
            self.activeSessionGeneration = UUID()
            let session = agentSession
            activeTeardownTask?.cancel()
            let teardown = Task<Void, Never> { [weak session] in
                if let s = session {
                    await s.close()
                }
            }
            self.activeTeardownTask = teardown
        }
    }
    
    // MARK: - API Key Configuration (Fallback)
    
    @discardableResult
    public func configureWithAPIKey(_ apiKey: String) async throws -> [ModelInfo] {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "GeminiProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key cannot be empty."])
        }
        
        keychain.saveString(key: apiKeyStorageKey, value: trimmed)
        defaults.set(GeminiAuthMode.apiKey.rawValue, forKey: authModeKey)
        defaults.set(false, forKey: officialActiveKey)
        
        return try await validateAPIKeyAndDiscoverModels(key: trimmed)
    }
    
    @discardableResult
    public func configure(apiKey: String) async throws -> [ModelInfo] {
        return try await configureWithAPIKey(apiKey)
    }
    
    // MARK: - Validation & Discovery
    
    public func validateAndDiscoverModels() async throws -> [ModelInfo] {
        let mode = self.currentMode
        
        if mode == .officialAccount && defaults.bool(forKey: officialActiveKey) {
            lock.withLock {
                self.activeSessionGeneration = UUID()
            }
            let session = await getOrCreateSession()
            _ = try await session.startAndInitialize()
            try await session.authenticate(methodId: "oauth-personal")
            let models = try await session.createNewSession()
            updateState(
                connected: true,
                description: "Connected with Google Account",
                mode: .officialAccount,
                models: models
            )
            return models
        } else if let key = keychain.loadString(key: apiKeyStorageKey) {
            return try await validateAPIKeyAndDiscoverModels(key: key)
        } else {
            throw NSError(
                domain: "GeminiProvider",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Google Gemini account or API key not configured."]
            )
        }
    }
    
    private func validateAPIKeyAndDiscoverModels(key: String) async throws -> [ModelInfo] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Authentication check failed"
            updateState(connected: false, description: "Authentication Failed", mode: .apiKey)
            throw NSError(domain: "GeminiProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini verification failed: \(msg)"])
        }
        
        var models: [ModelInfo] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawList = json["models"] as? [[String: Any]] {
            for item in rawList {
                let name = item["name"] as? String ?? ""
                let id = name.replacingOccurrences(of: "models/", with: "")
                let displayName = item["displayName"] as? String ?? id
                
                guard id.contains("gemini") else { continue }
                
                let tier: ModelTier
                if id.contains("pro") {
                    tier = .frontierReasoning
                } else if id.contains("flash") {
                    tier = .cheapFast
                } else {
                    tier = .balanced
                }
                
                models.append(ModelInfo(
                    id: id,
                    displayName: displayName,
                    provider: .gemini,
                    tier: tier,
                    supportsVision: true,
                    supportsTools: true
                ))
            }
        }
        
        if models.isEmpty {
            models = [
                ModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true),
                ModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini, tier: .frontierReasoning, supportsVision: true, supportsTools: true),
                ModelInfo(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true)
            ]
        }
        
        updateState(connected: true, description: "Connected via Gemini API Key", mode: .apiKey, models: models)
        return models
    }
    
    private func updateState(connected: Bool, description: String, mode: GeminiAuthMode, models: [ModelInfo]? = nil) {
        lock.withLock {
            _isConnected = connected
            _statusDescription = description
            _currentMode = mode
            if let m = models {
                _discoveredModels = m
            }
        }
    }
    
    // MARK: - Generation
    
    public func generateCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String {
        let mode = self.currentMode
        
        if mode == .officialAccount {
            let session = await getOrCreateSession()
            var fullPrompt = prompt
            if let system = systemPrompt, !system.isEmpty {
                fullPrompt = "[Instruction: \(system)]\n\n\(prompt)"
            }
            return try await session.sendPrompt(text: fullPrompt, model: model, image: image)
        } else {
            return try await generateAPIKeyCompletion(prompt: prompt, systemPrompt: systemPrompt, image: image, model: model)
        }
    }
    
    private func generateAPIKeyCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String {
        guard let key = keychain.loadString(key: apiKeyStorageKey) else {
            throw NSError(domain: "GeminiProvider", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API key not found."])
        }
        
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var parts: [[String: Any]] = []
        
        if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let base64 = jpeg.base64EncodedString()
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": base64
                ]
            ])
        }
        
        parts.append(["text": prompt])
        
        var body: [String: Any] = [
            "contents": [
                ["parts": parts]
            ]
        ]
        
        if let system = systemPrompt {
            body["system_instruction"] = [
                "parts": [["text": system]]
            ]
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Gemini API error"
            throw NSError(domain: "GeminiProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Gemini Error: \(msg)"])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let textParts = content["parts"] as? [[String: Any]] {
            let text = textParts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty {
                return text
            }
        }
        
        return "Completed without response text."
    }
    
    public func openGeminiWeb() {
        if let url = URL(string: "https://gemini.google.com") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public func openOfficialApp() {
        openGeminiWeb()
    }
    
    public func cancelGeneration() async {
        let session = lock.withLock { self.agentSession }
        _ = try? await session?.cancelCurrentPrompt()
    }
    
    public func cancelActivePrompt() async {
        await cancelGeneration()
    }
    
    public func disconnect() {
        lock.withLock {
            self.activeSessionGeneration = UUID()
            _isConnected = false
            _statusDescription = "Disconnected"
            _discoveredModels = []
            _currentMode = .officialAccount
            let session = agentSession
            activeTeardownTask?.cancel()
            let teardown = Task<Void, Never> { [weak session] in
                if let s = session {
                    await s.close()
                }
            }
            self.activeTeardownTask = teardown
        }
        
        defaults.set(false, forKey: officialActiveKey)
        defaults.removeObject(forKey: authModeKey)
        keychain.delete(key: apiKeyStorageKey)
    }
}
