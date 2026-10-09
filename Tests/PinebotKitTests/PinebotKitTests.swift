import XCTest
import AVFoundation
import Speech
@testable import PinebotKit

final class PinebotKitTests: XCTestCase {
    
    // MARK: - Model Router & Capability Tests
    
    func testRouterThrowsActionableErrorWhenVisionUnmet() {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        
        // Connected models that do NOT support vision
        let textOnlyModels = [
            ModelInfo(id: "o3-mini", displayName: "o3-mini", provider: .openai, tier: .frontierReasoning, supportsVision: false, supportsTools: true),
            ModelInfo(id: "llama3.2", displayName: "Llama 3.2", provider: .ollama, tier: .cheapFast, supportsVision: false, supportsTools: true)
        ]
        
        // Task requiring vision
        XCTAssertThrowsError(
            try router.route(
                prompt: "What is on my screen right now?",
                hasScreenImage: true,
                connectedModels: textOnlyModels
            )
        ) { error in
            guard let routerError = error as? RouterError else {
                XCTFail("Expected RouterError, got: \(error)")
                return
            }
            if case .unmetCapability(let reason) = routerError {
                XCTAssertTrue(reason.contains("vision") || reason.contains("image"), "Error must explain missing vision capability: \(reason)")
            } else {
                XCTFail("Expected .unmetCapability, got: \(routerError)")
            }
        }
    }
    
    func testRouterThrowsActionableErrorWhenToolsUnmet() {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        
        let toollessModels = [
            ModelInfo(id: "simple-llm", displayName: "Simple LLM", provider: .ollama, tier: .cheapFast, supportsVision: true, supportsTools: false)
        ]
        
        XCTAssertThrowsError(
            try router.route(
                prompt: "click on the Submit button and open the app",
                hasScreenImage: false,
                connectedModels: toollessModels
            )
        ) { error in
            guard let routerError = error as? RouterError else {
                XCTFail("Expected RouterError, got: \(error)")
                return
            }
            if case .unmetCapability(let reason) = routerError {
                XCTAssertTrue(reason.contains("tool"), "Error must explain missing tool capability: \(reason)")
            } else {
                XCTFail("Expected .unmetCapability, got: \(routerError)")
            }
        }
    }
    
