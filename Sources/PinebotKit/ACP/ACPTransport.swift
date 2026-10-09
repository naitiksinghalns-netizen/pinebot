import Foundation
import AppKit

/// Protocol defining the interface for JSON-RPC 2.0 transport to the Gemini CLI agent.
public protocol ACPTransportProtocol: AnyObject, Sendable {
    func start() async throws
    func stop() async
    func sendRequest(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    func sendNotification(method: String, params: JSONValue?) async throws
    func sendResponse(id: JSONRPCId, result: JSONValue) async throws
    func sendError(id: JSONRPCId, error: JSONRPCError) async throws
    func setNotificationHandler(_ handler: (@Sendable (String, JSONValue) async -> Void)?) async
    func setRequestHandler(_ handler: (@Sendable (JSONRPCId, String, JSONValue?) async throws -> JSONValue?)?) async
    var isRunning: Bool { get async }
}

/// Errors occurring during ACP communication.
public enum ACPError: Error, LocalizedError, Sendable, Equatable {
    case processNotStarted
    case processAlreadyRunning
    case executableNotFound(String)
    case processTerminated(exitCode: Int32, stderr: String)
    case invalidMessage(String)
    case requestFailed(code: Int, message: String, data: JSONValue?)
    case timeout(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .processNotStarted:
            return "ACP process is not running."
        case .processAlreadyRunning:
            return "ACP process is already running."
        case .executableNotFound(let details):
            return "ACP agent executable not found: \(details)"
        case .processTerminated(let exitCode, let stderr):
            let snippet = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "ACP agent exited (code \(exitCode))\(snippet.isEmpty ? "" : ": " + snippet)"
        case .invalidMessage(let msg):
            return "Invalid JSON-RPC message: \(msg)"
        case .requestFailed(let code, let msg, _):
            return "ACP error \(code): \(msg)"
        case .timeout(let desc):
            return "ACP request timed out: \(desc)"
        case .cancelled:
            return "ACP operation was cancelled."
        }
    }
}

/// Configuration for launching an arbitrary ACP agent process via Foundation Process.
public struct LaunchConfiguration: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environmentAdditions: [String: String]
    
    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environmentAdditions: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentAdditions = environmentAdditions
    }
}

