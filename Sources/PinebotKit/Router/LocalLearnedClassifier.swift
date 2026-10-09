import Foundation

/// Primary category of user request.
public enum TaskCategory: String, Codable, CaseIterable, Sendable {
    case greeting = "greeting"
    case simpleChat = "simple_chat"
    case factualLookup = "factual_lookup"
    case codeGeneration = "code_generation"
    case complexReasoning = "complex_reasoning"
    case computerTask = "computer_task"
    case screenAnalysis = "screen_analysis"
}

/// Inferred task difficulty.
public enum TaskDifficulty: String, Codable, CaseIterable, Sendable {
    case simple = "simple"
    case medium = "medium"
    case complex = "complex"
}

/// The provenance and status of the classifier output.
public enum ClassifierStatus: Equatable, Sendable {
    /// True learned model inference performed with the specified model name and output confidence.
    case learned(modelName: String, confidence: Double)
    
    /// Honest fallback when learned model weights are not loaded, missing, or malformed.
    /// Explicitly states why fallback occurred so no false ML claims are made.
    case fallback(reason: String)
    
    public var isLearned: Bool {
        if case .learned = self { return true }
        return false
    }
    
    public var displayLabel: String {
        switch self {
        case .learned(let model, let conf):
            return "Learned Classifier (\(model), conf: \(String(format: "%.2f", conf)))"
        case .fallback(let reason):
            return "Deterministic Fallback (\(reason))"
        }
    }
}

/// Output prediction from the local classifier.
public struct TaskClassification: Sendable, Equatable {
    public let category: TaskCategory
    public let difficulty: TaskDifficulty
    public let reasoningScore: Double // 0.0 to 1.0
    public let requiresVision: Bool
    public let requiresComputerTools: Bool
    public let status: ClassifierStatus
    public let confidence: Double
    public let rawScores: [String: Double]?
    
    public init(
        category: TaskCategory,
        difficulty: TaskDifficulty,
        reasoningScore: Double,
        requiresVision: Bool,
        requiresComputerTools: Bool,
        status: ClassifierStatus,
        confidence: Double,
        rawScores: [String: Double]? = nil
    ) {
        self.category = category
        self.difficulty = difficulty
        self.reasoningScore = reasoningScore
        self.requiresVision = requiresVision
        self.requiresComputerTools = requiresComputerTools
        self.status = status
        self.confidence = confidence
        self.rawScores = rawScores
    }
}

