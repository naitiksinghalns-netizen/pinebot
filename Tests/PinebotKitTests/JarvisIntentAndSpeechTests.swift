import XCTest
import AppKit
import AVFoundation
@testable import PinebotKit

// MARK: - Mocks for Testing

final class MockMediaAutomationAdapter: MediaAutomationAdapter, @unchecked Sendable {
    var supportedBundleId: String = "com.apple.Music"
    var playStateToReturn: MediaPlaybackState = .playing
    var playTrackNameToReturn: String? = nil
    var pauseStateToReturn: MediaPlaybackState = .paused
    var resumeStateToReturn: MediaPlaybackState = .playing
    var resumeTrackNameToReturn: String? = nil
    var toggleStateToReturn: MediaPlaybackState = .playing
    var nextTrackStateToReturn: MediaPlaybackState = .playing
    var nextTrackNameToReturn: String? = "Test Song"
    var prevTrackStateToReturn: MediaPlaybackState = .playing
    var prevTrackNameToReturn: String? = "Previous Song"
    var shouldThrowCode: Int? = nil
    
    var lastCalledMethod: String?
    var lastBundleId: String?
    var lastQuery: String?
    var callCount: Int = 0
    
    func play(appBundleId: String, query: String?) async throws -> (state: MediaPlaybackState, trackName: String?) {
        callCount += 1
        lastCalledMethod = "play"
        lastBundleId = appBundleId
        lastQuery = query
        if let code = shouldThrowCode {
            throw NSError(domain: "PinebotAppleMusic", code: code, userInfo: [NSLocalizedDescriptionKey: "Apple Events permission required for Music."])
        }
        return (playStateToReturn, playTrackNameToReturn)
    }
    
    func pause(appBundleId: String) async throws -> MediaPlaybackState {
        callCount += 1
        lastCalledMethod = "pause"
        lastBundleId = appBundleId
        if let code = shouldThrowCode {
            throw NSError(domain: "PinebotAppleMusic", code: code, userInfo: [NSLocalizedDescriptionKey: "Apple Events permission required for Music."])
        }
        return pauseStateToReturn
    }
    
    func resume(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        callCount += 1
        lastCalledMethod = "resume"
        lastBundleId = appBundleId
        return (resumeStateToReturn, resumeTrackNameToReturn)
    }
    
    func togglePlayPause(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        callCount += 1
        lastCalledMethod = "togglePlayPause"
        lastBundleId = appBundleId
        return (toggleStateToReturn, playTrackNameToReturn)
    }
    
    func nextTrack(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        callCount += 1
        lastCalledMethod = "nextTrack"
        lastBundleId = appBundleId
        if let code = shouldThrowCode {
            throw NSError(domain: "PinebotAppleMusic", code: code, userInfo: [NSLocalizedDescriptionKey: "Apple Events or track error."])
        }
        return (nextTrackStateToReturn, nextTrackNameToReturn)
    }
    
    func previousTrack(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        callCount += 1
        lastCalledMethod = "previousTrack"
        lastBundleId = appBundleId
        if let code = shouldThrowCode {
            throw NSError(domain: "PinebotAppleMusic", code: code, userInfo: [NSLocalizedDescriptionKey: "Apple Events or track error."])
        }
        return (prevTrackStateToReturn, prevTrackNameToReturn)
    }
    
    func currentPlaybackState(appBundleId: String) async throws -> MediaPlaybackState {
        return playStateToReturn
    }
}

final class MockAppLauncherAdapter: AppLauncherAdapter, @unchecked Sendable {
    var installedApps: [String: (bundleId: String, localizedName: String)] = [
        "safari": ("com.apple.Safari", "Safari"),
        "calculator": ("com.apple.calculator", "Calculator"),
        "music": ("com.apple.Music", "Apple Music")
    ]
    var launchResult: Bool = true
    var lastLaunchedBundleId: String?
    
    func launchApp(bundleId: String) async throws -> Bool {
        lastLaunchedBundleId = bundleId
        return launchResult
    }
    
    func findApp(named: String) -> (bundleId: String, localizedName: String)? {
        return installedApps[named.lowercased()]
    }
    
    func isAppInstalled(bundleId: String) -> Bool {
        return installedApps.values.contains { $0.bundleId == bundleId }
    }
}

final class MockSpeechSynthesizer: NSObject, SpeechSynthesizerProtocol, @unchecked Sendable {
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking: Bool = false
    var lastSpokenUtterance: AVSpeechUtterance?
    var stopSpeakingCalled: Bool = false
    
    func speak(_ utterance: AVSpeechUtterance) {
        isSpeaking = true
        lastSpokenUtterance = utterance
    }
    
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        isSpeaking = false
        stopSpeakingCalled = true
        return true
    }
}

// MARK: - Test Suite

