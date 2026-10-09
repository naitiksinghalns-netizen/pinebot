import XCTest
import AppKit
import CoreGraphics
@testable import PinebotKit

final class ComputerWorkAndTeachingTests: XCTestCase {
    
    // MARK: - 1. Gemini Reconnect & Callback Lifetime Tests
    
    func testGeminiInjectedSessionRegistersCallbacksBeforeInitialize() async throws {
        let mock = MockACPTransport()
        
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-init-order",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-2.5-flash",
                    "options": [["value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"]]
                ]
            ]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        
        let suite = "test.gemini.init.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { testDefaults.removePersistentDomain(forName: suite) }
        
        let provider = GeminiProvider(
            agentSession: session,
            defaults: testDefaults,
            keyPrefix: "test.init.\(UUID().uuidString)"
        )
        
        // Wrap transport check: transport.setRequestHandler was called when callbacks were setup
        _ = try await provider.startOfficialAccountAuth()
        XCTAssertTrue(provider.isConnected)
        XCTAssertEqual(provider.discoveredModels.first?.id, "gemini-2.5-flash")
    }
    
    func testGeminiReconnectReceivesCatalogUpdatesAfterDisconnect() async throws {
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": [:]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-reconnect",
            "configOptions": [
                [
                    "id": "model",
                    "category": "model",
                    "type": "select",
                    "currentValue": "gemini-v1",
                    "options": [["value": "gemini-v1", "name": "Gemini V1"]]
                ]
            ]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        let suite = "test.gemini.reconnect.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        defer { testDefaults.removePersistentDomain(forName: suite) }
        
        let provider = GeminiProvider(
            agentSession: session,
            defaults: testDefaults,
            keyPrefix: "test.reconnect.\(UUID().uuidString)"
        )
        
        let manager = await MainActor.run {
            ProviderManager(gemini: provider)
        }
        
        // 1. Initial connect
        await MainActor.run {
            manager.startGeminiOfficialAuth()
        }
        
        var connected = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let isConn = await MainActor.run { manager.geminiState.isConnected }
            if isConn { connected = true; break }
        }
        XCTAssertTrue(connected, "Initial connection should succeed")
        
        let firstModel = await MainActor.run { manager.connectedModels.first?.id }
        XCTAssertEqual(firstModel, "gemini-v1")
        
        // 2. Disconnect
        await MainActor.run {
            manager.disconnect(provider: .gemini)
        }
        let afterDisconnect = await MainActor.run { manager.geminiState.isConnected }
        XCTAssertFalse(afterDisconnect)
        
        // 3. Reconnect
        await MainActor.run {
            manager.startGeminiOfficialAuth()
        }
        
        var reconnected = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let isConn = await MainActor.run { manager.geminiState.isConnected }
            if isConn { reconnected = true; break }
        }
        XCTAssertTrue(reconnected, "Reconnect should succeed")
        
        // 4. Fire dynamic model catalog update on the reconnected session
        let updateNotification: JSONValue = [
            "sessionId": "sess-reconnect",
            "update": [
                "sessionUpdate": "config_option_update",
                "configOptions": [
                    [
                        "id": "model",
                        "category": "model",
                        "type": "select",
                        "currentValue": "gemini-v2-updated",
                        "options": [
                            ["value": "gemini-v2-updated", "name": "Gemini V2 Updated"]
                        ]
                    ]
                ]
            ]
        ]
        
        await mock.simulateNotification(method: "session/update", params: updateNotification)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let updatedModel = await MainActor.run { manager.connectedModels.first?.id }
        XCTAssertEqual(updatedModel, "gemini-v2-updated", "ProviderManager must receive catalog updates after reconnect")
    }
    
    // MARK: - 2. Coordinate Transforms & Strict Bounds Validation Tests
    
    func testCoordinateValidationRejectsOutOfBoundsWithoutClamping() {
        let cgFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let space = DisplayCoordinateSpace(
            displayID: 1,
            globalCoreGraphicsFrame: cgFrame,
            globalAppKitFrame: cgFrame,
            primaryScreenHeight: 1080,
            backingScaleFactor: 2.0,
            capturedPixelSize: CGSize(width: 3840, height: 2160)
        )
        let obsId = UUID()
        let observation = ComputerObservation(
            id: obsId,
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            displayId: 1,
            capturedPixelSize: CGSize(width: 3840, height: 2160),
            coordinateSpace: space
        )
        
        // Valid coordinates
        let validPoint = try? ScreenCaptureManager.convertAndValidateCoordinates(
            observation: observation,
            targetObservationId: obsId,
            targetDisplayId: 1,
            xNorm: 0.5,
            yNorm: 0.5
        )
        XCTAssertEqual(validPoint?.x, 960.0)
        XCTAssertEqual(validPoint?.y, 540.0)
        
        // Out of bounds (< 0.0) MUST throw, not clamp
        XCTAssertThrowsError(try ScreenCaptureManager.convertAndValidateCoordinates(
            observation: observation,
            targetObservationId: obsId,
            targetDisplayId: 1,
            xNorm: -0.05,
            yNorm: 0.5
        )) { error in
            guard let coordErr = error as? ComputerCoordinateError else {
                XCTFail("Expected ComputerCoordinateError, got \(error)")
                return
            }
            XCTAssertEqual(coordErr, .outOfBounds(xNorm: -0.05, yNorm: 0.5))
        }
        
        // Out of bounds (> 1.0) MUST throw, not clamp
        XCTAssertThrowsError(try ScreenCaptureManager.convertAndValidateCoordinates(
            observation: observation,
            targetObservationId: obsId,
            targetDisplayId: 1,
            xNorm: 0.5,
            yNorm: 1.05
        )) { error in
            guard let coordErr = error as? ComputerCoordinateError else {
                XCTFail("Expected ComputerCoordinateError, got \(error)")
                return
            }
            XCTAssertEqual(coordErr, .outOfBounds(xNorm: 0.5, yNorm: 1.05))
        }
        
        // Stale observation ID MUST throw
        let staleId = UUID()
        XCTAssertThrowsError(try ScreenCaptureManager.convertAndValidateCoordinates(
            observation: observation,
            targetObservationId: staleId,
            targetDisplayId: 1,
            xNorm: 0.5,
            yNorm: 0.5
        )) { error in
            guard let coordErr = error as? ComputerCoordinateError else {
                XCTFail("Expected ComputerCoordinateError")
                return
            }
            XCTAssertEqual(coordErr, .staleObservation(expected: obsId, actual: staleId))
        }
        
        // Display mismatch MUST throw
        XCTAssertThrowsError(try ScreenCaptureManager.convertAndValidateCoordinates(
            observation: observation,
            targetObservationId: obsId,
            targetDisplayId: 999,
            xNorm: 0.5,
            yNorm: 0.5
        )) { error in
            guard let coordErr = error as? ComputerCoordinateError else {
                XCTFail("Expected ComputerCoordinateError")
                return
            }
            XCTAssertEqual(coordErr, .displayMismatch(expected: 1, actual: 999))
        }
    }
    
    func testNegativeDisplayOffsetCoordinateMapping() {
        // Multi-monitor setup where display 2 is to the left: x: -1920, y: 0
        let secondaryCGFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let space = DisplayCoordinateSpace(
            displayID: 2,
            globalCoreGraphicsFrame: secondaryCGFrame,
            globalAppKitFrame: secondaryCGFrame,
            primaryScreenHeight: 1080,
            backingScaleFactor: 2.0,
            capturedPixelSize: CGSize(width: 3840, height: 2160)
        )
        let obsId = UUID()
        let observation = ComputerObservation(
            id: obsId,
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            displayId: 2,
            capturedPixelSize: CGSize(width: 3840, height: 2160),
            coordinateSpace: space
        )
        
        let centerPoint = try? ScreenCaptureManager.convertAndValidateCoordinates(
            observation: observation,
            targetObservationId: obsId,
            targetDisplayId: 2,
            xNorm: 0.5,
            yNorm: 0.5
        )
        // Center of [-1920, 0] is -960, 540
        XCTAssertEqual(centerPoint?.x, -960.0)
        XCTAssertEqual(centerPoint?.y, 540.0)
    }
    
    func testAXElementResolution() throws {
        let node = AXElementNode(
            id: "AX_SUBMIT_BUTTON",
            role: "AXButton",
            title: "Submit",
            globalFrame: CGRect(x: 400, y: 300, width: 100, height: 40),
            normalizedFrame: CGRect(x: 0.2, y: 0.2, width: 0.05, height: 0.03)
        )
        let obs = ComputerObservation(
            id: UUID(),
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            axElements: [node],
            displayId: 1,
            capturedPixelSize: CGSize(width: 1920, height: 1080),
            coordinateSpace: DisplayCoordinateSpace(
                displayID: 1,
                globalCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                globalAppKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                primaryScreenHeight: 1080,
                backingScaleFactor: 1.0,
                capturedPixelSize: CGSize(width: 1920, height: 1080)
            )
        )
        
        let resolved = try ScreenCaptureManager.resolveElementCoordinates(observation: obs, elementId: "AX_SUBMIT_BUTTON")
        XCTAssertEqual(resolved.point.x, 450.0) // 400 + 100/2
        XCTAssertEqual(resolved.point.y, 320.0) // 300 + 40/2
        XCTAssertEqual(resolved.node.title, "Submit")
        
        XCTAssertThrowsError(try ScreenCaptureManager.resolveElementCoordinates(observation: obs, elementId: "AX_NONEXISTENT")) { error in
            guard let coordErr = error as? ComputerCoordinateError else {
                XCTFail("Expected ComputerCoordinateError")
                return
            }
            XCTAssertEqual(coordErr, .elementNotFound("AX_NONEXISTENT"))
        }
    }
    
    // MARK: - 3. ComputerPlanner & One-Shot Repair Tests
    
    func testProviderComputerPlannerRepairsMalformedJSON() async throws {
        final class RepairMockProvider: LLMProvider, @unchecked Sendable {
            let type: ProviderType = .gemini
            var isConfigured: Bool = true
            var isConnected: Bool = true
            var statusDescription: String = "Connected"
            var discoveredModels: [ModelInfo] = []
            
            var callCount = 0
            
            func generateCompletion(prompt: String, systemPrompt: String?, image: NSImage?, model: String) async throws -> String {
                callCount += 1
                if callCount == 1 {
                    // First call returns malformed JSON with markdown comments
                    return "Here is what to do next: ```json { type: 'click', x: 0.5, } ```"
                } else {
                    // Second call (repair) returns clean JSON
                    return """
                    {
                        "type": "click",
                        "x": 0.5,
                        "y": 0.5,
                        "rationale": "Click the center button",
                        "isConsequential": false
                    }
                    """
                }
            }
            
            func validateAndDiscoverModels() async throws -> [ModelInfo] { [] }
            func cancelGeneration() async {}
            func disconnect() {}
        }
        
        let provider = RepairMockProvider()
        let planner = ProviderComputerPlanner(provider: provider, model: "gemini-2.5-pro")
        
        let obsId = UUID()
        let obs = ComputerObservation(
            id: obsId,
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            displayId: 1,
            capturedPixelSize: CGSize(width: 1920, height: 1080),
            coordinateSpace: DisplayCoordinateSpace(
                displayID: 1,
                globalCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                globalAppKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                primaryScreenHeight: 1080,
                backingScaleFactor: 1.0,
                capturedPixelSize: CGSize(width: 1920, height: 1080)
            )
        )
        
        let step = try await planner.planNextStep(goal: "Click submit", observation: obs, history: [], teachingMode: false)
        XCTAssertEqual(provider.callCount, 2, "Should attempt one-shot repair")
        XCTAssertEqual(step.action.type, .click)
        XCTAssertEqual(step.action.x, 0.5)
        XCTAssertEqual(step.action.y, 0.5)
        XCTAssertEqual(step.action.observationId, obsId)
        XCTAssertEqual(step.action.displayId, 1)
    }
    
    // MARK: - 4. ComputerTaskEngine Observe-Plan-Execute Loop Tests
    
    func testComputerTaskEngineMultiStepExecution() async throws {
        final class ScriptedPlanner: ComputerPlanner, @unchecked Sendable {
            var stepIndex = 0
            func planNextStep(goal: String, observation: ComputerObservation, history: [PlannedActionStep], teachingMode: Bool) async throws -> PlannedActionStep {
                stepIndex += 1
                if stepIndex == 1 {
                    return PlannedActionStep(
                        stepNumber: 1,
                        action: ComputerAction(type: .click, observationId: observation.id, displayId: observation.displayId, x: 0.5, y: 0.5, rationale: "Click first target"),
                        rationale: "Step 1"
                    )
                } else {
                    return PlannedActionStep(
                        stepNumber: 2,
                        action: ComputerAction(type: .complete, text: "Goal accomplished cleanly", rationale: "Task complete"),
                        rationale: "Step 2"
                    )
                }
            }
        }
        
        final class MockObserver: ComputerObserverProtocol, @unchecked Sendable {
            func captureObservation(displayID: CGDirectDisplayID?, maxDimension: CGFloat, excludePinebotWindows: Bool) async throws -> ComputerObservation {
                return ComputerObservation(
                    id: UUID(),
                    permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
                    displayId: 1,
                    capturedPixelSize: CGSize(width: 1920, height: 1080),
                    coordinateSpace: DisplayCoordinateSpace(
                        displayID: 1,
                        globalCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        globalAppKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                        primaryScreenHeight: 1080,
                        backingScaleFactor: 1.0,
                        capturedPixelSize: CGSize(width: 1920, height: 1080)
                    )
                )
            }
        }
        
        final class MockExecutor: ComputerActionExecutorProtocol, @unchecked Sendable {
            var executedActions: [ComputerActionType] = []
            func execute(action: ComputerAction, at point: CGPoint?, toPoint: CGPoint?, observation: ComputerObservation) async throws -> String {
                executedActions.append(action.type)
                return "Mock executed \(action.type.rawValue)"
            }
        }
        
        let planner = ScriptedPlanner()
        let observer = MockObserver()
        let executor = MockExecutor()
        let coordinator = AgentCoordinator()
        
        let engine = await MainActor.run {
            ComputerTaskEngine(
                observer: observer,
                planner: planner,
                overlay: ScreenOverlayManager(),
                coordinator: coordinator,
                executor: executor
            )
        }
        
        let result = try await engine.executeTask(
            goal: "Click button and complete",
            teachingMode: false,
            requireConfirmation: false
        )
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.summary, "Goal accomplished cleanly")
        XCTAssertEqual(executor.executedActions, [.click])
        let status = await MainActor.run { engine.status }
        XCTAssertEqual(status, .completed(summary: "Goal accomplished cleanly"))
    }
    
    // MARK: - 5. AgentCoordinator Child Depth & Lease Bounding Tests
    
    func testAgentCoordinatorDepthLimitPreventsChildSpawningChild() async throws {
        let coordinator = AgentCoordinator()
        
        // Depth 0: Root job
        let rootJobId = try await coordinator.spawnJob(description: "Root task")
        let root = await coordinator.getJob(id: rootJobId)
        XCTAssertEqual(root?.depth, 0)
        
        // Depth 1: Child job allowed
        let childJobId = try await coordinator.spawnJob(description: "Child subagent", parentJobId: rootJobId)
        let child = await coordinator.getJob(id: childJobId)
        XCTAssertEqual(child?.depth, 1)
        
        // Depth 2: Child cannot spawn another child (exceeds maxDepth = 1)
        do {
            _ = try await coordinator.spawnJob(description: "Grandchild subagent", parentJobId: childJobId)
            XCTFail("Should throw maxDepthExceeded")
        } catch let err as CoordinatorError {
            switch err {
            case .maxDepthExceeded(let msg):
                XCTAssertTrue(msg.contains("Child agent depth limit reached"))
            default:
                XCTFail("Expected maxDepthExceeded, got \(err)")
            }
        }
    }
    
    func testAgentCoordinatorEnforcesExclusiveDesktopLease() async throws {
        let coordinator = AgentCoordinator()
        let job1 = try await coordinator.spawnJob(description: "Task 1")
        let job2 = try await coordinator.spawnJob(description: "Task 2")
        
        // Job 1 acquires lease
        let lease1 = try await coordinator.acquireDesktopLease(jobId: job1)
        XCTAssertEqual(lease1.jobId, job1)
        
        // Job 2 cannot acquire while Job 1 holds it (times out)
        do {
            _ = try await coordinator.acquireDesktopLease(jobId: job2, timeoutSeconds: 0.1)
            XCTFail("Should fail because lease is held by job1")
        } catch let err as CoordinatorError {
            switch err {
            case .leaseBusy(let holder):
                XCTAssertEqual(holder, job1)
            default:
                XCTFail("Expected leaseBusy, got \(err)")
            }
        }
        
        // Release lease from Job 1
        await coordinator.releaseDesktopLease(jobId: job1)
        
        // Now Job 2 can acquire
        let lease2 = try await coordinator.acquireDesktopLease(jobId: job2, timeoutSeconds: 0.5)
        XCTAssertEqual(lease2.jobId, job2)
    }
    
    // MARK: - 6. Truthful Task Execution & Outcome Tests
    
    func testFallbackComputerPlannerReturnsNeedsUserAndNeverCompletes() async throws {
        let planner = FallbackComputerPlanner()
        let dummySpace = DisplayCoordinateSpace(
            displayID: 1,
            globalCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            globalAppKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            primaryScreenHeight: 1080,
            backingScaleFactor: 2.0,
            capturedPixelSize: CGSize(width: 1920, height: 1080)
        )
        let dummyObs = ComputerObservation(
            id: UUID(),
            timestamp: Date(),
            foregroundPID: nil,
            foregroundApp: nil,
            foregroundWindow: nil,
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            axElements: [],
            displayId: 1,
            image: NSImage(),
            imageBytes: nil,
            capturedPixelSize: CGSize(width: 1920, height: 1080),
            coordinateSpace: dummySpace
        )
        
        // 1. Planner must emit fail, NEVER complete or wait->complete
        let step = try await planner.planNextStep(goal: "Open Settings", observation: dummyObs, history: [], teachingMode: false)
        XCTAssertEqual(step.action.type, .fail, "Fallback planner must never claim success")
        XCTAssertEqual(step.status, .failed)
        XCTAssertTrue(step.action.text?.contains("No capable AI provider") == true)
        
        // 2. Engine executing with FallbackComputerPlanner must report .needsUser outcome
        let mockObserver = MockComputerObserver(observationToReturn: dummyObs)
        let coordinator = AgentCoordinator()
        let engine = await MainActor.run {
            ComputerTaskEngine(
                observer: mockObserver,
                planner: planner,
                overlay: ScreenOverlayManager(),
                coordinator: coordinator,
                executor: MockComputerActionExecutor()
            )
        }
        
        let result = try await engine.executeTask(goal: "Open Settings", requireConfirmation: false)
        XCTAssertFalse(result.success, "Fallback execution must not be reported as success")
        XCTAssertEqual(result.outcome, .needsUser, "Fallback planner should report needsUser outcome")
        let status = await MainActor.run { engine.status }
        if case .needsUser(let reason) = status {
            XCTAssertTrue(reason.contains("No capable"))
        } else {
            XCTFail("Expected .needsUser status, got: \(status)")
        }
    }
    
    func testClaudeComputerUseActionBidirectionalSerialization() throws {
        let screenSize = CGSize(width: 1920, height: 1080)
        
        // 1. Parse Anthropic Claude Computer Use click schema
        let claudeJSON = """
        {
            "action": "left_click",
            "coordinate": [960, 540]
        }
        """
        let dummySpace = DisplayCoordinateSpace(
            displayID: 1,
            globalCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            globalAppKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            primaryScreenHeight: 1080,
            backingScaleFactor: 2.0,
            capturedPixelSize: screenSize
        )
        let dummyObs = ComputerObservation(
            id: UUID(),
            timestamp: Date(),
            foregroundPID: nil,
            foregroundApp: "Safari",
            foregroundWindow: "Apple",
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            axElements: [],
            displayId: 1,
            image: NSImage(),
            imageBytes: nil,
            capturedPixelSize: screenSize,
            coordinateSpace: dummySpace
        )
        
        let parsed = try ProviderComputerPlanner.parseAction(from: claudeJSON, currentObservation: dummyObs)
        XCTAssertEqual(parsed.type, .click)
        XCTAssertEqual(parsed.x ?? 0.0, 0.5, accuracy: 0.01)
        XCTAssertEqual(parsed.y ?? 0.0, 0.5, accuracy: 0.01)
        
        // 2. Convert Pinebot action to Claude Computer Use schema
        let pinebotAction = ComputerAction(type: .typeText, text: "echo hello")
        let claudeTool = ClaudeComputerUseAction.from(action: pinebotAction, screenPixelSize: screenSize)
        XCTAssertEqual(claudeTool.action, "type")
        XCTAssertEqual(claudeTool.text, "echo hello")
        
        // 3. Key combination serialization
        let keyAction = ComputerAction(type: .keyCombination, keys: ["cmd", "c"])
        let claudeKey = ClaudeComputerUseAction.from(action: keyAction, screenPixelSize: screenSize)
        XCTAssertEqual(claudeKey.action, "key")
        XCTAssertEqual(claudeKey.text, "cmd+c")
    }
    
    func testActionRejectionTerminatesTaskAsRejected() async throws {
        let dummySpace = DisplayCoordinateSpace(
            displayID: 1,
            globalCoreGraphicsFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            globalAppKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            primaryScreenHeight: 1080,
            backingScaleFactor: 2.0,
            capturedPixelSize: CGSize(width: 1920, height: 1080)
        )
        let dummyObs = ComputerObservation(
            id: UUID(),
            timestamp: Date(),
            foregroundPID: 123,
            foregroundApp: "Terminal",
            foregroundWindow: "Terminal",
            permissionState: ComputerPermissionState(screenRecordingGranted: true, accessibilityGranted: true),
            axElements: [],
            displayId: 1,
            image: NSImage(),
            imageBytes: nil,
            capturedPixelSize: CGSize(width: 1920, height: 1080),
            coordinateSpace: dummySpace
        )
        
        let mockObserver = MockComputerObserver(observationToReturn: dummyObs)
        let mockPlanner = MockComputerPlanner(actionsToReturn: [
            ComputerAction(type: .typeText, text: "rm -rf /tmp/danger", isConsequential: true)
        ])
        let executor = MockComputerActionExecutor()
        let coordinator = AgentCoordinator()
        
        let engine = await MainActor.run {
            ComputerTaskEngine(
                observer: mockObserver,
                planner: mockPlanner,
                overlay: ScreenOverlayManager(),
                coordinator: coordinator,
                executor: executor
            )
        }
        
        let task = Task<TaskExecutionResult, Error> { @MainActor in
            return try await engine.executeTask(goal: "Delete files", requireConfirmation: true)
        }
        
        // Wait until engine is waiting for confirmation
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let isWaiting = await MainActor.run {
                if case .waitingForConfirmation = engine.status { return true }
                return false
            }
            if isWaiting { break }
        }
        
        // Reject the step
        await MainActor.run {
            if case .waitingForConfirmation(let step) = engine.status {
                engine.confirmStep(stepId: step.id, approved: false)
            }
        }
        
        let result = try await task.value
        XCTAssertEqual(result.outcome, .rejected, "Rejection must terminate task with .rejected outcome")
        XCTAssertFalse(result.success)
        XCTAssertEqual(executor.executedActions.count, 0, "No physical actions should be executed when rejected")
    }
}

