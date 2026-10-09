import AppKit
import SwiftUI
import Combine
import Speech
import AVFoundation

/// A chat message in the Pinebot session.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sender: MessageSender
    public let text: String
    public let timestamp: Date
    public let routeDecision: RouteDecision?
    public let attachedImage: NSImage?
    
    public enum MessageSender: String, Sendable {
        case user
        case pinebot
        case system
    }
    
    public init(
        id: UUID = UUID(),
        sender: MessageSender,
        text: String,
        timestamp: Date = Date(),
        routeDecision: RouteDecision? = nil,
        attachedImage: NSImage? = nil
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.routeDecision = routeDecision
        self.attachedImage = attachedImage
    }
}

/// Central orchestrator coordinating Pinebot's visual states, conversation, router, and tasks.
@MainActor
public final class PinebotAssistant: ObservableObject {
    public static let shared = PinebotAssistant()
    
    @Published public private(set) var buddyState: BuddyState = .happy
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var isListeningToVoice: Bool = false
    @Published public var attachScreenToNextMessage: Bool = false
    
    private let settingsStore: SettingsStore
    private let providerManager: ProviderManager
    private let router: ModelRouter
    private let taskEngine: ComputerTaskEngine
    private let speech: SpeechManager
    private let hotkeys: ModifierHotkeyMonitor
    private let localRegistry: LocalCapabilityRegistry
    private let intentClassifier: RequestIntentClassifier
    
    private var intentContext: IntentResolutionContext
    private var sleepTimer: AnyCancellable?
    private var lastActivityTime: Date = Date()
    private var activeVoiceSessionId: UUID?
    
    // Request ownership & generation guards
    private var activeProcessingTask: Task<Void, Never>?
    private var activeTeardownTask: Task<Void, Never>?
    private var activeTeardownId: UUID?
    private var activeRequestId: UUID?
    private var activeRequestGeneration: Int = 0
    private var activeProvider: (any LLMProvider)?
    
    public init(
        providerManager: ProviderManager = .shared,
        router: ModelRouter = .shared,
        taskEngine: ComputerTaskEngine = .shared,
        speech: SpeechManager = .shared,
        settingsStore: SettingsStore = .shared,
        localRegistry: LocalCapabilityRegistry = .shared,
        intentClassifier: RequestIntentClassifier = .shared,
        startHotkeys: Bool = true
    ) {
        self.providerManager = providerManager
        self.router = router
        self.taskEngine = taskEngine
        self.speech = speech
        self.settingsStore = settingsStore
        self.localRegistry = localRegistry
        self.intentClassifier = intentClassifier
        self.intentContext = IntentResolutionContext()
        self.hotkeys = .shared
        
        if startHotkeys {
            setupHotkeys()
        }
        resetSleepTimer()
    }
    
    public func clearMessages() {
        messages.removeAll()
    }
    
    /// Stops any in-flight prompt request, cancels provider and task engine, and ensures no late completions mutate state.
    public func stopCurrentProcessing() {
        // Stop audio playback immediately and silence active speech or held caption even when idle
        speech.stopSpeaking()
        
        let hadActive = isProcessing || activeProcessingTask != nil || activeTeardownTask != nil
        guard hadActive else {
            // Ensure repeated Stop when idle does not cancel future tasks or emit redundant stopped messages
            return
        }
        
        let previousProcessingTask = activeProcessingTask
        let previousTeardownTask = activeTeardownTask
        let capturedProvider = activeProvider
        
        // 1. Cancel previous processing task IMMEDIATELY
        previousProcessingTask?.cancel()
        
        activeProcessingTask = nil
        activeProvider = nil
        activeRequestId = nil
        activeRequestGeneration += 1
        
        isProcessing = false
        buddyState = .happy
        
        // Cancel task engine and unblock any waiting tool confirmations
        taskEngine.cancel()
        
        messages.append(ChatMessage(
            sender: .system,
            text: "⏹️ Stopped request."
        ))
        
        let newTeardownId = UUID()
        self.activeTeardownId = newTeardownId
        
        // Own an explicit teardown Task/barrier retaining OLD request and captured selected provider
        activeTeardownTask = Task { @MainActor [weak self, previousProcessingTask, previousTeardownTask, capturedProvider, newTeardownId] in
            // Await any earlier teardown barrier first
            _ = await previousTeardownTask?.value
            
            // Call captured provider.cancelGeneration BEFORE awaiting old task.value
            // so provider continuation cancellation can release it!
            if let provider = capturedProvider {
                await provider.cancelGeneration()
            }
            // If no captured provider, request was in classifier or no request yet;
            // NEVER call cancelAllGenerations and NEVER touch unrelated authentication!
            
            // Await old task completion
            if let task = previousProcessingTask {
                _ = await task.value
            }
            
            // Only clear activeTeardownTask if this specific barrier UUID still matches
            if let self = self, self.activeTeardownId == newTeardownId {
                self.activeTeardownTask = nil
                self.activeTeardownId = nil
            }
        }
    }
    