final class JarvisIntentAndSpeechTests: XCTestCase {
    
    // MARK: 1. Intent Classification & Polite Requests
    
    func testIntentClassificationDistinguishesQuestionsFromActions() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        // Questions: must never enter local actions
        let q1 = classifier.classifyIntent(prompt: "how do I play music")
        XCTAssertEqual(q1, .question(prompt: "how do I play music"))
        
        let q2 = classifier.classifyIntent(prompt: "how can I play music in Apple Music")
        XCTAssertEqual(q2, .question(prompt: "how can I play music in Apple Music"))
        
        let q3 = classifier.classifyIntent(prompt: "explain how to play music?")
        XCTAssertEqual(q3, .question(prompt: "explain how to play music?"))
        
        // Imperative actions: must enter local capability
        let a1 = classifier.classifyIntent(prompt: "play music in Apple Music")
        XCTAssertEqual(a1, .localAction(.media(.play(query: nil, bundleId: "com.apple.Music"))))
        
        let a2 = classifier.classifyIntent(prompt: "play some jazz in Apple Music")
        XCTAssertEqual(a2, .localAction(.media(.play(query: "jazz", bundleId: "com.apple.Music"))))
        
        let a3 = classifier.classifyIntent(prompt: "pause")
        XCTAssertEqual(a3, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
        
        let a4 = classifier.classifyIntent(prompt: "resume")
        XCTAssertEqual(a4, .localAction(.media(.resume(bundleId: "com.apple.Music"))))
        
        let a5 = classifier.classifyIntent(prompt: "open Safari")
        XCTAssertEqual(a5, .localAction(.launchApp(bundleId: "com.apple.Safari", appName: "Safari")))
        
        // Missing app: asks for clarification
        let a6 = classifier.classifyIntent(prompt: "open NonexistentAppXYZ")
        if case .clarification(let prompt, _, _) = a6 {
            XCTAssertEqual(prompt, "open NonexistentAppXYZ")
        } else {
            XCTFail("Expected .clarification for uninstalled app, got \(a6)")
        }
    }
    
    func testPoliteRequestsNormalizeToActions() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        let p1 = classifier.classifyIntent(prompt: "please play music in Apple Music")
        XCTAssertEqual(p1, .localAction(.media(.play(query: nil, bundleId: "com.apple.Music"))))
        
        let p2 = classifier.classifyIntent(prompt: "can you play music in Apple Music")
        XCTAssertEqual(p2, .localAction(.media(.play(query: nil, bundleId: "com.apple.Music"))))
        
        let p3 = classifier.classifyIntent(prompt: "could you pause the music, please")
        XCTAssertEqual(p3, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
        
        let p4 = classifier.classifyIntent(prompt: "can you please open Safari")
        XCTAssertEqual(p4, .localAction(.launchApp(bundleId: "com.apple.Safari", appName: "Safari")))
    }
    
    // MARK: 2. Non-Media Control & Bare Cancellation Separation
    
    func testNonMediaPauseAndStopTasksRouteToDesktopAction() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        let nm1 = classifier.classifyIntent(prompt: "pause downloads")
        XCTAssertEqual(nm1, .desktopAction(goal: "pause downloads"))
        
        let nm2 = classifier.classifyIntent(prompt: "stop downloads")
        XCTAssertEqual(nm2, .desktopAction(goal: "stop downloads"))
        