/// Persistent background worker actor managing the Python sidecar process.
/// Handles non-blocking async I/O over newline-delimited JSON stdin/stdout using
/// an AsyncStream single-consumer framing pattern with process-generation guards.
/// Enforces a genuine 3-second request deadline, non-blocking serial stdin writes,
/// bounded concurrent stderr draining, and guaranteed cleanup of all pending continuations.
public actor ClassifierSidecarWorker {
    private let pythonExecutable: String
    private let sidecarScriptURL: URL
    private let modelDirectory: URL
    
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    
    private let stdinQueue = DispatchQueue(label: "com.pinebot.classifier.stdin", qos: .userInitiated)
    private let stdoutQueue = DispatchQueue(label: "com.pinebot.classifier.stdout", qos: .userInitiated)
    private let stderrQueue = DispatchQueue(label: "com.pinebot.classifier.stderr", qos: .userInitiated)
    
    public enum StdoutEvent: Sendable {
        case data(Data, generation: UInt64)
        case eof(generation: UInt64)
    }
    
    private var processGeneration: UInt64 = 0
    private var stdoutStreamContinuation: AsyncStream<StdoutEvent>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var recordedExitCode: Int32? = nil
    
    private var stderrBuffer = Data()
    private let maxStderrBytes = 65536 // 64 KB bounded stderr buffer
    
    private struct PendingEntry {
        let continuation: CheckedContinuation<TaskClassification, Never>
        let timeoutTask: Task<Void, Never>
        let generation: UInt64
        let hasScreen: Bool
        let prompt: String
    }
    
    private var pendingRequests: [String: PendingEntry] = [:]
    
    public init(
        pythonExecutable: String,
        sidecarScriptURL: URL,
        modelDirectory: URL
    ) {
        self.pythonExecutable = pythonExecutable
        self.sidecarScriptURL = sidecarScriptURL
        self.modelDirectory = modelDirectory
    }
    
    deinit {
        let p = process
        let inH = stdinHandle
        let outH = stdoutHandle
        let errH = stderrHandle
        outH?.readabilityHandler = nil
        errH?.readabilityHandler = nil
        try? inH?.close()
        try? outH?.close()
        try? errH?.close()
        if let p = p, p.isRunning {
            p.terminate()
        }
    }
    
    public func classify(prompt: String, hasScreen: Bool) async -> TaskClassification {
        guard FileManager.default.fileExists(atPath: sidecarScriptURL.path) else {
            return LocalLearnedClassifier.runHonestFallback(
                prompt: prompt,
                hasScreenImage: hasScreen,
                fallbackReason: "Classifier sidecar script not found"
            )
        }
        
        // Fast path: if using the official sidecar and model weights are missing from the model directory,
        // return honest deterministic fallback immediately without spawning Python or runtime
        let modelFile = modelDirectory.appendingPathComponent("model.onnx")
        if sidecarScriptURL == LocalLearnedClassifier.discoverSidecarScript() && !FileManager.default.fileExists(atPath: modelFile.path) {
            return LocalLearnedClassifier.runHonestFallback(
                prompt: prompt,
                hasScreenImage: hasScreen,
                fallbackReason: "Learned weights not downloaded (model.onnx missing at \(modelDirectory.path))"
            )
        }
        
        let currentGen: UInt64
        do {
            currentGen = try startProcessIfNeeded()
        } catch {
            return LocalLearnedClassifier.runHonestFallback(
                prompt: prompt,
                hasScreenImage: hasScreen,
                fallbackReason: "Failed to launch classifier sidecar: \(error.localizedDescription)"
            )
        }
        
        guard let stdin = stdinHandle else {
            return LocalLearnedClassifier.runHonestFallback(
                prompt: prompt,
                hasScreenImage: hasScreen,
                fallbackReason: "Sidecar stdin handle unavailable"
            )
        }
        
        let requestId = "req-" + UUID().uuidString
        // Bounded prompt input (max 32KB)
        let boundedPrompt = String(prompt.prefix(32768))
        let payload: [String: Any] = [
            "id": requestId,
            "prompt": boundedPrompt,
            "has_screen": hasScreen,
            "model_dir": modelDirectory.path
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return LocalLearnedClassifier.runHonestFallback(
                prompt: prompt,
                hasScreenImage: hasScreen,
                fallbackReason: "Failed to serialize classification request"
            )
        }
        
        var messageData = jsonData
        messageData.append(0x0A) // newline
        
        // Rule 4: Register continuation, timeout task, and cancellation handler BEFORE stdin write
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self, requestId, currentGen, hasScreen, prompt] in
                    do {
                        try await Task.sleep(nanoseconds: 3_000_000_000) // Genuine 3.0s deadline
                    } catch {
                        // Sleep was cancelled (e.g. prompt succeeded or was cancelled) -> exit immediately
                        return
                    }
                    if Task.isCancelled { return }
                    await self?.handleRequestTimeout(requestId: requestId, generation: currentGen, hasScreen: hasScreen, prompt: prompt)
                }
                
                self.pendingRequests[requestId] = PendingEntry(
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    generation: currentGen,
                    hasScreen: hasScreen,
                    prompt: prompt
                )
                
                // Non-blocking serial stdin write
                self.stdinQueue.async { [weak self, requestId, currentGen, hasScreen, prompt, messageData, stdin] in
                    do {
                        try stdin.write(contentsOf: messageData)
                    } catch {
                        Task { [weak self] in
                            await self?.handleWriteFailure(
                                requestId: requestId,
                                generation: currentGen,
                                hasScreen: hasScreen,
                                prompt: prompt,
                                error: error
                            )
                        }
                    }
                }
            }
        } onCancel: {
            Task { [weak self, requestId] in
                await self?.handleRequestCancellation(requestId: requestId)
            }
        }
    }
    
    private func handleRequestTimeout(requestId: String, generation: UInt64, hasScreen: Bool, prompt: String) {
        guard generation == processGeneration else { return }
        guard let entry = pendingRequests.removeValue(forKey: requestId) else {
            // Already resolved and removed; do NOT kill warm worker or other requests!
            return
        }
        entry.timeoutTask.cancel()
        entry.continuation.resume(returning: LocalLearnedClassifier.runHonestFallback(
            prompt: entry.prompt,
            hasScreenImage: entry.hasScreen,
            fallbackReason: "Classifier sidecar request timed out (3.0s deadline exceeded for \(requestId))"
        ))
        
        // Only if this request actually timed out while pending, terminate worker and fail remaining
        let reason = "Classifier sidecar request timed out (3.0s deadline exceeded for \(requestId))"
        terminateProcessAndFailAllPending(reason: reason)
    }
    
    private func handleRequestCancellation(requestId: String) {
        guard let entry = pendingRequests.removeValue(forKey: requestId) else { return }
        entry.timeoutTask.cancel()
        
        entry.continuation.resume(returning: LocalLearnedClassifier.runHonestFallback(
            prompt: entry.prompt,
            hasScreenImage: entry.hasScreen,
            fallbackReason: "Classification request was cancelled (\(requestId))"
        ))
        
        // If no more requests are pending, terminate worker to cancel expensive background inference
        if pendingRequests.isEmpty {
            terminateProcess()
        }
    }
    
    private func handleWriteFailure(requestId: String, generation: UInt64, hasScreen: Bool, prompt: String, error: Error) {
        guard generation == processGeneration else { return }
        guard let entry = pendingRequests.removeValue(forKey: requestId) else { return }
        entry.timeoutTask.cancel()
        
        entry.continuation.resume(returning: LocalLearnedClassifier.runHonestFallback(
            prompt: prompt,
            hasScreenImage: hasScreen,
            fallbackReason: "Sidecar write failure: \(error.localizedDescription)"
        ))
        
        // Broken pipe indicates worker crashed; terminate and fail remaining
        terminateProcessAndFailAllPending(reason: "Sidecar write pipe broken: \(error.localizedDescription)")
    }
    
    private func startProcessIfNeeded() throws -> UInt64 {
        if let p = process, p.isRunning {
            return processGeneration
        }
        
        terminateProcess()
        processGeneration += 1
        let currentGen = processGeneration
        
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonExecutable)
        p.arguments = ["-B", sidecarScriptURL.path]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        
        // Rule 2: Setup single-consumer AsyncStream for framed stdout events
        var continuation: AsyncStream<StdoutEvent>.Continuation?
        let stream = AsyncStream<StdoutEvent> { cont in
            continuation = cont
        }
        self.stdoutStreamContinuation = continuation
        
        // Start single consumer task
        consumerTask = Task { [weak self, currentGen] in
            var lineBuffer = Data()
            for await event in stream {
                guard let self = self else { break }
                await self.consumeStdoutEvent(event, lineBuffer: &lineBuffer, currentGen: currentGen)
            }
        }
        
        // Setup direct synchronous yield in readabilityHandler without intermediary Tasks
        let outHandle = outPipe.fileHandleForReading
        let capturedContinuation = continuation
        outHandle.readabilityHandler = { [capturedContinuation, currentGen] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                capturedContinuation?.yield(.eof(generation: currentGen))
            } else {
                capturedContinuation?.yield(.data(chunk, generation: currentGen))
            }
        }
        
        // Rule 3: Concurrent bounded stderr draining
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { [weak self, currentGen] handle in
            let chunk = handle.availableData
            Task { [weak self] in
                await self?.handleStderrReadability(chunk, generation: currentGen)
            }
        }
        
        p.terminationHandler = { [weak self, currentGen] proc in
            let code = proc.terminationStatus
            Task { [weak self] in
                await self?.handleProcessExited(exitCode: code, generation: currentGen)
            }
        }
        
        try p.run()
        
        self.process = p
        self.recordedExitCode = nil
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outHandle
        self.stderrHandle = errHandle
        self.stderrBuffer.removeAll()
        
        return currentGen
    }
    
    private func handleProcessExited(exitCode: Int32, generation: UInt64) {
        guard generation == processGeneration else { return }
        self.recordedExitCode = exitCode
        // Record exit status only; let ordered stdout EOF drain pending bytes before teardown.
        // Start a bounded fallback in case EOF is not delivered by the handle within 500ms:
        Task { [weak self, generation, exitCode] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.handleTerminationFallback(exitCode: exitCode, generation: generation)
        }
    }
    
    private func handleTerminationFallback(exitCode: Int32, generation: UInt64) {
        guard generation == processGeneration else { return }
        guard !pendingRequests.isEmpty else { return }
        handleProcessTermination(exitCode: exitCode, generation: generation)
    }
    
    private func handleStderrReadability(_ chunk: Data, generation: UInt64) {
        guard generation == processGeneration else { return }
        guard !chunk.isEmpty else { return }
        
        // Bounded stderr ring buffer
        stderrBuffer.append(chunk)
        if stderrBuffer.count > maxStderrBytes {
            stderrBuffer.removeSubrange(0..<(stderrBuffer.count - maxStderrBytes))
        }
    }
    
    private func consumeStdoutEvent(_ event: StdoutEvent, lineBuffer: inout Data, currentGen: UInt64) {
        guard currentGen == processGeneration else { return }
        switch event {
        case .data(let chunk, let gen):
            guard gen == processGeneration else { return }
            lineBuffer.append(chunk)
            
            if lineBuffer.count > 1024 * 1024 {
                // Safeguard against malformed stream without newlines
                lineBuffer.removeAll()
                return
            }
            
            let newline: UInt8 = 0x0A
            while let newlineIdx = lineBuffer.firstIndex(of: newline) {
                let lineData = lineBuffer.subdata(in: 0..<newlineIdx)
                lineBuffer.removeSubrange(0...newlineIdx)
                
                guard !lineData.isEmpty else { continue }
                processOutputLine(lineData, generation: gen)
            }
            
        case .eof(let gen):
            guard gen == processGeneration else { return }
            if !lineBuffer.isEmpty {
                let lineData = lineBuffer
                lineBuffer.removeAll()
                processOutputLine(lineData, generation: gen)
            }
            stdoutStreamContinuation?.finish()
            let finalCode = self.recordedExitCode ?? -1
            handleProcessTermination(exitCode: finalCode, generation: gen)
        }
    }
    
    private func extractStrictJSONBool(_ value: Any?) -> Bool? {
        guard let val = value else { return nil }
        if CFGetTypeID(val as CFTypeRef) == CFBooleanGetTypeID() {
            return (val as? NSNumber)?.boolValue
        }
        return nil
    }
    
    private func processOutputLine(_ lineData: Data, generation: UInt64) {
        guard generation == processGeneration else { return }
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            // Malformed JSON output from sidecar: resolve pending request immediately with honest fallback
            if let (singleId, entry) = pendingRequests.first {
                pendingRequests.removeValue(forKey: singleId)
                entry.timeoutTask.cancel()
                let badText = String(data: lineData, encoding: .utf8) ?? "binary data"
                entry.continuation.resume(returning: LocalLearnedClassifier.runHonestFallback(
                    prompt: entry.prompt,
                    hasScreenImage: entry.hasScreen,
                    fallbackReason: "Malformed classifier output: \(badText)"
                ))
            }
            return
        }
        
        let reqId = json["id"] as? String ?? ""
        guard let entry = pendingRequests.removeValue(forKey: reqId) else {
            return
        }
        entry.timeoutTask.cancel()
        
        let statusStr = json["status"] as? String ?? "fallback"
        let strictVision = extractStrictJSONBool(json["requires_vision"])
        let strictTools = extractStrictJSONBool(json["requires_computer_tools"])
        
        if statusStr == "learned",
           let modelName = json["model_name"] as? String, !modelName.isEmpty,
           let confidence = json["confidence"] as? Double, confidence.isFinite && confidence >= 0.0 && confidence <= 1.0,
           let categoryStr = json["category"] as? String, let category = TaskCategory(rawValue: categoryStr),
           let difficultyStr = json["difficulty"] as? String, let difficulty = TaskDifficulty(rawValue: difficultyStr),
           let reasoningScore = json["reasoning_score"] as? Double, reasoningScore.isFinite && reasoningScore >= 0.0 && reasoningScore <= 1.0,
           let requiresVision = strictVision,
           let requiresTools = strictTools {
            
            let rawScores = json["raw_scores"] as? [String: Double]
            
            entry.continuation.resume(returning: TaskClassification(
                category: category,
                difficulty: difficulty,
                reasoningScore: reasoningScore,
                requiresVision: requiresVision,
                requiresComputerTools: requiresTools,
                status: .learned(modelName: modelName, confidence: confidence),
                confidence: confidence,
                rawScores: rawScores
            ))
        } else {
            let reason = json["reason"] as? String ?? (statusStr == "learned" ? "Sidecar payload had missing/malformed learned fields" : "Sidecar reported fallback")
            entry.continuation.resume(returning: LocalLearnedClassifier.runHonestFallback(
                prompt: entry.prompt,
                hasScreenImage: entry.hasScreen,
                fallbackReason: reason
            ))
        }
    }
    
    private func handleProcessTermination(exitCode: Int32, generation: UInt64) {
        guard generation == processGeneration else { return }
        let diagnostics = sanitizedStderrDiagnostics()
        let reason = "Sidecar process terminated (code \(exitCode))\(diagnostics.isEmpty ? "" : ": " + diagnostics)"
        terminateProcessAndFailAllPending(reason: reason)
    }
    
    private func terminateProcessAndFailAllPending(reason: String) {
        terminateProcess()
        
        let currentPending = pendingRequests
        pendingRequests.removeAll()
        
        for (reqId, entry) in currentPending {
            entry.timeoutTask.cancel()
            entry.continuation.resume(returning: LocalLearnedClassifier.runHonestFallback(
                prompt: entry.prompt,
                hasScreenImage: entry.hasScreen,
                fallbackReason: "\(reason) [request: \(reqId)]"
            ))
        }
    }
    
    public func stop() {
        terminateProcessAndFailAllPending(reason: "Classifier sidecar stopped")
    }
    
    private func terminateProcess() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        
        stdoutStreamContinuation?.finish()
        stdoutStreamContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
        
        // Rule 6: Capture Process reference and only kill if SAME process is still running
        if let p = process {
            if p.isRunning && p.processIdentifier > 0 {
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak p] in
                    guard let p = p, p.isRunning, p.processIdentifier > 0 else { return }
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
    }
    
    private func sanitizedStderrDiagnostics() -> String {
        guard !stderrBuffer.isEmpty else { return "" }
        let text = String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLines = text.components(separatedBy: .newlines).suffix(3).joined(separator: " | ")
        return String(lastLines.prefix(256))
    }
    
    // Testing hooks
    public func currentGeneration() -> UInt64 {
        return processGeneration
    }
    
    public func simulateStaleEOF(generation: UInt64) {
        stdoutStreamContinuation?.yield(.eof(generation: generation))
    }
    
    public func currentProcessIdentifier() -> Int32? {
        return process?.isRunning == true ? process?.processIdentifier : nil
    }
    
    public func isWorkerRunning() -> Bool {
        return process?.isRunning == true
    }
    
    public func pendingRequestCount() -> Int {
        return pendingRequests.count
    }
}

