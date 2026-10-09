import Foundation
import AppKit

/// Information regarding official Claude Code CLI authentication status.
public struct ClaudeAuthStatus: Sendable, Equatable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let email: String?
    public let subscriptionType: String?
    public let rawDetails: String?
    
    public init(
        loggedIn: Bool,
        authMethod: String? = nil,
        email: String? = nil,
        subscriptionType: String? = nil,
        rawDetails: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.subscriptionType = subscriptionType
        self.rawDetails = rawDetails
    }
}

/// Errors occurring during Claude Code CLI or ACP communication.
public enum ClaudeCodeError: Error, LocalizedError, Sendable, Equatable {
    case notSignedIn
    case runtimeNotFound(String)
    case authCancelled
    case authTimeout
    case authFailed(String)
    case invalidResponse(String)
    case promptRefused(String)
    
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Claude Code is not signed in. Please sign in with your Anthropic Claude account."
        case .runtimeNotFound(let details):
            return "Claude Code runtime not found: \(details)"
        case .authCancelled:
            return "Claude sign-in was cancelled."
        case .authTimeout:
            return "Claude sign-in timed out."
        case .authFailed(let details):
            return "Claude sign-in failed: \(details)"
        case .invalidResponse(let msg):
            return "Invalid Claude response: \(msg)"
        case .promptRefused(let reason):
            return "Claude refused the prompt: \(reason)"
        }
    }
}

private final class SingleResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>
    
    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }
    
    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
    
    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}

private final class AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    
    init(_ value: T) {
        self._value = value
    }
    
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    
    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        self._value = newValue
    }
}

