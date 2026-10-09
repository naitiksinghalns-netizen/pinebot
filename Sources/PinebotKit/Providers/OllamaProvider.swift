import AppKit

/// Local Ollama provider for offline, private, zero-cost inference.
public final class OllamaProvider: LLMProvider, @unchecked Sendable {
    public let type: ProviderType = .ollama
    
    private let endpointKey = "com.pinebot.ollama.endpoint"
    private let defaultEndpoint = "http://localhost:11434"
    
    private let lock = NSLock()
    private var _discoveredModels: [ModelInfo] = []
    private var _isConnected: Bool = false
    private var _statusDescription: String = "Disconnected"
    
    public init() {
        if UserDefaults.standard.string(forKey: endpointKey) != nil {
            _statusDescription = "Configured (Local)"
        }
    }
    
    public var isConfigured: Bool {
        return true // Ollama can always be checked locally
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
    
    public var endpoint: String {
        return UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint
    }
    
    public func setEndpoint(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? defaultEndpoint : trimmed, forKey: endpointKey)
    }
    
    @discardableResult
    public func configure(endpoint: String) async throws -> [ModelInfo] {
        setEndpoint(endpoint)
        return try await validateAndDiscoverModels()
    }
    
    public func validateAndDiscoverModels() async throws -> [ModelInfo] {
        guard let url = URL(string: "\(endpoint)/api/tags") else {
            throw NSError(domain: "OllamaProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama endpoint URL."])
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            updateState(connected: false, description: "Ollama Not Running at \(endpoint)")
            throw NSError(domain: "OllamaProvider", code: 503, userInfo: [NSLocalizedDescriptionKey: "Could not connect to Ollama at \(endpoint). Is Ollama running?"])
        }
        
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            updateState(connected: false, description: "Ollama Error")
            throw NSError(domain: "OllamaProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Ollama returned error status."])
        }
        
        var models: [ModelInfo] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawModels = json["models"] as? [[String: Any]] {
            for item in rawModels {
                let name = item["name"] as? String ?? ""
                guard !name.isEmpty else { continue }
                
                let tier: ModelTier
                if name.contains("70b") || name.contains("deepseek-r1:32b") {
                    tier = .frontierReasoning
                } else if name.contains("14b") || name.contains("8b") {
                    tier = .balanced
                } else {
                    tier = .cheapFast
                }
                
                models.append(ModelInfo(
                    id: name,
                    displayName: "\(name) (Local Ollama)",
                    provider: .ollama,
                    tier: tier,
                    supportsVision: name.contains("vision") || name.contains("llava"),
                    supportsTools: true,
                    isLocal: true
                ))
            }
        }
        
        if models.isEmpty {
            models = [
                ModelInfo(id: "llama3.2:latest", displayName: "Llama 3.2 (Local)", provider: .ollama, tier: .cheapFast, supportsVision: false, supportsTools: true, isLocal: true)
            ]
        }
        
        updateState(connected: true, description: "Connected (\(models.count) local models)", models: models)
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
    
    public func generateCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String {
        guard let url = URL(string: "\(endpoint)/api/chat") else {
            throw NSError(domain: "OllamaProvider", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama endpoint URL."])
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var messages: [[String: Any]] = []
        if let system = systemPrompt {
            messages.append(["role": "system", "content": system])
        }
        
        var userMsg: [String: Any] = ["role": "user", "content": prompt]
        if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let base64 = jpeg.base64EncodedString()
            userMsg["images"] = [base64]
        }
        messages.append(userMsg)
        
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Ollama error"
            throw NSError(domain: "OllamaProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Ollama Error: \(msg)"])
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        
        return "Completed without response text."
    }
    
    public func disconnect() {
        lock.lock()
        _isConnected = false
        _statusDescription = "Disconnected"
        _discoveredModels = []
        lock.unlock()
    }
}