/// Local classifier engine.
/// Connects to a Python/ONNX sidecar for genuine zero-shot neural classification.
/// File existence NEVER implies a loaded model or learned inference.
/// Until genuine inference succeeds, it strictly reports fallback with exact error rationale.
public final class LocalLearnedClassifier: @unchecked Sendable {
    public static let shared = LocalLearnedClassifier()
    
    public let modelDirectory: URL
    public let pythonExecutable: String
    public let sidecarScriptURL: URL
    
    public let worker: ClassifierSidecarWorker
    
    public init(
        modelDirectory: URL? = nil,
        pythonExecutable: String? = nil,
        sidecarScriptURL: URL? = nil
    ) {
        // 1. Model directory discovery
        if let injectedModel = modelDirectory {
            self.modelDirectory = injectedModel
        } else {
            self.modelDirectory = Self.discoverModelDirectory()
        }
        
        // 2. Python executable discovery (injected parameter takes absolute precedence)
        if let injectedPython = pythonExecutable {
            self.pythonExecutable = injectedPython
        } else {
            self.pythonExecutable = Self.discoverPythonExecutable()
        }
        
        // 3. Sidecar script discovery
        if let injectedScript = sidecarScriptURL {
            self.sidecarScriptURL = injectedScript
        } else {
            self.sidecarScriptURL = Self.discoverSidecarScript()
        }
        
        self.worker = ClassifierSidecarWorker(
            pythonExecutable: self.pythonExecutable,
            sidecarScriptURL: self.sidecarScriptURL,
            modelDirectory: self.modelDirectory
        )
    }
    
