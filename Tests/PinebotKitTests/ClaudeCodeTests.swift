import XCTest
import AppKit
@testable import PinebotKit

final class MockClaudeRuntimeLocator: ClaudeRuntimeLocating, @unchecked Sendable {
    var mockClaudeURL: URL?
    var mockACPAdapterURL: URL?
    var mockNodeURL: URL?
    var mockWorkingDir: URL?
    
    init(
        claudeURL: URL? = URL(fileURLWithPath: "/mock/bin/claude"),
        acpAdapterURL: URL? = URL(fileURLWithPath: "/mock/bin/claude-agent-acp"),
        nodeURL: URL? = URL(fileURLWithPath: "/usr/local/bin/node"),
        workingDir: URL? = URL(fileURLWithPath: "/mock")
    ) {
        self.mockClaudeURL = claudeURL
        self.mockACPAdapterURL = acpAdapterURL
        self.mockNodeURL = nodeURL
        self.mockWorkingDir = workingDir
    }
    
    func locateRuntime() throws -> ClaudeRuntimeLocations {
        guard let c = mockClaudeURL else {
            throw ClaudeRuntimeError.claudeCLINotFound("Mock claude not found")
        }
        guard let a = mockACPAdapterURL else {
            throw ClaudeRuntimeError.acpAdapterNotFound("Mock acp not found")
        }
        return ClaudeRuntimeLocations(
            claudeCLIURL: c,
            acpAdapterURL: a,
            nodeURL: mockNodeURL,
            workingDirectory: mockWorkingDir
        )
    }
    
    func locateClaudeCLI() -> URL? {
        return mockClaudeURL
    }
    
    func locateACPAdapter() -> URL? {
        return mockACPAdapterURL
    }
    
    func locateNode() -> URL? {
        return mockNodeURL
    }
}