    public func recordActivity() {
        lastActivityTime = Date()
        if buddyState == .sleeping {
            wakeUp()
        }
        resetSleepTimer()
    }
    
    public func wakeUp() {
        if buddyState == .sleeping {
            buddyState = .happy
        }
    }
    
    public func resetSleepTimer() {
        sleepTimer?.cancel()
        let delay = settingsStore.settings.idleSleepDelay
        sleepTimer = Timer.publish(every: delay, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if !self.isProcessing && !self.isListeningToVoice {
                    self.buddyState = .sleeping
                }
            }
    }
    
    private func setupHotkeys() {
        hotkeys.onFlagsDown = { [weak self] in
            guard let self = self else { return }
            // Immediately stop any active speech when modifier keys are pressed
            self.speech.stopSpeaking()
            self.startVoiceInput()
        }
        
        hotkeys.onFlagsUp = { [weak self] in
            guard let self = self else { return }
            self.finishVoiceInput()
        }
        hotkeys.start()
    }
    
    /// Starts voice interaction, preventing late permission callbacks from initiating recording
    /// after the modifier keys have already been released.
    public func startVoiceInput() {
        recordActivity()
        let sessionId = UUID()
        self.activeVoiceSessionId = sessionId
        isListeningToVoice = true
        buddyState = .thinking
        
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        if speechStatus == .authorized && audioStatus == .authorized {
            // Already authorized: start recording immediately if keys are still held
            guard hotkeys.isCommandOptionHeld, activeVoiceSessionId == sessionId else {
                isListeningToVoice = false
                buddyState = .happy
                return
            }
            
            do {
                try speech.startRecording()
            } catch {
                speech.resetRecording()
                isListeningToVoice = false
                buddyState = .happy
                messages.append(ChatMessage(
                    sender: .system,
                    text: "Could not start audio recording: \(error.localizedDescription)"
                ))
            }
        } else {
            // Need permission: request asynchronously and check key state upon completion
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let granted = await self.speech.requestPermissions()
                
                // CRITICAL CHECK: Did the user release the keys while the permission dialog was open?
                guard self.hotkeys.isCommandOptionHeld,
                      self.isListeningToVoice,
                      self.activeVoiceSessionId == sessionId else {
                    if self.activeVoiceSessionId == sessionId {
                        self.isListeningToVoice = false
                        self.buddyState = .happy
                    }
                    return
                }
                
                if granted {
                    do {
                        try self.speech.startRecording()
                    } catch {
                        self.speech.resetRecording()
                        self.isListeningToVoice = false
                        self.buddyState = .happy
                    }
                } else {
                    self.isListeningToVoice = false
                    self.buddyState = .sad
                    self.messages.append(ChatMessage(
                        sender: .system,
                        text: "Microphone and Speech Recognition permissions are required for voice interaction. Please grant access in System Settings > Privacy & Security, or use typed chat."
                    ))
                }
            }
        }
    }
    
    /// Finishes voice interaction asynchronously on key release without discarding trailing audio.
    public func finishVoiceInput() {
        activeVoiceSessionId = nil
        guard isListeningToVoice else { return }
        isListeningToVoice = false
        
        guard speech.isRecording else {
            speech.resetRecording()
            buddyState = .happy
            return
        }
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let transcribed = await self.speech.finishRecording(timeoutSeconds: 1.2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !transcribed.isEmpty {
                self.submitUserPrompt(transcribed)
            } else {
                self.buddyState = .happy
            }
        }
    }
    
    // MARK: - Prompt Submission & Request Ownership
    
    /// Submits a user prompt request with single task and UUID ownership.
    /// If an active turn is currently running, it is cancelled and teardown awaited before beginning the new turn.
    public func submitUserPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Interrupt any speech output immediately on new input
        speech.stopSpeaking()
        
        let previousTask = activeProcessingTask
        let previousTeardown = activeTeardownTask
        let previousTeardownId = activeTeardownId
        
        // 1. Cancel previous processing task IMMEDIATELY
        previousTask?.cancel()
        activeProcessingTask = nil
        
        let newRequestId = UUID()
        activeRequestId = newRequestId
        activeRequestGeneration += 1
        let thisGeneration = activeRequestGeneration
        
        activeProcessingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Await old request + provider teardown before starting new turn
            if let teardown = previousTeardown {
                _ = await teardown.value
            }
            if let prev = previousTask {
                _ = await prev.value
            }
            
            guard !Task.isCancelled,
                  self.activeRequestGeneration == thisGeneration,
                  self.activeRequestId == newRequestId else {
                return
            }
            
            // Only clear teardown if this barrier UUID matches
            if self.activeTeardownId == previousTeardownId {
                self.activeTeardownTask = nil
                self.activeTeardownId = nil
            }
            
            await self.executePromptRequest(trimmed, requestId: newRequestId, generation: thisGeneration)
        }
    }
    
    /// Processes a user request through the local router, model provider, and task engine.
    /// Sole-owned through submitUserPrompt; awaits the active request task.
    public func processUserPrompt(_ text: String) async {
        submitUserPrompt(text)
        if let task = activeProcessingTask {
            _ = await task.value
        }
    }
    
    private func executePromptRequest(_ trimmed: String, requestId: UUID, generation: Int) async {
        recordActivity()
        
        var screenImage: NSImage? = nil
        if attachScreenToNextMessage {
            screenImage = ScreenCaptureManager.shared.captureMainScreen()
            attachScreenToNextMessage = false
        }
        
        // Append user message
        messages.append(ChatMessage(
            sender: .user,
            text: trimmed,
            attachedImage: screenImage
        ))
        
        isProcessing = true
        buddyState = .thinking
        
        defer {
            if self.activeRequestGeneration == generation {
                self.isProcessing = false
                self.activeProcessingTask = nil
                self.activeRequestId = nil
                self.activeProvider = nil
                if self.buddyState == .thinking || self.buddyState == .working {
                    self.buddyState = .happy
                }
            }
        }
        
        guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
        
        // 1. Classify typed intent before routing
        let intent = intentClassifier.classifyIntent(prompt: trimmed, context: intentContext)
        
        switch intent {
        case .cancel:
            stopCurrentProcessing()
            return
            
        case .localAction(let localCmd):
            // Reset any pending action once an action is triggered
            intentContext.pendingAction = nil
            
            switch localCmd {
            case .launchApp(let bundleId, let appName):
                intentContext.lastTargetAppBundleId = bundleId
                intentContext.lastTargetAppName = appName
                let result = await localRegistry.executeAppLaunch(bundleId: bundleId, appName: appName)
                guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
                await handleLocalActionResult(result, requestId: requestId, prompt: trimmed, generation: generation, screenImage: screenImage)
                return
                
            case .media(let mediaAction):
                switch mediaAction {
                case .play(_, let bundleId), .pause(let bundleId), .resume(let bundleId),
                     .togglePlayPause(let bundleId), .nextTrack(let bundleId), .previousTrack(let bundleId):
                    intentContext.lastTargetAppBundleId = bundleId
                    intentContext.lastTargetAppName = bundleId == "com.apple.Music" ? "Apple Music" : "Music"
                }
                let result = await localRegistry.executeMediaAction(mediaAction)
                guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
                await handleLocalActionResult(result, requestId: requestId, prompt: trimmed, generation: generation, screenImage: screenImage)
                return
            }
            
        case .clarification(_, let suggestedResponse, let pendingAction):
            intentContext.pendingAction = pendingAction
            
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            buddyState = .curious
            messages.append(ChatMessage(
                sender: .pinebot,
                text: suggestedResponse
            ))
            if settingsStore.settings.speechOutputEnabled {
                let cleaned = ResponsePolicy.spokenCleaned(suggestedResponse)
                speech.speak(text: cleaned, requestId: requestId.uuidString)
            }
            return
            
        case .desktopAction(let goal):
            intentContext.pendingAction = nil
            await routeDesktopAction(goal: goal, generation: generation, requestId: requestId, screenImage: screenImage)
            return
            
        case .question(let questionPrompt):
            await handleConversationalQuery(prompt: questionPrompt, requestId: requestId, generation: generation, screenImage: screenImage, forceNoAction: true)
            return
            
        case .conversational(let prompt):
            await handleConversationalQuery(prompt: prompt, requestId: requestId, generation: generation, screenImage: screenImage, forceNoAction: false)
            return
        }
    }
    
    private func handleConversationalQuery(
        prompt: String,
        requestId: UUID,
        generation: Int,
        screenImage: NSImage?,
        forceNoAction: Bool
    ) async {
        // 2. Ensure providers are validated for conversational queries
        providerManager.refreshConnectedModels()
        let connected = providerManager.connectedModels
        
        guard !connected.isEmpty else {
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            buddyState = .sad
            messages.append(ChatMessage(
                sender: .pinebot,
                text: "No models are connected yet! Please open the **Providers** tab to sign in with your Google account (Gemini), connect your ChatGPT Plus/Pro plan, or configure Claude, Ollama, or an API key under Advanced."
            ))
            return
        }
        
        guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
        
        // 3. Route via local learned classifier & deterministic policy (forceRequiresTools: false)
        let routeDecision: RouteDecision
        do {
            routeDecision = try await router.route(
                prompt: prompt,
                hasScreenImage: screenImage != nil,
                connectedModels: connected,
                userOverride: settingsStore.settings.modelOverride,
                forceRequiresTools: false
            )
        } catch {
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            if isCancellationError(error) { return }
            buddyState = .sad
            messages.append(ChatMessage(sender: .pinebot, text: "Routing error: \(error.localizedDescription)"))
            return
        }
        
        guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
        
        // If unresolved conversational intent requires tools and model supports planning, route to desktop action.
        // Explicit questions (forceNoAction = true) strictly follow conversational generation (hard no-action contract).
        if !forceNoAction && routeDecision.classification.requiresComputerTools && routeDecision.selectedModel.supportsComputerPlanning {
            buddyState = .working
            await handleComputerTask(prompt: prompt, route: routeDecision, screenImage: screenImage, generation: generation, requestId: requestId)
            return
        }
        
        // 4. Standard conversational / query generation with concise Jarvis persona
        do {
            let provider = providerManager.provider(for: routeDecision.selectedModel.provider)
            self.activeProvider = provider
            
            let responseText = try await provider.generateCompletion(
                prompt: prompt,
                systemPrompt: ResponsePolicy.standardPersonaSystemPrompt,
                image: screenImage,
                model: routeDecision.selectedModel.id
            )
            
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            
            buddyState = .happy
            messages.append(ChatMessage(
                sender: .pinebot,
                text: responseText,
                routeDecision: routeDecision
            ))
            
            if settingsStore.settings.speechOutputEnabled {
                let cleaned = ResponsePolicy.spokenCleaned(responseText)
                speech.speak(text: cleaned, requestId: requestId.uuidString)
            }
        } catch {
            // Guard against cancellation: CancellationError must NOT trigger model escalation!
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            if isCancellationError(error) {
                return
            }
            
            // Attempt bounded escalation with the same concise Jarvis persona system prompt
            do {
                let escalatedRoute = try router.escalate(
                    currentDecision: routeDecision,
                    error: error.localizedDescription,
                    connectedModels: connected
                )
                let provider = providerManager.provider(for: escalatedRoute.selectedModel.provider)
                self.activeProvider = provider
                let responseText = try await provider.generateCompletion(
                    prompt: prompt,
                    systemPrompt: ResponsePolicy.standardPersonaSystemPrompt,
                    image: screenImage,
                    model: escalatedRoute.selectedModel.id
                )
                
                guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
                
                buddyState = .happy
                messages.append(ChatMessage(
                    sender: .pinebot,
                    text: "\(responseText)\n\n*(Note: \(escalatedRoute.routingReason))*",
                    routeDecision: escalatedRoute
                ))
                
                if settingsStore.settings.speechOutputEnabled {
                    let cleaned = ResponsePolicy.spokenCleaned(responseText)
                    speech.speak(text: cleaned, requestId: requestId.uuidString)
                }
            } catch {
                guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
                if isCancellationError(error) { return }
                buddyState = .sad
                messages.append(ChatMessage(
                    sender: .pinebot,
                    text: "Error during inference: \(error.localizedDescription)\n\n(Tried with \(routeDecision.selectedModel.displayName))"
                ))
            }
        }
    }
    
    private func handleLocalActionResult(
        _ result: LocalActionResult,
        requestId: UUID,
        prompt: String,
        generation: Int,
        screenImage: NSImage?
    ) async {
        switch result {
        case .completed(let spokenSummary, let detail):
            buddyState = .happy
            _ = detail // Preserved internally; do not expose technical detail or bundle IDs in chat bubble
            messages.append(ChatMessage(sender: .pinebot, text: spokenSummary))
            if settingsStore.settings.speechOutputEnabled {
                let cleaned = ResponsePolicy.spokenCleaned(spokenSummary)
                speech.speak(text: cleaned, requestId: requestId.uuidString)
            }
            
        case .failed(let spokenError, let detail):
            buddyState = .sad
            _ = detail // Preserved internally
            messages.append(ChatMessage(sender: .pinebot, text: spokenError))
            if settingsStore.settings.speechOutputEnabled {
                let cleaned = ResponsePolicy.spokenCleaned(spokenError)
                speech.speak(text: cleaned, requestId: requestId.uuidString)
            }
            
        case .needsPermission(let reason):
            buddyState = .curious
            messages.append(ChatMessage(sender: .pinebot, text: reason))
            if settingsStore.settings.speechOutputEnabled {
                let cleaned = ResponsePolicy.spokenCleaned("Pinebot needs permission to control Apple Music.")
                speech.speak(text: cleaned, requestId: requestId.uuidString)
            }
            
        case .needsPlanner(let reason):
            messages.append(ChatMessage(sender: .pinebot, text: reason))
            await routeDesktopAction(goal: prompt, generation: generation, requestId: requestId, screenImage: screenImage)
        }
    }
    
    private func routeDesktopAction(goal: String, generation: Int, requestId: UUID, screenImage: NSImage?) async {
        providerManager.refreshConnectedModels()
        let connected = providerManager.connectedModels
        guard !connected.isEmpty else {
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            buddyState = .sad
            messages.append(ChatMessage(
                sender: .pinebot,
                text: "No models are connected yet! Please open the **Providers** tab to connect a model for desktop actions."
            ))
            return
        }
        
        let routeDecision: RouteDecision
        do {
            routeDecision = try await router.route(
                prompt: goal,
                hasScreenImage: screenImage != nil,
                connectedModels: connected,
                userOverride: settingsStore.settings.modelOverride,
                forceRequiresTools: true
            )
        } catch {
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            if isCancellationError(error) { return }
            buddyState = .sad
            messages.append(ChatMessage(sender: .pinebot, text: "Routing error: \(error.localizedDescription)"))
            return
        }
        
        guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
        buddyState = .working
        await handleComputerTask(prompt: goal, route: routeDecision, screenImage: screenImage, generation: generation, requestId: requestId)
    }
    
    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let acp = error as? ACPError, acp == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        if ns.code == -999 { return true } // URLSession cancelled
        let lower = error.localizedDescription.lowercased()
        if lower.contains("cancel") || lower.contains("stopped") { return true }
        return false
    }
    
    private func handleComputerTask(prompt: String, route: RouteDecision, screenImage: NSImage?, generation: Int, requestId: UUID) async {
        let lower = prompt.lowercased()
        let teachingMode = lower.contains("teach") || lower.contains("guide me") || lower.contains("show me how") || lower.contains("explain step")
        
        let selectedModel = route.selectedModel
        let provider = providerManager.provider(for: selectedModel.provider)
        self.activeProvider = provider
        
        let planner: ComputerPlanner
        if selectedModel.supportsComputerPlanning || selectedModel.supportsVision {
            planner = ProviderComputerPlanner(provider: provider, model: selectedModel.id)
        } else {
            planner = FallbackComputerPlanner()
        }
        
        do {
            let result = try await taskEngine.executeTask(
                goal: prompt,
                planner: planner,
                teachingMode: teachingMode,
                requireConfirmation: settingsStore.settings.requireToolConfirmation
            )
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            
            switch result.outcome {
            case .completed:
                buddyState = .happy
                let summaryText = result.summary.isEmpty ? "Action completed." : result.summary
                let evidenceNote = result.observedEvidence.map { " (\($0))" } ?? ""
                messages.append(ChatMessage(
                    sender: .pinebot,
                    text: "\(summaryText)\(evidenceNote)",
                    routeDecision: route
                ))
                if settingsStore.settings.speechOutputEnabled {
                    let cleaned = ResponsePolicy.spokenCleaned(summaryText)
                    speech.speak(text: cleaned, requestId: requestId.uuidString)
                }
                
            case .needsUser:
                buddyState = .curious
                messages.append(ChatMessage(
                    sender: .pinebot,
                    text: result.summary,
                    routeDecision: route
                ))
                if settingsStore.settings.speechOutputEnabled {
                    let cleaned = ResponsePolicy.spokenCleaned(result.summary)
                    speech.speak(text: cleaned, requestId: requestId.uuidString)
                }
                
            case .rejected:
                buddyState = .idle
                messages.append(ChatMessage(
                    sender: .pinebot,
                    text: "Desktop action was declined: \(result.summary)",
                    routeDecision: route
                ))
                if settingsStore.settings.speechOutputEnabled {
                    let cleaned = ResponsePolicy.spokenCleaned("Action declined: \(result.summary)")
                    speech.speak(text: cleaned, requestId: requestId.uuidString)
                }
                
            case .cancelled:
                buddyState = .idle
                
            case .failed:
                buddyState = .sad
                messages.append(ChatMessage(
                    sender: .pinebot,
                    text: "Computer task could not be completed: \(result.summary)",
                    routeDecision: route
                ))
                if settingsStore.settings.speechOutputEnabled {
                    let cleaned = ResponsePolicy.spokenCleaned("Action failed: \(result.summary)")
                    speech.speak(text: cleaned, requestId: requestId.uuidString)
                }
            }
        } catch {
            guard !Task.isCancelled, self.activeRequestGeneration == generation else { return }
            if isCancellationError(error) {
                buddyState = .idle
                return
            }
            buddyState = .sad
            messages.append(ChatMessage(
                sender: .pinebot,
                text: "Task interrupted or failed: \(error.localizedDescription)"
            ))
            if settingsStore.settings.speechOutputEnabled {
                speech.speak(text: "Task failed.", requestId: requestId.uuidString)
            }
        }
    }
}