    // MARK: - Classification API
    
    /// Asynchronously classifies a user prompt using the warm persistent sidecar worker.
    /// Non-blocking, enforces a 3-second deadline, and never blocks MainActor.
    public func classify(prompt: String, hasScreenImage: Bool = false) async -> TaskClassification {
        await worker.classify(prompt: prompt, hasScreen: hasScreenImage)
    }
    
    /// Explicit async classification convenience method.
    public func classifyAsync(prompt: String, hasScreenImage: Bool = false) async -> TaskClassification {
        await classify(prompt: prompt, hasScreenImage: hasScreenImage)
    }
    
    /// Synchronous classification fallback: returns honest deterministic fallback without blocking subprocess calls.
    public func classify(prompt: String, hasScreenImage: Bool = false) -> TaskClassification {
        Self.runHonestFallback(
            prompt: prompt,
            hasScreenImage: hasScreenImage,
            fallbackReason: "Synchronous classification uses deterministic fallback; use async classify for learned model inference"
        )
    }
    
    // MARK: - Deterministic Honest Fallback Policy
    
    public static func isExecutableComputerAction(prompt: String) -> Bool {
        // 1. Strip quoted text ("...", '...', `...`) to avoid treating quoted commands as actions
        var unquoted = prompt
        let quoteRegex = try? NSRegularExpression(pattern: "\"[^\"]*\"|'[^']*'|`[^`]*`", options: [])
        if let regex = quoteRegex {
            let range = NSRange(location: 0, length: unquoted.utf16.count)
            unquoted = regex.stringByReplacingMatches(in: unquoted, options: [], range: range, withTemplate: " ")
        }
        let lower = unquoted.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 2. Reject teaching, explanations, or meta-questions
        let teachingPatterns = [
            "^(how\\s+(do|can|to|should)\\s+i\\b)",
            "^(show\\s+me\\s+how\\b)",
            "^(explain\\s+(how|what|why)\\b)",
            "^(tell\\s+me\\s+how\\b)",
            "^(what\\s+does\\b)",
            "^(in\\s+[a-z0-9_#\\.\\-]+\\s*,?\\s*how\\s+(do|can|to)\\b)",
            "^(can\\s+you\\s+explain\\b)",
            "^(describe\\s+how\\b)",
            "^(guide\\s+me\\s+on\\b)",
            "^(tutorial\\s+on\\b)"
        ]
        for pat in teachingPatterns {
            if let reg = try? NSRegularExpression(pattern: pat, options: []),
               reg.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return false
            }
        }
        