private final class NonblockingPipeDrainer: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let fd: Int32
    private let maxBytes: Int
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var buffer = Data()
    private var isClosed = false
    private var hasStarted = false
    private let eofGroup = DispatchGroup()
    
    init(fileHandle: FileHandle, maxBytes: Int = 512 * 1024, label: String) {
        self.fileHandle = fileHandle
        let rawFd = fileHandle.fileDescriptor
        self.fd = rawFd
        self.maxBytes = maxBytes
        self.queue = DispatchQueue(label: "com.pinebot.drainer.\(label)", qos: .userInitiated)
        
        let flags = fcntl(rawFd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(rawFd, F_SETFL, flags | O_NONBLOCK)
        }
    }
    
    func start() {
        lock.lock()
        guard !hasStarted, !isClosed else {
            lock.unlock()
            return
        }
        hasStarted = true
        eofGroup.enter()
        
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = readSource
        
        var tempBuffer = [UInt8](repeating: 0, count: 4096)
        
        readSource.setEventHandler { [weak self, weak readSource] in
            guard let self = self else { return }
            while true {
                let bytesRead = tempBuffer.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return read(self.fd, base, 4096)
                }
                
                if bytesRead > 0 {
                    self.lock.lock()
                    if self.buffer.count < self.maxBytes {
                        let allowed = min(bytesRead, self.maxBytes - self.buffer.count)
                        self.buffer.append(tempBuffer, count: allowed)
                    }
                    self.lock.unlock()
                } else if bytesRead == 0 {
                    // EOF event calls source.cancel
                    readSource?.cancel()
                    break
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        break
                    } else if err == EINTR {
                        continue
                    } else {
                        // Error on read -> cancel source
                        readSource?.cancel()
                        break
                    }
                }
            }
        }
        
        readSource.setCancelHandler { [weak self, fileHandle] in
            // DispatchSource cancel handler on the same serial read queue is the ONLY place calling fileHandle.close() after in-flight reads finish.
            try? fileHandle.close()
            guard let self = self else { return }
            self.lock.lock()
            let alreadyClosed = self.isClosed
            self.isClosed = true
            self.lock.unlock()
            if !alreadyClosed {
                self.eofGroup.leave()
            }
        }
        
        lock.unlock()
        readSource.resume()
    }
    
    func cancelWithoutSync() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if !hasStarted {
            // Explicit pre-start/early-cancel paths close original wrapper exactly once when no source exists.
            isClosed = true
            lock.unlock()
            try? fileHandle.close()
            return
        }
        let src = source
        lock.unlock()
        // Abort must request cancellation without queue sync/EOF wait
        src?.cancel()
    }
    
    func collectWithGrace(timeoutMs: Int = 100) -> Data {
        _ = eofGroup.wait(timeout: .now() + .milliseconds(timeoutMs))
        cancelWithoutSync()
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
    
    func cancelImmediately() -> Data {
        cancelWithoutSync()
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

private struct AuthProcessResult: Sendable {
    let epoch: UUID
    let exitCode: Int32
    let stdoutData: Data
    let stderrData: Data
}

private final class AuthProcessOperation: @unchecked Sendable {
    let id: UUID
    let process: Process
    let resumer: SingleResumer<AuthProcessResult>
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutDrainer: NonblockingPipeDrainer
    private let stderrDrainer: NonblockingPipeDrainer
    private var deadlineTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var isTerminated = false
    
    init(
        id: UUID,
        process: Process,
        resumer: SingleResumer<AuthProcessResult>,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutDrainer: NonblockingPipeDrainer,
        stderrDrainer: NonblockingPipeDrainer
    ) {
        self.id = id
        self.process = process
        self.resumer = resumer
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdoutDrainer = stdoutDrainer
        self.stderrDrainer = stderrDrainer
    }
    
    func start(timeout: TimeInterval) throws {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return
        }
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.handleDeadlineTimeout()
        }
        self.deadlineTimer = timer
        timer.resume()
        
        stdoutDrainer.start()
        stderrDrainer.start()
        
        process.terminationHandler = { [weak self] p in
            self?.handleProcessTermination(exitCode: p.terminationStatus)
        }
        
        do {
            try process.run()
            lock.unlock()
        } catch {
            isTerminated = true
            deadlineTimer?.cancel()
            deadlineTimer = nil
            lock.unlock()
            
            _ = stdoutDrainer.cancelImmediately()
            _ = stderrDrainer.cancelImmediately()
            closeWritePipes()
            resumer.resume(throwing: ClaudeCodeError.authFailed(error.localizedDescription))
            throw error
        }
    }
    
    private func handleDeadlineTimeout() {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return
        }
        isTerminated = true
        deadlineTimer?.cancel()
        deadlineTimer = nil
        lock.unlock()
        
        // Signal owned process FIRST and schedule kill
        signalAndEscalate()
        
        // Reader cancellation closes fd without waiting on EOF
        _ = stdoutDrainer.cancelImmediately()
        _ = stderrDrainer.cancelImmediately()
        closeWritePipes()
        
        resumer.resume(throwing: ClaudeCodeError.authTimeout)
    }
    
    private func handleProcessTermination(exitCode: Int32) {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return
        }
        isTerminated = true
        deadlineTimer?.cancel()
        deadlineTimer = nil
        lock.unlock()
        
        // Normal exit: bounded drain grace so final JSON is retained
        let stdoutData = stdoutDrainer.collectWithGrace(timeoutMs: 100)
        let stderrData = stderrDrainer.collectWithGrace(timeoutMs: 100)
        closeWritePipes()
        
        resumer.resume(returning: AuthProcessResult(
            epoch: id,
            exitCode: exitCode,
            stdoutData: stdoutData,
            stderrData: stderrData
        ))
    }
    
    func abort(reason: Error = CancellationError()) {
        lock.lock()
        guard !isTerminated else {
            lock.unlock()
            return
        }
        isTerminated = true
        deadlineTimer?.cancel()
        deadlineTimer = nil
        lock.unlock()
        
        // Signal owned process FIRST and schedule kill
        signalAndEscalate()
        
        // Reader cancellation closes fd without waiting on EOF
        _ = stdoutDrainer.cancelImmediately()
        _ = stderrDrainer.cancelImmediately()
        closeWritePipes()
        
        // Immediately resume continuation with abort reason
        resumer.resume(throwing: reason)
    }
    
    private func signalAndEscalate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate() // SIGTERM
        
        // Bounded escalation: if process does not exit within 250ms, send SIGKILL
        DispatchQueue.global(qos: .utility).async { [process] in
            let gracePeriodUs: useconds_t = 250_000 // 250ms
            usleep(gracePeriodUs)
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
    
    private func closeWritePipes() {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }
}

