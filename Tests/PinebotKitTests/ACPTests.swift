import XCTest
import AppKit
@testable import PinebotKit

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func append(_ element: String) where T == [String] {
        lock.withLock { value.append(element) }
    }
    var items: T {
        lock.withLock { value }
    }
    func set(_ newValue: T) {
        lock.withLock { value = newValue }
    }
    var current: T {
        lock.withLock { value }
    }
}

/// Mock transport actor implementing ACPTransportProtocol with scripted JSON-RPC transcript.
actor MockACPTransport: ACPTransportProtocol {
    private var _isRunning: Bool = false
    
    var isRunning: Bool {
        return _isRunning
    }
    
    var sentRequests: [(method: String, params: JSONValue?)] = []
    var sentNotifications: [(method: String, params: JSONValue?)] = []
    var sentResponses: [(id: JSONRPCId, result: JSONValue)] = []
    var sentErrors: [(id: JSONRPCId, error: JSONRPCError)] = []
    
    var scriptedResponses: [String: Result<JSONValue, Error>] = [:]
    var notificationHandler: (@Sendable (String, JSONValue) async -> Void)?
    var requestHandler: (@Sendable (JSONRPCId, String, JSONValue?) async throws -> JSONValue?)?
    
    var onPromptRequestStreamChunks: [String] = []
    var stopDelayNanoseconds: UInt64 = 0
    
    private var heldContinuations: [String: [CheckedContinuation<JSONValue, Error>]] = [:]
    private var heldMethods: Set<String> = []
    private var heldArrivalContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requestArrivalContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var autoCancelPromptOnCancelNotification: Bool = false
    
    func setStopDelay(nanoseconds: UInt64) {
        self.stopDelayNanoseconds = nanoseconds
    }
    
    func setHoldRequest(method: String, autoCancelOnNotification: Bool = false) {
        heldMethods.insert(method)
        if autoCancelOnNotification {
            self.autoCancelPromptOnCancelNotification = true
        }
    }
    
    func waitForRequestArrival(method: String) async {
        if sentRequests.contains(where: { $0.method == method }) {
            return
        }
        await withCheckedContinuation { cont in
            requestArrivalContinuations[method, default: []].append(cont)
        }
    }
    
    /// Awaits until a request for `method` has arrived AND registered into heldContinuations
    func waitForHeldRequest(method: String) async {
        if let conts = heldContinuations[method], !conts.isEmpty {
            return
        }
        await withCheckedContinuation { cont in
            heldArrivalContinuations[method, default: []].append(cont)
        }
    }
    
    func releaseHeldRequest(method: String, result: Result<JSONValue, Error>) {
        if let continuations = heldContinuations.removeValue(forKey: method) {
            for c in continuations {
                switch result {
                case .success(let val): c.resume(returning: val)
                case .failure(let err): c.resume(throwing: err)
                }
            }
        }
    }
    
    func start() async throws {
        _isRunning = true
    }
    
    func stop() async {
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
        _isRunning = false
        // Fail any pending held requests when transport stops
        for (_, continuations) in heldContinuations {
            for c in continuations {
                c.resume(throwing: ACPError.cancelled)
            }
        }
        heldContinuations.removeAll()
        for (_, waiters) in heldArrivalContinuations {
            for w in waiters {
                w.resume()
            }
        }
        heldArrivalContinuations.removeAll()
        for (_, waiters) in requestArrivalContinuations {
            for w in waiters {
                w.resume()
            }
        }
        requestArrivalContinuations.removeAll()
    }
    
    func setNotificationHandler(_ handler: (@Sendable (String, JSONValue) async -> Void)?) {
        self.notificationHandler = handler
    }
    
    func setRequestHandler(_ handler: (@Sendable (JSONRPCId, String, JSONValue?) async throws -> JSONValue?)?) {
        self.requestHandler = handler
    }
    
    func setScriptedResponse(method: String, result: Result<JSONValue, Error>) {
        scriptedResponses[method] = result
    }
    
    func setPromptStreamChunks(_ chunks: [String]) {
        self.onPromptRequestStreamChunks = chunks
    }
    
    func simulateNotification(method: String, params: JSONValue) async {
        if let notifHandler = notificationHandler {
            await notifHandler(method, params)
        }
    }
    
    func sendRequest(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        sentRequests.append((method: method, params: params))
        
        // Signal request arrival waiters immediately
        if let waiters = requestArrivalContinuations.removeValue(forKey: method) {
            for w in waiters {
                w.resume()
            }
        }
        
        // If method is explicitly held, suspend on continuation until released or transport stops
        if heldMethods.contains(method) {
            return try await withCheckedThrowingContinuation { cont in
                heldContinuations[method, default: []].append(cont)
                if let waiters = heldArrivalContinuations.removeValue(forKey: method) {
                    for w in waiters {
                        w.resume()
                    }
                }
            }
        }
        
        // If this is session/prompt, stream chunks sequentially and await them
        if method == "session/prompt" && !onPromptRequestStreamChunks.isEmpty {
            let sessionId = params?["sessionId"]?.stringValue ?? "mock-session"
            for chunk in onPromptRequestStreamChunks {
                if let notifHandler = notificationHandler {
                    await notifHandler("session/update", [
                        "sessionId": .string(sessionId),
                        "update": [
                            "sessionUpdate": "agent_message_chunk",
                            "content": [
                                "type": "text",
                                "text": .string(chunk)
                            ]
                        ]
                    ])
                }
            }
        }
        
        guard let response = scriptedResponses[method] else {
            throw ACPError.requestFailed(code: -32601, message: "Method not scripted: \(method)", data: nil)
        }
        
        switch response {
        case .success(let data):
            return data
        case .failure(let err):
            throw err
        }
    }
    
    func sendNotification(method: String, params: JSONValue?) async throws {
        sentNotifications.append((method: method, params: params))
        
        if method == "session/cancel" && autoCancelPromptOnCancelNotification {
            releaseHeldRequest(method: "session/prompt", result: .success([
                "stopReason": "cancelled"
            ]))
        }
    }
    
    func sendResponse(id: JSONRPCId, result: JSONValue) async throws {
        sentResponses.append((id: id, result: result))
    }
    
    func sendError(id: JSONRPCId, error: JSONRPCError) async throws {
        sentErrors.append((id: id, error: error))
    }
    
    func getSentRequests() -> [(method: String, params: JSONValue?)] {
        return sentRequests
    }
    
    func getSentNotifications() -> [(method: String, params: JSONValue?)] {
        return sentNotifications
    }
}