        // 3. Executable action patterns
        let actionPattern = "(?:^|[.;\\n]|(?:please\\s+)|(?:can\\s+you\\s+))(open|launch|click|press|type|drag|scroll|switch\\s+to|focus|close|select|navigate\\s+to)\\b"
        guard let actionReg = try? NSRegularExpression(pattern: actionPattern, options: []),
              let match = actionReg.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) else {
            return false
        }
        
        let verbRange = match.range(at: 1)
        guard let verbRangeInString = Range(verbRange, in: lower) else { return false }
        let verb = String(lower[verbRangeInString])
        
        let targets = [
            "\\b(calculator|safari|chrome|finder|terminal|textedit|notes|slack|settings|mail|preview|system\\s+settings|app|application|window|button|dialog|menu|icon|dock|tab|desktop|screen)\\b",
            "\\b(submit|cancel|ok|save|close|confirm|continue|search|apply|enter|delete)\\b.*button",
            "\\b(button|checkbox|textfield|text\\s+field|input|dropdown|link)\\b",
            "\\b(into\\s+(the\\s+)?(search|text|input|field|box|terminal))\\b"
        ]
        
        let hasTarget = targets.contains { targetPat in
            if let tReg = try? NSRegularExpression(pattern: targetPat, options: []),
               tReg.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return true
            }
            return false
        }
        
        if verb == "open" || verb == "launch" || verb == "type" {
            return hasTarget
        } else if ["click", "press", "drag", "scroll", "switch to", "focus"].contains(verb) {
            return true
        }
        return false
    }
    
    public static func runHonestFallback(prompt: String, hasScreenImage: Bool, fallbackReason: String) -> TaskClassification {
        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Separate capability decision:
        // Explicit request to operate desktop/software must reach planner
        // even when maths/coding topic wins; do not treat quoted/described commands as actions.
        let isAction = isExecutableComputerAction(prompt: prompt)
        let isScreenQuery = ["look at screen", "see this window", "what is on my screen", "read screen", "screenshot", "error on screen"].contains { lower.contains($0) }
        let requiresTools = isAction
        let requiresVision = isAction || isScreenQuery || hasScreenImage
        
        if requiresTools {
            return TaskClassification(
                category: .computerTask,
                difficulty: .medium,
                reasoningScore: 0.65,
                requiresVision: true,
                requiresComputerTools: true,
                status: .fallback(reason: fallbackReason),
                confidence: 0.85
            )
        }
        
        if requiresVision && !isAction {
            return TaskClassification(
                category: .screenAnalysis,
                difficulty: .medium,
                reasoningScore: 0.60,
                requiresVision: true,
                requiresComputerTools: false,
                status: .fallback(reason: fallbackReason),
                confidence: 0.90
            )
        }
        
        // 2. Greetings & casual conversation
        let greetings = ["hi", "hello", "hey", "good morning", "good evening", "how are you", "who are you", "what's up", "sup"]
        let isGreeting = greetings.contains { lower == $0 || lower.hasPrefix("\($0) ") || lower.hasPrefix("\($0)!") || lower.hasPrefix("\($0),") }
        if isGreeting && lower.count < 30 {
            return TaskClassification(
                category: .greeting,
                difficulty: .simple,
                reasoningScore: 0.05,
                requiresVision: false,
                requiresComputerTools: false,
                status: .fallback(reason: fallbackReason),
                confidence: 0.95
            )
        }
        
        // 3. Routine arithmetic (Never force complex/frontier on simple arithmetic calculations)
        let arithmeticPattern = "\\b(calculate|what is|how much is)\\s+([0-9\\+\\-\\*/\\s]|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|plus|minus|times|divided by)+\\b"
        let isRoutineArithmetic: Bool = {
            if let reg = try? NSRegularExpression(pattern: arithmeticPattern, options: []),
               reg.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return true
            }
            return false
        }()
        
        if isRoutineArithmetic {
            return TaskClassification(
                category: .simpleChat,
                difficulty: .simple,
                reasoningScore: 0.20,
                requiresVision: false,
                requiresComputerTools: false,
                status: .fallback(reason: fallbackReason),
                confidence: 0.85
            )
        }
        
        // 4. Code / SQL
        let codeIndicators = [
            "\\b(sql|query|select\\s+.*from|insert\\s+into|update\\s+.*set|delete\\s+from|create\\s+table)\\b",
            "\\b(python|javascript|typescript|swift|rust|c\\+\\+|golang|java|html|css|bash|shell)\\b",
            "\\b(function|class|method|def\\s+|var\\s+|let\\s+|const\\s+|import\\s+|return\\s+)\\b",
            "\\b(debug|refactor|compile|regex|deadlock|mutex|threads?|stack\\s*trace)\\b"
        ]
        let isCode = codeIndicators.contains { pat in
            if let reg = try? NSRegularExpression(pattern: pat, options: []),
               reg.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return true
            }
            return false
        }
        
        // 5. Deep proof / distributed architecture
        let proofIndicators = [
            "\\b(prove\\s+that|proof\\s+of|theorem|lemma|spectral\\s+theorem|eigenvector|self-adjoint|orthonormal\\s+basis|metric\\s+space|isomorphism)\\b",
            "\\b(distributed\\s+(database|system)|schema\\s+with\\s+sharding|cross-region\\s+replication|raft\\s+consensus|byzantine)\\b"
        ]
        let isProof = proofIndicators.contains { pat in
            if let reg = try? NSRegularExpression(pattern: pat, options: []),
               reg.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return true
            }
            return false
        }
        
        if isProof {
            return TaskClassification(
                category: .complexReasoning,
                difficulty: .complex,
                reasoningScore: 0.90,
                requiresVision: false,
                requiresComputerTools: false,
                status: .fallback(reason: fallbackReason),
                confidence: 0.88
            )
        }
        
        if isCode {
            let isComplexCode = ["deadlock", "mutex", "concurrency", "distributed architecture", "race condition"].contains { lower.contains($0) }
            return TaskClassification(
                category: .codeGeneration,
                difficulty: isComplexCode ? .complex : .simple,
                reasoningScore: isComplexCode ? 0.85 : 0.40,
                requiresVision: false,
                requiresComputerTools: false,
                status: .fallback(reason: fallbackReason),
                confidence: 0.88
            )
        }
        
        // 6. Factual lookup / teaching
        let isFactual = ["how do i", "how to", "show me how", "what does", "explain", "describe", "who was", "where is", "when did"].contains { lower.contains($0) }
        if isFactual {
            return TaskClassification(
                category: .factualLookup,
                difficulty: .simple,
                reasoningScore: 0.25,
                requiresVision: false,
                requiresComputerTools: false,
                status: .fallback(reason: fallbackReason),
                confidence: 0.85
            )
        }
        
        // 7. Default general chat
        return TaskClassification(
            category: .simpleChat,
            difficulty: .simple,
            reasoningScore: 0.25,
            requiresVision: false,
            requiresComputerTools: false,
            status: .fallback(reason: fallbackReason),
            confidence: 0.80
        )
    }
    
    public func runHonestFallback(prompt: String, hasScreenImage: Bool, fallbackReason: String) -> TaskClassification {
        Self.runHonestFallback(prompt: prompt, hasScreenImage: hasScreenImage, fallbackReason: fallbackReason)
    }
    
    // MARK: - Dynamic Path Discovery
    
    public static func discoverPythonExecutable() -> String {
        // 1. Environment variable override
        if let envPy = ProcessInfo.processInfo.environment["PINEBOT_PYTHON"],
           FileManager.default.fileExists(atPath: envPy) {
            return envPy
        }
        
        // 2. App-bundle-owned relocatable CPython runtime (standalone, zero symlinks)
        if let bundlePython = Bundle.main.resourceURL?.appendingPathComponent("runtime/python/bin/python3"),
           FileManager.default.isExecutableFile(atPath: bundlePython.path) {
            return bundlePython.path
        }
        let bundleAppPython = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/python/bin/python3").path
        if FileManager.default.isExecutableFile(atPath: bundleAppPython) {
            return bundleAppPython
        }
        if let bundleRuntime = Bundle.main.resourceURL?.appendingPathComponent("runtime/bin/python3"),
           FileManager.default.isExecutableFile(atPath: bundleRuntime.path) {
            return bundleRuntime.path
        }
        let bundleAppPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/bin/python3").path
        if FileManager.default.isExecutableFile(atPath: bundleAppPath) {
            return bundleAppPath
        }
        
        // 3. Application Support app-owned private runtime (user-isolated, portable launcher)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupportPython = appSupport.appendingPathComponent("Pinebot/runtime/python/bin/python3").path
            if FileManager.default.isExecutableFile(atPath: appSupportPython) {
                return appSupportPython
            }
            let legacyAppSupport = appSupport.appendingPathComponent("Pinebot/classifier_runtime/bin/python3").path
            if FileManager.default.isExecutableFile(atPath: legacyAppSupport) {
                return legacyAppSupport
            }
        }
        
        // 4. Bundled project runtime (for local runs in project root)
        let cwd = FileManager.default.currentDirectoryPath
        let projectPythonCandidates = [
            (cwd as NSString).appendingPathComponent("work/pinebot/runtime/python/bin/python3"),
            (cwd as NSString).appendingPathComponent("runtime/python/bin/python3")
        ]
        for candidate in projectPythonCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        
        // 5. Explicit dev runtime discovery (for local test/dev in package tree)
        let devCandidates = [
            (cwd as NSString).appendingPathComponent(".venv/bin/python3"),
            (cwd as NSString).appendingPathComponent("work/pinebot/.venv/bin/python3"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".pinebot/venv/bin/python3"),
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        
        for candidate in devCandidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        
        // 6. System Python fallback (transparently reports fallback when ML dependencies absent)
        return "/usr/bin/python3"
    }
    
    public static func discoverModelDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appSupportModels = appSupport.appendingPathComponent("Pinebot/models")
        if FileManager.default.fileExists(atPath: appSupportModels.appendingPathComponent("model.onnx").path) {
            return appSupportModels
        }
        
        if let bundleModels = Bundle.main.resourceURL?.appendingPathComponent("models"),
           FileManager.default.fileExists(atPath: bundleModels.appendingPathComponent("model.onnx").path) {
            return bundleModels
        }
        
        let cwd = FileManager.default.currentDirectoryPath
        let cwdModels = URL(fileURLWithPath: cwd).appendingPathComponent("models")
        if FileManager.default.fileExists(atPath: cwdModels.appendingPathComponent("model.onnx").path) {
            return cwdModels
        }
        let workModels = URL(fileURLWithPath: cwd).appendingPathComponent("work/pinebot/models")
        if FileManager.default.fileExists(atPath: workModels.appendingPathComponent("model.onnx").path) {
            return workModels
        }
        
        return appSupportModels
    }
    
    public static func discoverSidecarScript() -> URL {
        // 1. Bundle resource
        if let bundleURL = Bundle.main.url(forResource: "classifier_sidecar", withExtension: "py") {
            return bundleURL
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("classifier_sidecar.py"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        
        // 2. PinebotKit resource bundle
        #if SWIFT_PACKAGE
        if let kitBundle = Bundle.module.url(forResource: "classifier_sidecar", withExtension: "py") {
            return kitBundle
        }
        #endif
        
        // 3. Application Support app-owned resource
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupportScript = appSupport.appendingPathComponent("Pinebot/classifier_sidecar.py")
            if FileManager.default.fileExists(atPath: appSupportScript.path) {
                return appSupportScript
            }
        }
        
        // 4. Local source tree / relative paths
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            (cwd as NSString).appendingPathComponent("work/pinebot/Sources/PinebotKit/Router/classifier_sidecar.py"),
            (cwd as NSString).appendingPathComponent("Sources/PinebotKit/Router/classifier_sidecar.py"),
            (cwd as NSString).appendingPathComponent("classifier_sidecar.py")
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        
        return URL(fileURLWithPath: "/usr/local/share/pinebot/classifier_sidecar.py")
    }
}