/// Manages an official Claude Code ACP session and CLI authentication lifecycle.
/// Strictly enforces compliance: end user signs into unmodified official Claude Code binary.
/// Zero custom OAuth, zero token extraction, zero private endpoint calls.
public actor ClaudeCodeSession {
    private let runtimeLocator: ClaudeRuntimeLocating
    private var transport: ACPTransportProtocol
    
    public private(set) var isInitialized: Bool = false
    public private(set) var isAuthenticated: Bool = false
    public private(set) var authEmail: String? = nil
    public private(set) var authMethod: String? = nil
    public private(set) var activeSessionId: String? = nil
    public private(set) var currentModelId: String? = nil
    public private(set) var availableModels: [ModelInfo] = []
    public private(set) var configOptions: [JSONValue] = []
    public private(set) var modelConfigId: String? = nil
    public private(set) var agentSupportsVision: Bool = true
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
    
    // Single owned AuthProcessOperation and epoch
    private var activeAuthOperation: AuthProcessOperation? = nil
    private var activeAuthEpoch: UUID = UUID()
    
    public func setOnModelsUpdatedHandler(_ handler: (@Sendable ([ModelInfo], String?) -> Void)?) {
        self.onModelsUpdatedHandler = handler
    }
    
    public var turnActive: Bool {
        return isTurnActive
    }
    
    public var isPromptBusy: Bool {
        return isTurnActive || isCancelling || isClosing
    }
    
    public var isLoginInProgress: Bool {
        return activeAuthOperation != nil
    }
    
    public init(
        runtimeLocator: ClaudeRuntimeLocating = ClaudeCodeRuntimeLocator(),
        transport: ACPTransportProtocol? = nil
    ) {
        self.runtimeLocator = runtimeLocator
        self.transport = transport ?? ACPTransport()
    }
    
    private func waitForCloseToFinish() async {
        while isClosing {
            await withCheckedContinuation { continuation in
                closeWaiters.append(continuation)
            }
        }
    }
    
    // MARK: - Unified Auth Process Runner
    
    private func runAuthProcess(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> AuthProcessResult {
        // Guard cancellation before launch
        try Task.checkCancellation()
        
        guard let claudeURL = runtimeLocator.locateClaudeCLI() else {
            throw ClaudeCodeError.runtimeNotFound("Cannot locate official Claude Code CLI executable.")
        }
        
        // Invalidate any previous auth operation
        if let existing = activeAuthOperation {
            existing.abort(reason: ClaudeCodeError.authCancelled)
            activeAuthOperation = nil
        }
        
        let epoch = UUID()
        self.activeAuthEpoch = epoch
        
        // Defer cleanup placed BEFORE throwing await
        defer {
            if self.activeAuthEpoch == epoch {
                self.activeAuthOperation = nil
            }
        }
        
        let proc = Process()
        proc.executableURL = claudeURL
        proc.arguments = arguments
        
        var env = ProcessInfo.processInfo.environment
        var extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin")
        ]
        if let nodeURL = runtimeLocator.locateNode() {
            extraPaths.insert(nodeURL.deletingLastPathComponent().path, at: 0)
        }
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        proc.environment = env
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        
        let stdoutDrainer = NonblockingPipeDrainer(
            fileHandle: stdoutPipe.fileHandleForReading,
            label: "stdout-\(epoch.uuidString)"
        )
        let stderrDrainer = NonblockingPipeDrainer(
            fileHandle: stderrPipe.fileHandleForReading,
            label: "stderr-\(epoch.uuidString)"
        )
        
        let box = AtomicBox<AuthProcessOperation?>(nil)
        let cancelLatch = AtomicBox<Bool>(false)
        
        let result: AuthProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumer = SingleResumer(continuation: continuation)
                
                if cancelLatch.value || Task.isCancelled {
                    resumer.resume(throwing: CancellationError())
                    return
                }
                
                let op = AuthProcessOperation(
                    id: epoch,
                    process: proc,
                    resumer: resumer,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe,
                    stdoutDrainer: stdoutDrainer,
                    stderrDrainer: stderrDrainer
                )
                box.set(op)
                self.activeAuthOperation = op
                
                if cancelLatch.value {
                    op.abort(reason: CancellationError())
                    return
                }
                
                do {
                    try op.start(timeout: timeout)
                } catch {
                    // Start failure handled via SingleResumer inside AuthProcessOperation.start
                }
            }
        } onCancel: {
            cancelLatch.set(true)
            if let op = box.value {
                op.abort(reason: CancellationError())
            }
        }
        
        // Guard cancellation and epoch before caller processes result
        try Task.checkCancellation()
        guard self.activeAuthEpoch == epoch else {
            throw ClaudeCodeError.authCancelled
        }
        
        return result
    }
    
    // MARK: - Official CLI Auth Status & Login
    
    /// Checks authentication state via official `claude auth status --json`.
    /// Never parses, stores, or logs secret tokens.
    public func checkOfficialAuthStatus(timeout: TimeInterval = 5.0) async throws -> ClaudeAuthStatus {
        let result = try await runAuthProcess(arguments: ["auth", "status", "--json"], timeout: timeout)
        
        let decoder = JSONDecoder()
        let status: ClaudeAuthStatus
        if let json = try? decoder.decode(JSONValue.self, from: result.stdoutData) {
            let loggedIn = json["loggedIn"]?.boolValue ?? false
            let method = json["authMethod"]?.stringValue
            let email = json["email"]?.stringValue
            let subType = json["subscriptionType"]?.stringValue
            status = ClaudeAuthStatus(
                loggedIn: loggedIn,
                authMethod: method,
                email: email,
                subscriptionType: subType,
                rawDetails: nil
            )
        } else {
            status = ClaudeAuthStatus(loggedIn: false)
        }
        
        // Guard status mutation against cancellation or superseded epoch
        try Task.checkCancellation()
        guard !Task.isCancelled, self.activeAuthEpoch == result.epoch else {
            throw CancellationError()
        }
        
        self.isAuthenticated = status.loggedIn
        if status.loggedIn {
            self.authEmail = status.email
            self.authMethod = status.authMethod
        } else {
            self.authEmail = nil
            self.authMethod = nil
        }
        return status
    }
    
    /// Spawns official `claude auth login` in the browser with cancelable task/process UUID and timeout.
    /// User confirms login in their browser; Pinebot never intercepts credentials.
    public func startOfficialLogin(
        timeout: TimeInterval = 180.0,
        onStatusUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> ClaudeAuthStatus {
        guard activeAuthOperation == nil else {
            throw ClaudeCodeError.authFailed("A Claude sign-in flow is already in progress.")
        }
        
        onStatusUpdate?("Opening official Claude login in browser...")
        
        let result = try await runAuthProcess(arguments: ["auth", "login"], timeout: timeout)
        
        guard self.activeAuthEpoch == result.epoch else {
            throw ClaudeCodeError.authCancelled
        }
        
        guard result.exitCode == 0 else {
            let errSnippet = String(data: result.stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ClaudeCodeError.authFailed("Claude login process exited with code \(result.exitCode)\(errSnippet.isEmpty ? "" : ": " + errSnippet)")
        }
        
        onStatusUpdate?("Verifying authentication status...")
        let status = try await checkOfficialAuthStatus()
        guard status.loggedIn else {
            throw ClaudeCodeError.authFailed("Claude login completed but auth status indicates not logged in.")
        }
        
        onStatusUpdate?("Successfully signed in to Claude.")
        return status
    }
    
    /// Cancels any in-flight official login process.
    public func cancelLogin() {
        self.activeAuthEpoch = UUID()
        if let op = activeAuthOperation {
            op.abort(reason: ClaudeCodeError.authCancelled)
            self.activeAuthOperation = nil
        }
    }
    
    // MARK: - ACP Lifecycle & Session Handshake
    
    /// Starts the ACP transport process and performs initialize handshake.
    @discardableResult
    public func startAndInitialize() async throws -> JSONValue {
        if isClosing {
            await waitForCloseToFinish()
        }
        
        let running = await transport.isRunning
        if !running {
            // If transport is standard ACPTransport without custom launch configuration, configure it
            if transport is ACPTransport {
                // If custom transport has not yet started, create an ACPTransport configured for claude-agent-acp
                if let locations = try? runtimeLocator.locateRuntime() {
                    let launchConfig: LaunchConfiguration
                    var envAdditions: [String: String] = [
                        "CLAUDE_CODE_EXECUTABLE": locations.claudeCLIURL.path
                    ]
                    if let nodeURL = locations.nodeURL {
                        let nodeBinDir = nodeURL.deletingLastPathComponent().path
                        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                        envAdditions["PATH"] = "\(nodeBinDir):\(currentPath)"
                    }
                    let isJS = locations.acpAdapterURL.path.hasSuffix(".js") || locations.acpAdapterURL.path.contains("dist/index.js")
                    if isJS, let node = locations.nodeURL {
                        launchConfig = LaunchConfiguration(
                            executableURL: node,
                            arguments: [locations.acpAdapterURL.path],
                            workingDirectory: locations.workingDirectory,
                            environmentAdditions: envAdditions
                        )
                    } else {
                        launchConfig = LaunchConfiguration(
                            executableURL: locations.acpAdapterURL,
                            arguments: [],
                            workingDirectory: locations.workingDirectory,
                            environmentAdditions: envAdditions
                        )
                    }
                    self.transport = ACPTransport(launchConfiguration: launchConfig)
                }
            }
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
        
        if let promptCaps = result["agentCapabilities"]?["promptCapabilities"] {
            self.agentSupportsVision = promptCaps["image"]?.boolValue ?? true
        } else {
            self.agentSupportsVision = true
        }
        
        if let sessionCaps = result["agentCapabilities"]?["sessionCapabilities"] {
            self.agentSupportsSessionClose = sessionCaps["close"] != nil
        } else {
            self.agentSupportsSessionClose = false
        }
        
        self.isInitialized = true
        return result
    }
    
    /// Creates a new ACP session and derives actual models from agent configOptions / models.
    /// Never invents a static catalog.
    @discardableResult
    public func createNewSession(cwd: String? = nil) async throws -> [ModelInfo] {
        if isClosing {
            await waitForCloseToFinish()
        }
        if !isInitialized {
            _ = try await startAndInitialize()
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
        
        // 1. Official ACP configOptions (standard for claude-agent-acp)
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
        
        // 2. Fallback to models.availableModels if present
        if parsedModels.isEmpty,
           let modelsState = result["models"],
           let rawModels = modelsState["availableModels"]?.arrayValue {
            for m in rawModels {
                guard let modelId = m["modelId"]?.stringValue else { continue }
                let name = m["name"]?.stringValue ?? modelId
                let tier: ModelTier
                if modelId.contains("opus") || modelId.contains("3-7") || modelId.contains("sonnet") {
                    tier = .frontierReasoning
                } else if modelId.contains("haiku") {
                    tier = .cheapFast
                } else {
                    tier = .balanced
                }
                
                parsedModels.append(ModelInfo(
                    id: modelId,
                    displayName: name,
                    provider: .claude,
                    tier: tier,
                    supportsVision: true,
                    supportsTools: true
                ))
            }
            if let curModel = modelsState["currentModelId"]?.stringValue {
                self.currentModelId = curModel
            }
        }
        
        guard !parsedModels.isEmpty else {
            throw ACPError.invalidMessage(
                "Claude Code returned no available models. Ensure your Anthropic Claude account is active."
            )
        }
        
        if currentModelId == nil {
            currentModelId = parsedModels.first?.id
        }
        
        self.availableModels = parsedModels
        return parsedModels
    }
    
    /// Parses models and current selection from the ACP configOptions array.
    private func parseModelsFromConfigOptions(_ rawOptions: [JSONValue]) -> (models: [ModelInfo], currentModelId: String?, configId: String)? {
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
                if let groupOptions = item["options"]?.arrayValue {
                    for opt in groupOptions {
                        guard let val = opt["value"]?.stringValue else { continue }
                        let name = opt["name"]?.stringValue ?? opt["displayName"]?.stringValue ?? val
                        let tier: ModelTier
                        if val.contains("opus") || val.contains("3-7") || val.contains("sonnet") {
                            tier = .frontierReasoning
                        } else if val.contains("haiku") {
                            tier = .cheapFast
                        } else {
                            tier = .balanced
                        }
                        models.append(ModelInfo(
                            id: val,
                            displayName: name,
                            provider: .claude,
                            tier: tier,
                            supportsVision: true,
                            supportsTools: true
                        ))
                    }
                } else {
                    guard let val = item["value"]?.stringValue else { continue }
                    let name = item["name"]?.stringValue ?? item["displayName"]?.stringValue ?? val
                    let tier: ModelTier
                    if val.contains("opus") || val.contains("3-7") || val.contains("sonnet") {
                        tier = .frontierReasoning
                    } else if val.contains("haiku") {
                        tier = .cheapFast
                    } else {
                        tier = .balanced
                    }
                    models.append(ModelInfo(
                        id: val,
                        displayName: name,
                        provider: .claude,
                        tier: tier,
                        supportsVision: true,
                        supportsTools: true
                    ))
                }
            }
        }
        
        return (models: models, currentModelId: currentVal, configId: configId)
    }
    
    /// Switches the active session model and verifies authoritative selection.
    public func setSessionModel(_ modelId: String) async throws {
        guard let sessionId = activeSessionId else {
            throw ACPError.invalidMessage("No active Claude ACP session.")
        }
        
        if currentModelId == modelId {
            return
        }
        
        if let configId = modelConfigId {
            let params: JSONValue = [
                "sessionId": .string(sessionId),
                "configId": .string(configId),
                "value": .string(modelId)
            ]
            let result = try await transport.sendRequest(method: "session/set_config_option", params: params, timeout: 15.0)
            
            if let rawOptions = result["configOptions"]?.arrayValue,
               let parsed = parseModelsFromConfigOptions(rawOptions) {
                self.availableModels = parsed.models
                self.modelConfigId = parsed.configId
                if let authoritative = parsed.currentModelId {
                    guard authoritative == modelId else {
                        self.currentModelId = authoritative
                        self.onModelsUpdatedHandler?(self.availableModels, authoritative)
                        throw ACPError.requestFailed(
                            code: -32000,
                            message: "Model selection mismatch: requested '\(modelId)', but Claude agent selected '\(authoritative)'.",
                            data: nil
                        )
                    }
                    self.currentModelId = authoritative
                } else {
                    self.currentModelId = modelId
                }
            } else {
                self.currentModelId = modelId
            }
        } else {
            let params: JSONValue = [
                "sessionId": .string(sessionId),
                "modelId": .string(modelId)
            ]
            _ = try await transport.sendRequest(method: "session/set_model", params: params, timeout: 15.0)
            self.currentModelId = modelId
        }
        
        self.onModelsUpdatedHandler?(self.availableModels, self.currentModelId)
    }
    
    // MARK: - Prompt Execution & Streaming
    
    /// Sends a prompt turn to Claude Code and streams text chunks.
    public func sendPrompt(
        text: String,
        model: String,
        image: NSImage? = nil,
        timeout: TimeInterval = 120.0,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard !isClosing else {
            throw ACPError.requestFailed(code: -32000, message: "Cannot launch prompt turn: session is currently closing.", data: nil)
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
            throw ACPError.invalidMessage("No active Claude ACP session.")
        }
        
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
                // Cancellation cleanly handled by defer
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
            throw ACPError.requestFailed(code: -32001, message: "Claude refused prompt", data: nil)
        case "max_turn_requests", "max_tokens":
            return promptBuffer
        default:
            throw ACPError.requestFailed(code: -32000, message: "Unexpected stopReason: \(stopReason)", data: nil)
        }
    }
    
    /// Cancels the currently active prompt turn without disconnecting the user.
    public func cancelCurrentPrompt(timeout: TimeInterval = 5.0) async throws {
        if isClosing { return }
        guard let sessionId = activeSessionId, isTurnActive else { return }
        if isCancelling { return }
        
        let turnId = self.activeTurnId
        isCancelling = true
        self.onChunkHandler = nil
        
        cancelTimeoutTask?.cancel()
        cancelTimeoutTask = Task { [weak self, turnId] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.handleCancelDeadlineExpired(turnId: turnId)
        }
        
        try await transport.sendNotification(
            method: "session/cancel",
            params: ["sessionId": .string(sessionId)]
        )
        
        await withCheckedContinuation { continuation in
            if !self.isTurnActive {
                continuation.resume()
            } else {
                self.cancelWaiterContinuation = continuation
            }
        }
    }
    
    private func handleCancelDeadlineExpired(turnId: UUID?) async {
        guard self.isTurnActive, self.activeTurnId == turnId, !self.isClosing else { return }
        await close()
    }
    
    private func handlePromptTaskCancellation(turnId: UUID) async {
        guard self.isTurnActive, self.activeTurnId == turnId, !self.isClosing else { return }
        await close()
    }
    
    /// Shuts down the transport and clears session state without modifying saved user credentials.
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
        
        isTurnActive = false
        activeTurnId = nil
        isInitialized = false
        availableModels = []
        currentModelId = nil
        configOptions = []
        modelConfigId = nil
        promptBuffer = ""
        
        let waiter = cancelWaiterContinuation
        cancelWaiterContinuation = nil
        waiter?.resume()
        
        isClosing = false
        
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
        
        guard isTurnActive && !isCancelling && !isClosing else { return }
        if updateType == "agent_message_chunk" {
            if let content = update["content"],
               let text = content["text"]?.stringValue {
                promptBuffer.append(text)
                onChunkHandler?(text)
            }
        }
    }
    
    private func applyConfigOptionsUpdate(_ rawOptions: [JSONValue]) {
        self.configOptions = rawOptions
        if let parsed = parseModelsFromConfigOptions(rawOptions) {
            self.availableModels = parsed.models
            self.modelConfigId = parsed.configId
            if let current = parsed.currentModelId {
                self.currentModelId = current
            }
            self.onModelsUpdatedHandler?(self.availableModels, self.currentModelId)
        } else {
            self.availableModels = []
            self.currentModelId = nil
            self.modelConfigId = nil
            self.onModelsUpdatedHandler?([], nil)
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
        return nil
    }
}