    func testManualOverrideValidatesRequiredCapabilities() {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        
        let models = [
            ModelInfo(id: "vision-model", displayName: "Vision Model", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsTools: true),
            ModelInfo(id: "text-model", displayName: "Text Only Model", provider: .ollama, tier: .cheapFast, supportsVision: false, supportsTools: true)
        ]
        
        // User manually attempts to override with text-model for a screen analysis task
        XCTAssertThrowsError(
            try router.route(
                prompt: "Analyze the screenshot",
                hasScreenImage: true,
                connectedModels: models,
                userOverride: "text-model"
            )
        ) { error in
            guard let routerError = error as? RouterError,
                  case .unmetCapability(let reason) = routerError else {
                XCTFail("Expected .unmetCapability on manual override, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("Manual override"), "Error must identify manual override failure: \(reason)")
        }
    }
    
    func testEscalationPreservesRequiredCapabilities() throws {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        
        let models = [
            ModelInfo(id: "cheap-vision", displayName: "Cheap Vision", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true),
            ModelInfo(id: "frontier-vision", displayName: "Frontier Vision", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsTools: true),
            ModelInfo(id: "frontier-text", displayName: "Frontier Text Only", provider: .claude, tier: .frontierReasoning, supportsVision: false, supportsTools: true)
        ]
        
        // Initial route for vision task
        let initial = try router.route(
            prompt: "Look at this screenshot",
            hasScreenImage: true,
            connectedModels: models
        )
        XCTAssertTrue(initial.selectedModel.supportsVision)
        
        // Escalate after simulated failure
        let escalated = try router.escalate(
            currentDecision: initial,
            error: "API rate limit reached (429)",
            connectedModels: models
        )
        
        XCTAssertTrue(escalated.selectedModel.supportsVision, "Escalated model must support vision")
        XCTAssertEqual(escalated.selectedModel.id, "frontier-vision")
        XCTAssertEqual(escalated.escalationLevel, 1)
        
        // Second escalation
        let escalated2 = try router.escalate(
            currentDecision: escalated,
            error: "Timeout error",
            connectedModels: models
        )
        XCTAssertEqual(escalated2.escalationLevel, 2)
        
        // Third escalation must be rejected by bounded limit
        XCTAssertThrowsError(
            try router.escalate(
                currentDecision: escalated2,
                error: "Fatal crash",
                connectedModels: models
            )
        ) { error in
            guard let routerError = error as? RouterError,
                  case .maxEscalationsExceeded = routerError else {
                XCTFail("Expected .maxEscalationsExceeded, got \(error)")
                return
            }
        }
    }
    
    func testEscalationRejectsAuthFailureWithoutFrontierEscalation() throws {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        let models = [
            ModelInfo(id: "cheap-model", displayName: "Cheap Model", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true),
            ModelInfo(id: "frontier-model", displayName: "Frontier Model", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsTools: true)
        ]
        
        let initial = try router.route(
            prompt: "What is 2 + 2?",
            hasScreenImage: false,
            connectedModels: models
        )
        XCTAssertEqual(initial.selectedModel.id, "cheap-model")
        
        // 401 / Unauthorized failure must throw RouterError.escalationNotPermitted and never escalate to frontier
        XCTAssertThrowsError(
            try router.escalate(
                currentDecision: initial,
                error: "401 Unauthorized: Invalid API key provided",
                connectedModels: models
            )
        ) { error in
            guard let routerError = error as? RouterError else {
                XCTFail("Expected RouterError, got \(error)")
                return
            }
            if case .escalationNotPermitted(let reason) = routerError {
                XCTAssertTrue(reason.contains("Authentication failure") || reason.contains("Re-authentication"), "Expected auth failure message, got: \(reason)")
            } else {
                XCTFail("Expected .escalationNotPermitted, got \(routerError)")
            }
        }
    }
    
    func testEscalationRejectsCancellation() throws {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        let models = [
            ModelInfo(id: "cheap-model", displayName: "Cheap Model", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true),
            ModelInfo(id: "frontier-model", displayName: "Frontier Model", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsTools: true)
        ]
        
        let initial = try router.route(
            prompt: "What is 2 + 2?",
            hasScreenImage: false,
            connectedModels: models
        )
        
        // Cancellation must throw CancellationError and never escalate
        XCTAssertThrowsError(
            try router.escalate(
                currentDecision: initial,
                error: "Task cancelled by user",
                connectedModels: models
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
    }
    
    func testEscalationSelectsPeerAtSameTierOnRateLimit() throws {
        let router = ModelRouter(classifier: LocalLearnedClassifier.shared)
        let models = [
            ModelInfo(id: "gemini-flash", displayName: "Gemini 2.5 Flash", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true),
            ModelInfo(id: "llama-3.2", displayName: "Llama 3.2", provider: .ollama, tier: .cheapFast, supportsVision: true, supportsTools: true, isLocal: false),
            ModelInfo(id: "o3-mini", displayName: "o3-mini", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsTools: true)
        ]
        
        let initial = try router.route(
            prompt: "What is 2 + 2?",
            hasScreenImage: false,
            connectedModels: models
        )
        XCTAssertEqual(initial.selectedModel.tier, .cheapFast)
        let firstPickedId = initial.selectedModel.id
        
        // Rate limit (429) on first model: must fall back to peer at the SAME tier before escalating
        let escalated = try router.escalate(
            currentDecision: initial,
            error: "429 Too Many Requests: Rate limit exceeded",
            connectedModels: models
        )
        
        XCTAssertEqual(escalated.selectedModel.tier, .cheapFast, "Quota fallback must choose peer at same tier first")
        let expectedPeerId = (firstPickedId == "gemini-flash") ? "llama-3.2" : "gemini-flash"
        XCTAssertEqual(escalated.selectedModel.id, expectedPeerId)
        
        // Second rate limit: now that same tier peers are exhausted, it may escalate to next available tier
        let secondEscalated = try router.escalate(
            currentDecision: escalated,
            error: "429 Too Many Requests: Rate limit exceeded",
            connectedModels: models
        )
        XCTAssertEqual(secondEscalated.selectedModel.id, "o3-mini")
    }
    
    // MARK: - Local Learned Classifier & Honest Fallback Tests
    
    func testClassifierReportsFallbackHonestlyWhenWeightsAbsent() {
        let emptyDir = URL(fileURLWithPath: "/tmp/pinebot_nonexistent_weights_dir_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: emptyDir)
        
        let result = classifier.classify(prompt: "Hello Pinebot!")
        
        // Must NEVER claim learned ML when weights are absent
        XCTAssertFalse(result.status.isLearned, "Must not claim learned inference without weights")
        if case .fallback(let reason) = result.status {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("Expected .fallback status, got \(result.status)")
        }
    }
    
    func testClassifierReportsFallbackWhenFilesMalformed() throws {
        let tempDir = URL(fileURLWithPath: "/tmp/pinebot_malformed_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Create corrupt/truncated dummy files
        let dummyOnnx = tempDir.appendingPathComponent("model.onnx")
        let dummyTok = tempDir.appendingPathComponent("tokenizer.json")
        try "corrupt".write(to: dummyOnnx, atomically: true, encoding: .utf8)
        try "{}".write(to: dummyTok, atomically: true, encoding: .utf8)
        
        let classifier = LocalLearnedClassifier(modelDirectory: tempDir)
        let result = classifier.classify(prompt: "Write a quicksort in Swift")
        
        // File existence must NEVER trick the classifier into claiming learned ML
        XCTAssertFalse(result.status.isLearned, "Corrupt or truncated file must result in fallback")
        if case .fallback(let reason) = result.status {
            XCTAssertTrue(reason.contains("corrupted") || reason.contains("fallback") || reason.contains("failure"))
        } else {
            XCTFail("Expected .fallback status, got \(result.status)")
        }
    }
    
    func testGenuineLearnedInferenceWithWeights() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("work/pinebot/models"),
            URL(fileURLWithPath: cwd).appendingPathComponent("models")
        ]
        guard let modelsDir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.onnx").path) }) else {
            return
        }
        
        let classifier = LocalLearnedClassifier(modelDirectory: modelsDir)
        let codingResult = await classifier.classify(prompt: "Write a Swift function to parse JSON with async/await")
        
        // Genuine inference with weights loaded
        XCTAssertTrue(codingResult.status.isLearned, "Classifier must report learned when valid weights are present")
        XCTAssertEqual(codingResult.category, .codeGeneration)
        XCTAssertEqual(codingResult.difficulty, .medium, "Standard JSON parse function is moderate coding task, not formal theorem proof")
        XCTAssertGreaterThan(codingResult.confidence, 0.5)
        XCTAssertNotNil(codingResult.rawScores)
        
        // Test greeting query
        let greetingResult = await classifier.classify(prompt: "Good morning!")
        XCTAssertTrue(greetingResult.status.isLearned)
        XCTAssertEqual(greetingResult.category, .greeting)
        XCTAssertEqual(greetingResult.difficulty, .simple)
    }
    
    // MARK: - Screen Coordinate & Mapping Tests
    
    func testCoordinateTransforms() {
        let screenHeight: CGFloat = 1080.0
        
        let appKitPoint = CGPoint(x: 100, y: 200)
        let cgPoint = ScreenCoordinateHelper.appKitToCoreGraphics(point: appKitPoint, screenHeight: screenHeight)
        XCTAssertEqual(cgPoint.x, 100)
        XCTAssertEqual(cgPoint.y, 880) // 1080 - 200
        
        let roundTrip = ScreenCoordinateHelper.coreGraphicsToAppKit(point: cgPoint, screenHeight: screenHeight)
        XCTAssertEqual(roundTrip, appKitPoint)
    }
    
    func testCaptureRegionAppKitToCoreGraphicsConversion() {
        let primaryHeight: CGFloat = 1440.0
        
        // An AppKit region on the primary display: origin at bottom-left (100, 200), size (400, 300)
        let appKitRect = CGRect(x: 100, y: 200, width: 400, height: 300)
        
        let cgRect = ScreenCoordinateHelper.appKitToCoreGraphics(rect: appKitRect, screenHeight: primaryHeight)
        
        // In CoreGraphics:
        // cgX = 100
        // cgY = 1440 - 200 - 300 = 940
        XCTAssertEqual(cgRect.origin.x, 100)
        XCTAssertEqual(cgRect.origin.y, 940)
        XCTAssertEqual(cgRect.size.width, 400)
        XCTAssertEqual(cgRect.size.height, 300)
        
        // Round trip back to AppKit
        let roundTrip = ScreenCoordinateHelper.coreGraphicsToAppKit(rect: cgRect, screenHeight: primaryHeight)
        XCTAssertEqual(roundTrip, appKitRect)
    }
    
    func testDisplayCoordinateSpaceMappingWithNegativeOriginAndDownsampling() {
        // Multi-display scenario:
        // Primary display: (0, 0, 2560, 1440), primaryHeight = 1440
        // Secondary display placed to the left: AppKit frame (-1920, 0, 1920, 1080)
        let primaryHeight: CGFloat = 1440.0
        let secondaryAppKitFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let secondaryCGFrame = ScreenCoordinateHelper.displayBoundsInCoreGraphics(
            from: secondaryAppKitFrame,
            primaryScreenHeight: primaryHeight
        )
        // secondaryCGFrame should be (-1920, 1440 - (0 + 1080)) = (-1920, 360, 1920, 1080)
        XCTAssertEqual(secondaryCGFrame.origin.x, -1920)
        XCTAssertEqual(secondaryCGFrame.origin.y, 360)
        XCTAssertEqual(secondaryCGFrame.size.width, 1920)
        XCTAssertEqual(secondaryCGFrame.size.height, 1080)
        
        // Suppose the display is captured with downsampling:
        // Native Retina 2x would be 3840x2160, but downsampled for vision to 1280x720
        let capturedPixelSize = CGSize(width: 1280, height: 720)
        
        let space = DisplayCoordinateSpace(
            displayID: 2,
            globalCoreGraphicsFrame: secondaryCGFrame,
            globalAppKitFrame: secondaryAppKitFrame,
            primaryScreenHeight: primaryHeight,
            backingScaleFactor: 2.0,
            capturedPixelSize: capturedPixelSize
        )
        
        // Effective scale: 1280 / 1920 = 2/3 ≈ 0.666667
        XCTAssertEqual(space.effectiveScaleX, 1280.0 / 1920.0, accuracy: 0.0001)
        XCTAssertEqual(space.effectiveScaleY, 720.0 / 1080.0, accuracy: 0.0001)
        
        // A UI element detected in the downsampled image at pixel (256, 144):
        let detectedPixel = CGPoint(x: 256, y: 144)
        
        // 1. Map to global CoreGraphics:
        let globalCG = space.pixelToGlobalCoreGraphics(pixel: detectedPixel)
        // cgX = -1920 + (256 / (2/3)) = -1920 + 384 = -1536
        // cgY = 360 + (144 / (2/3)) = 360 + 216 = 576
        XCTAssertEqual(globalCG.x, -1536.0, accuracy: 0.001)
        XCTAssertEqual(globalCG.y, 576.0, accuracy: 0.001)
        
        // 2. Map to global AppKit:
        let globalAppKit = space.pixelToGlobalAppKit(pixel: detectedPixel)
        // appKitX = -1536
        // appKitY = 1440 - 576 = 864
        XCTAssertEqual(globalAppKit.x, -1536.0, accuracy: 0.001)
        XCTAssertEqual(globalAppKit.y, 864.0, accuracy: 0.001)
        
        // 3. Round-trip from AppKit point back to pixel:
        let mappedBackPixel = space.globalAppKitToPixel(point: globalAppKit)
        XCTAssertEqual(mappedBackPixel.x, detectedPixel.x, accuracy: 0.001)
        XCTAssertEqual(mappedBackPixel.y, detectedPixel.y, accuracy: 0.001)
        
        // 4. Rect mapping round-trip
        let pixelRect = CGRect(x: 100, y: 100, width: 200, height: 150)
        let appKitRectFromPixel = space.pixelRectToGlobalAppKit(pixelRect: pixelRect)
        let roundTripPixelRect = space.globalAppKitToPixelRect(appKitRect: appKitRectFromPixel)
        XCTAssertEqual(roundTripPixelRect.origin.x, pixelRect.origin.x, accuracy: 0.001)
        XCTAssertEqual(roundTripPixelRect.origin.y, pixelRect.origin.y, accuracy: 0.001)
        XCTAssertEqual(roundTripPixelRect.size.width, pixelRect.size.width, accuracy: 0.001)
        XCTAssertEqual(roundTripPixelRect.size.height, pixelRect.size.height, accuracy: 0.001)
    }
    
    func testScreenClamping() {
        let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let companionSize = CGSize(width: 110, height: 110)
        
        // Off-screen to the left/bottom
        let clampedMin = ScreenCoordinateHelper.clamp(
            point: CGPoint(x: -500, y: -200),
            size: companionSize,
            within: screenBounds,
            margin: 10
        )
        XCTAssertEqual(clampedMin.x, 10)
        XCTAssertEqual(clampedMin.y, 10)
        
        // Off-screen to the right/top
        let clampedMax = ScreenCoordinateHelper.clamp(
            point: CGPoint(x: 2500, y: 2000),
            size: companionSize,
            within: screenBounds,
            margin: 10
        )
        XCTAssertEqual(clampedMax.x, 1920 - 110 - 10)
        XCTAssertEqual(clampedMax.y, 1080 - 110 - 10)
    }
    
    // MARK: - Speech & TTS Lifecycle Tests
    
    @MainActor
    func testSpeechAsyncFinishWhenNotRecording() async {
        let speech = SpeechManager.shared
        speech.resetRecording()
        
        // Calling finishRecording when not recording returns cleanly without hanging
        let result = await speech.finishRecording(timeoutSeconds: 0.2)
        XCTAssertFalse(speech.isRecording)
        XCTAssertEqual(result, "")
    }
    
    @MainActor
    func testSpeechTTSDelegateResetsSpeakingState() {
        let speech = SpeechManager.shared
        let dummyUtterance = AVSpeechUtterance(string: "Hello Pinebot")
        let dummySynthesizer = AVSpeechSynthesizer()
        
        // Manually simulate delegate notification for didFinish
        speech.speechSynthesizer(dummySynthesizer, didFinish: dummyUtterance)
        
        // Delegate callback dispatches to MainActor
        let expectation = expectation(description: "isSpeaking becomes false")
        DispatchQueue.main.async {
            XCTAssertFalse(speech.isSpeaking)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
    
    @MainActor
    func testSpeechTTSDelegateDidCancelResetsSpeakingState() {
        let speech = SpeechManager.shared
        let dummyUtterance = AVSpeechUtterance(string: "Cancelled speech")
        let dummySynthesizer = AVSpeechSynthesizer()
        
        speech.speechSynthesizer(dummySynthesizer, didCancel: dummyUtterance)
        
        let expectation = expectation(description: "isSpeaking becomes false on cancel")
        DispatchQueue.main.async {
            XCTAssertFalse(speech.isSpeaking)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }
    
    // MARK: - Task Engine Bounded Loop & Cancellation Tests
    
    @MainActor
    func testTaskEngineCancellation() async {
        let engine = ComputerTaskEngine.shared
        engine.reset()
        
        engine.cancel()
        XCTAssertEqual(engine.status, .cancelled)
    }
    
    @MainActor
    func testTaskEngineBoundedStepLimit() async throws {
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
        let mockObserver = MockComputerObserver(observationToReturn: dummyObs)
        let engine = ComputerTaskEngine(observer: mockObserver)
        
        // Create 15 steps (exceeding bounded limit of 10) using .screenshot backed by mockObserver
        let excessiveSteps = (1...15).map {
            TaskStep(stepNumber: $0, tool: .screenshot, rationale: "Step \($0)")
        }
        
        try await engine.executeTask(
            goal: "Excessive steps test",
            initialSteps: excessiveSteps,
            requireConfirmation: false
        )
        
        // Must fail with step limit error
        if case .failed(let err) = engine.status {
            XCTAssertTrue(err.contains("Bounded step limit reached"))
        } else {
            XCTFail("Expected engine to fail due to bounded step limit, got: \(engine.status)")
        }
    }
    
    @MainActor
    func testUnsupportedLegacyToolsFailAndDoNotFakeCompletion() async throws {
        let engine = ComputerTaskEngine()
        
        // 1. openApp must fail as unsupported
        let openAppStep = TaskStep(stepNumber: 1, tool: .openApp(name: "Calculator"), rationale: "Launch app")
        try await engine.executeTask(goal: "Open App Test", initialSteps: [openAppStep], requireConfirmation: false)
        if case .failed(let err) = engine.status {
            XCTAssertTrue(err.contains("unsupported"))
        } else {
            XCTFail("openApp must fail as unsupported legacy tool, got: \(engine.status)")
        }
        
        // 2. drawOverlay must fail as unsupported
        let drawOverlayStep = TaskStep(stepNumber: 1, tool: .drawOverlay(type: "box", x: 0.5, y: 0.5, label: "Target"), rationale: "Draw box")
        try await engine.executeTask(goal: "Draw Overlay Test", initialSteps: [drawOverlayStep], requireConfirmation: false)
        if case .failed(let err) = engine.status {
            XCTAssertTrue(err.contains("unsupported"))
        } else {
            XCTFail("drawOverlay must fail as unsupported legacy tool, got: \(engine.status)")
        }
    }
    
    @MainActor
    func testLegacyTaskRejectionTerminatesTaskAsRejectedAndNeverCompletesAsSuccess() async throws {
        let engine = ComputerTaskEngine()
        let step = TaskStep(stepNumber: 1, tool: .draftReply(text: "Draft message", recipientHint: nil), rationale: "Send reply")
        
        let task = Task { @MainActor in
            try await engine.executeTask(goal: "Rejection test", initialSteps: [step], requireConfirmation: true)
        }
        
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if case .waitingForConfirmation = engine.status { break }
        }
        
        // Reject the step
        engine.confirmStep(stepId: step.id, approved: false)
        _ = try? await task.value
        
        if case .rejected(let reason) = engine.status {
            XCTAssertTrue(reason.contains("User declined"))
        } else {
            XCTFail("Rejection must terminate task as .rejected, got: \(engine.status)")
        }
        XCTAssertNotEqual(engine.status, .completed(summary: "Successfully completed task: Rejection test"))
    }
    
    @MainActor
    func testChildAgentDepthLimit() async {
        let engine = ComputerTaskEngine.shared
        engine.reset()
        
        do {
            try await engine.executeTask(
                goal: "Recursive child test",
                initialSteps: [TaskStep(stepNumber: 1, tool: .inspect, rationale: "test")],
                requireConfirmation: false,
                childDepth: 2 // Exceeds max depth of 1
            )
            XCTFail("Should have thrown error for child agent depth limit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("depth limit"))
        }
    }
    
    // MARK: - Provider Manager Lifecycle & Authoritative State Tests
    
    @MainActor
    func testFakeProviderThrows401RetainsFailedStateAndExcludesModelsAfterRefresh() async {
        struct HTTPError401: Error, LocalizedError {
            var errorDescription: String? { "HTTP 401 Unauthorized" }
        }
        
        let fakeModel = ModelInfo(
            id: "fake-gpt4",
            displayName: "Fake GPT-4",
            provider: .openai,
            tier: .frontierReasoning
        )
        
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: false,
            discoveredModels: [fakeModel],
            errorToThrowOnValidation: HTTPError401()
        )
        
        let manager = ProviderManager()
        manager.setProvider(fakeProvider, for: .openai)
        
        // Execute explicit validation task
        await manager.validateProvider(.openai)
        
        // Manager must be in failed state
        if case .failed(let message, let recovery) = manager.state(for: .openai) {
            XCTAssertTrue(message.contains("401"), "Error message should reflect 401: \(message)")
            XCTAssertFalse(recovery.isEmpty, "Recovery instructions must be present")
        } else {
            XCTFail("Expected .failed state after 401 error, got: \(manager.state(for: .openai))")
        }
        
        // Explicitly trigger refreshConnectedModels
        manager.refreshConnectedModels()
        
        // Authoritative verification: state MUST remain failed (not overwritten to .connecting)
        if case .failed = manager.state(for: .openai) {
            // Success
        } else {
            XCTFail("State must remain .failed after refresh, but got: \(manager.state(for: .openai))")
        }
        
        // connectedModels MUST exclude models from this failed provider
        XCTAssertFalse(
            manager.connectedModels.contains(where: { $0.provider == .openai }),
            "connectedModels must exclude models from failed provider"
        )
    }
    
    @MainActor
    func testRefreshDuringActiveAuthorizationCannotReplaceConnectingOrNeedsAuthorizationWithStaleIsConnected() {
        let staleModel = ModelInfo(
            id: "stale-model",
            displayName: "Stale Model",
            provider: .openai,
            tier: .frontierReasoning
        )
        
        // Fake provider with stale isConnected = true (e.g. from lingering connection/cache)
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [staleModel]
        )
        
        let manager = ProviderManager()
        manager.setProvider(fakeProvider, for: .openai)
        
        // Case A: Manager is actively connecting
        manager.setState(.connecting(stage: "Waiting for OAuth loopback"), for: .openai)
        manager.refreshConnectedModels()
        
        XCTAssertEqual(
            manager.state(for: .openai),
            .connecting(stage: "Waiting for OAuth loopback"),
            "refreshConnectedModels must not overwrite .connecting with stale provider.isConnected"
        )
        XCTAssertFalse(
            manager.connectedModels.contains(where: { $0.id == "stale-model" }),
            "connectedModels must not include models while connecting"
        )
        
        // Case B: Manager needs user authorization in browser
        let dummyAuthURL = URL(string: "https://auth.openai.com/authorize?state=test1234")!
        manager.setState(.needsAuthorization(authURL: dummyAuthURL), for: .openai)
        manager.refreshConnectedModels()
        
        XCTAssertEqual(
            manager.state(for: .openai),
            .needsAuthorization(authURL: dummyAuthURL),
            "refreshConnectedModels must not overwrite .needsAuthorization with stale provider.isConnected"
        )
        XCTAssertFalse(
            manager.connectedModels.contains(where: { $0.id == "stale-model" }),
            "connectedModels must not include models while waiting for authorization"
        )
    }
    
    // MARK: - Gemini ProviderManager Integration Tests
    
    @MainActor
    func testGeminiOfficialAuthSuccessInProviderManager() async throws {
        let suiteName = "com.pinebot.test.gemini.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": ["promptCapabilities": ["image": true]]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-test",
            "models": [
                "availableModels": [
                    ["modelId": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]
                ]
            ]
        ]))
        
        let session = GeminiAgentSession(transport: mock)
        let provider = GeminiProvider(agentSession: session, defaults: isolatedDefaults)
        let manager = ProviderManager(gemini: provider)
        
        manager.startGeminiOfficialAuth()
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        if case .connected(let summary, let models) = manager.state(for: .gemini) {
            XCTAssertEqual(summary, "Google Account (Personal)")
            XCTAssertEqual(models.count, 1)
            XCTAssertEqual(models.first?.id, "gemini-2.5-pro")
        } else {
            XCTFail("Expected .connected state, got: \(manager.state(for: .gemini))")
        }
        
        XCTAssertTrue(manager.connectedModels.contains(where: { $0.id == "gemini-2.5-pro" }))
        
        manager.disconnect(provider: .gemini)
        XCTAssertEqual(manager.state(for: .gemini), .disconnected)
        XCTAssertFalse(manager.connectedModels.contains(where: { $0.id == "gemini-2.5-pro" }))
    }
    
    @MainActor
    func testGeminiOfficialAuthCancellationInProviderManager() async throws {
        let suiteName = "com.pinebot.test.gemini.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        
        let mock = MockACPTransport()
        let session = GeminiAgentSession(transport: mock)
        let provider = GeminiProvider(agentSession: session, defaults: isolatedDefaults)
        let manager = ProviderManager(gemini: provider)
        
        manager.startGeminiOfficialAuth()
        XCTAssertEqual(manager.state(for: .gemini), .connecting(stage: "Starting Google client..."))
        
        manager.cancelGeminiAuth()
        XCTAssertEqual(manager.state(for: .gemini), .disconnected)
    }
    
    @MainActor
    func testGeminiAuthCancellationGuardsLateSuccessAndStatusUpdates() async throws {
        let suiteName = "com.pinebot.test.gemini.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        let officialActiveKey = "com.pinebot.gemini.official_active"
        
        let mock = MockACPTransport()
        let session = GeminiAgentSession(transport: mock)
        let provider = GeminiProvider(agentSession: session, defaults: isolatedDefaults)
        let manager = ProviderManager(gemini: provider)
        
        manager.startGeminiOfficialAuth()
        XCTAssertTrue(manager.state(for: .gemini).isConnecting)
        
        // Synchronously cancel auth
        manager.cancelGeminiAuth()
        XCTAssertEqual(manager.state(for: .gemini), .disconnected)
        
        // Now script success on the mock to test whether delayed stage or completion could overwrite disconnected
        await mock.setScriptedResponse(method: "initialize", result: .success([
            "protocolVersion": 1,
            "authMethods": [["id": "oauth-personal", "name": "Google"]],
            "agentCapabilities": ["promptCapabilities": ["image": true]]
        ]))
        await mock.setScriptedResponse(method: "authenticate", result: .success([:]))
        await mock.setScriptedResponse(method: "session/new", result: .success([
            "sessionId": "sess-late",
            "models": ["availableModels": [["modelId": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"]]]
        ]))
        
        // Wait a short time for any background tasks to run
        try await Task.sleep(nanoseconds: 150_000_000)
        
        // Assert: manager remains disconnected and official_active is NOT saved
        XCTAssertEqual(manager.state(for: .gemini), .disconnected, "Manager must remain disconnected after cancellation")
        XCTAssertFalse(isolatedDefaults.bool(forKey: officialActiveKey), "official_active must NOT be saved after cancellation")
        XCTAssertFalse(manager.connectedModels.contains(where: { $0.id == "gemini-2.5-pro" }))
    }
    
    @MainActor
    func testGeminiOfficialAuthFailureInProviderManager() async throws {
        let suiteName = "com.pinebot.test.gemini.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        
        let mock = MockACPTransport()
        await mock.setScriptedResponse(method: "initialize", result: .failure(ACPError.requestFailed(code: -32000, message: "Node missing", data: nil)))
        
        let session = GeminiAgentSession(transport: mock)
        let provider = GeminiProvider(agentSession: session, defaults: isolatedDefaults)
        let manager = ProviderManager(gemini: provider)
        
        manager.startGeminiOfficialAuth()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        if case .failed(let msg, let recovery) = manager.state(for: .gemini) {
            XCTAssertTrue(msg.contains("Google sign-in failed"))
            XCTAssertTrue(recovery.contains("Node missing"))
        } else {
            XCTFail("Expected .failed state, got: \(manager.state(for: .gemini))")
        }
    }
    
    // MARK: - SIWC ID Token Cryptographic Verification & Auth Tests
    
    private func generateTestRSAKeyPair() throws -> (privateKey: SecKey, publicKey: SecKey, jwk: JWKSValidator.JWK) {
        let parameters: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(parameters as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) as? Data else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "Key generation failed"
            throw NSError(domain: "TestRSA", code: 500, userInfo: [NSLocalizedDescriptionKey: desc])
        }
        
        func toBase64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        
        // Parse PKCS#1 DER RSAPublicKey: SEQUENCE { modulus INTEGER, exponent INTEGER }
        var offset = 0
        guard pubData.count > 4, pubData[offset] == 0x30 else {
            throw NSError(domain: "TestRSA", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid DER sequence"])
        }
        offset += 1
        if pubData[offset] & 0x80 == 0 {
            offset += 1
        } else {
            let lenBytes = Int(pubData[offset] & 0x7F)
            offset += 1 + lenBytes
        }
        
        guard offset < pubData.count, pubData[offset] == 0x02 else {
            throw NSError(domain: "TestRSA", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid modulus integer tag"])
        }
        offset += 1
        let modLen: Int
        if pubData[offset] & 0x80 == 0 {
            modLen = Int(pubData[offset])
            offset += 1
        } else {
            let lenBytes = Int(pubData[offset] & 0x7F)
            offset += 1
            var l = 0
            for _ in 0..<lenBytes {
                l = (l << 8) | Int(pubData[offset])
                offset += 1
            }
            modLen = l
        }
        var modData = pubData.subdata(in: offset..<(offset + modLen))
        offset += modLen
        if modData.first == 0x00 {
            modData = modData.dropFirst()
        }
        
        guard offset < pubData.count, pubData[offset] == 0x02 else {
            throw NSError(domain: "TestRSA", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid exponent integer tag"])
        }
        offset += 1
        let expLen: Int
        if pubData[offset] & 0x80 == 0 {
            expLen = Int(pubData[offset])
            offset += 1
        } else {
            let lenBytes = Int(pubData[offset] & 0x7F)
            offset += 1
            var l = 0
            for _ in 0..<lenBytes {
                l = (l << 8) | Int(pubData[offset])
                offset += 1
            }
            expLen = l
        }
        let expData = pubData.subdata(in: offset..<(offset + expLen))
        
        let jwk = JWKSValidator.JWK(
            kty: "RSA",
            kid: "test-unit-kid-\(UUID().uuidString)",
            use: "sig",
            alg: "RS256",
            n: toBase64URL(modData),
            e: toBase64URL(expData)
        )
        return (privateKey, publicKey, jwk)
    }
    
    private func createSignedJWT(
        header: [String: Any],
        payload: [String: Any],
        privateKey: SecKey
    ) throws -> String {
        func toBase64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        
        let headerB64 = toBase64URL(headerData)
        let payloadB64 = toBase64URL(payloadData)
        let signingInput = "\(headerB64).\(payloadB64)".data(using: .utf8)!
        
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            &error
        ) as? Data else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "Signature creation failed"
            throw NSError(domain: "TestJWT", code: 500, userInfo: [NSLocalizedDescriptionKey: desc])
        }
        
        let signatureB64 = toBase64URL(signature)
        return "\(headerB64).\(payloadB64).\(signatureB64)"
    }
    
    func testJWKSValidatorValidatesCryptographicSignatureAndClaims() async throws {
        let (privateKey, _, jwk) = try generateTestRSAKeyPair()
        let validator = JWKSValidator()
        await validator.setCachedKey(jwk)
        
        let expectedNonce = "test_nonce_\(UUID().uuidString)"
        let expectedClientId = "oaiapp_test_client_123"
        
        let header: [String: Any] = ["alg": "RS256", "kid": jwk.kid]
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "sub": "user_pinebot_42",
            "aud": expectedClientId,
            "nonce": expectedNonce,
            "exp": Date().timeIntervalSince1970 + 3600,
            "email": "pinebot.tester@example.com"
        ]
        
        let signedJWT = try createSignedJWT(header: header, payload: payload, privateKey: privateKey)
        
        let validated = try await validator.validateIDToken(
            idToken: signedJWT,
            expectedNonce: expectedNonce,
            expectedClientId: expectedClientId
        )
        
        XCTAssertEqual(validated.issuer, "https://auth.openai.com")
        XCTAssertEqual(validated.subject, "user_pinebot_42")
        XCTAssertEqual(validated.audience, expectedClientId)
        XCTAssertEqual(validated.nonce, expectedNonce)
        XCTAssertEqual(validated.email, "pinebot.tester@example.com")
    }
    
    func testJWKSValidatorRejectsTamperedSignature() async throws {
        let (privateKey, _, jwk) = try generateTestRSAKeyPair()
        let validator = JWKSValidator()
        await validator.setCachedKey(jwk)
        
        let expectedNonce = "nonce_tamper"
        let expectedClientId = "oaiapp_tamper"
        
        let header: [String: Any] = ["alg": "RS256", "kid": jwk.kid]
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "sub": "user_tamper",
            "aud": expectedClientId,
            "nonce": expectedNonce,
            "exp": Date().timeIntervalSince1970 + 3600
        ]
        
        let signedJWT = try createSignedJWT(header: header, payload: payload, privateKey: privateKey)
        
        // Tamper with the payload: change user_tamper to user_hacked
        let parts = signedJWT.components(separatedBy: ".")
        var tamperedPayloadData = parts[1].data(using: .utf8)!
        // Modify a byte
        tamperedPayloadData[0] = tamperedPayloadData[0] == UInt8(ascii: "e") ? UInt8(ascii: "f") : UInt8(ascii: "e")
        let tamperedJWT = "\(parts[0]).\(String(data: tamperedPayloadData, encoding: .utf8)!).\(parts[2])"
        
        do {
            _ = try await validator.validateIDToken(
                idToken: tamperedJWT,
                expectedNonce: expectedNonce,
                expectedClientId: expectedClientId
            )
            XCTFail("Should have thrown error for tampered token signature")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("signature") || error.localizedDescription.contains("verification") || error.localizedDescription.contains("decode"),
                "Error should describe signature verification failure: \(error.localizedDescription)"
            )
        }
    }
    
    func testJWKSValidatorRejectsExpiredToken() async throws {
        let (privateKey, _, jwk) = try generateTestRSAKeyPair()
        let validator = JWKSValidator()
        await validator.setCachedKey(jwk)
        
        let expectedNonce = "nonce_exp"
        let expectedClientId = "oaiapp_exp"
        
        let header: [String: Any] = ["alg": "RS256", "kid": jwk.kid]
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "sub": "user_exp",
            "aud": expectedClientId,
            "nonce": expectedNonce,
            "exp": Date().timeIntervalSince1970 - 120 // Expired 2 minutes ago
        ]
        
        let signedJWT = try createSignedJWT(header: header, payload: payload, privateKey: privateKey)
        
        do {
            _ = try await validator.validateIDToken(
                idToken: signedJWT,
                expectedNonce: expectedNonce,
                expectedClientId: expectedClientId
            )
            XCTFail("Should have thrown error for expired token")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("expired"),
                "Error should state token has expired: \(error.localizedDescription)"
            )
        }
    }
    
    func testJWKSValidatorRejectsAudienceMismatch() async throws {
        let (privateKey, _, jwk) = try generateTestRSAKeyPair()
        let validator = JWKSValidator()
        await validator.setCachedKey(jwk)
        
        let expectedNonce = "nonce_aud"
        
        let header: [String: Any] = ["alg": "RS256", "kid": jwk.kid]
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "sub": "user_aud",
            "aud": "oaiapp_imposter_app",
            "nonce": expectedNonce,
            "exp": Date().timeIntervalSince1970 + 3600
        ]
        
        let signedJWT = try createSignedJWT(header: header, payload: payload, privateKey: privateKey)
        
        do {
            _ = try await validator.validateIDToken(
                idToken: signedJWT,
                expectedNonce: expectedNonce,
                expectedClientId: "oaiapp_legit_pinebot"
            )
            XCTFail("Should have thrown error for audience mismatch")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("audience mismatch"),
                "Error should state audience mismatch: \(error.localizedDescription)"
            )
        }
    }
    
    func testJWKSValidatorRejectsNonceMismatch() async throws {
        let (privateKey, _, jwk) = try generateTestRSAKeyPair()
        let validator = JWKSValidator()
        await validator.setCachedKey(jwk)
        
        let expectedClientId = "oaiapp_nonce_test"
        
        let header: [String: Any] = ["alg": "RS256", "kid": jwk.kid]
        let payload: [String: Any] = [
            "iss": "https://auth.openai.com",
            "sub": "user_nonce",
            "aud": expectedClientId,
            "nonce": "nonce_from_replay_attack",
            "exp": Date().timeIntervalSince1970 + 3600
        ]
        
        let signedJWT = try createSignedJWT(header: header, payload: payload, privateKey: privateKey)
        
        do {
            _ = try await validator.validateIDToken(
                idToken: signedJWT,
                expectedNonce: "nonce_expected_fresh",
                expectedClientId: expectedClientId
            )
            XCTFail("Should have thrown error for nonce mismatch")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("nonce mismatch"),
                "Error should state nonce mismatch: \(error.localizedDescription)"
            )
        }
    }
    
    func testOpenAIProviderAutoDetectsOAuthFromKeychainWithoutError() async {
        let testPrefix = "com.pinebot.test.openai.\(UUID().uuidString)"
        let testSuiteName = "com.pinebot.test.suite.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: testSuiteName)!
        defer {
            testDefaults.removePersistentDomain(forName: testSuiteName)
        }
        let keychain = KeychainHelper.shared
        let tokenKey = "\(testPrefix).access_token"
        let authTypeKey = "\(testPrefix).auth_type"
        defer {
            keychain.delete(key: tokenKey)
        }
        
        // Simulate OAuth token in Keychain with missing UserDefaults auth_type
        keychain.saveString(key: tokenKey, value: "test_oauth_access_token_abc")
        testDefaults.removeObject(forKey: authTypeKey)
        
        let provider = OpenAIProvider(
            userDefaults: testDefaults,
            keychain: keychain,
            keyPrefix: testPrefix
        )
        
        // Background credential restoration discovers saved credentials even when metadata/auth_type is missing
        await provider.restoreConnection()
        
        XCTAssertTrue(provider.isConfigured, "Provider must be configured when token exists in Keychain")
        // Verify authTypeKey was auto-detected and persisted to isolated UserDefaults
        let detected = testDefaults.string(forKey: authTypeKey)
        XCTAssertEqual(detected, "oauth", "authType must auto-detect as 'oauth' when OAuth token is present in Keychain")
    }
    
    func testLiveOpenAIValidationIfCredentialsPresent() async throws {
        let provider = OpenAIProvider()
        guard provider.isConfigured else {
            return
        }
        
        do {
            let models = try await provider.validateAndDiscoverModels()
            XCTAssertFalse(models.isEmpty, "Should discover models when credentials exist")
            XCTAssertTrue(provider.isConnected)
        } catch {
            XCTAssertFalse(
                error.localizedDescription.contains("API Key missing"),
                "Must never fail with 'API Key missing' when OAuth credentials exist: \(error.localizedDescription)"
            )
        }
    }
    
    // MARK: - R1 Regressions: Sidecar Worker & Assistant Ownership
    
    @MainActor
    func testSlowSidecarDoesNotBlockMainActorHeartbeat() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("slow_sidecar_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json, time
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            time.sleep(0.6)
            resp = {
                "id": req.get("id"),
                "status": "learned",
                "model_name": "mock-delayed-model",
                "category": "simple_chat",
                "difficulty": "simple",
                "reasoning_score": 0.2,
                "confidence": 0.95,
                "requires_vision": False,
                "requires_computer_tools": False
            }
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        var mainActorTickTimestamps: [CFAbsoluteTime] = []
        var classificationFinishedTime: CFAbsoluteTime = 0
        
        // Launch classification directly from MainActor Task to prove MainActor caller does not block
        let classifyTask = Task { @MainActor in
            let res = await classifier.classify(prompt: "Hello from MainActor")
            classificationFinishedTime = CFAbsoluteTimeGetCurrent()
            return res
        }
        
        // Run independent MainActor ticks and record their timestamps
        let tickTask = Task { @MainActor in
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 60_000_000)
                mainActorTickTimestamps.append(CFAbsoluteTimeGetCurrent())
            }
        }
        
        _ = try await tickTask.value
        let result = await classifyTask.value
        
        XCTAssertGreaterThanOrEqual(mainActorTickTimestamps.count, 4, "MainActor must remain responsive and execute ticks while sidecar runs in background")
        for tickTime in mainActorTickTimestamps {
            XCTAssertLessThan(tickTime, classificationFinishedTime, "MainActor tick timestamp must occur BEFORE inference returns, proving non-blocking concurrency")
        }
        XCTAssertTrue(result.status.isLearned)
    }
    
    func testHungWorkerDeadlineReturnsFallback() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("hung_sidecar_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, time
        # Ignore input and sleep indefinitely
        time.sleep(60)
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = await classifier.classify(prompt: "Testing 3-second deadline")
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        XCTAssertGreaterThanOrEqual(duration, 2.8, "Must wait for genuine deadline before falling back")
        XCTAssertLessThan(duration, 5.0, "Must not hang beyond 3-second deadline plus bounded cleanup")
        
        XCTAssertFalse(result.status.isLearned, "Hung worker must result in honest fallback")
        if case .fallback(let reason) = result.status {
            XCTAssertTrue(
                reason.lowercased().contains("timed out") || reason.contains("3.0s"),
                "Fallback reason must identify the 3s timeout: \(reason)"
            )
        } else {
            XCTFail("Expected fallback status, got \(result.status)")
        }
    }
    
    func testWorkerHandlesStderrFloodWithoutDeadlock() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("stderr_flood_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            # Flood 100KB of stderr diagnostics
            sys.stderr.write("D" * 102400 + "\\n")
            sys.stderr.flush()
            resp = {
                "id": req.get("id"),
                "status": "learned",
                "model_name": "flood-test-model",
                "category": "greeting",
                "difficulty": "simple",
                "reasoning_score": 0.1,
                "confidence": 0.99,
                "requires_vision": False,
                "requires_computer_tools": False
            }
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        let result = await classifier.classify(prompt: "Test stderr flood")
        XCTAssertTrue(result.status.isLearned, "Worker must consume stderr concurrently without deadlocking stdout")
        XCTAssertEqual(result.category, .greeting)
    }
    
    func testWorkerHandlesSplitOutputFrames() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("split_sidecar_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json, time
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            req_id = req.get("id")
            chunk1 = '{"id": "' + req_id + '", "status": "learned", '
            chunk2 = '"model_name": "split-model", "category": "greeting", '
            chunk3 = '"difficulty": "simple", "reasoning_score": 0.1, "confidence": 0.95, "requires_vision": false, "requires_computer_tools": false}\\n'
            sys.stdout.write(chunk1)
            sys.stdout.flush()
            time.sleep(0.05)
            sys.stdout.write(chunk2)
            sys.stdout.flush()
            time.sleep(0.05)
            sys.stdout.write(chunk3)
            sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        let result = await classifier.classify(prompt: "Test split frames")
        XCTAssertTrue(result.status.isLearned, "Single-consumer line buffer must reassemble split output chunks")
        XCTAssertEqual(result.category, .greeting)
    }
    
    func testStaleEOFFromTerminatedWorkerDoesNotKillNewWorker() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("stale_eof_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            resp = {
                "id": req.get("id"),
                "status": "learned",
                "model_name": "stale-eof-model",
                "category": "simple_chat",
                "difficulty": "simple",
                "reasoning_score": 0.2,
                "confidence": 0.95,
                "requires_vision": False,
                "requires_computer_tools": False
            }
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        // Start gen 1
        let firstResult = await classifier.classify(prompt: "Gen 1 prompt")
        XCTAssertTrue(firstResult.status.isLearned)
        let gen1 = await classifier.worker.currentGeneration()
        
        // Stop worker and start gen 2
        await classifier.worker.stop()
        let secondResult = await classifier.classify(prompt: "Gen 2 prompt")
        XCTAssertTrue(secondResult.status.isLearned)
        let gen2 = await classifier.worker.currentGeneration()
        XCTAssertGreaterThan(gen2, gen1)
        
        // Simulate a stale EOF from generation 1 arriving late
        await classifier.worker.simulateStaleEOF(generation: gen1)
        
        // Generation 2 must still be alive and answer subsequent requests
        let thirdResult = await classifier.classify(prompt: "Gen 2 subsequent prompt")
        XCTAssertTrue(thirdResult.status.isLearned, "Stale EOF from previous generation must not kill the active worker")
    }
    
    @MainActor
    func testStopCancelPreventsLateReplyAndOutput() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        let manager = ProviderManager()
        let assistant = PinebotAssistant(providerManager: manager, router: router, startHotkeys: false)
        
        let fakeModel = ModelInfo(id: "fake-gpt", displayName: "Fake GPT", provider: .openai, tier: .cheapFast, supportsVision: false, supportsTools: false)
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [fakeModel]
        )
        
        var heldContinuation: CheckedContinuation<String, Never>?
        fakeProvider.completionHandler = { _ in
            await withCheckedContinuation { cont in
                heldContinuation = cont
            }
        }
        
        manager.setProvider(fakeProvider, for: .openai)
        manager.setState(.connected(accountSummary: "Fake Connected", models: [fakeModel]), for: .openai)
        manager.refreshConnectedModels()
        
        // Submit prompt
        assistant.submitUserPrompt("Generate a response")
        
        // Wait for prompt execution to enter generateCompletion
        for _ in 0..<80 {
            if heldContinuation != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNotNil(heldContinuation, "Provider must be executing prompt completion")
        XCTAssertTrue(assistant.isProcessing)
        
        // Trigger stop
        assistant.stopCurrentProcessing()
        XCTAssertFalse(assistant.isProcessing, "Assistant must immediately mark isProcessing as false on stop")
        XCTAssertEqual(assistant.messages.last?.text, "⏹️ Stopped request.")
        
        // Now resume the held completion with a late response
        heldContinuation?.resume(returning: "Late response that should be discarded")
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Verify late reply was NOT appended
        let hasLateMessage = assistant.messages.contains { $0.text.contains("Late response that should be discarded") }
        XCTAssertFalse(hasLateMessage, "Late completions arriving after Stop must not mutate conversation messages")
    }
    
    @MainActor
    func testProviderCancellationDoesNotTriggerEscalation() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        let manager = ProviderManager()
        let assistant = PinebotAssistant(providerManager: manager, router: router, startHotkeys: false)
        
        let cheapModel = ModelInfo(id: "cheap-model", displayName: "Cheap Model", provider: .openai, tier: .cheapFast, supportsVision: false, supportsTools: false)
        let frontierModel = ModelInfo(id: "frontier-model", displayName: "Frontier Model", provider: .claude, tier: .frontierReasoning, supportsVision: false, supportsTools: false)
        
        let fakeOpenAI = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [cheapModel]
        )
        fakeOpenAI.completionHandler = { _ in
            throw CancellationError()
        }
        
        let fakeClaude = FakeLLMProvider(
            type: .claude,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [frontierModel]
        )
        var claudeCalled = false
        fakeClaude.completionHandler = { _ in
            claudeCalled = true
            return "Escalated reply"
        }
        
        manager.setProvider(fakeOpenAI, for: .openai)
        manager.setState(.connected(accountSummary: "OpenAI Connected", models: [cheapModel]), for: .openai)
        manager.setProvider(fakeClaude, for: .claude)
        manager.setState(.connected(accountSummary: "Claude Connected", models: [frontierModel]), for: .claude)
        manager.refreshConnectedModels()
        
        await assistant.processUserPrompt("A query that gets cancelled")
        
        XCTAssertFalse(claudeCalled, "CancellationError must NOT trigger model escalation to frontier model")
        let hasEscalatedNote = assistant.messages.contains { $0.text.contains("Note: Escalated") }
        XCTAssertFalse(hasEscalatedNote, "No escalation note should be present on CancellationError")
        let hasInferenceError = assistant.messages.contains { $0.text.contains("Error during inference") }
        XCTAssertFalse(hasInferenceError, "CancellationError must not be presented as an inference error")
    }
    
    func testWarmWorkerSequentialPIDReuseAndSecondRequestSurvival() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("warm_worker_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json, time
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            req_id = req.get("id", "")
            resp = {
                "id": req_id,
                "status": "learned",
                "model_name": "warm-pid-model",
                "category": "simple_chat",
                "difficulty": "simple",
                "reasoning_score": 0.1,
                "confidence": 0.99,
                "requires_vision": False,
                "requires_computer_tools": False
            }
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        // Sequential Request 1
        let res1 = await classifier.classify(prompt: "Sequential Prompt 1")
        XCTAssertTrue(res1.status.isLearned)
        let pid1 = await classifier.worker.currentProcessIdentifier()
        XCTAssertNotNil(pid1, "Worker process must be active")
        
        // Sequential Request 2: must reuse same warm PID
        let res2 = await classifier.classify(prompt: "Sequential Prompt 2")
        XCTAssertTrue(res2.status.isLearned)
        let pid2 = await classifier.worker.currentProcessIdentifier()
        XCTAssertEqual(pid1, pid2, "Warm worker must reuse the exact same PID across sequential requests")
        
        // Concurrent requests: verify timer cancellation in request A does not kill request B
        async let concurrentA = classifier.classify(prompt: "Concurrent A")
        async let concurrentB = classifier.classify(prompt: "Concurrent B")
        let (valA, valB) = await (concurrentA, concurrentB)
        XCTAssertTrue(valA.status.isLearned)
        XCTAssertTrue(valB.status.isLearned)
        
        let pidAfterConcurrent = await classifier.worker.currentProcessIdentifier()
        XCTAssertEqual(pid1, pidAfterConcurrent, "Worker must remain warm and alive without being killed by timer cancellations")
    }
    
    @MainActor
    func testImmediateStopThenNewPromptWithDelayedTeardown() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        let manager = ProviderManager()
        let assistant = PinebotAssistant(providerManager: manager, router: router, startHotkeys: false)
        
        let model1 = ModelInfo(id: "fake-gpt-model", displayName: "Fake GPT", provider: .openai, tier: .cheapFast, supportsVision: false, supportsTools: false)
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [model1]
        )
        
        var prompt1Started = false
        var prompt1Continuation: CheckedContinuation<String, Never>?
        var prompt2Completed = false
        
        fakeProvider.completionHandler = { prompt in
            if prompt == "Prompt 1" {
                prompt1Started = true
                return await withCheckedContinuation { cont in
                    prompt1Continuation = cont
                }
            } else if prompt == "Prompt 2" {
                prompt2Completed = true
                return "Response for Prompt 2"
            }
            return "Default response"
        }
        
        manager.setProvider(fakeProvider, for: .openai)
        manager.setState(.connected(accountSummary: "Fake Connected", models: [model1]), for: .openai)
        manager.refreshConnectedModels()
        
        // 1. Submit Prompt 1
        assistant.submitUserPrompt("Prompt 1")
        
        for _ in 0..<80 {
            if prompt1Started && prompt1Continuation != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNotNil(prompt1Continuation, "Prompt 1 must have started execution")
        
        // 2. Immediately Stop Prompt 1
        assistant.stopCurrentProcessing()
        XCTAssertFalse(assistant.isProcessing)
        
        // 3. Immediately submit Prompt 2 while Prompt 1's teardown is still pending
        assistant.submitUserPrompt("Prompt 2")
        
        // 4. Complete Prompt 1 with a delayed response
        prompt1Continuation?.resume(returning: "Stale reply 1")
        
        // 5. Wait for Prompt 2 to finish execution
        for _ in 0..<80 {
            if prompt2Completed { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        
        XCTAssertTrue(prompt2Completed, "Prompt 2 must successfully complete despite immediate stop of Prompt 1")
        
        // Check message assertions:
        let hasPrompt2Response = assistant.messages.contains { $0.text.contains("Response for Prompt 2") }
        XCTAssertTrue(hasPrompt2Response, "Prompt 2 response must be present")
        
        let hasPrompt1Stale = assistant.messages.contains { $0.text.contains("Stale reply 1") }
        XCTAssertFalse(hasPrompt1Stale, "Stale reply from Prompt 1 must not be appended after stop")
    }
    
    @MainActor
    func testStopWithNoActiveRequestDoesNotCancelFutureRequests() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        let manager = ProviderManager()
        let assistant = PinebotAssistant(providerManager: manager, router: router, startHotkeys: false)
        
        let model = ModelInfo(id: "fake-gpt-model", displayName: "Fake GPT", provider: .openai, tier: .cheapFast, supportsVision: false, supportsTools: false)
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [model]
        )
        fakeProvider.completionHandler = { _ in
            return "Normal completion text"
        }
        
        manager.setProvider(fakeProvider, for: .openai)
        manager.setState(.connected(accountSummary: "Fake Connected", models: [model]), for: .openai)
        manager.refreshConnectedModels()
        
        // Call stop when completely idle
        assistant.stopCurrentProcessing()
        XCTAssertEqual(assistant.messages.count, 0, "Stop on idle must not append stop message")
        
        // Submit prompt afterwards
        await assistant.processUserPrompt("Idle test prompt")
        
        let hasNormalResponse = assistant.messages.contains { $0.text.contains("Normal completion text") }
        XCTAssertTrue(hasNormalResponse, "Future prompt must complete normally without being cancelled by prior idle stop")
    }
    
    func testOneShotWorkerWritesFinalJSONAndExitsImmediately() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            resp = {
                "id": req.get("id"),
                "status": "learned",
                "model_name": "oneshot-model",
                "category": "simple_chat",
                "difficulty": "simple",
                "reasoning_score": 0.2,
                "confidence": 0.99,
                "requires_vision": False,
                "requires_computer_tools": False
            }
            # Write valid final JSON and exit immediately without reading further
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
            sys.exit(0)
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        // This request must succeed and NOT be discarded or failed by premature termination handling!
        let result = await classifier.classify(prompt: "One shot prompt")
        XCTAssertTrue(result.status.isLearned, "One-shot worker's final JSON must be drained and parsed successfully before teardown")
        if case .learned(let model, _) = result.status {
            XCTAssertEqual(model, "oneshot-model")
        }
    }
    
    func testLearnedClassifierMissingRequiredBoolFieldsTriggersFallback() async throws {
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("missing_bools_\(UUID().uuidString).py")
        let scriptContent = """
        import sys, json
        for line in sys.stdin:
            if not line.strip(): continue
            req = json.loads(line)
            # Emit status learned but omit requires_vision and requires_computer_tools
            resp = {
                "id": req.get("id"),
                "status": "learned",
                "model_name": "missing-bool-model",
                "category": "computer_task",
                "difficulty": "complex",
                "reasoning_score": 0.9,
                "confidence": 0.99
            }
            sys.stdout.write(json.dumps(resp) + "\\n")
            sys.stdout.flush()
        """
        try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        
        let classifier = LocalLearnedClassifier(
            pythonExecutable: "/usr/bin/python3",
            sidecarScriptURL: tempScript
        )
        
        let result = await classifier.classify(prompt: "Click the red button")
        // Missing required boolean fields must trigger honest fallback, never silent defaulting
        XCTAssertFalse(result.status.isLearned, "Missing required boolean fields must trigger fallback")
        if case .fallback(let reason) = result.status {
            XCTAssertTrue(reason.contains("missing/malformed learned fields"), "Reason should indicate missing/malformed learned fields, got: \(reason)")
        } else {
            XCTFail("Expected fallback status, got \(result.status)")
        }
    }
    
    @MainActor
    func testStopPreservesConfiguredAndConnectedAccountStateAndNeverCallsDisconnect() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        let manager = ProviderManager()
        let assistant = PinebotAssistant(providerManager: manager, router: router, startHotkeys: false)
        
        let model = ModelInfo(id: "fake-gpt-model", displayName: "Fake GPT", provider: .openai, tier: .cheapFast, supportsVision: false, supportsTools: false)
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [model]
        )
        
        var promptStarted = false
        var promptContinuation: CheckedContinuation<String, Never>?
        fakeProvider.completionHandler = { _ in
            promptStarted = true
            return await withCheckedContinuation { cont in
                promptContinuation = cont
            }
        }
        
        manager.setProvider(fakeProvider, for: .openai)
        manager.setState(.connected(accountSummary: "Connected Account", models: [model]), for: .openai)
        manager.refreshConnectedModels()
        
        XCTAssertTrue(fakeProvider.isConfigured)
        XCTAssertTrue(fakeProvider.isConnected)
        XCTAssertFalse(fakeProvider.disconnectCalled)
        
        // Submit prompt
        assistant.submitUserPrompt("A prompt to stop")
        
        for _ in 0..<80 {
            if promptStarted && promptContinuation != nil { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNotNil(promptContinuation)
        
        // Stop current processing
        assistant.stopCurrentProcessing()
        XCTAssertFalse(assistant.isProcessing)
        
        // Resume prompt continuation to complete task
        promptContinuation?.resume(returning: "Late response")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // CRITICAL ASSERTIONS: Provider must NOT have disconnect() called!
        // Configuration and connection state must remain completely intact!
        XCTAssertFalse(fakeProvider.disconnectCalled, "Stop must NEVER call provider.disconnect() or purge credentials")
        XCTAssertTrue(fakeProvider.isConfigured, "Provider must remain configured after Stop")
        XCTAssertTrue(fakeProvider.isConnected, "Provider must remain connected after Stop")
        XCTAssertTrue(fakeProvider.cancelGenerationCalled, "Stop must call provider.cancelGeneration()")
    }
    
    // MARK: - R2 Regressions: Routing Quality & Difficulty Separation
    
    func testRoutingQualityPlainGenerateResponseIsNotComputerTask() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        
        let textOnlyModel = ModelInfo(
            id: "text-cheap-model",
            displayName: "Text Cheap Model",
            provider: .openai,
            tier: .cheapFast,
            supportsVision: false,
            supportsTools: false
        )
        
        let classification = await classifier.classify(prompt: "Generate a response", hasScreenImage: false)
        XCTAssertFalse(classification.requiresVision, "Plain 'Generate a response' must not require vision")
        XCTAssertFalse(classification.requiresComputerTools, "Plain 'Generate a response' must not require computer tools")
        XCTAssertNotEqual(classification.category, .computerTask)
        XCTAssertNotEqual(classification.category, .screenAnalysis)
        
        let decision = try await router.route(
            prompt: "Generate a response",
            hasScreenImage: false,
            connectedModels: [textOnlyModel]
        )
        XCTAssertEqual(decision.selectedModel.id, "text-cheap-model")
        XCTAssertEqual(decision.selectedModel.tier, .cheapFast)
    }
    
    func testRoutingQualitySimpleCodeOver50CharsDoesNotForceFrontier() async throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("pinebot_test_missing_models_\(UUID().uuidString)")
        let classifier = LocalLearnedClassifier(modelDirectory: missingDir)
        let router = ModelRouter(classifier: classifier)
        
        let cheapCodeModel = ModelInfo(
            id: "cheap-code-model",
            displayName: "Cheap Code Model",
            provider: .openai,
            tier: .cheapFast,
            supportsVision: false,
            supportsTools: false
        )
        let frontierCodeModel = ModelInfo(
            id: "frontier-code-model",
            displayName: "Frontier Code Model",
            provider: .claude,
            tier: .frontierReasoning,
            supportsVision: false,
            supportsTools: false
        )
        let connected = [cheapCodeModel, frontierCodeModel]
        
        // 50+ characters of simple code (64 characters)
        let simpleCodePrompt = "Write a python function to print hello world 10 times in a loop."
        let simpleClassification = await classifier.classify(prompt: simpleCodePrompt, hasScreenImage: false)
        XCTAssertEqual(simpleClassification.category, .codeGeneration)
        XCTAssertEqual(simpleClassification.difficulty, .simple, "50+ characters of simple code must NOT be classified as complex difficulty")
        
        let simpleDecision = try await router.route(
            prompt: simpleCodePrompt,
            hasScreenImage: false,
            connectedModels: connected
        )
        XCTAssertEqual(simpleDecision.selectedModel.id, "cheap-code-model", "Simple code must route to cheapFast model, not forcing frontier")
        
        // Complex code prompt requiring deep reasoning / architecture / concurrency
        let complexCodePrompt = "Refactor this distributed architecture to prevent async deadlock and race conditions"
        let complexClassification = await classifier.classify(prompt: complexCodePrompt, hasScreenImage: false)
        XCTAssertEqual(complexClassification.category, .codeGeneration)
        XCTAssertEqual(complexClassification.difficulty, .complex, "Concurrency/deadlock code must be classified as complex difficulty")
        
        let complexDecision = try await router.route(
            prompt: complexCodePrompt,
            hasScreenImage: false,
            connectedModels: connected
        )
        XCTAssertEqual(complexDecision.selectedModel.id, "frontier-code-model", "Complex code must route to frontierReasoning model")
    }
    
    func testLearnedClassifierRoutingQualityWhenWeightsPresent() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("work/pinebot/models"),
            URL(fileURLWithPath: cwd).appendingPathComponent("models")
        ]
        guard let modelsDir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.onnx").path) }) else {
            return
        }
        
        let classifier = LocalLearnedClassifier(modelDirectory: modelsDir)
        
        // 1. Plain "Generate a response"
        let plainRes = await classifier.classify(prompt: "Generate a response", hasScreenImage: false)
        XCTAssertTrue(plainRes.status.isLearned)
        XCTAssertFalse(plainRes.requiresVision, "Plain 'Generate a response' must not require vision in learned model")
        XCTAssertFalse(plainRes.requiresComputerTools, "Plain 'Generate a response' must not require computer tools in learned model")
        XCTAssertNotEqual(plainRes.category, .computerTask)
        XCTAssertNotEqual(plainRes.category, .screenAnalysis)
        
        // 2. Simple code over 50 chars (64 chars)
        let simpleCode = "Write a python script that prints hello world 10 times in a loop."
        let simpleRes = await classifier.classify(prompt: simpleCode, hasScreenImage: false)
        XCTAssertTrue(simpleRes.status.isLearned)
        XCTAssertEqual(simpleRes.category, .codeGeneration)
        XCTAssertEqual(simpleRes.difficulty, .simple, "Simple code over 50 chars must have difficulty .simple in learned model")
    }
    
    func testHeldOutRoutingAcceptanceSet() async throws {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("work/pinebot/models"),
            URL(fileURLWithPath: cwd).appendingPathComponent("models")
        ]
        guard let modelsDir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.onnx").path) }) else {
            return
        }
        
        let classifier = LocalLearnedClassifier(modelDirectory: modelsDir)
        let connectedModels: [ModelInfo] = [
            ModelInfo(id: "gemini-flash", displayName: "Gemini 2.5 Flash", provider: .gemini, tier: .cheapFast, supportsVision: true, supportsTools: true, supportsComputerPlanning: true),
            ModelInfo(id: "gpt-4o", displayName: "GPT-4o", provider: .openai, tier: .balanced, supportsVision: true, supportsTools: true, supportsComputerPlanning: true),
            ModelInfo(id: "o3-mini", displayName: "o3-mini", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsTools: true, supportsComputerPlanning: true)
        ]
        let router = ModelRouter(classifier: classifier)
        
        // Case 1: Verbose arithmetic (previously failed: classified as complex_reasoning/complex .93)
        let c1Prompt = "Please calculate seventeen plus twenty-six and reply with the number only."
        let c1Route = try await router.route(prompt: c1Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertEqual(c1Route.classification.difficulty, .simple, "Arithmetic must be classified as simple")
        XCTAssertFalse(c1Route.classification.requiresComputerTools, "Arithmetic must not require computer tools")
        XCTAssertFalse(c1Route.classification.requiresVision, "Arithmetic must not require vision")
        XCTAssertEqual(c1Route.selectedModel.tier, .cheapFast, "Arithmetic must route to cheap/fast tier instead of wasting frontier reasoning")
        
        // Case 2: Short difficult proof (spectral theorem)
        let c2Prompt = "Prove that every self-adjoint operator on a finite-dimensional inner product space has an orthonormal basis of eigenvectors."
        let c2Route = try await router.route(prompt: c2Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertEqual(c2Route.classification.category, .complexReasoning)
        XCTAssertEqual(c2Route.classification.difficulty, .complex)
        XCTAssertFalse(c2Route.classification.requiresComputerTools)
        XCTAssertEqual(c2Route.selectedModel.tier, .frontierReasoning, "Formal proof must route to frontier reasoning")
        
        // Case 3: Simple CRUD SQL (previously failed: miscategorized as simple_chat .86)
        let c3Prompt = "Write one SQL query selecting all rows from the users table."
        let c3Route = try await router.route(prompt: c3Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertEqual(c3Route.classification.category, .codeGeneration, "SQL query must be code_generation")
        XCTAssertEqual(c3Route.classification.difficulty, .simple, "Simple CRUD query must be simple difficulty")
        XCTAssertEqual(c3Route.selectedModel.tier, .cheapFast, "Simple CRUD query must route to cheap/fast")
        
        // Case 4: Database design
        let c4Prompt = "Design a distributed database schema with sharding and cross-region replication for payments."
        let c4Route = try await router.route(prompt: c4Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertEqual(c4Route.classification.difficulty, .complex)
        XCTAssertEqual(c4Route.selectedModel.tier, .frontierReasoning)
        
        // Case 5: Menu teaching (teaching explanation, NOT desktop action)
        let c5Prompt = "Show me how to save a file from the File menu."
        let c5Route = try await router.route(prompt: c5Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertFalse(c5Route.classification.requiresComputerTools, "Menu teaching/explanation must NOT require computer tools")
        XCTAssertFalse(c5Route.classification.requiresVision)
        XCTAssertNotEqual(c5Route.classification.category, .computerTask)
        XCTAssertEqual(c5Route.classification.difficulty, .simple)
        
        // Case 6: Action request (previously failed: requires_computer_tools was false)
        let c6Prompt = "Open Calculator and calculate 17+26."
        let c6Route = try await router.route(prompt: c6Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertTrue(c6Route.classification.requiresComputerTools, "Desktop action request must set requires_computer_tools")
        XCTAssertTrue(c6Route.classification.requiresVision, "Desktop action request must set requires_vision")
        XCTAssertEqual(c6Route.classification.category, .computerTask)
        
        // Case 7: Quoted instructions (not executable action)
        let c7Prompt = "What does the command \"pkill -f node\" do?"
        let c7Route = try await router.route(prompt: c7Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertFalse(c7Route.classification.requiresComputerTools, "Quoted instruction explanation must NOT require computer tools")
        XCTAssertFalse(c7Route.classification.requiresVision)
        XCTAssertNotEqual(c7Route.classification.category, .computerTask)
        
        // Case 8: Executable intent
        let c8Prompt = "Click the Submit button in the active window."
        let c8Route = try await router.route(prompt: c8Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertTrue(c8Route.classification.requiresComputerTools, "Executable UI click must set requires_computer_tools")
        XCTAssertTrue(c8Route.classification.requiresVision, "Executable UI click must set requires_vision")
        XCTAssertEqual(c8Route.classification.category, .computerTask)
        
        // Case 9: Simple email
        let c9Prompt = "Can you write a short friendly email thanking Alice for the coffee yesterday?"
        let c9Route = try await router.route(prompt: c9Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertEqual(c9Route.classification.category, .simpleChat)
        XCTAssertEqual(c9Route.classification.difficulty, .simple)
        XCTAssertEqual(c9Route.selectedModel.tier, .cheapFast)
        
        // Case 10: Concurrent debugging
        let c10Prompt = "Debug this concurrent deadlock between two threads accessing mutex A and B in reverse order with thread dumps."
        let c10Route = try await router.route(prompt: c10Prompt, hasScreenImage: false, connectedModels: connectedModels)
        XCTAssertEqual(c10Route.classification.difficulty, .complex)
        XCTAssertEqual(c10Route.selectedModel.tier, .frontierReasoning)
    }
}

// MARK: - Test Helpers

final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
    let type: ProviderType
    var isConfigured: Bool
    var isConnected: Bool
    var statusDescription: String
    var discoveredModels: [ModelInfo]
    var errorToThrowOnValidation: Error?
    var completionHandler: ((String) async throws -> String)?
    var cancelGenerationCalled: Bool = false
    var disconnectCalled: Bool = false
    
    init(
        type: ProviderType = .openai,
        isConfigured: Bool = true,
        isConnected: Bool = false,
        statusDescription: String = "Test",
        discoveredModels: [ModelInfo] = [],
        errorToThrowOnValidation: Error? = nil
    ) {
        self.type = type
        self.isConfigured = isConfigured
        self.isConnected = isConnected
        self.statusDescription = statusDescription
        self.discoveredModels = discoveredModels
        self.errorToThrowOnValidation = errorToThrowOnValidation
    }
    
    func validateAndDiscoverModels() async throws -> [ModelInfo] {
        if let error = errorToThrowOnValidation {
            throw error
        }
        return discoveredModels
    }
    
    func generateCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String {
        if let handler = completionHandler {
            return try await handler(prompt)
        }
        return "fake completion"
    }
    
    func cancelGeneration() async {
        cancelGenerationCalled = true
    }
    
    func disconnect() {
        disconnectCalled = true
        isConfigured = false
        isConnected = false
        discoveredModels = []
    }
}