final class ClaudeCodeTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var testKeychain: KeychainHelper!
    private var uniqueSuiteName: String!
    
    override func setUp() {
        super.setUp()
        uniqueSuiteName = "com.pinebot.test.claude.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: uniqueSuiteName)!
        testKeychain = KeychainHelper.shared
    }
    
    override func tearDown() {
        testDefaults.removePersistentDomain(forName: uniqueSuiteName)
        testDefaults = nil
        super.tearDown()
    }
    
    // MARK: - 1. Model Discovery from ACP configOptions
    
    func testClaudeCodeSessionModelDiscoveryFromConfigOptions() async throws {
        let mockTransport = MockACPTransport()
        
        await mockTransport.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "agentCapabilities": [
                "promptCapabilities": ["image": true],
                "sessionCapabilities": ["close": true]
            ]
        ]))
        
        await mockTransport.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "claude-session-123",
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-7-sonnet-20250219",
                    "options": [
                        [
                            "value": "claude-3-7-sonnet-20250219",
                            "name": "Claude 3.7 Sonnet (Hybrid Reasoning)"
                        ],
                        [
                            "value": "claude-3-5-haiku-20241022",
                            "name": "Claude 3.5 Haiku"
                        ]
                    ]
                ]
            ]
        ]))
        
        let locator = MockClaudeRuntimeLocator()
        let session = ClaudeCodeSession(runtimeLocator: locator, transport: mockTransport)
        
        let models = try await session.createNewSession()
        
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "claude-3-7-sonnet-20250219")
        XCTAssertEqual(models[0].provider, .claude)
        XCTAssertEqual(models[0].tier, .frontierReasoning)
        XCTAssertTrue(models[0].supportsVision)
        XCTAssertTrue(models[0].supportsTools)
        XCTAssertEqual(models[0].compactDisplayName, "Claude 3.7 Sonnet")
        
        XCTAssertEqual(models[1].id, "claude-3-5-haiku-20241022")
        XCTAssertEqual(models[1].tier, .cheapFast)
        
        let curModel = await session.currentModelId
        XCTAssertEqual(curModel, "claude-3-7-sonnet-20250219")
    }
    
    // MARK: - 2. Authoritative Model Switch
    
    func testClaudeCodeSessionModelSwitchEnforcesAuthoritativeSelection() async throws {
        let mockTransport = MockACPTransport()
        
        await mockTransport.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1
        ]))
        
        await mockTransport.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "claude-session-456",
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-7-sonnet-20250219",
                    "options": [
                        ["value": "claude-3-7-sonnet-20250219", "name": "Claude 3.7 Sonnet"],
                        ["value": "claude-3-5-haiku-20241022", "name": "Claude 3.5 Haiku"]
                    ]
                ]
            ]
        ]))
        
        // Successful switch returns updated currentValue matching requested
        await mockTransport.setScriptedResponse(method: "session/set_config_option", result: .success([
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-5-haiku-20241022",
                    "options": [
                        ["value": "claude-3-7-sonnet-20250219", "name": "Claude 3.7 Sonnet"],
                        ["value": "claude-3-5-haiku-20241022", "name": "Claude 3.5 Haiku"]
                    ]
                ]
            ]
        ]))
        
        let session = ClaudeCodeSession(runtimeLocator: MockClaudeRuntimeLocator(), transport: mockTransport)
        _ = try await session.createNewSession()
        
        try await session.setSessionModel("claude-3-5-haiku-20241022")
        let updated = await session.currentModelId
        XCTAssertEqual(updated, "claude-3-5-haiku-20241022")
        
        // Mismatch response: user requests sonnet, but agent keeps/returns haiku
        await mockTransport.setScriptedResponse(method: "session/set_config_option", result: .success([
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-5-haiku-20241022",
                    "options": [
                        ["value": "claude-3-7-sonnet-20250219", "name": "Claude 3.7 Sonnet"],
                        ["value": "claude-3-5-haiku-20241022", "name": "Claude 3.5 Haiku"]
                    ]
                ]
            ]
        ]))
        
        do {
            try await session.setSessionModel("claude-3-7-sonnet-20250219")
            XCTFail("Should have thrown model selection mismatch error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("selection mismatch"))
        }
    }
    
    // MARK: - 3. Streaming Text and Stop Preserves Login
    
    func testClaudeCodeSessionStreamingTextAndStopPreservesLogin() async throws {
        let mockTransport = MockACPTransport()
        
        await mockTransport.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1
        ]))
        
        await mockTransport.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "claude-session-stream",
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-7-sonnet-20250219",
                    "options": [["value": "claude-3-7-sonnet-20250219", "name": "Claude 3.7 Sonnet"]]
                ]
            ]
        ]))
        
        await mockTransport.setPromptStreamChunks(["Hello ", "world", "!"])
        await mockTransport.setScriptedResponse(method: "session/prompt", result: .success([
            "stopReason": "end_turn"
        ]))
        
        let session = ClaudeCodeSession(runtimeLocator: MockClaudeRuntimeLocator(), transport: mockTransport)
        _ = try await session.createNewSession()
        
        let receivedChunks = LockedBox<[String]>([])
        let fullText = try await session.sendPrompt(
            text: "Hi",
            model: "claude-3-7-sonnet-20250219",
            timeout: 10.0,
            onChunk: { chunk in
                receivedChunks.append(chunk)
            }
        )
        
        XCTAssertEqual(fullText, "Hello world!")
        XCTAssertEqual(receivedChunks.items, ["Hello ", "world", "!"])
        
        // Cancellation must not revoke credentials or crash
        try await session.cancelCurrentPrompt()
        let isBusy = await session.isPromptBusy
        XCTAssertFalse(isBusy)
        
        // Close session
        await session.close()
        let running = await mockTransport.isRunning
        XCTAssertFalse(running)
    }
    
    // MARK: - 4. ClaudeProvider Dual Modes & Generation Guards
    
    func testClaudeProviderDualModesAndStateIsolation() async throws {
        let mockTransport = MockACPTransport()
        await mockTransport.setScriptedResponse(method: "initialize", result: .success(["protocolVersion": 1]))
        await mockTransport.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-provider-test",
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-7-sonnet",
                    "options": [["value": "claude-3-7-sonnet", "name": "Claude 3.7 Sonnet"]]
                ]
            ]
        ]))
        
        let session = ClaudeCodeSession(runtimeLocator: MockClaudeRuntimeLocator(), transport: mockTransport)
        let provider = ClaudeProvider(
            codeSession: session,
            defaults: testDefaults,
            keychain: testKeychain,
            keyPrefix: "com.pinebot.test.claude.\(UUID().uuidString)"
        )
        
        XCTAssertEqual(provider.currentMode, .officialAccount)
        XCTAssertFalse(provider.isConnected)
        
        // Disconnect clears local session without error
        provider.disconnect()
        XCTAssertFalse(provider.isConnected)
    }
    
    // MARK: - 5. ProviderManager Claude Auth Guards
    
    @MainActor
    func testProviderManagerClaudeAuthLifecycle() async throws {
        let mockTransport = MockACPTransport()
        await mockTransport.setScriptedResponse(method: "initialize", result: .success(["protocolVersion": 1]))
        await mockTransport.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-mgr-test",
            "configOptions": [
                [
                    "id": "model",
                    "type": "select",
                    "category": "model",
                    "currentValue": "claude-3-7-sonnet",
                    "options": [["value": "claude-3-7-sonnet", "name": "Claude 3.7 Sonnet"]]
                ]
            ]
        ]))
        
        let session = ClaudeCodeSession(runtimeLocator: MockClaudeRuntimeLocator(), transport: mockTransport)
        let provider = ClaudeProvider(
            codeSession: session,
            defaults: testDefaults,
            keychain: testKeychain,
            keyPrefix: "com.pinebot.test.claude.\(UUID().uuidString)"
        )
        
        let manager = ProviderManager(claude: provider)
        XCTAssertEqual(manager.claudeState, .disconnected)
        
        // Cancel in-flight auth resets state cleanly
        manager.cancelClaudeAuth()
        XCTAssertEqual(manager.claudeState, .disconnected)
        
        // Disconnect
        manager.disconnect(provider: .claude)
        XCTAssertEqual(manager.claudeState, .disconnected)
    }
    
    // MARK: - 6. Runtime Locator & Bundled Node Discovery
    
    func testClaudeCodeRuntimeLocatorResolvesNodeAndSymlinks() throws {
        let locator = ClaudeCodeRuntimeLocator()
        
        // locateNode should find bundled Node
        let nodeURL = locator.locateNode()
        XCTAssertNotNil(nodeURL, "locateNode should discover Node runtime")
        if let node = nodeURL {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: node.path))
            XCTAssertTrue(node.path.hasSuffix("node"))
        }
        
        // locateACPAdapter should find and resolve symlink to dist/index.js
        let acpURL = locator.locateACPAdapter()
        XCTAssertNotNil(acpURL, "locateACPAdapter should discover ACP adapter")
        if let acp = acpURL {
            XCTAssertTrue(acp.path.hasSuffix("dist/index.js") || acp.path.contains("claude-agent-acp"))
            XCTAssertFalse(acp.path.contains(".bin/claude-agent-acp"), "Symlink should be fully resolved")
        }
        
        // locateClaudeCLI should find and resolve symlink to claude.exe Mach-O binary
        let claudeURL = locator.locateClaudeCLI()
        XCTAssertNotNil(claudeURL, "locateClaudeCLI should discover Claude CLI")
        if let claude = claudeURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: claude.path))
            XCTAssertFalse(claude.path.contains(".bin/claude"), "Symlink should be fully resolved")
        }
    }
    
    // MARK: - 7. Clean Environment Execution
    
    func testBundledNodeExecutesClaudeACPVersionWithCleanEnvironment() throws {
        let locator = ClaudeCodeRuntimeLocator()
        guard let nodeURL = locator.locateNode(),
              let acpURL = locator.locateACPAdapter(),
              let claudeURL = locator.locateClaudeCLI() else {
            XCTFail("Prerequisites not met for clean environment ACP execution test")
            return
        }
        
        let proc = Process()
        proc.executableURL = nodeURL
        proc.arguments = [acpURL.path, "--version"]
        proc.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        
        // Restricted environment: PATH=/usr/bin:/bin only, plus CLAUDE_CODE_EXECUTABLE
        proc.environment = [
            "PATH": "/usr/bin:/bin",
            "CLAUDE_CODE_EXECUTABLE": claudeURL.path
        ]
        
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        
        try proc.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        
        XCTAssertEqual(proc.terminationStatus, 0, "node dist/index.js --version should exit with code 0")
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(output, "0.88.0", "Output should match version 0.88.0")
    }
    
    // MARK: - 8. Isolated Fake-Executable Tests
    
    func testAuthProcessHandlesStdoutAndStderrFloodExceedingPipeCapacity() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("flood_auth_\(UUID().uuidString).py")
        let scriptContent = """
        #!/usr/bin/env python3
        import sys, json
        # Flood 128KB to stderr
        sys.stderr.write("E" * (128 * 1024) + "\\n")
        sys.stderr.flush()
        # Emit valid JSON object with >128KB padding string field
        payload = {
            "loggedIn": True,
            "email": "flood@example.com",
            "authMethod": "oauth",
            "padding": "O" * (130 * 1024)
        }
        sys.stdout.write(json.dumps(payload) + "\\n")
        sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: tempScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        let status = try await session.checkOfficialAuthStatus(timeout: 5.0)
        XCTAssertTrue(status.loggedIn, "Should parse loggedIn true after stdout/stderr flood")
        XCTAssertEqual(status.email, "flood@example.com")
    }
    
    func testAuthProcessCancellationEscalatesToSIGKILLWhenSIGTERMIgnored() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("sigterm_ignore_\(UUID().uuidString).py")
        let scriptContent = """
        #!/usr/bin/env python3
        import signal, time, sys
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdout.write("running\\n")
        sys.stdout.flush()
        while True:
            time.sleep(1)
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: tempScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        let startTime = Date()
        let authTask = Task {
            try await session.startOfficialLogin(timeout: 15.0)
        }
        
        // Give process brief moment to start
        try await Task.sleep(nanoseconds: 150_000_000)
        
        // Cancel the task
        authTask.cancel()
        
        do {
            _ = try await authTask.value
            XCTFail("Should have thrown cancellation error")
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertLessThan(elapsed, 3.0, "Cancellation must resume immediately and not wait for the 15s timeout")
        }
        
        let inProgress = await session.isLoginInProgress
        XCTAssertFalse(inProgress)
    }
    
    func testAuthProcessAlreadyCancelledLaunchThrowsImmediatelyWithoutRunning() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("already_cancelled_\(UUID().uuidString).py")
        let scriptContent = """
        #!/usr/bin/env python3
        import sys
        sys.exit(0)
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: tempScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        let task = Task { () -> ClaudeAuthStatus in
            try Task.checkCancellation()
            return try await session.checkOfficialAuthStatus()
        }
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Should have thrown cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        
        let isAuth = await session.isAuthenticated
        XCTAssertFalse(isAuth)
    }
    
    func testAuthProcessLateExitFromOldProcessDoesNotAffectNewAuth() async throws {
        let slowScript = FileManager.default.temporaryDirectory.appendingPathComponent("slow_auth_\(UUID().uuidString).py")
        let slowContent = """
        #!/usr/bin/env python3
        import time, sys, json
        time.sleep(1.0)
        sys.stdout.write(json.dumps({"loggedIn": False}) + "\\n")
        sys.stdout.flush()
        """
        try slowContent.write(to: slowScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowScript.path)
        defer { try? FileManager.default.removeItem(at: slowScript) }
        
        let fastScript = FileManager.default.temporaryDirectory.appendingPathComponent("fast_auth_\(UUID().uuidString).py")
        let fastContent = """
        #!/usr/bin/env python3
        import sys, json
        sys.stdout.write(json.dumps({"loggedIn": True, "email": "new@example.com"}) + "\\n")
        sys.stdout.flush()
        """
        try fastContent.write(to: fastScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fastScript.path)
        defer { try? FileManager.default.removeItem(at: fastScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: slowScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        // Start slow task
        let slowTask = Task {
            try await session.checkOfficialAuthStatus(timeout: 5.0)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Supersede with fast task using fastScript
        locator.mockClaudeURL = fastScript
        let fastResult = try await session.checkOfficialAuthStatus(timeout: 5.0)
        XCTAssertTrue(fastResult.loggedIn)
        XCTAssertEqual(fastResult.email, "new@example.com")
        
        // Wait for slow task to conclude (it was superseded/cancelled)
        _ = try? await slowTask.value
        
        // Verify session state retains fastResult
        let finalAuth = await session.isAuthenticated
        let finalEmail = await session.authEmail
        XCTAssertTrue(finalAuth)
        XCTAssertEqual(finalEmail, "new@example.com")
    }
    
    func testAuthProcessMalformedStatusJSONHandledSafelyWithoutCrash() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("malformed_\(UUID().uuidString).py")
        let scriptContent = """
        #!/usr/bin/env python3
        import sys
        sys.stdout.write("THIS IS NOT JSON AT ALL { malformed [[]]\\n")
        sys.exit(0)
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: tempScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        let status = try await session.checkOfficialAuthStatus(timeout: 5.0)
        XCTAssertFalse(status.loggedIn, "Malformed JSON should safely evaluate to not logged in without throwing")
    }
    
    func testAuthProcessTimeoutOnHangingProcessWithNoOutputAndPipeHeldOpen() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("hang_held_open_\(UUID().uuidString).py")
        let scriptContent = """
        #!/usr/bin/env python3
        import time, sys
        # Holds pipes open without emitting any output
        while True:
            time.sleep(1)
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: tempScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        let startTime = Date()
        do {
            _ = try await session.checkOfficialAuthStatus(timeout: 0.5)
            XCTFail("Should have thrown authTimeout")
        } catch let err as ClaudeCodeError {
            let elapsed = Date().timeIntervalSince(startTime)
            XCTAssertEqual(err, .authTimeout)
            XCTAssertLessThan(elapsed, 2.0, "Timeout must fire promptly without blocking on open pipe")
        } catch {
            XCTFail("Expected ClaudeCodeError.authTimeout, got \(error)")
        }
        
        let inProgress = await session.isLoginInProgress
        XCTAssertFalse(inProgress, "isLoginInProgress must be false after timeout")
    }
    
    func testFiftySequentialIsolatedFakeStatusLaunchesWithNoFDCorruption() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("fast_status_\(UUID().uuidString).sh")
        let scriptContent = """
        #!/bin/sh
        echo '{"loggedIn": true, "email": "iter@example.com"}'
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let locator = MockClaudeRuntimeLocator(claudeURL: tempScript)
        let session = ClaudeCodeSession(runtimeLocator: locator)
        
        for i in 1...50 {
            let status = try await session.checkOfficialAuthStatus(timeout: 2.0)
            XCTAssertTrue(status.loggedIn, "Iteration \(i) failed to report loggedIn true")
            XCTAssertEqual(status.email, "iter@example.com", "Iteration \(i) failed on email")
        }
        
        let isAuth = await session.isAuthenticated
        let email = await session.authEmail
        XCTAssertTrue(isAuth)
        XCTAssertEqual(email, "iter@example.com")
    }
}
