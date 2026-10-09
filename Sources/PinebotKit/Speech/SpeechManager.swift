import Foundation
import Speech
import AVFoundation

/// Presentation phase of speech synthesis for UI captions.
public enum SpeechPresentationPhase: String, Sendable, Equatable {
    case idle
    case speaking
    case finished
    case cancelled
}

/// State published for UI captions and word highlighting during speech playback.
public struct SpeechPresentationState: Sendable, Equatable {
    public var requestId: String
    public var utteranceId: UUID
    public var text: String
    public var phase: SpeechPresentationPhase
    public var currentRange: NSRange?
    public var progress: Double
    
    public init(
        requestId: String = "",
        utteranceId: UUID = UUID(),
        text: String = "",
        phase: SpeechPresentationPhase = .idle,
        currentRange: NSRange? = nil,
        progress: Double = 0.0
    ) {
        self.requestId = requestId
        self.utteranceId = utteranceId
        self.text = text
        self.phase = phase
        self.currentRange = currentRange
        self.progress = progress
    }
    
    public static let idle = SpeechPresentationState()
}

/// Protocol for speech synthesis in teaching mode and audio output.
@MainActor
public protocol SpeechManagerProtocol: AnyObject {
    func speak(text: String)
    func speak(text: String, requestId: String)
    func stopSpeaking()
}

public extension SpeechManagerProtocol {
    func speak(text: String) {
        speak(text: text, requestId: UUID().uuidString)
    }
}

/// Abstract protocol for the underlying speech synthesizer allowing test injection.
@MainActor
public protocol SpeechSynthesizerProtocol: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizerProtocol {}

/// Manages real macOS speech transcription (dictation) and speech synthesis (voice response),
/// with asynchronous endAudio completion on key release, error recovery, TTS delegate tracking,
/// generational utterance token guards, and natural voice selection.
@MainActor
public final class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate, SpeechManagerProtocol {
    public static let shared = SpeechManager()
    
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var transcribedText: String = ""
    @Published public private(set) var permissionDenied: Bool = false
    @Published public private(set) var isSpeaking: Bool = false
    @Published public private(set) var presentationState: SpeechPresentationState = .idle
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer: SpeechSynthesizerProtocol
    
    private var finishContinuation: CheckedContinuation<String, Never>?
    private var timeoutTask: Task<Void, Never>?
    
    // Generational guards and object identity tracking
    private var activeUtteranceIdentifier: ObjectIdentifier?
    private var currentUtteranceId: UUID?
    public private(set) var currentGeneration: Int = 0
    private var currentRecordingGeneration: Int = 0
    
    public init(synthesizer: SpeechSynthesizerProtocol? = nil) {
        let synth = synthesizer ?? AVSpeechSynthesizer()
        self.synthesizer = synth
        super.init()
        speechRecognizer?.delegate = self
        self.synthesizer.delegate = self
    }
    