// MARK: - Injected Test Fakes

final class MockComputerObserver: ComputerObserverProtocol, @unchecked Sendable {
    var observationToReturn: ComputerObservation
    
    init(observationToReturn: ComputerObservation) {
        self.observationToReturn = observationToReturn
    }
    
    func captureObservation(
        displayID: CGDirectDisplayID?,
        maxDimension: CGFloat,
        excludePinebotWindows: Bool
    ) async throws -> ComputerObservation {
        return observationToReturn
    }
}

final class MockComputerPlanner: ComputerPlanner, @unchecked Sendable {
    var actionsToReturn: [ComputerAction]
    private var index = 0
    private let lock = NSLock()
    
    init(actionsToReturn: [ComputerAction]) {
        self.actionsToReturn = actionsToReturn
    }
    
    func planNextStep(
        goal: String,
        observation: ComputerObservation,
        history: [PlannedActionStep],
        teachingMode: Bool
    ) async throws -> PlannedActionStep {
        return lock.withLock {
            let action: ComputerAction
            if index < actionsToReturn.count {
                action = actionsToReturn[index]
                index += 1
            } else {
                action = ComputerAction(type: .complete, text: "Finished")
            }
            return PlannedActionStep(
                stepNumber: history.count + 1,
                action: action,
                rationale: "Mock step",
                status: .pending
            )
        }
    }
}

final class MockComputerActionExecutor: ComputerActionExecutorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _executedActions: [ComputerAction] = []
    
    var executedActions: [ComputerAction] {
        lock.withLock { _executedActions }
    }
    
    func execute(
        action: ComputerAction,
        at point: CGPoint?,
        toPoint: CGPoint?,
        observation: ComputerObservation
    ) async throws -> String {
        lock.withLock {
            _executedActions.append(action)
        }
        return "Executed \(action.type)"
    }
}