        let nm3 = classifier.classifyIntent(prompt: "stop server")
        XCTAssertEqual(nm3, .desktopAction(goal: "stop server"))
    }
    
    func testBareCancelVsMediaStopSeparation() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        // Bare cancellation
        XCTAssertEqual(classifier.classifyIntent(prompt: "stop"), .cancel)
        XCTAssertEqual(classifier.classifyIntent(prompt: "quiet"), .cancel)
        XCTAssertEqual(classifier.classifyIntent(prompt: "stop please"), .cancel)
        
        // Media stop -> routes to media pause
        let ms1 = classifier.classifyIntent(prompt: "stop music")
        XCTAssertEqual(ms1, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
        
        let ms2 = classifier.classifyIntent(prompt: "stop playing")
        XCTAssertEqual(ms2, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
    }
    
    // MARK: 3. Target App Routing & No Silent Redirection
    
    func testUnsupportedMediaTargetsNeverSilentlyRedirectToMusic() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        // YouTube: web/browser target -> desktop action
        let yt = classifier.classifyIntent(prompt: "play jazz on YouTube")
        XCTAssertEqual(yt, .desktopAction(goal: "play jazz on YouTube"))
        
        // Tidal: unsupported local media app -> desktop action
        let tidal = classifier.classifyIntent(prompt: "play jazz on Tidal")
        XCTAssertEqual(tidal, .desktopAction(goal: "play jazz on Tidal"))
        
        // Spotify (not installed): clarification offering Apple Music
        let spot = classifier.classifyIntent(prompt: "play music on Spotify")
        if case .clarification(let prompt, let suggested, _) = spot {
            XCTAssertEqual(prompt, "play music on Spotify")
            XCTAssertTrue(suggested.contains("Spotify is not installed"))
            XCTAssertTrue(suggested.contains("Apple Music instead"))
        } else {
            XCTFail("Expected clarification for missing Spotify, got \(spot)")
        }
        
        // AppleMusicAutomationAdapter rejects unsupported bundle IDs
        let appleMusicAdapter = AppleMusicAutomationAdapter()
        XCTAssertEqual(appleMusicAdapter.supportedBundleId, "com.apple.Music")
    }
    
    // MARK: 4. Readback Verification & Truthful Reporting
    
    func testMediaActionReadbackVerificationSaysPlayingOnlyWhenObserved() async {
        let mockMedia = MockMediaAutomationAdapter()
        let mockLauncher = MockAppLauncherAdapter()
        let registry = LocalCapabilityRegistry(mediaAdapter: mockMedia, appLauncher: mockLauncher)
        
        // Case 1: Real playing observed -> says "Playing"
        mockMedia.playStateToReturn = .playing
        mockMedia.playTrackNameToReturn = "Take Five"
        let res1 = await registry.executeMediaAction(.play(query: "jazz", bundleId: "com.apple.Music"))
        if case .completed(let spoken, let detail) = res1 {
            XCTAssertTrue(spoken.contains("Playing Take Five in Apple Music."), "Must report verified track name: \(spoken)")
            XCTAssertTrue(detail?.contains("Take Five") == true)
        } else {
            XCTFail("Expected .completed, got \(res1)")
        }
        
        // Case 2: Readback reports paused -> must report failure, NEVER claim completed/playing!
        mockMedia.playStateToReturn = .paused
        mockMedia.playTrackNameToReturn = nil
        let res2 = await registry.executeMediaAction(.play(query: nil, bundleId: "com.apple.Music"))
        if case .failed(let spoken, _) = res2 {
            XCTAssertFalse(spoken.contains("Playing"), "Must not claim 'Playing' when readback state is paused: \(spoken)")
            XCTAssertTrue(spoken.contains("paused"), "Must accurately report paused state: \(spoken)")
        } else {
            XCTFail("Expected .failed when player remains paused, got \(res2)")
        }
        
        // Case 3: Toggle resulting in stopped cannot claim Paused
        mockMedia.toggleStateToReturn = .stopped
        let res3 = await registry.executeMediaAction(.togglePlayPause(bundleId: "com.apple.Music"))
        if case .failed(let spoken, _) = res3 {
            XCTAssertFalse(spoken.contains("Paused"), "Stopped state must not claim Paused: \(spoken)")
        } else {
            XCTFail("Expected .failed when toggled to stopped, got \(res3)")
        }
        
        // Case 4: Next track identity readback
        mockMedia.nextTrackStateToReturn = .playing
        mockMedia.nextTrackNameToReturn = "So What"
        let res4 = await registry.executeMediaAction(.nextTrack(bundleId: "com.apple.Music"))
        if case .completed(let spoken, _) = res4 {
            XCTAssertEqual(spoken, "Skipped to So What.")
        } else {
            XCTFail("Expected .completed for next track, got \(res4)")
        }
        
        // Case 5: Next track identity missing -> report failure
        mockMedia.nextTrackNameToReturn = nil
        let res5 = await registry.executeMediaAction(.nextTrack(bundleId: "com.apple.Music"))
        if case .failed(let spoken, _) = res5 {
            XCTAssertTrue(spoken.contains("Could not skip track"))
        } else {
            XCTFail("Expected .failed when track identity missing, got \(res5)")
        }
    }
    
    // MARK: 5. App Launcher Readback Loop
    
    func testLauncherReadbackReturnsFalseOnTimeout() async {
        let mockLauncher = MockAppLauncherAdapter()
        mockLauncher.launchResult = false // Simulates timeout
        let registry = LocalCapabilityRegistry(appLauncher: mockLauncher)
        
        let res = await registry.executeAppLaunch(bundleId: "com.apple.Safari", appName: "Safari")
        if case .failed(let spoken, let detail) = res {
            XCTAssertTrue(spoken.contains("Could not open Safari"))
            XCTAssertTrue(detail?.contains("timed out") == true)
        } else {
            XCTFail("Expected .failed on launcher timeout, got \(res)")
        }
    }
    
    // MARK: 6. Pending Clarification Followup Resolution
    
    func testPendingClarificationFollowupResolution() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        // Context with pending action
        let pending = LocalActionCommand.media(.play(query: "jazz", bundleId: "com.apple.Music"))
        let context = IntentResolutionContext(pendingAction: pending)
        
        // Affirmative replies resolve pending action
        XCTAssertEqual(classifier.classifyIntent(prompt: "yes", context: context), .localAction(pending))
        XCTAssertEqual(classifier.classifyIntent(prompt: "sure", context: context), .localAction(pending))
        XCTAssertEqual(classifier.classifyIntent(prompt: "use Apple Music", context: context), .localAction(pending))
        XCTAssertEqual(classifier.classifyIntent(prompt: "do it", context: context), .localAction(pending))
        
        // Negative replies cancel
        XCTAssertEqual(classifier.classifyIntent(prompt: "no", context: context), .cancel)
        XCTAssertEqual(classifier.classifyIntent(prompt: "nevermind", context: context), .cancel)
    }
    
    // MARK: 7. App Context Retention for Follow-up Commands
    
    func testAppContextRetentionForFollowUpCommands() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        let context = IntentResolutionContext(lastTargetAppBundleId: "com.apple.Music", lastTargetAppName: "Apple Music")
        
        let followUp1 = classifier.classifyIntent(prompt: "pause", context: context)
        XCTAssertEqual(followUp1, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
        
        let followUp2 = classifier.classifyIntent(prompt: "resume", context: context)
        XCTAssertEqual(followUp2, .localAction(.media(.resume(bundleId: "com.apple.Music"))))
        
        let followUp3 = classifier.classifyIntent(prompt: "next track", context: context)
        XCTAssertEqual(followUp3, .localAction(.media(.nextTrack(bundleId: "com.apple.Music"))))
    }
    
    // MARK: 8. Stale TTS Callback Guards
    
    @MainActor
    func testStaleTTSCallbackDoesNotClearNewerSpeech() async {
        let mockSynth = MockSpeechSynthesizer()
        let speech = SpeechManager(synthesizer: mockSynth)
        
        speech.speak(text: "First prompt", requestId: "req-1")
        let firstUtteranceId = speech.presentationState.utteranceId
        guard let utterance1 = mockSynth.lastSpokenUtterance else {
            XCTFail("Missing first spoken utterance")
            return
        }
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertEqual(speech.presentationState.phase, .speaking)
        
        speech.speak(text: "Second prompt", requestId: "req-2")
        let secondUtteranceId = speech.presentationState.utteranceId
        guard let utterance2 = mockSynth.lastSpokenUtterance else {
            XCTFail("Missing second spoken utterance")
            return
        }
        XCTAssertNotEqual(firstUtteranceId, secondUtteranceId)
        XCTAssertNotEqual(ObjectIdentifier(utterance1), ObjectIdentifier(utterance2))
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertEqual(speech.presentationState.phase, .speaking)
        XCTAssertEqual(speech.presentationState.text, "Second prompt")
        
        // Simulate stale didFinish from utterance 1
        speech.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance1)
        await Task.yield()
        
        // Utterance 2 must remain speaking because utterance1's ObjectIdentifier does not match activeUtteranceIdentifier
        XCTAssertTrue(speech.isSpeaking, "Stale callback from old utterance must NOT reset isSpeaking")
        XCTAssertEqual(speech.presentationState.utteranceId, secondUtteranceId)
        XCTAssertEqual(speech.presentationState.phase, .speaking)
        
        // Now deliver matching didFinish for utterance 2
        speech.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance2)
        await Task.yield()
        
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(speech.presentationState.phase, .finished)
        XCTAssertEqual(speech.presentationState.utteranceId, secondUtteranceId)
        
        // Stop invalidates identity before synthesizer.stopSpeaking()
        speech.speak(text: "Third prompt", requestId: "req-3")
        guard let utterance3 = mockSynth.lastSpokenUtterance else {
            XCTFail("Missing third spoken utterance")
            return
        }
        speech.stopSpeaking()
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(speech.presentationState.phase, .cancelled)
        
        // Delayed callback for utterance3 after stop must be ignored
        speech.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance3)
        await Task.yield()
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(speech.presentationState.phase, .cancelled)
    }
    
    // MARK: 9. Response Policy Text Cleaning & Jarvis Brevity
    
    func testResponsePolicyTextCleaning() {
        let raw = """
        ### Music Player
        Sure! Here is your song: [Song Title](https://music.apple.com/song).
        ```
        let code = 123
        ```
        Enjoy the music! *(Note: escalated via Claude 3.5 Sonnet)*
        """
        
        let cleaned = ResponsePolicy.spokenCleaned(raw)
        XCTAssertFalse(cleaned.contains("###"))
        XCTAssertFalse(cleaned.contains("Sure!"))
        XCTAssertFalse(cleaned.contains("https://"))
        XCTAssertFalse(cleaned.contains("```"))
        XCTAssertFalse(cleaned.contains("Note:"))
        XCTAssertTrue(cleaned.contains("Song Title"))
        XCTAssertTrue(cleaned.contains("Enjoy the music!"))
        
        let longRaw = "Sentence one. Sentence two! Sentence three? Sentence four."
        let bounded = ResponsePolicy.spokenCleaned(longRaw)
        XCTAssertEqual(bounded, "Sentence one. Sentence two!")
    }
    
    func testResponsePolicyWordCountLimits() {
        // Natural clause boundary shortening when delimiter exists
        let withClause = "This is the primary sentence clause, and this secondary clause exceeds the eighteen word limit by continuing on and on with extra words."
        let cleaned1 = ResponsePolicy.spokenCleaned(withClause)
        XCTAssertEqual(cleaned1, "This is the primary sentence clause.")
        
        // Whole brief sentence preserved without mid-sentence word severing
        let verbose1 = "This is a single very verbose sentence that definitely contains more than eighteen individual words to verify that spoken policy preserves whole grammar."
        let cleaned2 = ResponsePolicy.spokenCleaned(verbose1)
        XCTAssertEqual(cleaned2, verbose1, "Whole brief sentence must be preserved rather than severed mid-clause")
        
        // Multi-sentence: takes first two brief sentences
        let verbose2 = "This is the first sentence. This is the second sentence. This third sentence must be omitted."
        let cleaned3 = ResponsePolicy.spokenCleaned(verbose2)
        XCTAssertEqual(cleaned3, "This is the first sentence. This is the second sentence.")
    }
    
    // MARK: 10. Wired Assistant Local Command Execution & Followup
    
    @MainActor
    func testWiredAssistantLocalCommandExecutionAndFollowup() async throws {
        let isolatedPM = ProviderManager()
        var aiCallCount = 0
        let fakeModel = ModelInfo(id: "fake-chat", displayName: "Fake Chat Model", provider: .openai, tier: .balanced)
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [fakeModel]
        )
        fakeProvider.completionHandler = { (prompt: String) in
            aiCallCount += 1
            return "Should not be called for local commands!"
        }
        isolatedPM.setProvider(fakeProvider, for: .openai)
        isolatedPM.setState(.connected(accountSummary: "Fake Account", models: [fakeModel]), for: .openai)
        isolatedPM.refreshConnectedModels()
        
        let mockMedia = MockMediaAutomationAdapter()
        mockMedia.playStateToReturn = .playing
        mockMedia.playTrackNameToReturn = "Giant Steps"
        let mockLauncher = MockAppLauncherAdapter()
        let localRegistry = LocalCapabilityRegistry(mediaAdapter: mockMedia, appLauncher: mockLauncher)
        let classifier = RequestIntentClassifier(appLauncher: mockLauncher)
        
        let assistant = PinebotAssistant(
            providerManager: isolatedPM,
            speech: SpeechManager(synthesizer: MockSpeechSynthesizer()),
            localRegistry: localRegistry,
            intentClassifier: classifier,
            startHotkeys: false
        )
        assistant.clearMessages()
        
        // Execute polite command: "can you please play music in Apple Music"
        await assistant.processUserPrompt("can you please play music in Apple Music")
        
        XCTAssertEqual(mockMedia.callCount, 1)
        XCTAssertEqual(mockMedia.lastCalledMethod, "play")
        XCTAssertEqual(aiCallCount, 0, "Zero AI provider calls for local media command")
        
        let replies = assistant.messages.filter { $0.sender == .pinebot }
        XCTAssertFalse(replies.isEmpty)
        let lastReply = replies.last?.text ?? ""
        XCTAssertTrue(lastReply.contains("Giant Steps") || lastReply.contains("Playing"), "Reply must confirm verified track: \(lastReply)")
        
        // Next turn follow-up: "pause"
        await assistant.processUserPrompt("pause")
        XCTAssertEqual(mockMedia.callCount, 2)
        XCTAssertEqual(mockMedia.lastCalledMethod, "pause")
        XCTAssertEqual(mockMedia.lastBundleId, "com.apple.Music")
        XCTAssertEqual(aiCallCount, 0, "Zero AI provider calls for local followup pause command")
        
        // Next turn app launch: "open Safari"
        await assistant.processUserPrompt("open Safari")
        XCTAssertEqual(mockLauncher.lastLaunchedBundleId, "com.apple.Safari")
        XCTAssertEqual(aiCallCount, 0, "Zero AI provider calls for local app launch")
        
        let launchReplies = assistant.messages.filter { $0.sender == .pinebot }
        let lastLaunchReply = launchReplies.last?.text ?? ""
        XCTAssertEqual(lastLaunchReply, "Opened Safari.", "Chat bubble must display natural spokenSummary, not technical detail")
        XCTAssertFalse(lastLaunchReply.contains("com.apple.Safari"), "Chat bubble must not contain bundle identifier")
    }
    
    // MARK: 11. Explicit Question Hard No-Action Contract
    
    @MainActor
    func testExplicitQuestionNeverExecutesTools() async throws {
        let isolatedPM = ProviderManager()
        let fakeModel = ModelInfo(
            id: "fake-chat",
            displayName: "Fake Chat Model",
            provider: .openai,
            tier: .frontierReasoning,
            supportsVision: true,
            supportsTools: true,
            supportsComputerPlanning: true
        )
        let fakeProvider = FakeLLMProvider(
            type: .openai,
            isConfigured: true,
            isConnected: true,
            discoveredModels: [fakeModel]
        )
        fakeProvider.completionHandler = { (prompt: String) in
            return "To play music in Apple Music, open the Music app and select a track or press play."
        }
        isolatedPM.setProvider(fakeProvider, for: .openai)
        isolatedPM.setState(.connected(accountSummary: "Fake Account", models: [fakeModel]), for: .openai)
        isolatedPM.refreshConnectedModels()
        
        // Injected classifier intentionally claiming requiresComputerTools = true
        let customClassifier: @Sendable (String, Bool) async -> TaskClassification = { prompt, hasScreen in
            TaskClassification(
                category: .computerTask,
                difficulty: .medium,
                reasoningScore: 0.8,
                requiresVision: false,
                requiresComputerTools: true,
                status: .learned(modelName: "test-model", confidence: 0.98),
                confidence: 0.98
            )
        }
        let router = ModelRouter(customClassifier: customClassifier)
        
        let mockExecutor = MockComputerActionExecutor()
        let taskEngine = ComputerTaskEngine(executor: mockExecutor)
        let mockMedia = MockMediaAutomationAdapter()
        let mockLauncher = MockAppLauncherAdapter()
        let localRegistry = LocalCapabilityRegistry(mediaAdapter: mockMedia, appLauncher: mockLauncher)
        let classifier = RequestIntentClassifier(appLauncher: mockLauncher)
        
        let assistant = PinebotAssistant(
            providerManager: isolatedPM,
            router: router,
            taskEngine: taskEngine,
            speech: SpeechManager(synthesizer: MockSpeechSynthesizer()),
            localRegistry: localRegistry,
            intentClassifier: classifier,
            startHotkeys: false
        )
        assistant.clearMessages()
        
        // "how do I play music in Apple Music" is an informational question -> zero tool calls, zero app launches
        await assistant.processUserPrompt("how do I play music in Apple Music")
        
        let lastMsg = assistant.messages.last
        XCTAssertEqual(lastMsg?.sender, .pinebot)
        XCTAssertTrue(lastMsg?.text.contains("open the Music app") == true)
        XCTAssertTrue(mockExecutor.executedActions.isEmpty, "Explicit questions must NEVER execute computer tools even if classifier claims requiresComputerTools")
        XCTAssertEqual(mockMedia.callCount, 0, "Explicit questions must NEVER execute local media automation")
        XCTAssertNil(mockLauncher.lastLaunchedBundleId, "Explicit questions must NEVER launch apps")
    }
    
    // MARK: 12. Caption Geometry and Height Pre-measurement
    
    @MainActor
    func testCaptionGeometryAndHeightPreMeasurement() {
        let shortText = "Playing Take Five."
        let shortHeight = CaptionPanelController.measureCaptionHeight(for: shortText)
        XCTAssertGreaterThanOrEqual(shortHeight, 76)
        
        let longText = "This is a much longer caption designed to test multi-line text measurement with word wrapping and transparent gutter bounds to avoid layout clipping."
        let longHeight = CaptionPanelController.measureCaptionHeight(for: longText)
        XCTAssertGreaterThan(longHeight, shortHeight, "Longer wrapped text must produce greater height than single line")
        
        let controller = CaptionPanelController.shared
        XCTAssertEqual(controller.panelFrame.width, 332, "Caption panel width must be 332pt (300pt card + 16pt gutter on each side)")
        XCTAssertEqual(controller.panel.title, "Pinebot Speech")
        XCTAssertEqual(controller.panel.accessibilityTitle(), "Pinebot Speech")
        XCTAssertEqual(controller.panel.accessibilityLabel(), "Pinebot Speech")
        XCTAssertEqual(controller.panel.accessibilityRole(), .window)
    }
    
    // MARK: 13. ModelRouter Tool Forcing for Desktop Actions
    
    func testModelRouterForceRequiresTools() throws {
        let router = ModelRouter.shared
        let models = [
            ModelInfo(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: .openai, tier: .cheapFast, supportsVision: true, supportsComputerPlanning: true),
            ModelInfo(id: "gpt-4o", displayName: "GPT-4o", provider: .openai, tier: .frontierReasoning, supportsVision: true, supportsComputerPlanning: true)
        ]
        
        let decision = try router.route(
            prompt: "Open settings and change brightness",
            connectedModels: models,
            forceRequiresTools: true
        )
        
        XCTAssertTrue(decision.classification.requiresComputerTools, "forceRequiresTools must guarantee requiresComputerTools is true")
        XCTAssertTrue(decision.selectedModel.supportsComputerPlanning)
    }
    
    // MARK: 14. Negative Fixtures & Target Ordering
    
    func testQuestionWithYouTubeTargetRoutesToQuestionNotDesktopAction() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        let q = classifier.classifyIntent(prompt: "how do I play music on YouTube")
        XCTAssertEqual(q, .question(prompt: "how do I play music on YouTube"), "Questions with YouTube target must route to .question, never .desktopAction")
    }
    
    func testTargetedPauseAndStopCommands() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        let p1 = classifier.classifyIntent(prompt: "pause music in Apple Music")
        XCTAssertEqual(p1, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
        
        let p2 = classifier.classifyIntent(prompt: "stop music on Apple Music")
        XCTAssertEqual(p2, .localAction(.media(.pause(bundleId: "com.apple.Music"))))
    }
    
    func testSpotifyFallbackPreservesQueryInPendingAction() {
        let launcher = MockAppLauncherAdapter()
        let classifier = RequestIntentClassifier(appLauncher: launcher)
        
        let spot = classifier.classifyIntent(prompt: "play jazz on Spotify")
        if case .clarification(let prompt, let suggested, let pendingAction) = spot {
            XCTAssertEqual(prompt, "play jazz on Spotify")
            XCTAssertTrue(suggested.contains("Spotify is not installed"))
            XCTAssertEqual(pendingAction, .media(.play(query: "jazz", bundleId: "com.apple.Music")), "Must preserve query 'jazz' in pendingAction")
        } else {
            XCTFail("Expected clarification for Spotify fallback, got \(spot)")
        }
    }
    
    func testAppleMusicRemainedPausedAfterQueryPlayFailsTruthfully() async {
        let mockMedia = MockMediaAutomationAdapter()
        let mockLauncher = MockAppLauncherAdapter()
        let registry = LocalCapabilityRegistry(mediaAdapter: mockMedia, appLauncher: mockLauncher)
        
        // Simulates query play where player readback reports paused
        mockMedia.playStateToReturn = .paused
        mockMedia.playTrackNameToReturn = nil
        let res = await registry.executeMediaAction(.play(query: "jazz", bundleId: "com.apple.Music"))
        if case .failed(let spoken, let detail) = res {
            XCTAssertFalse(spoken.contains("Playing"), "Must not claim playing when player is paused: \(spoken)")
            XCTAssertTrue(spoken.contains("paused"), "Must report paused: \(spoken)")
            XCTAssertTrue(detail?.contains("paused") == true)
        } else {
            XCTFail("Expected .failed when query play remains paused, got \(res)")
        }
    }
    
    func testUnchangedNextTrackFailsTruthfully() async {
        let mockMedia = MockMediaAutomationAdapter()
        let mockLauncher = MockAppLauncherAdapter()
        let registry = LocalCapabilityRegistry(mediaAdapter: mockMedia, appLauncher: mockLauncher)
        
        // When next track remains unchanged (adapter throws code 409)
        mockMedia.shouldThrowCode = 409
        let res = await registry.executeMediaAction(.nextTrack(bundleId: "com.apple.Music"))
        if case .failed(let spoken, let detail) = res {
            XCTAssertFalse(spoken.contains("Skipped"), "Must not claim skipped when track is unchanged: \(spoken)")
            XCTAssertTrue(spoken.contains("Could not skip track"))
            XCTAssertEqual(detail, "Track remained unchanged.")
        } else {
            XCTFail("Expected .failed when next track is unchanged, got \(res)")
        }
    }
    
    // MARK: 15. Caption Panel Event Gating & Speech Policy
    
    @MainActor
    func testCaptionPanelStaleQueuedEventsAndAutoDismissGating() async {
        let controller = CaptionPanelController.shared
        
        // Live speech manager is idle
        SpeechManager.shared.stopSpeaking()
        
        // 1. Stale speaking event arrives from an old cancelled utterance while live is idle
        let staleUtteranceId = UUID()
        let staleSpeaking = SpeechPresentationState(
            requestId: "old-req",
            utteranceId: staleUtteranceId,
            text: "Stale spoken text that arrived late",
            phase: .speaking
        )
        controller.handlePresentationStateChange(staleSpeaking)
        
        // Gating against live SpeechManager state ensures stale event is discarded
        XCTAssertFalse(controller.isVisible, "Stale queued speaking event must be dropped and not make caption visible")
        
        // 2. Stale finished event arrives
        let staleFinished = SpeechPresentationState(
            requestId: "old-req",
            utteranceId: staleUtteranceId,
            text: "Stale finished text",
            phase: .finished
        )
        controller.handlePresentationStateChange(staleFinished)
        XCTAssertFalse(controller.isVisible, "Stale finished event must be dropped")
        
        // 3. Now start a genuine new utterance
        SpeechManager.shared.speak(text: "Active caption utterance", requestId: "req-active")
        let activeState = SpeechManager.shared.presentationState
        controller.handlePresentationStateChange(activeState)
        XCTAssertTrue(controller.isVisible, "Genuine active utterance must make caption visible")
        XCTAssertEqual(controller.currentUtteranceId, activeState.utteranceId)
        
        // 4. Stale cancelled event from old utterance arrives via delayed publication
        let staleCancelled = SpeechPresentationState(
            requestId: "old-req",
            utteranceId: staleUtteranceId,
            text: "Old text",
            phase: .cancelled
        )
        controller.handlePresentationStateChange(staleCancelled)
        XCTAssertTrue(controller.isVisible, "Stale cancelled event from an earlier utterance must NOT hide active caption!")
        XCTAssertEqual(controller.currentUtteranceId, activeState.utteranceId)
        
        // 5. Stale idle event arrives via delayed publication
        let staleIdle = SpeechPresentationState(
            requestId: "",
            utteranceId: UUID(),
            text: "",
            phase: .idle
        )
        controller.handlePresentationStateChange(staleIdle)
        XCTAssertTrue(controller.isVisible, "Stale idle event must NOT hide active caption while speech is active!")
        XCTAssertEqual(controller.currentUtteranceId, activeState.utteranceId)
        
        // 6. Genuine cancel arrives for the active utterance
        SpeechManager.shared.stopSpeaking()
        let liveCancelledState = SpeechManager.shared.presentationState
        controller.handlePresentationStateChange(liveCancelledState)
        XCTAssertFalse(controller.isVisible, "Legitimate cancel matching active utterance must hide caption")
        XCTAssertNil(controller.currentUtteranceId)
    }
    
    func testPreviousTrackPlaybackStateWording() async {
        let mockMedia = MockMediaAutomationAdapter()
        let mockLauncher = MockAppLauncherAdapter()
        let registry = LocalCapabilityRegistry(mediaAdapter: mockMedia, appLauncher: mockLauncher)
        
        // Case 1: When player state is .playing -> says "Playing"
        mockMedia.prevTrackStateToReturn = .playing
        mockMedia.prevTrackNameToReturn = "Take Five"
        let resPlaying = await registry.executeMediaAction(.previousTrack(bundleId: "com.apple.Music"))
        if case .completed(let spoken, let detail) = resPlaying {
            XCTAssertTrue(spoken.contains("Playing Take Five"), "Must say 'Playing' when player state is playing: \(spoken)")
            XCTAssertEqual(detail, "Playing previous track: 'Take Five'.")
        } else {
            XCTFail("Expected .completed, got \(resPlaying)")
        }
        
        // Case 2: When player state is .paused -> says "Selected"
        mockMedia.prevTrackStateToReturn = .paused
        mockMedia.prevTrackNameToReturn = "Take Five"
        let resPaused = await registry.executeMediaAction(.previousTrack(bundleId: "com.apple.Music"))
        if case .completed(let spoken, let detail) = resPaused {
            XCTAssertFalse(spoken.contains("Playing"), "Must NOT say 'Playing' when player state is paused: \(spoken)")
            XCTAssertTrue(spoken.contains("Selected Take Five"), "Must say 'Selected' when player state is paused: \(spoken)")
            XCTAssertEqual(detail, "Selected previous track: 'Take Five' (paused).")
        } else {
            XCTFail("Expected .completed, got \(resPaused)")
        }
    }
    
    func testWholeSentenceSpeechCleaningPreservesDecimals() {
        // Preserves decimal numbers like 3.14 without slicing or splitting
        let raw = "The value of pi is approximately 3.14. It is widely used in mathematics."
        let cleaned = ResponsePolicy.spokenCleaned(raw)
        XCTAssertTrue(cleaned.contains("3.14"), "Spoken cleaning must preserve decimal numbers like 3.14: \(cleaned)")
        
        // Preserves whole brief sentences without severing words mid-clause
        let sentence = "Pinebot is ready to assist you with all desktop automation tasks across your applications."
        let cleanedSentence = ResponsePolicy.spokenCleaned(sentence)
        XCTAssertEqual(cleanedSentence, "Pinebot is ready to assist you with all desktop automation tasks across your applications.", "Must preserve whole brief sentence rather than severing words mid-sentence")
    }
}