    /// Requests speech recognition and microphone permissions.
    public func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        
        let micAuth = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        
        let granted = speechAuth && micAuth
        permissionDenied = !granted
        return granted
    }
    
    /// Starts real-time dictation recording.
    public func startRecording(onDelta: ((String) -> Void)? = nil) throws {
        // Reset any previous state cleanly
        resetRecording()
        
        currentRecordingGeneration += 1
        let generation = currentRecordingGeneration
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            permissionDenied = true
            throw NSError(domain: "PinebotSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is unavailable."])
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        self.transcribedText = ""
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        
        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            // Error starting audio engine: clean up recording state immediately
            resetRecording()
            throw error
        }
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.currentRecordingGeneration == generation else { return }
                
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self.transcribedText = text
                    onDelta?(text)
                    
                    if result.isFinal {
                        self.resolveFinishContinuation(generation: generation)
                    }
                }
                
                if error != nil {
                    // Recognition failed or ended with error: resolve continuation or reset
                    self.resolveFinishContinuation(generation: generation)
                }
            }
        }
    }
    
    /// Asynchronously finishes dictation on hotkey release by signaling endAudio,
    /// waiting for the final recognition result or a short timeout without prematurely
    /// canceling the task and losing the user's trailing words.
    public func finishRecording(timeoutSeconds: TimeInterval = 1.2) async -> String {
        guard isRecording else {
            return transcribedText
        }
        
        // 1. Stop feeding new audio from microphone
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // 2. Signal end of audio to speech recognizer so it can process final buffered audio
        recognitionRequest?.endAudio()
        
        let generation = self.currentRecordingGeneration
        
        // 3. Await final transcription from recognition task or timeout
        return await withCheckedContinuation { continuation in
            self.finishContinuation = continuation
            
            // Timeout task in case speech recognizer doesn't signal isFinal
            self.timeoutTask?.cancel()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                self.resolveFinishContinuation(generation: generation)
            }
        }
    }
    
    /// Resolves any waiting finish continuation, stops the task, and resets recording state.
    private func resolveFinishContinuation(generation: Int? = nil) {
        if let gen = generation, gen != self.currentRecordingGeneration {
            return
        }
        currentRecordingGeneration += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        
        let final = transcribedText
        
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        
        if let cont = finishContinuation {
            finishContinuation = nil
            cont.resume(returning: final)
        }
    }
    
    /// Immediately resets and cancels active recording and cleans up all audio resources.
    public func resetRecording() {
        currentRecordingGeneration += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        
        if let cont = finishContinuation {
            finishContinuation = nil
            cont.resume(returning: transcribedText)
        }
    }
    
    /// Synchronous cancellation/stop for backward compatibility.
    @discardableResult
    public func stopRecording() -> String {
        resetRecording()
        return transcribedText
    }
    
    // MARK: - Speech Synthesis (TTS)
    
    /// Speaks the given text aloud using AVSpeechSynthesizer with utterance tracking and natural voice selection.
    public func speak(text: String, requestId: String) {
        stopSpeaking()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        currentGeneration += 1
        let utteranceId = UUID()
        self.currentUtteranceId = utteranceId
        
        let utterance = AVSpeechUtterance(string: trimmed)
        self.activeUtteranceIdentifier = ObjectIdentifier(utterance)
        
        presentationState = SpeechPresentationState(
            requestId: requestId,
            utteranceId: utteranceId,
            text: trimmed,
            phase: .speaking,
            currentRange: nil,
            progress: 0.0
        )
        
        utterance.voice = selectNaturalVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0 // Neutral pitch
        
        isSpeaking = true
        synthesizer.speak(utterance)
    }
    
    public func speak(text: String) {
        speak(text: text, requestId: UUID().uuidString)
    }
    
    /// Stops any active speech synthesis immediately and marks presentation state as cancelled.
    public func stopSpeaking() {
        currentGeneration += 1
        activeUtteranceIdentifier = nil
        currentUtteranceId = nil
        isSpeaking = false
        if presentationState.phase == .speaking {
            presentationState = SpeechPresentationState(
                requestId: presentationState.requestId,
                utteranceId: presentationState.utteranceId,
                text: presentationState.text,
                phase: .cancelled,
                currentRange: nil,
                progress: presentationState.progress
            )
        } else if presentationState.phase == .finished {
            presentationState = .idle
        }
        
        if synthesizer.isSpeaking {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }
    
    /// Selects an installed natural English voice prioritizing enhanced and premium qualities.
    public func selectNaturalVoice() -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        
        // 1. Check user preference from settings if configured
        let preferredVoiceId = SettingsStore.shared.settings.preferredVoiceId
        if !preferredVoiceId.isEmpty, let userVoice = allVoices.first(where: { $0.identifier == preferredVoiceId }) {
            return userVoice
        }
        
        // 2. Default: prefer natural British voice (en-GB, enhanced "Daniel")
        let gbVoices = allVoices.filter { $0.language.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix("en-gb") }
        
        if let danielEnhanced = gbVoices.first(where: { $0.name.localizedCaseInsensitiveContains("daniel") && ($0.quality == .enhanced || $0.quality == .premium) }) {
            return danielEnhanced
        }
        if let daniel = gbVoices.first(where: { $0.name.localizedCaseInsensitiveContains("daniel") }) {
            return daniel
        }
        if let premiumGB = gbVoices.first(where: { $0.quality == .premium }) {
            return premiumGB
        }
        if let enhancedGB = gbVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedGB
        }
        if let firstGB = gbVoices.first {
            return firstGB
        }
        
        // 3. Fallback to English natural voices
        let enVoices = allVoices.filter { $0.language.lowercased().hasPrefix("en") }
        if let premium = enVoices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = enVoices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        let preferredNames = ["Daniel", "Samantha", "Ava", "Alex", "Zoe", "Fred"]
        for name in preferredNames {
            if let match = enVoices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match
            }
        }
        
        return AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let callbackId = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.isSpeaking,
                  self.activeUtteranceIdentifier == callbackId,
                  let activeId = self.currentUtteranceId,
                  self.presentationState.utteranceId == activeId else {
                return
            }
            let length = self.presentationState.text.utf16.count
            let fraction = length > 0 ? Double(characterRange.location + characterRange.length) / Double(length) : 0.0
            self.presentationState.currentRange = characterRange
            self.presentationState.progress = min(max(fraction, 0.0), 1.0)
        }
    }
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let callbackId = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.activeUtteranceIdentifier == callbackId,
                  let activeId = self.currentUtteranceId,
                  self.presentationState.utteranceId == activeId else {
                // Stale callback from an earlier cancelled/finished utterance: ignore!
                return
            }
            self.isSpeaking = false
            self.activeUtteranceIdentifier = nil
            self.currentUtteranceId = nil
            self.presentationState = SpeechPresentationState(
                requestId: self.presentationState.requestId,
                utteranceId: activeId,
                text: self.presentationState.text,
                phase: .finished,
                currentRange: nil,
                progress: 1.0
            )
        }
    }
    
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let callbackId = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.activeUtteranceIdentifier == callbackId,
                  let activeId = self.currentUtteranceId,
                  self.presentationState.utteranceId == activeId else {
                // Stale callback from an earlier utterance: ignore!
                return
            }
            self.isSpeaking = false
            self.activeUtteranceIdentifier = nil
            self.currentUtteranceId = nil
            self.presentationState = SpeechPresentationState(
                requestId: self.presentationState.requestId,
                utteranceId: activeId,
                text: self.presentationState.text,
                phase: .cancelled,
                currentRange: nil,
                progress: self.presentationState.progress
            )
        }
    }
    
    // MARK: - SFSpeechRecognizerDelegate
    
    nonisolated public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            self.permissionDenied = !available
        }
    }
}