/// Manages child process lifecycle and bidirectional JSON-RPC 2.0 stdio communication
/// for official ACP agent processes.
public actor ACPTransport: ACPTransportProtocol {
    private enum LifecycleState {
        case stopped
        case starting
        case running
        case stopping
    }
    private var lifecycleState: LifecycleState = .stopped
    
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    
    private var consumerTask: Task<Void, Never>?
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var terminatedExitCode: Int32?
    private var eofFallbackTask: Task<Void, Never>?
    private var producerEofReceived: Bool = false
    
    private var processGeneration: Int = 0
    private var nextRequestId: Int = 1
    
    private struct PendingRequest {
        let id: JSONRPCId
        let continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>?
    }
    private var pendingRequests: [JSONRPCId: PendingRequest] = [:]
    
    private var notificationHandler: (@Sendable (String, JSONValue) async -> Void)?
    private var requestHandler: (@Sendable (JSONRPCId, String, JSONValue?) async throws -> JSONValue?)?
    
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var recentStderrLines: [String] = []
    private let maxRecentStderrLines = 30
    private let maxFrameSize = 10 * 1024 * 1024 // 10MB frame limit
    
    private let launchConfiguration: LaunchConfiguration?
    private let customExecutablePath: String?
    private let customArguments: [String]?
    
    public init(launchConfiguration: LaunchConfiguration? = nil) {
        self.launchConfiguration = launchConfiguration
        self.customExecutablePath = nil
        self.customArguments = nil
    }
    
    public init(executablePath: String? = nil, arguments: [String]? = nil) {
        self.launchConfiguration = nil
        self.customExecutablePath = executablePath
        self.customArguments = arguments
    }
    
    public var isRunning: Bool {
        return lifecycleState == .running && process?.isRunning == true
    }
    
    public func setNotificationHandler(_ handler: (@Sendable (String, JSONValue) async -> Void)?) {
        self.notificationHandler = handler
    }
    
    public func setRequestHandler(_ handler: (@Sendable (JSONRPCId, String, JSONValue?) async throws -> JSONValue?)?) {
        self.requestHandler = handler
    }
    
    /// Spawns the ACP agent process using Foundation Process.
    public func start() async throws {
        guard lifecycleState == .stopped else {
            throw ACPError.processAlreadyRunning
        }
        
        lifecycleState = .starting
        processGeneration += 1
        let currentGen = processGeneration
        
        do {
            let proc = Process()
            
            var env = ProcessInfo.processInfo.environment
            let extraPaths = [
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                (NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin"),
                (NSHomeDirectory() as NSString).appendingPathComponent(".antigravity/bin")
            ]
            let currentPath = env["PATH"] ?? ""
            let combinedPath = (extraPaths + [currentPath]).joined(separator: ":")
            env["PATH"] = combinedPath
            
            if let config = self.launchConfiguration {
                proc.executableURL = config.executableURL
                proc.arguments = config.arguments
                if let wd = config.workingDirectory {
                    proc.currentDirectoryURL = wd
                }
                for (key, val) in config.environmentAdditions {
                    env[key] = val
                }
            } else {
                let resolution = try resolveExecutableAndArguments()
                proc.executableURL = URL(fileURLWithPath: resolution.executable)
                proc.arguments = resolution.arguments
            }
            proc.environment = env
            
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = stderr
            
            self.process = proc
            self.stdinPipe = stdin
            self.stdoutPipe = stdout
            self.stderrPipe = stderr
            self.stdoutBuffer.removeAll()
            self.stderrBuffer.removeAll()
            self.recentStderrLines.removeAll()
            self.terminatedExitCode = nil
            self.eofFallbackTask?.cancel()
            self.eofFallbackTask = nil
            self.producerEofReceived = false
            
            // Serial Stream Producer -> AsyncStream -> Single Consumer Task
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            self.stdoutContinuation = continuation
            
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    // Disable producer readabilityHandler immediately on empty data to avoid repeated EOF yields
                    handle.readabilityHandler = nil
                    Task { [weak self] in
                        await self?.handleProducerEof(generation: currentGen)
                    }
                }
                continuation.yield(data)
            }
            
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                Task { [weak self] in
                    await self?.handleIncomingStderr(data: data, generation: currentGen)
                }
            }
            
            proc.terminationHandler = { [weak self] p in
                Task { [weak self] in
                    await self?.handleProcessTerminated(exitCode: p.terminationStatus, generation: currentGen)
                }
            }
            
            // Single sequential consumer processing wire events in order
            consumerTask = Task { [weak self] in
                for await chunk in stream {
                    guard !Task.isCancelled else { break }
                    guard let self = self else { break }
                    await self.handleIncomingStdoutChunk(chunk, generation: currentGen)
                    guard !Task.isCancelled else { break }
                }
            }
            
            try proc.run()
            lifecycleState = .running
        } catch {
            // Roll back lifecycle and clean up on failure
            lifecycleState = .stopped
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe?.fileHandleForReading.close()
            try? stderrPipe?.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
            stdoutContinuation?.finish()
            stdoutContinuation = nil
            consumerTask?.cancel()
            consumerTask = nil
            if let p = self.process {
                _ = await terminateProcessWithFallback(p)
            }
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            failAllPendingRequests(with: error)
            throw error
        }
    }
    
    /// Bounded process teardown: SIGTERM -> wait loop -> SIGKILL fallback.
    private func terminateProcessWithFallback(_ p: Process) async -> Int32 {
        if p.processIdentifier == 0 {
            return -1
        }
        guard p.isRunning else { return p.terminationStatus }
        p.terminate()
        for _ in 0..<10 {
            if !p.isRunning { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            for _ in 0..<5 {
                if !p.isRunning { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return p.isRunning ? -1 : p.terminationStatus
    }
    
    /// Shuts down the child process and cleans up resources without blocking the actor thread.
    public func stop() async {
        guard lifecycleState != .stopped && lifecycleState != .stopping else { return }
        lifecycleState = .stopping
        let stopGen = processGeneration
        
        let proc = self.process
        let stdout = self.stdoutPipe
        let stderr = self.stderrPipe
        let stdin = self.stdinPipe
        let continuation = self.stdoutContinuation
        
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        continuation?.finish()
        self.stdoutContinuation = nil
        
        consumerTask?.cancel()
        consumerTask = nil
        eofFallbackTask?.cancel()
        eofFallbackTask = nil
        terminatedExitCode = nil
        producerEofReceived = false
        
        if let p = proc {
            _ = await terminateProcessWithFallback(p)
        }
        
        // Recheck processGeneration after awaited termination before touching shared state
        guard stopGen == self.processGeneration else { return }
        
        try? stdin?.fileHandleForWriting.close()
        try? stdout?.fileHandleForReading.close()
        try? stderr?.fileHandleForReading.close()
        
        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.stdoutBuffer.removeAll()
        self.lifecycleState = .stopped
        
        failAllPendingRequests(with: ACPError.cancelled)
    }
    
    /// Sends a JSON-RPC 2.0 request and awaits the result with strictly coordinated timeout & cancellation.
    public func sendRequest(method: String, params: JSONValue? = nil, timeout: TimeInterval = 30.0) async throws -> JSONValue {
        guard isRunning, let stdin = stdinPipe else {
            throw ACPError.processNotStarted
        }
        
        let reqId = JSONRPCId.int(nextRequestId)
        nextRequestId += 1
        
        let req = JSONRPCRequest(id: reqId, method: method, params: params)
        let encoder = JSONEncoder()
        var payload = try encoder.encode(req)
        payload.append(0x0A)
        
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var entry = PendingRequest(id: reqId, continuation: continuation, timeoutTask: nil)
                
                if timeout > 0 {
                    entry.timeoutTask = Task { [weak self, reqId, timeout, method] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        await self?.handleRequestTimeout(id: reqId, timeout: timeout, method: method)
                    }
                }
                
                self.pendingRequests[reqId] = entry
                
                do {
                    try stdin.fileHandleForWriting.write(contentsOf: payload)
                } catch {
                    self.resolvePendingRequest(id: reqId, with: .failure(error))
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolvePendingRequest(id: reqId, with: .failure(ACPError.cancelled))
            }
        }
    }
    
    /// Sends a JSON-RPC 2.0 notification (no response expected).
    public func sendNotification(method: String, params: JSONValue? = nil) throws {
        guard isRunning, let stdin = stdinPipe else {
            throw ACPError.processNotStarted
        }
        
        let notif = JSONRPCNotification(method: method, params: params)
        var payload = try JSONEncoder().encode(notif)
        payload.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: payload)
    }
    
    /// Sends a JSON-RPC 2.0 response to an incoming request from the agent.
    public func sendResponse(id: JSONRPCId, result: JSONValue) throws {
        guard isRunning, let stdin = stdinPipe else {
            throw ACPError.processNotStarted
        }
        
        let resp = JSONRPCResponse(id: id, result: result)
        var payload = try JSONEncoder().encode(resp)
        payload.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: payload)
    }
    
    /// Sends a JSON-RPC 2.0 error response to an incoming request from the agent.
    public func sendError(id: JSONRPCId, error: JSONRPCError) throws {
        guard isRunning, let stdin = stdinPipe else {
            throw ACPError.processNotStarted
        }
        
        let resp = JSONRPCResponse(id: id, error: error)
        var payload = try JSONEncoder().encode(resp)
        payload.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: payload)
    }
    
    // MARK: - Internal Continuation & Timeout Coordination
    
    @discardableResult
    private func resolvePendingRequest(id: JSONRPCId, with result: Result<JSONValue, Error>) -> Bool {
        guard let entry = pendingRequests.removeValue(forKey: id) else {
            return false
        }
        entry.timeoutTask?.cancel()
        entry.continuation.resume(with: result)
        return true
    }
    
    private func handleRequestTimeout(id: JSONRPCId, timeout: TimeInterval, method: String) {
        resolvePendingRequest(
            id: id,
            with: .failure(ACPError.timeout("Request '\(method)' timed out after \(timeout)s"))
        )
    }
    
    private func failAllPendingRequests(with error: Error) {
        let entries = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for entry in entries {
            entry.timeoutTask?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }
    
    private func handleProducerEof(generation: Int) {
        guard generation == self.processGeneration else { return }
        self.producerEofReceived = true
        self.eofFallbackTask?.cancel()
        self.eofFallbackTask = nil
    }
    
    private func handleProcessTerminated(exitCode: Int32, generation: Int) {
        guard generation == self.processGeneration else { return }
        self.terminatedExitCode = exitCode
        
        // If producer has already observed EOF on stdout, pipe closed and data is already in stream.
        // Bounded request deadline will govern processing without cancelling consumer via fallback.
        guard !self.producerEofReceived else { return }
        
        // Schedule a bounded 3.0s fallback in case EOF never arrives.
        eofFallbackTask?.cancel()
        eofFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.handleEofTimeout(generation: generation)
        }
    }
    
    private func handleEofTimeout(generation: Int) {
        guard generation == self.processGeneration, lifecycleState != .stopped else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        try? stdinPipe?.fileHandleForWriting.close()
        stdoutContinuation?.finish()
        stdoutContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
        
        let exitCode = self.terminatedExitCode ?? (process?.terminationStatus ?? -1)
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        lifecycleState = .stopped
        
        let sanitized = sanitizedStderr()
        failAllPendingRequests(with: ACPError.processTerminated(exitCode: exitCode, stderr: sanitized))
    }
    
    // MARK: - Incoming Data Handling
    
    private func handleIncomingStdoutChunk(_ data: Data, generation: Int) async {
        guard generation == self.processGeneration, !Task.isCancelled else { return }
        
        if data.isEmpty {
            // EOF encountered on stdout.
            eofFallbackTask?.cancel()
            eofFallbackTask = nil
            
            // 1. Process any remaining bytes in stdoutBuffer
            while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = stdoutBuffer.subdata(in: 0..<newlineIndex)
                stdoutBuffer.removeSubrange(0...newlineIndex)
                if lineData.isEmpty { continue }
                await processIncomingLine(lineData)
                guard generation == self.processGeneration, !Task.isCancelled else { return }
            }
            if !stdoutBuffer.isEmpty {
                let remaining = stdoutBuffer
                stdoutBuffer.removeAll()
                await processIncomingLine(remaining)
                guard generation == self.processGeneration, !Task.isCancelled else { return }
            }
            
            // Recheck before touching shared buffers, pipes, lifecycle or failing requests
            guard generation == self.processGeneration, !Task.isCancelled else { return }
            
            // 2. Disable readers on file handles and close them
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe?.fileHandleForReading.close()
            try? stderrPipe?.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
            
            // 3. End stream
            stdoutContinuation?.finish()
            stdoutContinuation = nil
            
            // 4. Resolve process exit code
            let exitCode: Int32
            if let savedCode = self.terminatedExitCode {
                exitCode = savedCode
            } else if let p = process {
                exitCode = await terminateProcessWithFallback(p)
                guard generation == self.processGeneration, !Task.isCancelled else { return }
            } else {
                exitCode = -1
            }
            
            guard generation == self.processGeneration, !Task.isCancelled else { return }
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            
            // 5. Mark stopped
            lifecycleState = .stopped
            
            // 6. Fail any unresolved pending requests
            let sanitized = sanitizedStderr()
            failAllPendingRequests(with: ACPError.processTerminated(exitCode: exitCode, stderr: sanitized))
            return
        }
        
        stdoutBuffer.append(data)
        if stdoutBuffer.count > maxFrameSize {
            stdoutBuffer.removeAll()
            failAllPendingRequests(with: ACPError.invalidMessage("Frame size exceeded \(maxFrameSize) bytes"))
            return
        }
        
        // Process lines sequentially in wire order
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineIndex)
            stdoutBuffer.removeSubrange(0...newlineIndex)
            
            if lineData.isEmpty { continue }
            await processIncomingLine(lineData)
            guard generation == self.processGeneration, !Task.isCancelled else { return }
        }
    }
    
    private func handleIncomingStderr(data: Data, generation: Int) {
        guard generation == self.processGeneration else { return }
        if data.isEmpty { return }
        
        stderrBuffer.append(data)
        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer.subdata(in: 0..<newlineIndex)
            stderrBuffer.removeSubrange(0...newlineIndex)
            
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                appendSanitizedStderr(line)
            }
        }
    }
    
    private func appendSanitizedStderr(_ raw: String) {
        var sanitized = raw
        let redactions = [
            "Bearer [A-Za-z0-9_.-]+",
            "AIza[0-9A-Za-z-_]{35}",
            "code=[A-Za-z0-9_.-]+",
            "access_token=[A-Za-z0-9_.-]+",
            "client_secret=[A-Za-z0-9_.-]+"
        ]
        for pattern in redactions {
            sanitized = sanitized.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        
        recentStderrLines.append(sanitized)
        if recentStderrLines.count > maxRecentStderrLines {
            recentStderrLines.removeFirst(recentStderrLines.count - maxRecentStderrLines)
        }
    }
    
    private func sanitizedStderr() -> String {
        return recentStderrLines.joined(separator: "\n")
    }
    
    private func processIncomingLine(_ data: Data) async {
        let decoder = JSONDecoder()
        guard let rawJson = try? decoder.decode(JSONValue.self, from: data) else {
            return
        }
        
        guard rawJson["jsonrpc"]?.stringValue == "2.0" else {
            return
        }
        
        let hasMethod = rawJson["method"] != nil
        let idVal = rawJson["id"]
        
        // 1. Check if it's a REQUEST: method present + id present
        if hasMethod, let idVal = idVal {
            let reqId: JSONRPCId
            if let i = idVal.intValue {
                reqId = .int(i)
            } else if let s = idVal.stringValue {
                reqId = .string(s)
            } else {
                return
            }
            let method = rawJson["method"]?.stringValue ?? ""
            let params = rawJson["params"]
            
            if let reqHandler = self.requestHandler {
                do {
                    if let result = try await reqHandler(reqId, method, params) {
                        try? self.sendResponse(id: reqId, result: result)
                    } else {
                        // Handler returned nil: send methodNotFound (-32601)
                        try? self.sendError(
                            id: reqId,
                            error: JSONRPCError(code: -32601, message: "Method not found: \(method)")
                        )
                    }
                } catch {
                    try? self.sendError(
                        id: reqId,
                        error: JSONRPCError(code: -32603, message: error.localizedDescription)
                    )
                }
            } else {
                if method == "session/request_permission" {
                    try? self.sendResponse(id: reqId, result: [
                        "outcome": ["outcome": "cancelled"]
                    ])
                } else {
                    try? self.sendError(
                        id: reqId,
                        error: JSONRPCError(code: -32601, message: "Method not found: \(method)")
                    )
                }
            }
            return
        }
        
        // 2. Check if it's a NOTIFICATION: method present + no id
        if hasMethod && idVal == nil {
            let method = rawJson["method"]?.stringValue ?? ""
            let params = rawJson["params"] ?? .null
            if let notifHandler = self.notificationHandler {
                // Awaited sequentially in wire order!
                await notifHandler(method, params)
            }
            return
        }
        
        // 3. Check if it's a RESPONSE: no method + id present + (result OR error present)
        if !hasMethod, let idVal = idVal {
            let respId: JSONRPCId
            if let i = idVal.intValue {
                respId = .int(i)
            } else if let s = idVal.stringValue {
                respId = .string(s)
            } else {
                return
            }
            
            let hasResult = rawJson.objectValue?.keys.contains("result") == true
            let hasError = rawJson.objectValue?.keys.contains("error") == true
            
            if hasError, let errObj = rawJson["error"] {
                let code = errObj["code"]?.intValue ?? -1
                let msg = errObj["message"]?.stringValue ?? "ACP request failed"
                let errData = errObj["data"]
                resolvePendingRequest(id: respId, with: .failure(ACPError.requestFailed(code: code, message: msg, data: errData)))
            } else if hasResult {
                let res = rawJson["result"] ?? .null
                resolvePendingRequest(id: respId, with: .success(res))
            } else {
                // Neither result nor error: invalid JSON-RPC response
                resolvePendingRequest(id: respId, with: .failure(ACPError.invalidMessage("Response has neither result nor error")))
            }
            return
        }
    }
    
    // MARK: - Executable Resolution
    
    public struct ResolvedExecution: Sendable {
        public let executable: String
        public let arguments: [String]
    }
    
    public func resolveExecutableAndArguments() throws -> ResolvedExecution {
        if let customExe = customExecutablePath {
            let defaultArgs: [String] = customExe.hasSuffix("agy_acp_server.par") ? [] : ["--acp"]
            return ResolvedExecution(
                executable: customExe,
                arguments: customArguments ?? defaultArgs
            )
        }
        
        let fm = FileManager.default
        let currentDir = fm.currentDirectoryPath
        
        // 1. Primary: Official standalone Antigravity ACP Server (agy_acp_server.par, runs directly without --acp)
        var candidateStandalones: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidateStandalones.append((resourcePath as NSString).appendingPathComponent("runtime/antigravity-acp/agy_acp_server.par"))
            candidateStandalones.append((resourcePath as NSString).appendingPathComponent("antigravity-acp/agy_acp_server.par"))
        }
        candidateStandalones.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/antigravity-acp/agy_acp_server.par"))
        candidateStandalones.append((currentDir as NSString).appendingPathComponent("runtime/antigravity-acp/agy_acp_server.par"))
        candidateStandalones.append((NSHomeDirectory() as NSString).appendingPathComponent(".antigravity/bin/agy_acp_server.par"))
        candidateStandalones.append((NSHomeDirectory() as NSString).appendingPathComponent(".gemini/bin/agy_acp_server.par"))
        candidateStandalones.append("/usr/local/bin/agy_acp_server.par")
        candidateStandalones.append("/opt/homebrew/bin/agy_acp_server.par")
        
        for candidate in candidateStandalones {
            if fm.isExecutableFile(atPath: candidate) {
                return ResolvedExecution(executable: candidate, arguments: [])
            }
        }
        
        // 2. Fallbacks: Node bundle or local binary if installed
        var candidateBundleScripts: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            candidateBundleScripts.append((resourcePath as NSString).appendingPathComponent("runtime/node_modules/@google/gemini-cli/bundle/gemini.js"))
            candidateBundleScripts.append((resourcePath as NSString).appendingPathComponent("node_modules/@google/gemini-cli/bundle/gemini.js"))
        }
        candidateBundleScripts.append((currentDir as NSString).appendingPathComponent("runtime/node_modules/@google/gemini-cli/bundle/gemini.js"))
        candidateBundleScripts.append((currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/@google/gemini-cli/bundle/gemini.js"))
        
        let nodeCandidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node"
        ]
        
        var foundNode: String?
        for node in nodeCandidates {
            if fm.isExecutableFile(atPath: node) {
                foundNode = node
                break
            }
        }
        
        for script in candidateBundleScripts {
            if fm.fileExists(atPath: script), let node = foundNode {
                return ResolvedExecution(executable: node, arguments: [script, "--acp"])
            }
        }
        
        let binaryCandidates = [
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini",
            (NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin/gemini"),
            (currentDir as NSString).appendingPathComponent("runtime/node_modules/.bin/gemini"),
            (currentDir as NSString).appendingPathComponent("work/pinebot/runtime/node_modules/.bin/gemini")
        ]
        
        for bin in binaryCandidates {
            if fm.isExecutableFile(atPath: bin) {
                if let node = foundNode {
                    return ResolvedExecution(executable: node, arguments: [bin, "--acp"])
                }
                return ResolvedExecution(executable: bin, arguments: ["--acp"])
            }
        }
        
        throw ACPError.executableNotFound(
            "Could not locate official Antigravity ACP binary (agy_acp_server.par). Checked app bundle runtime, project runtime, and system paths."
        )
    }
}