final class ACPTests: XCTestCase {
    
    // MARK: - State Machine & Protocol Scripted Tests
    
    func testGeminiAgentSessionFullStateMachine() async throws {
        let mock = MockACPTransport()
        
        // 1. Script initialize response
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [
                [
                    "id": "oauth-personal",
                    "name": "Log in with Google",
                    "description": "Log in with your Google account"
                ],
                [
                    "id": "gemini-api-key",
                    "name": "Gemini API key",
                    "description": "Use an API key"
                ]
            ],
            "agentInfo": [
                "name": "gemini-cli",
                "title": "Gemini CLI",
                "version": "0.63.0"
            ],
            "agentCapabilities": [
                "promptCapabilities": [
                    "image": true
                ],
                "sessionCapabilities": [
                    "close": [:]
                ]
            ]
        ]))
        
        // 2. Script authenticate response
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        // 3. Script session/new response
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-pinebot-test-42",
            "models": [
                "availableModels": [
                    [
                        "modelId": "gemini-2.5-pro",
                        "name": "Gemini 2.5 Pro",
                        "description": "Frontier reasoning model"
                    ],
                    [
                        "modelId": "gemini-2.5-flash",
                        "name": "Gemini 2.5 Flash",
                        "description": "Fast multimodal model"
                    ]
                ],
                "currentModelId": "gemini-2.5-pro"
            ]
        ]))
        
        // 4. Script session/set_model response
        await mock.setScriptedResponse(method: "session/set_model", result: .success([:]))
        
        // 5. Script session/prompt streaming chunks and final response
        await mock.setPromptStreamChunks(["Hello", " from ", "Gemini ", "via ", "ACP!"])
        await mock.setScriptedResponse(method: "session/prompt", result: .success([
            "stopReason": "end_turn"
        ]))
        
        // 6. Script session/close response
        await mock.setScriptedResponse(method: "session/close", result: .success([:]))
        
        let session = GeminiAgentSession(transport: mock)
        
        // Initial state checks
        let initialInit = await session.isInitialized
        let initialAuth = await session.isAuthenticated
        let initialSess = await session.activeSessionId
        XCTAssertFalse(initialInit)
        XCTAssertFalse(initialAuth)
        XCTAssertNil(initialSess)
        
        // Step 1: Initialize
        _ = try await session.startAndInitialize()
        let postInit = await session.isInitialized
        let authMethods = await session.supportedAuthMethods
        let visionSupported = await session.agentSupportsVision
        let closeSupported = await session.agentSupportsSessionClose
        XCTAssertTrue(postInit)
        XCTAssertTrue(visionSupported)
        XCTAssertTrue(closeSupported)
        XCTAssertTrue(authMethods.contains("oauth-personal"))
        
        // Step 2: Authenticate with status update verification
        let capturedStatuses = LockedBox<[String]>([])
        try await session.authenticate(methodId: "oauth-personal") { status in
            capturedStatuses.append(status)
        }
        let postAuth = await session.isAuthenticated
        XCTAssertTrue(postAuth)
        XCTAssertTrue(capturedStatuses.items.contains(where: { $0.contains("Google") }))
        
        // Step 3: Create Session & Discover Models
        let models = try await session.createNewSession()
        let activeSessionId = await session.activeSessionId
        XCTAssertEqual(activeSessionId, "sess-pinebot-test-42")
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "gemini-2.5-pro")
        XCTAssertEqual(models[0].tier, .frontierReasoning)
        XCTAssertTrue(models[0].supportsVision, "Vision should be true as advertised by initialize")
        XCTAssertFalse(models[0].supportsTools, "Tools should be false until executor integration")
        
        // Step 4: Stream Prompt with selected model
        let streamedChunks = LockedBox<[String]>([])
        let fullResponse = try await session.sendPrompt(
            text: "Introduce yourself",
            model: "gemini-2.5-flash"
        ) { chunk in
            streamedChunks.append(chunk)
        }
        XCTAssertEqual(fullResponse, "Hello from Gemini via ACP!")
        XCTAssertEqual(streamedChunks.items, ["Hello", " from ", "Gemini ", "via ", "ACP!"])
        
        // Verify session/set_model was called before prompt
        let sentReqs = await mock.getSentRequests()
        let setModelReq = sentReqs.first { $0.method == "session/set_model" }
        XCTAssertNotNil(setModelReq, "Must select model before prompt")
        XCTAssertEqual(setModelReq?.params?["modelId"]?.stringValue, "gemini-2.5-flash")
        
        // Step 5: Cancel Prompt while active
        await mock.setHoldRequest(method: "session/prompt", autoCancelOnNotification: true)
        let cancelTask = Task {
            try await session.sendPrompt(text: "Cancel me", model: "gemini-2.5-flash")
        }
        await mock.waitForHeldRequest(method: "session/prompt")
        try await session.cancelCurrentPrompt()
        _ = try? await cancelTask.value
        
        let sentNotifs = await mock.getSentNotifications()
        let cancelNotif = sentNotifs.first { $0.method == "session/cancel" }
        XCTAssertNotNil(cancelNotif)
        XCTAssertEqual(cancelNotif?.params?["sessionId"]?.stringValue, "sess-pinebot-test-42")
        
        // Step 6: Close Session
        await session.close()
        let closedSessionId = await session.activeSessionId
        let closedAuth = await session.isAuthenticated
        XCTAssertNil(closedSessionId)
        XCTAssertFalse(closedAuth)
    }
    
    func testGeminiAgentSessionRejectsUnadvertisedAuthMethod() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "gemini-api-key", "name": "API Key"]]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.startAndInitialize()
        
        do {
            try await session.authenticate(methodId: "oauth-personal")
            XCTFail("Should have thrown error for unadvertised auth method")
        } catch let err as ACPError {
            if case .requestFailed(_, let msg, _) = err {
                XCTAssertTrue(msg.contains("not supported"))
            } else {
                XCTFail("Expected .requestFailed, got: \(err)")
            }
        }
    }
    
    func testGeminiAgentSessionErrorsOnEmptyModelCatalog() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        // session/new returns empty models
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-empty",
            "models": ["availableModels": []]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        
        do {
            _ = try await session.createNewSession()
            XCTFail("Must not invent models when catalog is empty")
        } catch let err as ACPError {
            if case .invalidMessage(let msg) = err {
                XCTAssertTrue(msg.contains("no available models"))
            } else {
                XCTFail("Expected .invalidMessage, got: \(err)")
            }
        }
    }
    
    // MARK: - Helper Script Path
    
    private func getHelperScriptPath() -> String {
        let currentDir = FileManager.default.currentDirectoryPath
        let candidates = [
            (currentDir as NSString).appendingPathComponent("Tests/PinebotKitTests/Resources/acp_test_helper.py"),
            (currentDir as NSString).appendingPathComponent("work/pinebot/Tests/PinebotKitTests/Resources/acp_test_helper.py")
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) {
                return c
            }
        }
        XCTFail("Missing test helper fixture acp_test_helper.py at: \(candidates)")
        return candidates[0]
    }
    
    // MARK: - Real Transport Boundary Tests (Using Test Helper)
    
    func testRealTransportTimeoutKeepsProcessRunningAndNextRequestSucceeds() async throws {
        let helper = getHelperScriptPath()
        
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "timeout_then_respond"]
        )
        try await transport.start()
        
        // Request 1: Must timeout within 500ms
        let startTime = Date()
        do {
            _ = try await transport.sendRequest(method: "first_request", params: nil, timeout: 0.1)
            XCTFail("First request must timeout")
        } catch let err as ACPError {
            if case .timeout(let desc) = err {
                XCTAssertTrue(desc.contains("timed out"))
            } else {
                XCTFail("Expected .timeout, got: \(err)")
            }
        }
        let elapsed = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsed, 0.5, "100ms timeout must return within 500ms")
        
        // Process must remain running
        let runningAfterFirst = await transport.isRunning
        XCTAssertTrue(runningAfterFirst, "Process must remain running after request timeout")
        
        // Request 2: Must SUCCEED as promised
        let secondResult = try await transport.sendRequest(method: "second_request", params: nil, timeout: 1.5)
        XCTAssertEqual(secondResult["status"]?.stringValue, "ok_second_attempt")
        
        await transport.stop()
        let runningAfterStop = await transport.isRunning
        XCTAssertFalse(runningAfterStop)
    }
    
    func testDelayedNotificationOrderingAndSplitReads() async throws {
        let helper = getHelperScriptPath()
        
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "delayed_notifications_then_result"]
        )
        try await transport.start()
        
        let receivedChunks = LockedBox<[String]>([])
        await transport.setNotificationHandler { method, params in
            if method == "session/update" {
                // 50ms delay inside handler to verify single consumer wire order preservation
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let text = params["update"]?["content"]?["text"]?.stringValue {
                    receivedChunks.append(text)
                }
            }
        }
        
        let promptParams: JSONValue = [
            "sessionId": "test-session",
            "prompt": .array([["type": "text", "text": "ping"]])
        ]
        
        let result = try await transport.sendRequest(method: "session/prompt", params: promptParams, timeout: 2.0)
        XCTAssertEqual(result["stopReason"]?.stringValue, "end_turn")
        
        // Chunks MUST be delivered in wire order before sendRequest returns
        XCTAssertEqual(receivedChunks.items, ["part1_", "part2"])
        
        await transport.stop()
    }
    
    func testDelayedNotificationOrderingWithImmediateProcessExit() async throws {
        let helper = getHelperScriptPath()
        
        // Run 5 consecutive iterations to guarantee no timing/drain race exists
        for iteration in 1...5 {
            let transport = ACPTransport(
                executablePath: "/usr/bin/python3",
                arguments: [helper, "notifications_then_result_then_exit_now"]
            )
            try await transport.start()
            
            let receivedChunks = LockedBox<[String]>([])
            await transport.setNotificationHandler { method, params in
                if method == "session/update" {
                    // Slow handler simulation: 30ms async sleep
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if let text = params["update"]?["content"]?["text"]?.stringValue {
                        receivedChunks.append(text)
                    }
                }
            }
            
            let promptParams: JSONValue = [
                "sessionId": .string("test-session-\(iteration)"),
                "prompt": .array([["type": "text", "text": "ping"]])
            ]
            
            let result = try await transport.sendRequest(method: "session/prompt", params: promptParams, timeout: 3.0)
            XCTAssertEqual(result["stopReason"]?.stringValue, "end_turn", "Iteration \(iteration) must receive valid final result before process termination cleanup")
            XCTAssertEqual(receivedChunks.items, ["part1_", "part2"], "Iteration \(iteration) must deliver all notifications in wire order even when process exits immediately")
            
            await transport.stop()
        }
    }
    
    func testSlowNotificationHandlerWithImmediateExitDoesNotTriggerFallbackTimeout() async throws {
        let helper = getHelperScriptPath()
        
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "notifications_then_result_then_exit_now"]
        )
        try await transport.start()
        
        let receivedChunks = LockedBox<[String]>([])
        await transport.setNotificationHandler { method, params in
            if method == "session/update" {
                // Deterministic >3.0s slow-handler simulation: 3.2s sleep (> 3.0s fallback timer)
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                if let text = params["update"]?["content"]?["text"]?.stringValue {
                    receivedChunks.append(text)
                }
            }
        }
        
        let promptParams: JSONValue = [
            "sessionId": .string("test-session-slow-handler"),
            "prompt": .array([["type": "text", "text": "ping"]])
        ]
        
        // Request deadline is 10.0s (longer than the 3.2s slow handler)
        let result = try await transport.sendRequest(method: "session/prompt", params: promptParams, timeout: 10.0)
        XCTAssertEqual(result["stopReason"]?.stringValue, "end_turn", "Must receive valid final result even when slow handler exceeds 3.0s")
        XCTAssertEqual(receivedChunks.items, ["part1_", "part2"], "Must deliver all notifications in wire order despite >3s slow handler")
        
        await transport.stop()
    }
    
    func testStopAndRestartWhileOldNotificationHandlerIsSuspendedDoesNotCorruptNewProcess() async throws {
        let helper = getHelperScriptPath()
        
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "persistent_serve_requests"]
        )
        try await transport.start()
        
        let handlerGate = LockedBox<Bool>(false)
        let handlerEntered = LockedBox<Bool>(false)
        await transport.setNotificationHandler { method, _ in
            if method == "session/update" {
                handlerEntered.set(true)
                // Deterministic suspended handler gate that deliberately ignores cancellation until released
                while !handlerGate.current {
                    usleep(10_000)
                }
            }
        }
        
        let promptParams1: JSONValue = [
            "sessionId": .string("test-session-gen1"),
            "prompt": .array([["type": "text", "text": "ping"]])
        ]
        
        // Launch request asynchronously on gen 1 to trigger notification handler
        Task {
            _ = try? await transport.sendRequest(method: "session/prompt", params: promptParams1, timeout: 5.0)
        }
        
        // Wait until handler is actively suspended
        for _ in 0..<100 {
            if handlerEntered.current { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(handlerEntered.current, "Old notification handler must have started and entered suspension")
        
        // While old handler is suspended, stop and restart transport (advancing processGeneration to gen 2)
        await transport.stop()
        try await transport.start()
        let isRunningGen2 = await transport.isRunning
        XCTAssertTrue(isRunningGen2, "Gen two process must be running after start")
        
        // Configure new fast handler for gen 2
        let gen2Chunks = LockedBox<[String]>([])
        await transport.setNotificationHandler { method, params in
            if method == "session/update" {
                if let text = params["update"]?["content"]?["text"]?.stringValue {
                    gen2Chunks.append(text)
                }
            }
        }
        
        // Release the deterministic gate so old handler resumes
        handlerGate.set(true)
        
        // Allow the old suspended thread to wake up and exit
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify new process was NOT closed or corrupted by the old resumed consumer
        let isStillRunning = await transport.isRunning
        XCTAssertTrue(isStillRunning, "New persistent process must still be running after old resumed handler exits")
        
        // Assert fresh subsequent gen two request still succeeds after old handler resumes
        let promptParams2: JSONValue = [
            "sessionId": .string("test-session-gen2"),
            "prompt": .array([["type": "text", "text": "ping2"]])
        ]
        let result2 = try await transport.sendRequest(method: "session/prompt", params: promptParams2, timeout: 5.0)
        XCTAssertEqual(result2["stopReason"]?.stringValue, "end_turn", "New generation request must succeed after old handler resumes")
        XCTAssertEqual(gen2Chunks.items, ["chunk1", "chunk2"])
        
        // Verify another subsequent request continues serving normally
        let promptParams3: JSONValue = [
            "sessionId": .string("test-session-gen2-subsequent"),
            "prompt": .array([["type": "text", "text": "ping3"]])
        ]
        let result3 = try await transport.sendRequest(method: "session/prompt", params: promptParams3, timeout: 5.0)
        XCTAssertEqual(result3["stopReason"]?.stringValue, "end_turn", "Subsequent generation request must succeed on persistent server")
        
        await transport.stop()
    }
    
    func testSplitReadsCoalescing() async throws {
        let helper = getHelperScriptPath()
        
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "split_reads"]
        )
        try await transport.start()
        
        let result = try await transport.sendRequest(method: "split_test", params: nil, timeout: 2.0)
        XCTAssertEqual(result["coalesced"]?.boolValue, true)
        
        await transport.stop()
    }
    
    func testUnknownAgentRequestReceivesMethodNotFound() async throws {
        let helper = getHelperScriptPath()
        
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "agent_unknown_request"]
        )
        
        let verifiedBox = LockedBox<[String]>([])
        await transport.setNotificationHandler { method, params in
            if method == "test/verified" {
                if let code = params["got_code"]?.intValue, let id = params["got_id"]?.intValue {
                    verifiedBox.append("\(code):\(id)")
                }
            }
        }
        
        try await transport.start()
        
        // Wait for helper to send unknown request and receive -32601 error response
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Helper must verify that it received error code -32601 for id 888
        let items = verifiedBox.items
        XCTAssertTrue(items.contains("-32601:888"), "Agent must receive Method not found (-32601) error for unknown request: \(items)")
        
        await transport.stop()
    }
    
    func testTransportStartRollbackOnRunFailurePermitsRetry() async throws {
        let nonexistent = "/nonexistent/binary_\(UUID().uuidString)"
        let transport = ACPTransport(
            executablePath: nonexistent,
            arguments: []
        )
        
        do {
            try await transport.start()
            XCTFail("start() must throw on non-existent executable")
        } catch {
            // Expected
        }
        
        let runningAfterFail = await transport.isRunning
        XCTAssertFalse(runningAfterFail)
        
        // Retry with valid executable
        let helper = getHelperScriptPath()
        let validTransport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "close_stdout_alive"]
        )
        try await validTransport.start()
        let runningValid = await validTransport.isRunning
        XCTAssertTrue(runningValid)
        await validTransport.stop()
    }
    
    func testTransportEOFTerminatesProcessAndCleansUp() async throws {
        let helper = getHelperScriptPath()
        let transport = ACPTransport(
            executablePath: "/usr/bin/python3",
            arguments: [helper, "close_stdout_alive"]
        )
        try await transport.start()
        
        // Helper immediately closes stdout, triggering EOF branch in ACPTransport
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let running = await transport.isRunning
        XCTAssertFalse(running, "Transport must not be running after stdout EOF")
        
        // Subsequent request must fail
        do {
            _ = try await transport.sendRequest(method: "ping", params: nil, timeout: 1.0)
            XCTFail("Request must fail after process termination")
        } catch let err as ACPError {
            switch err {
            case .processNotStarted, .processTerminated:
                break
            default:
                XCTFail("Expected .processNotStarted or .processTerminated, got: \(err)")
            }
        }
    }
    
    // MARK: - GeminiAgentSession Cancellation Tests
    
    func testNeverAcksCancelReturnsWithinBound() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": ["sessionCapabilities": ["close": [:]]]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-hang-cancel",
            "models": ["availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini Pro"]]]
        ]))
        await mock.setScriptedResponse(method: "session/set_model", result: .success([:]))
        await mock.setScriptedResponse(method: "session/close", result: .success([:]))
        // Explicitly hold session/prompt so it waits indefinitely without replying
        await mock.setHoldRequest(method: "session/prompt")
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.startAndInitialize()
        try await session.authenticate(methodId: "oauth-personal")
        _ = try await session.createNewSession()
        
        let promptTask = Task {
            try await session.sendPrompt(text: "Hanging prompt", model: "gemini-2.5-pro", timeout: 30.0)
        }
        
        // Wait for held request arrival
        await mock.waitForHeldRequest(method: "session/prompt")
        let isTurnActive = await session.turnActive
        XCTAssertTrue(isTurnActive)
        
        let start = Date()
        try await session.cancelCurrentPrompt(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        
        XCTAssertLessThan(elapsed, 0.7, "Cancel must return within deadline bound even if agent never acks cancel")
        let turnAfter = await session.turnActive
        let sessAfter = await session.activeSessionId
        XCTAssertFalse(turnAfter)
        XCTAssertNil(sessAfter, "Session must be closed when cancel deadline expires")
        
        promptTask.cancel()
    }
    
    func testTimedOutPromptLateChunkVsNextPrompt() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": ["sessionCapabilities": ["close": [:]]]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-timed-out-prompt",
            "models": ["availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini Pro"]]]
        ]))
        await mock.setScriptedResponse(method: "session/set_model", result: .success([:]))
        await mock.setScriptedResponse(method: "session/close", result: .success([:]))
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.startAndInitialize()
        try await session.authenticate(methodId: "oauth-personal")
        _ = try await session.createNewSession()
        
        // 1. Send prompt that times out (sendRequest throws timeout)
        await mock.setScriptedResponse(method: "session/prompt", result: .failure(ACPError.timeout("Request timed out")))
        
        do {
            _ = try await session.sendPrompt(text: "Prompt 1", model: "gemini-2.5-pro", timeout: 0.1)
            XCTFail("Prompt 1 must fail with timeout")
        } catch {
            // Expected
        }
        
        // Session should be closed after RPC error
        let sessAfterTimeout = await session.activeSessionId
        XCTAssertNil(sessAfterTimeout, "Session must be closed after abandoned prompt")
        
        // 2. Late chunk arrives for the old session - must be dropped
        if let notifHandler = await mock.notificationHandler {
            await notifHandler("session/update", [
                "sessionId": "sess-timed-out-prompt",
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": "LATE CHUNK FROM PROMPT 1"]
                ]
            ])
        }
        
        // 3. Prompt 2 starts on a fresh session
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-prompt-2",
            "models": ["availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini Pro"]]]
        ]))
        await mock.setPromptStreamChunks(["Fresh chunk 1", " Fresh chunk 2"])
        await mock.setScriptedResponse(method: "session/prompt", result: .success([
            "stopReason": "end_turn"
        ]))
        
        let prompt2Result = try await session.sendPrompt(text: "Prompt 2", model: "gemini-2.5-pro", timeout: 2.0)
        XCTAssertEqual(prompt2Result, "Fresh chunk 1 Fresh chunk 2")
        XCTAssertFalse(prompt2Result.contains("LATE CHUNK"), "Prompt 2 result must not be contaminated by late chunk from Prompt 1")
    }
    
    func testNormalAckCancel() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-normal-cancel",
            "models": ["availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini Pro"]]]
        ]))
        await mock.setScriptedResponse(method: "session/set_model", result: .success([:]))
        // Hold session/prompt until session/cancel notification arrives, then reply with stopReason: "cancelled"
        await mock.setHoldRequest(method: "session/prompt", autoCancelOnNotification: true)
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.startAndInitialize()
        try await session.authenticate(methodId: "oauth-personal")
        _ = try await session.createNewSession()
        
        let promptTask = Task {
            try await session.sendPrompt(text: "Prompt to cancel", model: "gemini-2.5-pro", timeout: 5.0)
        }
        
        // Wait for held request arrival before cancelling
        await mock.waitForHeldRequest(method: "session/prompt")
        let isTurnActive = await session.turnActive
        XCTAssertTrue(isTurnActive)
        
        try await session.cancelCurrentPrompt(timeout: 2.0)
        
        do {
            _ = try await promptTask.value
            XCTFail("Cancelled prompt must throw ACPError.cancelled")
        } catch let err as ACPError {
            if case .cancelled = err {
                // Success
            } else {
                XCTFail("Expected .cancelled, got: \(err)")
            }
        }
        
        let turnActiveAfter = await session.turnActive
        XCTAssertFalse(turnActiveAfter)
        
        // Regression assertion: normal ack returns promptly without closing or requiring re-authentication
        let sessIdAfter = await session.activeSessionId
        let isAuthAfter = await session.isAuthenticated
        XCTAssertEqual(sessIdAfter, "sess-normal-cancel", "Normal cancellation must keep active session")
        XCTAssertTrue(isAuthAfter, "Normal cancellation must keep session authenticated")
    }
    
    func testImmediateNewTurnDuringCloseCannotLaunchAgainstDyingTransport() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-close-race",
            "models": ["availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini Pro"]]]
        ]))
        await mock.setScriptedResponse(method: "session/set_model", result: .success([:]))
        // Stop takes 100ms
        await mock.setStopDelay(nanoseconds: 100_000_000)
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.startAndInitialize()
        try await session.authenticate(methodId: "oauth-personal")
        _ = try await session.createNewSession()
        
        // Launch close in background task
        let closeTask = Task {
            await session.close()
        }
        
        // Brief yield so close() enters and sets isClosing = true before transport.stop completes
        try await Task.sleep(nanoseconds: 10_000_000)
        
        // Immediate attempt to launch new prompt turn while session is closing
        do {
            _ = try await session.sendPrompt(text: "Immediate turn during close", model: "gemini-2.5-pro")
            XCTFail("sendPrompt must be rejected while session is closing")
        } catch let err as ACPError {
            if case .requestFailed(_, let msg, _) = err {
                XCTAssertTrue(msg.contains("closing") || msg.contains("tearing down"), "Error should explain session is closing: \(msg)")
            } else {
                XCTFail("Expected .requestFailed, got: \(err)")
            }
        }
        
        // Verify mock never received session/prompt from that dying turn
        let requests = await mock.getSentRequests()
        let promptSent = requests.contains(where: { $0.method == "session/prompt" })
        XCTAssertFalse(promptSent, "Prompt must NEVER be sent to transport while dying/closing")
        
        // Await close completion
        await closeTask.value
        
        let isClosed = await session.activeSessionId
        let isTurnActive = await session.turnActive
        XCTAssertNil(isClosed)
        XCTAssertFalse(isTurnActive)
    }
    
    // MARK: - Official ACP session-config-options Tests
    
    func testSessionConfigOptionsFlatParsingAndSetOption() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": ["promptCapabilities": ["image": true]]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        // session/new with ONLY configOptions (no legacy models field)
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-config-flat",
            "configOptions": [
                [
                    "id": "mode",
                    "name": "Session Mode",
                    "category": "mode",
                    "type": "select",
                    "currentValue": "code",
                    "options": [
                        ["value": "code", "name": "Code"]
                    ]
                ],
                [
                    "id": "model_selector",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash", "description": "Fast"],
                        ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro", "description": "Reasoning"]
                    ]
                ]
            ]
        ]))
        
        // session/set_config_option response
        await mock.setScriptedResponse(method: "session/set_config_option", result: .success([
            "configOptions": [
                [
                    "id": "model_selector",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-pro",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"],
                        ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                    ]
                ]
            ]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        let models = try await session.createNewSession()
        
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "gemini-2.5-flash")
        XCTAssertEqual(models[0].tier, .cheapFast)
        XCTAssertEqual(models[1].id, "gemini-2.5-pro")
        XCTAssertEqual(models[1].tier, .frontierReasoning)
        
        let currentModel = await session.currentModelId
        XCTAssertEqual(currentModel, "gemini-2.5-flash")
        
        // Set model: must invoke session/set_config_option with configId: model_selector
        try await session.setSessionModel("gemini-2.5-pro")
        
        let requests = await mock.getSentRequests()
        guard let setReq = requests.first(where: { $0.method == "session/set_config_option" }) else {
            XCTFail("Must call session/set_config_option when modelConfigId is present")
            return
        }
        XCTAssertEqual(setReq.params?["configId"]?.stringValue, "model_selector")
        XCTAssertEqual(setReq.params?["value"]?.stringValue, "gemini-2.5-pro")
        
        let updatedModel = await session.currentModelId
        XCTAssertEqual(updatedModel, "gemini-2.5-pro")
    }
    
    func testSessionConfigOptionsGroupedParsing() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        // session/new with Grouped Select Options
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-grouped",
            "configOptions": [
                [
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        [
                            "group": "recommended",
                            "name": "Recommended",
                            "options": [
                                ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash", "description": "Fast for everyday tasks"]
                            ]
                        ],
                        [
                            "group": "advanced",
                            "name": "Advanced Reasoning",
                            "options": [
                                ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro", "description": "Complex tasks"],
                                ["value": "gemini-ultra-test", "name": "Gemini Ultra", "description": "Deepest reasoning"]
                            ]
                        ]
                    ]
                ]
            ]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        let models = try await session.createNewSession()
        
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models.map { $0.id }, ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-ultra-test"])
        XCTAssertEqual(models.map { $0.displayName }, ["Gemini 2.5 Flash", "Gemini 2.5 Pro", "Gemini Ultra"])
        let current = await session.currentModelId
        XCTAssertEqual(current, "gemini-2.5-flash")
    }
    
    func testSessionConfigOptionUpdateNotificationAuthoritativeRefresh() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-notification-test",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"]
                    ]
                ]
            ]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.createNewSession()
        let initialModel = await session.currentModelId
        XCTAssertEqual(initialModel, "gemini-2.5-flash")
        
        // Agent sends authoritative config_option_update notification
        let notificationParams: JSONValue = [
            "sessionId": "sess-notification-test",
            "update": [
                "sessionUpdate": "config_option_update",
                "configOptions": [
                    [
                        "id": "model",
                        "category": "model",
                        "type": "select",
                        "currentValue": "gemini-2.5-pro",
                        "options": [
                            ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"],
                            ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                        ]
                    ]
                ]
            ]
        ]
        
        await mock.simulateNotification(method: "session/update", params: notificationParams)
        
        let refreshedModel = await session.currentModelId
        let refreshedList = await session.availableModels
        XCTAssertEqual(refreshedModel, "gemini-2.5-pro", "Current model must update authoritatively from config_option_update")
        XCTAssertEqual(refreshedList.count, 2, "Available models list must update from config_option_update")
    }
    
    func testSessionLegacyModelsFallbackWhenNoConfigOptions() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        // Legacy response: models.availableModels ONLY
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-legacy-models",
            "models": [
                "availableModels": [
                    ["modelId": "gemini-legacy-1", "name": "Legacy Model 1"]
                ],
                "currentModelId": "gemini-legacy-1"
            ]
        ]))
        await mock.setScriptedResponse(method: "session/set_model", result: .success([:]))
        
        let session = GeminiAgentSession(transport: mock)
        let models = try await session.createNewSession()
        
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.id, "gemini-legacy-1")
        
        // Without configOptions, setSessionModel must fall back to legacy session/set_model
        try await session.setSessionModel("gemini-legacy-1-new")
        
        let requests = await mock.getSentRequests()
        let hasLegacySetModel = requests.contains { $0.method == "session/set_model" }
        XCTAssertTrue(hasLegacySetModel, "Must call legacy session/set_model when configOptions is absent")
    }
    
    func testSessionSetConfigOptionThrowsOnMissingOrMalformedConfigOptions() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        let initialConfig: JSONValue = [
            "sessionId": "sess-malformed-test",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"],
                        ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                    ]
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/new", result: .success(initialConfig))
        
        // Malformed response: missing configOptions array (empty dictionary)
        await mock.setScriptedResponse(method: "session/set_config_option", result: .success([:]))
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.createNewSession()
        
        let beforeModel = await session.currentModelId
        XCTAssertEqual(beforeModel, "gemini-2.5-flash")
        
        do {
            try await session.setSessionModel("gemini-2.5-pro")
            XCTFail("Must throw error when session/set_config_option response is missing configOptions")
        } catch {
            // Expected error
        }
        
        let afterModel = await session.currentModelId
        XCTAssertEqual(afterModel, "gemini-2.5-flash", "Must NOT pretend requested model was selected on malformed response")
    }
    
    func testSessionConfigOptionUpdateClearsCatalogWhenModelSelectorRemoved() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        let initialConfig: JSONValue = [
            "sessionId": "sess-remove-models",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"]
                    ]
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/new", result: .success(initialConfig))
        
        let session = GeminiAgentSession(transport: mock)
        let initialModels = try await session.createNewSession()
        XCTAssertEqual(initialModels.count, 1)
        
        // Notification where model selector is removed (e.g. only temperature option remains)
        let updateNotification: JSONValue = [
            "sessionId": "sess-remove-models",
            "update": [
                "sessionUpdate": "config_option_update",
                "configOptions": [
                    [
                        "id": "temperature",
                        "category": "generation",
                        "type": "slider",
                        "currentValue": 0.7
                    ]
                ]
            ]
        ]
        
        await mock.simulateNotification(method: "session/update", params: updateNotification)
        
        let clearedModels = await session.availableModels
        let clearedCurrent = await session.currentModelId
        XCTAssertTrue(clearedModels.isEmpty, "Full refresh which removes model selector must clear old catalog")
        XCTAssertNil(clearedCurrent, "Current model must be cleared when model selector is removed")
    }
    
    @MainActor
    func testConfigOptionUpdatePropagatesToGeminiProviderAndProviderManager() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        let initialConfig: JSONValue = [
            "sessionId": "sess-propagate",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"]
                    ]
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/new", result: .success(initialConfig))
        
        let session = GeminiAgentSession(transport: mock)
        let suiteName = "test.propagate.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        
        let provider = GeminiProvider(
            agentSession: session,
            defaults: testDefaults,
            keyPrefix: "test.gemini.\(UUID().uuidString)"
        )
        
        let manager = ProviderManager(gemini: provider)
        _ = try await provider.startOfficialAccountAuth()
        
        manager.setState(.connected(accountSummary: "Google Account", models: provider.discoveredModels), for: .gemini)
        manager.refreshConnectedModels()
        
        XCTAssertEqual(manager.connectedModels.count, 1)
        XCTAssertEqual(manager.connectedModels.first?.id, "gemini-2.5-flash")
        
        // Now simulate config_option_update with an added second model
        let updateNotification: JSONValue = [
            "sessionId": "sess-propagate",
            "update": [
                "sessionUpdate": "config_option_update",
                "configOptions": [
                    [
                        "id": "model",
                        "category": "model",
                        "type": "select",
                        "currentValue": "gemini-2.5-pro",
                        "options": [
                            ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"],
                            ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                        ]
                    ]
                ]
            ]
        ]
        
        await mock.simulateNotification(method: "session/update", params: updateNotification)
        
        // Allow Task hop on MainActor
        try await Task.sleep(nanoseconds: 50_000_000)
        
        XCTAssertEqual(provider.discoveredModels.count, 2, "GeminiProvider must reflect updated models")
        XCTAssertEqual(manager.connectedModels.count, 2, "ProviderManager must authoritatively update connected models")
        let ids = manager.connectedModels.map { $0.id }
        XCTAssertTrue(ids.contains("gemini-2.5-pro"))
    }
    
    func testRequestedInCatalogButNotSelectedThrowsActionableMismatch() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        let initialConfig: JSONValue = [
            "sessionId": "sess-mismatch-test",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"],
                        ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                    ]
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/new", result: .success(initialConfig))
        
        // Agent responds to set_config_option returning configOptions where currentValue remains gemini-2.5-flash
        let agentRejectionResponse: JSONValue = [
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [
                        ["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"],
                        ["value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                    ]
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/set_config_option", result: .success(agentRejectionResponse))
        
        let session = GeminiAgentSession(transport: mock)
        _ = try await session.createNewSession()
        
        do {
            try await session.setSessionModel("gemini-2.5-pro")
            XCTFail("Must throw error when agent did not select requested model, even if present in catalog")
        } catch let err as ACPError {
            switch err {
            case .requestFailed(_, let message, _):
                XCTAssertTrue(message.contains("Model selection mismatch"), "Error must be actionable mismatch: \(message)")
                XCTAssertTrue(message.contains("gemini-2.5-pro"), "Error must name requested model: \(message)")
                XCTAssertTrue(message.contains("gemini-2.5-flash"), "Error must name actual selected model: \(message)")
            default:
                XCTFail("Expected .requestFailed, got \(err)")
            }
        }
        
        let current = await session.currentModelId
        XCTAssertEqual(current, "gemini-2.5-flash", "Session must authoritatively retain actual selected model")
    }
    
    @MainActor
    func testDelayedOldCatalogAfterReconnectOrReplacementDropped() async throws {
        let mock1 = MockACPTransport()
        await mock1.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock1.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock1.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-old",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-old-model",
                    "options": [
                        ["value": "gemini-old-model", "name": "Old Model"]
                    ]
                ]
            ]
        ]))
        
        let session1 = GeminiAgentSession(transport: mock1)
        let suite1 = "test.reconnect.\(UUID().uuidString)"
        let testDefaults1 = UserDefaults(suiteName: suite1)!
        defer { testDefaults1.removePersistentDomain(forName: suite1) }
        
        let provider1 = GeminiProvider(
            agentSession: session1,
            defaults: testDefaults1,
            keyPrefix: "test.gemini.\(UUID().uuidString)"
        )
        
        let manager = ProviderManager(gemini: provider1)
        _ = try await provider1.startOfficialAccountAuth()
        manager.setState(.connected(accountSummary: "Google Account", models: provider1.discoveredModels), for: .gemini)
        manager.refreshConnectedModels()
        
        XCTAssertEqual(manager.connectedModels.first?.id, "gemini-old-model")
        
        // Now create provider2 and replace provider1 in manager
        let mock2 = MockACPTransport()
        await mock2.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock2.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock2.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-new",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-new-model",
                    "options": [
                        ["value": "gemini-new-model", "name": "New Model"]
                    ]
                ]
            ]
        ]))
        
        let session2 = GeminiAgentSession(transport: mock2)
        let provider2 = GeminiProvider(
            agentSession: session2,
            defaults: testDefaults1,
            keyPrefix: "test.gemini.\(UUID().uuidString)"
        )
        manager.setProvider(provider2, for: .gemini)
        _ = try await provider2.startOfficialAccountAuth()
        manager.setState(.connected(accountSummary: "Google Account New", models: provider2.discoveredModels), for: .gemini)
        manager.refreshConnectedModels()
        
        XCTAssertEqual(manager.connectedModels.first?.id, "gemini-new-model")
        
        // Now old session1 fires a delayed config_option_update trying to inject stale models
        let staleUpdate: JSONValue = [
            "sessionId": "sess-old",
            "update": [
                "sessionUpdate": "config_option_update",
                "configOptions": [
                    [
                        "id": "model",
                        "category": "model",
                        "type": "select",
                        "currentValue": "gemini-stale-injected",
                        "options": [
                            ["value": "gemini-stale-injected", "name": "Stale Injected"]
                        ]
                    ]
                ]
            ]
        ]
        
        await mock1.simulateNotification(method: "session/update", params: staleUpdate)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Assert manager and provider2 were NOT overwritten by old session1
        XCTAssertEqual(manager.connectedModels.first?.id, "gemini-new-model", "ProviderManager must ignore delayed updates from replaced provider/old session")
        XCTAssertEqual(provider2.discoveredModels.first?.id, "gemini-new-model")
    }
    
    func testModelConfigParsingRequiresSelectTypeAndValidId() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        
        // Option with category "model" but type "boolean" (unsupported selector)
        let booleanOption: JSONValue = [
            "sessionId": "sess-type-check",
            "configOptions": [
                [
                    "id": "enable_model",
                    "category": "model",
                    "type": "boolean",
                    "currentValue": true
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/new", result: .success(booleanOption))
        
        let session = GeminiAgentSession(transport: mock)
        do {
            _ = try await session.createNewSession()
            XCTFail("Must fail when config options only contain non-select types")
        } catch let err as ACPError {
            switch err {
            case .invalidMessage(let msg):
                XCTAssertTrue(msg.contains("returned no available models"), "Should report no models: \(msg)")
            default:
                XCTFail("Expected .invalidMessage, got \(err)")
            }
        }
        
        // Option with type "select" but empty id
        let emptyIdOption: JSONValue = [
            "sessionId": "sess-empty-id",
            "configOptions": [
                [
                    "id": "   ",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-flash",
                    "options": [["value": "gemini-flash", "name": "Gemini Flash"]]
                ]
            ]
        ]
        await mock.setScriptedResponse(method: "session/new", result: .success(emptyIdOption))
        
        do {
            _ = try await session.createNewSession()
            XCTFail("Must fail when config option has empty id and not invent 'model'")
        } catch let err as ACPError {
            switch err {
            case .invalidMessage:
                break // Expected
            default:
                XCTFail("Expected .invalidMessage, got \(err)")
            }
        }
    }
    
    // MARK: - Live CLI Handshake (if executable exists in environment)
    
    func testLiveGeminiCLIHandshakeIfInstalled() async throws {
        let transport = ACPTransport()
        let resolution: ACPTransport.ResolvedExecution
        do {
            resolution = try await transport.resolveExecutableAndArguments()
        } catch {
            throw XCTSkip("No ACP executable resolved: \(error)")
        }
        
        guard FileManager.default.isExecutableFile(atPath: resolution.executable) else {
            throw XCTSkip("Executable not present or not executable: \(resolution.executable)")
        }
        
        let liveTransport = ACPTransport(
            executablePath: resolution.executable,
            arguments: resolution.arguments
        )
        
        try await liveTransport.start()
        
        let initParams: JSONValue = [
            "protocolVersion": 1,
            "clientInfo": ["name": "PinebotTest", "version": "1.0.0"],
            "clientCapabilities": [:]
        ]
        
        let result = try await liveTransport.sendRequest(method: "initialize", params: initParams, timeout: 10.0)
        
        XCTAssertEqual(result["protocolVersion"]?.intValue, 1)
        
        guard let authMethods = result["authMethods"]?.arrayValue else {
            XCTFail("Missing authMethods in initialize response: \(result)")
            await liveTransport.stop()
            return
        }
        let hasOAuthPersonal = authMethods.contains { ($0["id"]?.stringValue) == "oauth-personal" }
        XCTAssertTrue(hasOAuthPersonal, "CLI initialize must advertise 'oauth-personal' for Google login: \(authMethods)")
        
        await liveTransport.stop()
    }
}

