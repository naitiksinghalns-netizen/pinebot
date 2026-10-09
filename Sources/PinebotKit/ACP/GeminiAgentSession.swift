import Foundation
import AppKit

/// Manages an ACP (Agent Client Protocol) session lifecycle for the Google Gemini agent.
/// Handles initialize, authenticate (oauth-personal), session creation, model selection, prompt streaming, and cancellation.
public actor GeminiAgentSession {
    private let transport: ACPTransportProtocol
    
    public private(set) var isInitialized: Bool = false
    public private(set) var isAuthenticated: Bool = false
    public private(set) var activeSessionId: String? = nil
    public private(set) var currentModelId: String? = nil
    public private(set) var availableModels: [ModelInfo] = []
    public private(set) var configOptions: [JSONValue] = []
    public private(set) var modelConfigId: String? = nil
    public private(set) var supportedAuthMethods: [String] = []
    
    public private(set) var agentSupportsVision: Bool = false
    public private(set) var agentSupportsSessionClose: Bool = false
    
    private var isTurnActive: Bool = false
    private var activeTurnId: UUID? = nil
    private var isCancelling: Bool = false
    private var isClosing: Bool = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentPromptGeneration: Int = 0
    private var cancelWaiterContinuation: CheckedContinuation<Void, Never>?
    private var cancelTimeoutTask: Task<Void, Never>?
    private var promptBuffer: String = ""
    private var onChunkHandler: (@Sendable (String) -> Void)?
    private var onModelsUpdatedHandler: (@Sendable ([ModelInfo], String?) -> Void)?
    
    public func setOnModelsUpdatedHandler(_ handler: (@Sendable ([ModelInfo], String?) -> Void)?) {
        self.onModelsUpdatedHandler = handler
    }
    
    public var turnActive: Bool {
        return isTurnActive
    }
    
    public var isPromptBusy: Bool {
        return isTurnActive || isCancelling || isClosing
    }
    
    public var closing: Bool {
        return isClosing
    }
    
    private func waitForCloseToFinish() async {
        while isClosing {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
        }
    }
    
    public init(transport: ACPTransportProtocol = ACPTransport()) {
        self.transport = transport
    }
    
    /// Starts the transport and completes the ACP `initialize` handshake.
    @discardableResult
    public func startAndInitialize() async throws -> JSONValue {
        if isClosing {
            await waitForCloseToFinish()
        }
        let running = await transport.isRunning
        if !running {
            try await transport.start()
        }
        
        await transport.setRequestHandler { [weak self] id, method, params in
            guard let self = self else { return nil }
            return await self.handleAgentRequest(id: id, method: method, params: params)
        }
        
        await transport.setNotificationHandler { [weak self] method, params in
            guard let self = self else { return }
            await self.handleAgentNotification(method: method, params: params)
        }
        
        let initParams: JSONValue = [
            "protocolVersion": 1,
            "clientInfo": [
                "name": "Pinebot",
                "title": "Pinebot Desktop Companion",
                "version": "1.0.0"
            ],
            "clientCapabilities": [
                "auth": ["terminal": false],
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false
            ]
        ]
        
        let result = try await transport.sendRequest(method: "initialize", params: initParams, timeout: 15.0)
        
        // 1. Inspect supported auth methods
        if let methods = result["authMethods"]?.arrayValue {
            self.supportedAuthMethods = methods.compactMap { $0["id"]?.stringValue }
        }
        
        // 2. Capture vision capability
        if let promptCaps = result["agentCapabilities"]?["promptCapabilities"] {
            self.agentSupportsVision = promptCaps["image"]?.boolValue ?? false
        } else {
            self.agentSupportsVision = false
        }
        
        // 3. Capture close session capability
        if let sessionCaps = result["agentCapabilities"]?["sessionCapabilities"] {
            self.agentSupportsSessionClose = sessionCaps["close"] != nil
        } else {
            self.agentSupportsSessionClose = false
        }
        
        self.isInitialized = true
        return result
    }
    
    /// Performs authentication via ACP. Validates that the requested method is advertised by the CLI.
    public func authenticate(
        methodId: String = "oauth-personal",
        apiKey: String? = nil,
        timeout: TimeInterval = 180.0,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws {
        if isClosing {
            await waitForCloseToFinish()
        }
        if !isInitialized {
            _ = try await startAndInitialize()
        }
        
        guard supportedAuthMethods.contains(methodId) else {
            throw ACPError.requestFailed(
                code: -32000,
                message: "Authentication method '\(methodId)' is not supported by Gemini CLI. Available methods: \(supportedAuthMethods.joined(separator: ", "))",
                data: nil
            )
        }
        
        onStatusUpdate?("Connecting to Google authentication...")
        
        var authObj: [String: JSONValue] = ["methodId": .string(methodId)]
        if let key = apiKey, !key.isEmpty {
            authObj["_meta"] = ["api-key": .string(key)]
        }
        
        if methodId == "oauth-personal" {
            onStatusUpdate?("Waiting for Google sign-in in browser...")
        } else {
            onStatusUpdate?("Verifying credentials with Google...")
        }
        
        _ = try await transport.sendRequest(method: "authenticate", params: .object(authObj), timeout: timeout)
        
        self.isAuthenticated = true
        onStatusUpdate?("Successfully authenticated with Google.")
    }
    
    /// Creates a new ACP session and discovers the available Gemini models.
    /// Strictly derives models from metadata without invented fallbacks.
    @discardableResult
    public func createNewSession(cwd: String? = nil) async throws -> [ModelInfo] {
        if isClosing {
            await waitForCloseToFinish()
        }
        if !isAuthenticated {
            try await authenticate()
        }
        
        let sessionParams: JSONValue = [
            "cwd": .string(cwd ?? FileManager.default.temporaryDirectory.path),
            "mcpServers": .array([])
        ]
        
        let result = try await transport.sendRequest(method: "session/new", params: sessionParams, timeout: 30.0)
        
        guard let sessionId = result["sessionId"]?.stringValue else {
            throw ACPError.invalidMessage("session/new response missing 'sessionId'")
        }
        self.activeSessionId = sessionId
        
        var parsedModels: [ModelInfo] = []
        
        // 1. Modern official ACP: session configOptions
        if let rawConfigOptions = result["configOptions"]?.arrayValue {
            self.configOptions = rawConfigOptions
            if let parsed = parseModelsFromConfigOptions(rawConfigOptions) {
                parsedModels = parsed.models
                self.modelConfigId = parsed.configId
                if let cur = parsed.currentModelId {
                    self.currentModelId = cur
                }
            }
        }
        
        // 2. Legacy ACP: models.availableModels fallback
        if parsedModels.isEmpty,
           let modelsState = result["models"],
           let rawModels = modelsState["availableModels"]?.arrayValue {
            for m in rawModels {
                guard let modelId = m["modelId"]?.stringValue else { continue }
                let name = m["name"]?.stringValue ?? modelId
                
                let tier: ModelTier
                if modelId.contains("pro") {
                    tier = .frontierReasoning
                } else if modelId.contains("flash") {
                    tier = .cheapFast
                } else {
                    tier = .balanced
                }
                
                parsedModels.append(ModelInfo(
                    id: modelId,
                    displayName: name,
                    provider: .gemini,
                    tier: tier,
                    supportsVision: self.agentSupportsVision,
                    supportsTools: false // Tools false until computer task executor integration
                ))
            }
            if let curModel = modelsState["currentModelId"]?.stringValue {
                self.currentModelId = curModel
            }
        }
        
        guard !parsedModels.isEmpty else {
            throw ACPError.invalidMessage(
                "Gemini CLI returned no available models. Ensure your Google account has active Gemini access or re-authenticate."
            )
        }
        
        if currentModelId == nil {
            currentModelId = parsedModels.first?.id
        }
        
        self.availableModels = parsedModels
        return parsedModels
    }
    
    /// Parses models and current selection from the official ACP configOptions array.
    /// Supports both flat option lists and grouped option lists (ConfigOptionGroup).
    private func parseModelsFromConfigOptions(_ rawOptions: [JSONValue]) -> (models: [ModelInfo], currentModelId: String?, configId: String)? {
        // Find option with (category == "model" or id == "model") AND advertised type == "select" AND valid non-empty id
        guard let modelOption = rawOptions.first(where: { opt in
            let isModelCategoryOrId = (opt["category"]?.stringValue == "model" || opt["id"]?.stringValue == "model")
            let isSelectType = opt["type"]?.stringValue == "select"
            let hasValidId = opt["id"]?.stringValue.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            return isModelCategoryOrId && isSelectType && hasValidId
        }),
        let configId = modelOption["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !configId.isEmpty else {
            return nil
        }
        
        let currentVal = modelOption["currentValue"]?.stringValue
        var models: [ModelInfo] = []
        
        if let optionsArr = modelOption["options"]?.arrayValue {
            for item in optionsArr {
                // Grouped options (ConfigOptionGroup: has "group" and nested "options" array)
                if let groupOptions = item["options"]?.arrayValue {
                    for opt in groupOptions {
                        guard let val = opt["value"]?.stringValue else { continue }
                        let name = opt["name"]?.stringValue ?? val
                        let tier: ModelTier
                        if val.contains("pro") {
                            tier = .frontierReasoning
                        } else if val.contains("flash") {
                            tier = .cheapFast
                        } else {
                            tier = .balanced
                        }
                        models.append(ModelInfo(
                            id: val,
                            displayName: name,
                            provider: .gemini,
                            tier: tier,
                            supportsVision: self.agentSupportsVision,
                            supportsTools: false
                        ))
                    }
                } else {
                    // Flat option (ConfigOptionValue: has "value" and "name")
                    guard let val = item["value"]?.stringValue else { continue }
                    let name = item["name"]?.stringValue ?? val
                    let tier: ModelTier
                    if val.contains("pro") {
                        tier = .frontierReasoning
                    } else if val.contains("flash") {
                        tier = .cheapFast
                    } else {
                        tier = .balanced
                    }
                    models.append(ModelInfo(
                        id: val,
                        displayName: name,
                        provider: .gemini,
                        tier: tier,
                        supportsVision: self.agentSupportsVision,
                        supportsTools: false
                    ))
                }
            }
        }
        
        guard !models.isEmpty else { return nil }
        return (models, currentVal, configId)
    }
    
    private func applyConfigOptionsUpdate(_ rawOptions: [JSONValue]) {
        self.configOptions = rawOptions
        if let parsed = parseModelsFromConfigOptions(rawOptions) {
            self.availableModels = parsed.models
            self.modelConfigId = parsed.configId
            if let cur = parsed.currentModelId {
                self.currentModelId = cur
            }
        } else {
            // Full refresh removed model selector: clear old catalog
            self.availableModels = []
            self.modelConfigId = nil
            self.currentModelId = nil
        }
        self.onModelsUpdatedHandler?(self.availableModels, self.currentModelId)
    }
    
    /// Sets the active model on the session if it differs from current.
    /// Uses session/set_config_option for modern ACP, or session/set_model for legacy agents.
    public func setSessionModel(_ modelId: String) async throws {
        guard let sessionId = activeSessionId else {
            throw ACPError.invalidMessage("No active ACP session to set model.")
        }
        if currentModelId == modelId { return }
        
        if let configId = self.modelConfigId {
            // Modern ACP session-config-options method
            let params: JSONValue = [
                "sessionId": .string(sessionId),
                "configId": .string(configId),
                "value": .string(modelId)
            ]
            let res = try await transport.sendRequest(method: "session/set_config_option", params: params, timeout: 15.0)
            guard let updatedOptions = res["configOptions"]?.arrayValue else {
                throw ACPError.invalidMessage("Missing or malformed 'configOptions' array in session/set_config_option response.")
            }
            self.applyConfigOptionsUpdate(updatedOptions)
            
            // Require that the requested model was authoritatively selected
            guard self.currentModelId == modelId else {
                throw ACPError.requestFailed(
                    code: -32000,
                    message: "Model selection mismatch: requested '\(modelId)', but agent selected '\(self.currentModelId ?? "none")'.",
                    data: nil
                )
            }
        } else {
            // Legacy ACP method
            let params: JSONValue = [
                "sessionId": .string(sessionId),
                "modelId": .string(modelId)
            ]
            _ = try await transport.sendRequest(method: "session/set_model", params: params, timeout: 15.0)
            self.currentModelId = modelId
            self.onModelsUpdatedHandler?(self.availableModels, self.currentModelId)
        }
    }
    
    /// Sends a prompt to the active session with the selected model and streams the response back chunk-by-chunk.
    public func sendPrompt(
        text: String,
        model: String,
        image: NSImage? = nil,
        timeout: TimeInterval = 120.0,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard !isClosing else {
            throw ACPError.requestFailed(code: -32000, message: "Cannot launch prompt turn: session is currently closing/tearing down.", data: nil)
        }
        guard !isTurnActive else {
            throw ACPError.requestFailed(code: -32002, message: "A prompt turn is already active on this session.", data: nil)
        }
        isTurnActive = true
        let turnId = UUID()
        self.activeTurnId = turnId
        currentPromptGeneration += 1
        
        defer {
            if self.activeTurnId == turnId && !self.isClosing {
                self.isTurnActive = false
                self.isCancelling = false
                self.activeTurnId = nil
                self.onChunkHandler = nil
                self.cancelTimeoutTask?.cancel()
                self.cancelTimeoutTask = nil
                let waiter = self.cancelWaiterContinuation
                self.cancelWaiterContinuation = nil
                waiter?.resume()
            }
        }
        
        if activeSessionId == nil {
            _ = try await createNewSession()
        }
        guard let sessionId = activeSessionId else {
            throw ACPError.invalidMessage("No active ACP session.")
        }
        
        // Select model before prompt
        try await setSessionModel(model)
        
        var promptBlocks: [JSONValue] = []
        if let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            promptBlocks.append([
                "type": "image",
                "data": .string(jpeg.base64EncodedString()),
                "mimeType": "image/jpeg"
            ])
        }
        
        promptBlocks.append([
            "type": "text",
            "text": .string(text)
        ])
        
        promptBuffer = ""
        self.onChunkHandler = onChunk
        
        let promptParams: JSONValue = [
            "sessionId": .string(sessionId),
            "prompt": .array(promptBlocks)
        ]
        
        let result: JSONValue
        do {
            result = try await withTaskCancellationHandler {
                try await transport.sendRequest(method: "session/prompt", params: promptParams, timeout: timeout)
            } onCancel: {
                Task { [weak self] in
                    await self?.handlePromptTaskCancellation(turnId: turnId)
                }
            }
        } catch {
            if let acpErr = error as? ACPError, acpErr == .cancelled {
                // Genuine cancellation terminal reply, defer cleans up the turn cleanly without closing session
            } else if self.activeTurnId == turnId {
                await close()
            }
            throw error
        }
        
        guard let stopReason = result["stopReason"]?.stringValue else {
            throw ACPError.invalidMessage("Missing stopReason in session/prompt response: \(result)")
        }
        
        switch stopReason {
        case "end_turn":
            return promptBuffer
        case "cancelled":
            throw ACPError.cancelled
        case "refusal":
            throw ACPError.requestFailed(code: -32001, message: "Model refused prompt", data: nil)
        case "max_turn_requests", "max_tokens":
            return promptBuffer
        default:
            throw ACPError.requestFailed(code: -32000, message: "Unexpected stopReason: \(stopReason)", data: nil)
        }
    }
    
    /// Cancels the currently active prompt turn without deadlock.
    /// Holds cancelling/busy until terminal acknowledgement or deadline; closes session on timeout.
    public func cancelCurrentPrompt(timeout: TimeInterval = 5.0) async throws {
        if isClosing {
            return
        }
        guard let sessionId = activeSessionId, isTurnActive else { return }
        if isCancelling { return }
        
        let turnId = self.activeTurnId
        isCancelling = true
        self.onChunkHandler = nil
        
        // Spawn actor-owned deadline task to close session if agent hangs
        cancelTimeoutTask?.cancel()
        cancelTimeoutTask = Task { [weak self, turnId] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.handleCancelDeadlineExpired(turnId: turnId)
        }
        
        try await transport.sendNotification(
            method: "session/cancel",
            params: ["sessionId": .string(sessionId)]
        )
        
        // Suspend waiter without racing in a task group
        await withCheckedContinuation { continuation in
            if !self.isTurnActive || self.activeTurnId != turnId || self.isClosing {
                continuation.resume()
            } else {
                self.cancelWaiterContinuation = continuation
            }
        }
    }
    
    private func handleCancelDeadlineExpired(turnId: UUID?) async {
        guard self.isTurnActive, self.activeTurnId == turnId, !self.isClosing else { return }
        // Agent failed to acknowledge cancel within deadline: close session to terminate child
        await close()
    }
    
    private func handlePromptTaskCancellation(turnId: UUID) async {
        guard self.isTurnActive, self.activeTurnId == turnId, !self.isClosing else { return }
        await close()
    }
    
    /// Stops the session and shuts down the transport process.
    public func close() async {
        if isClosing {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
            return
        }
        isClosing = true
        isCancelling = false
        currentPromptGeneration += 1
        
        cancelTimeoutTask?.cancel()
        cancelTimeoutTask = nil
        onChunkHandler = nil
        
        let oldSessionId = activeSessionId
        activeSessionId = nil
        
        if let sessionId = oldSessionId {
            if agentSupportsSessionClose {
                _ = try? await transport.sendRequest(
                    method: "session/close",
                    params: ["sessionId": .string(sessionId)],
                    timeout: 2.0
                )
            } else {
                _ = try? await transport.sendNotification(
                    method: "session/cancel",
                    params: ["sessionId": .string(sessionId)]
                )
            }
        }
        
        await transport.stop()
        
        // Teardown is fully completed.
        isTurnActive = false
        activeTurnId = nil
        isInitialized = false
        isAuthenticated = false
        availableModels = []
        currentModelId = nil
        configOptions = []
        modelConfigId = nil
        promptBuffer = ""
        
        // ONLY release cancel waiter after stop completes
        let waiter = cancelWaiterContinuation
        cancelWaiterContinuation = nil
        waiter?.resume()
        
        isClosing = false
        
        // Resume any pending close waiters
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for w in waiters {
            w.resume()
        }
    }
    
    // MARK: - Internal Protocol Handlers
    
    private func handleAgentNotification(method: String, params: JSONValue) {
        guard method == "session/update" else { return }
        guard let sessionId = params["sessionId"]?.stringValue, sessionId == self.activeSessionId else { return }
        guard let update = params["update"] else { return }
        
        let updateType = update["sessionUpdate"]?.stringValue
        if updateType == "config_option_update" {
            if let rawOptions = update["configOptions"]?.arrayValue {
                self.applyConfigOptionsUpdate(rawOptions)
            }
            return
        }
        
        guard isTurnActive && !isCancelling && !isClosing else { return } // Reject late chunks when no turn is active or when cancelling or closing
        if updateType == "agent_message_chunk" {
            if let content = update["content"],
               let text = content["text"]?.stringValue {
                promptBuffer.append(text)
                onChunkHandler?(text)
            }
        }
    }
    
    private func handleAgentRequest(id: JSONRPCId, method: String, params: JSONValue?) -> JSONValue? {
        if method == "session/request_permission" {
            return [
                "outcome": [
                    "outcome": "cancelled"
                ]
            ]
        }
        // Returning nil instructs ACPTransport to return Method not found (-32601)
        return nil
    }
}
