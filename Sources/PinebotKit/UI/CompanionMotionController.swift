import AppKit
import SwiftUI
import Combine

/// Dedicated presentation, motion, and layout controller for the Pinebot companion buddy.
/// Owns the cancellable presentation scheduler with generation guards, separate interaction generation tokens,
/// shared envelope geometry, and reduced-motion policy.
@MainActor
public final class CompanionMotionController: ObservableObject {
    public static let shared = CompanionMotionController()
    
    // MARK: - Geometry & Constants
    
    /// Gutter padding around artwork inside the fixed square container (20pt).
    /// Provides at least 16pt margin ensuring maximum transformed artwork,
    /// rings, shadow, and overlays remain within bounds without clipping.
    public static let gutter: CGFloat = 20.0
    
    /// Backward compatible alias for internalPadding.
    public static var internalPadding: CGFloat { gutter }
    
    /// Distance threshold in points to distinguish between a click and a drag.
    public static let dragThreshold: CGFloat = 4.0
    
    /// Margin from screen edge for clamping.
    public static let screenMargin: CGFloat = 8.0
    
    // MARK: - Published Presentation State
    
    /// Horizontal scale factor.
    @Published public var scaleX: CGFloat = 1.0
    
    /// Vertical scale factor (for breathing and gestures, bottom anchored).
    @Published public var scaleY: CGFloat = 1.0
    
    /// Backward compatibility: breathingScale maps to scaleY.
    public var breathingScale: CGFloat {
        get { scaleY }
        set { scaleY = newValue }
    }
    
    /// Vertical displacement in points (<= 1pt for idle gesture, subtle entry nod).
    @Published public var verticalDisplacement: CGFloat = 0.0
    
    /// Adaptive opacity (0.92 awake idle -> 0.76 after 8s -> sleepOpacity when sleeping, 1.0 on hover).
    @Published public var currentOpacity: Double = 0.92
    
    /// Press state: pointer down compresses to 0.97 over 120ms; release springs back.
    @Published public private(set) var isPressed: Bool = false
    
    /// True while actively dragging the companion buddy window.
    @Published public private(set) var isDragging: Bool = false
    
    /// True only when user voice intent AND real SpeechManager audio recording are active.
    @Published public private(set) var isActivelyRecording: Bool = false
    
    /// Recording ring scale (cycles 1.0 to 1.05 over 1.2s during active recording).
    @Published public var recordingRingScale: CGFloat = 1.0
    
    /// Recording ring opacity (cycles 0.45 to 0.70 over 1.2s during active recording).
    @Published public var recordingRingOpacity: Double = 0.45
    
    /// Separate token incremented on genuine interaction cancellation/reset/hide/display change.
    @Published public private(set) var interactionGeneration: Int = 0
    
    // MARK: - Internal Dependencies & State Tracking
    
    private weak var assistant: PinebotAssistant?
    private weak var settingsStore: SettingsStore?
    private let speechManager: SpeechManager = .shared
    
    private var isHovered: Bool = false
    public private(set) var isVisible: Bool = true
    private var previousState: BuddyState = .happy
    
    // Generation guard to cancel and invalidate stale async tasks before any mutation
    private var animationGeneration: Int = 0
    
    // Programmatic test drag state
    private var dragStartMouseLocation: CGPoint? = nil
    private var dragStartPanelOrigin: CGPoint? = nil
    private var dragExceededThreshold: Bool = false
    
    // Tasks & Timers
    private var idleTask: Task<Void, Never>? = nil
    private var recordingTask: Task<Void, Never>? = nil
    private var transitionTask: Task<Void, Never>? = nil
    private var cancellables = Set<AnyCancellable>()
    private var lastDragActivityRecordTime: TimeInterval = 0
    
    // MARK: - Initializer & Configuration
    
    public init(assistant: PinebotAssistant = .shared, settingsStore: SettingsStore = .shared) {
        self.assistant = assistant
        self.settingsStore = settingsStore
        setupObservers()
    }
    
    public func configure(assistant: PinebotAssistant, settingsStore: SettingsStore) {
        self.assistant = assistant
        self.settingsStore = settingsStore
        setupObservers()
    }
    
    /// Checks whether reduced motion is active either via macOS system settings or Pinebot user preferences.
    public var effectiveReducedMotion: Bool {
        if let store = settingsStore, store.settings.reducedMotion {
            return true
        }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    
    // MARK: - Interaction Invalidation Token
    
    public func invalidateInteraction() {
        interactionGeneration &+= 1
        logDiagnostic("INVALIDATE_INTERACTION: token=\(interactionGeneration)")
    }
    
    // MARK: - Diagnostics Telemetry (DEBUG-only, Bounded)
    
    public func logDiagnostic(_ message: String) {
        #if DEBUG
        Self.writeDiagnostic(message)
        #endif
    }
    
    public static func writeDiagnostic(_ message: String) {
        let logPath = "/private/tmp/pinebot-motion-events.log"
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let line = "[\(timestamp)] \(message)\n"
        
        guard let data = line.data(using: .utf8) else { return }
        
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            let offset = handle.offsetInFile
            if offset > 100 * 1024 {
                handle.truncateFile(atOffset: 0)
            }
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
    
    // MARK: - Observers
    
    private func setupObservers() {
        cancellables.removeAll()
        
        guard let assistant = assistant, let settingsStore = settingsStore else { return }
        
        // Observe BuddyState transitions
        assistant.$buddyState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.handleStateTransition(to: newState)
            }
            .store(in: &cancellables)
        
        // Observe Real Recording state: requires user voice intent AND speech audio engine active
        Publishers.CombineLatest(assistant.$isListeningToVoice, speechManager.$isRecording)
            .map { isListening, isRecording in isListening && isRecording }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.handleRecordingStateChange(active: active)
            }
            .store(in: &cancellables)
        
        // Observe Settings changes
        settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSettingsOrSystemMotionChanged()
            }
            .store(in: &cancellables)
        
        // Correctly observe macOS System Accessibility Reduce Motion via NSWorkspace.shared.notificationCenter
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSettingsOrSystemMotionChanged()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Sizing & Container Geometry
    
    /// Computes the fixed square container dimension for a given buddy size.
    /// Uses ONE shared geometry calculation: buddySize + (gutter * 2).
    public static func containerSize(for buddySize: Double) -> CGFloat {
        return CGFloat(buddySize) + (gutter * 2.0)
    }
    
    /// Computes the NSWindow size for a given buddy size.
    public static func panelSize(for buddySize: Double) -> CGSize {
        let side = containerSize(for: buddySize)
        return CGSize(width: side, height: side)
    }
    
    /// Clamps a panel origin point so the entire window frame remains visible within screenBounds.
    /// Fully supports multi-display arrangements with negative origins.
    public static func clamp(origin: CGPoint, size: CGSize, within screenBounds: CGRect, margin: CGFloat = screenMargin) -> CGPoint {
        return ScreenCoordinateHelper.clamp(point: origin, size: size, within: screenBounds, margin: margin)
    }
    
    /// Resolves the NSScreen containing the specified point in AppKit screen coordinates.
    public static func targetScreen(for mouseLocation: CGPoint, fallback: NSScreen?) -> NSScreen? {
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? fallback ?? NSScreen.main
    }
    
    /// Resolves the screen for an existing window frame, prioritizing direct panel.screen,
    /// largest intersecting screen rect, or nearest screen center on removal.
    /// Crucial for preventing multi-monitor teleportation during size or display changes.
    public static func screenForWindow(frame: CGRect, panelScreen: NSScreen?) -> NSScreen? {
        if let s = panelScreen { return s }
        var bestScreen: NSScreen? = nil
        var maxOverlapArea: CGFloat = 0.0
        for s in NSScreen.screens {
            let intersection = s.frame.intersection(frame)
            if !intersection.isNull && !intersection.isEmpty {
                let area = intersection.width * intersection.height
                if area > maxOverlapArea {
                    maxOverlapArea = area
                    bestScreen = s
                }
            }
        }
        if let best = bestScreen { return best }
        
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var closestScreen: NSScreen? = nil
        var minDistance: CGFloat = .greatestFiniteMagnitude
        for s in NSScreen.screens {
            let sCenter = CGPoint(x: s.frame.midX, y: s.frame.midY)
            let dist = hypot(center.x - sCenter.x, center.y - sCenter.y)
            if dist < minDistance {
                minDistance = dist
                closestScreen = s
            }
        }
        return closestScreen ?? NSScreen.main ?? NSScreen.screens.first
    }
    
    // MARK: - Drag & Press Processing
    
    /// Handles pointer down: begins press scale to 0.97 over 120ms.
    public func handlePointerDown() {
        guard !isDragging else { return }
        isPressed = true
        cancelIdleScheduler()
        assistant?.recordActivity()
        
        if effectiveReducedMotion {
            scaleX = 1.0
            scaleY = 1.0
            return
        }
        
        withAnimation(.easeInOut(duration: 0.12)) {
            self.scaleX = 0.97
            self.scaleY = 0.97
        }
    }
    
    /// Handles pointer up: springs back to 1.0.
    public func handlePointerUp() {
        guard isPressed else { return }
        isPressed = false
        assistant?.recordActivity()
        
        if effectiveReducedMotion {
            scaleX = 1.0
            scaleY = 1.0
            return
        }
        
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            self.scaleX = 1.0
            self.scaleY = 1.0
        }
    }
    
    public func notifyDragStarted() {
        guard !isDragging else { return }
        isDragging = true
        isPressed = false
        resetTransformsToNeutral()
        logDiagnostic("DRAG_STARTED: isDragging=true")
    }
    
    public func notifyDragMoved(clampedOrigin: CGPoint) {
        if !isDragging {
            notifyDragStarted()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDragActivityRecordTime >= 0.5 {
            lastDragActivityRecordTime = now
            assistant?.recordActivity()
        }
    }
    
    public func notifyDragEnded() {
        isDragging = false
        isPressed = false
        assistant?.recordActivity()
        logDiagnostic("DRAG_ENDED: isDragging=false")
        reconcilePresentationState()
    }
    
    public func resetDrag() {
        dragStartMouseLocation = nil
        dragStartPanelOrigin = nil
        dragExceededThreshold = false
        isDragging = false
        isPressed = false
        invalidateInteraction()
        reconcilePresentationState()
    }
    
    /// Genuine cancellation: invalidates token, neutralizes transforms atomically, and cleans up logical flags.
    public func cancelInteraction() {
        dragStartMouseLocation = nil
        dragStartPanelOrigin = nil
        dragExceededThreshold = false
        isDragging = false
        isPressed = false
        invalidateInteraction()
        resetTransformsToNeutral()
        reconcilePresentationState()
    }
    
    // MARK: - Programmatic Testing Helpers
    
    public func handleDragChanged(mouseLocation: CGPoint, panel: NSWindow?) -> CGPoint? {
        if dragStartMouseLocation == nil {
            dragStartMouseLocation = mouseLocation
            dragStartPanelOrigin = panel?.frame.origin
            dragExceededThreshold = false
        }
        
        guard let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartPanelOrigin else {
            return nil
        }
        
        let deltaX = mouseLocation.x - startMouse.x
        let deltaY = mouseLocation.y - startMouse.y
        let distance = hypot(deltaX, deltaY)
        
        if distance >= Self.dragThreshold {
            dragExceededThreshold = true
            if !isDragging {
                notifyDragStarted()
            }
        }
        
        if isDragging, let panel = panel {
            let rawOrigin = CGPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY)
            let targetScreen = Self.targetScreen(for: mouseLocation, fallback: panel.screen)
            if let visible = targetScreen?.visibleFrame {
                return Self.clamp(origin: rawOrigin, size: panel.frame.size, within: visible)
            }
            return rawOrigin
        }
        return nil
    }
    
    public func handleDragEnded(mouseLocation: CGPoint) -> Bool {
        handlePointerUp()
        let wasClick: Bool
        if let startMouse = dragStartMouseLocation {
            let deltaX = mouseLocation.x - startMouse.x
            let deltaY = mouseLocation.y - startMouse.y
            let distance = hypot(deltaX, deltaY)
            wasClick = !dragExceededThreshold && (distance < Self.dragThreshold)
        } else {
            wasClick = !dragExceededThreshold
        }
        resetDrag()
        return wasClick
    }
    
    // MARK: - Atomic Neutral Transform Reset
    
    /// Resets transform scales and offsets to neutral values WITHOUT clearing logical interaction flags.
    public func resetTransformsToNeutral() {
        cancelAllAnimationTasks()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.scaleX = 1.0
            self.scaleY = 1.0
            self.verticalDisplacement = 0.0
            self.recordingRingScale = 1.0
            self.recordingRingOpacity = 0.45
        }
    }
    
    // MARK: - Presentation Reconciliation
    
    /// Reconciles presentation state after interaction ends or state resets.
    public func reconcilePresentationState() {
        guard isVisible, !isDragging else { return }
        if isActivelyRecording {
            handleRecordingStateChange(active: true)
        } else if assistant?.buddyState == .happy {
            startIdleScheduler()
        }
    }
    
    // MARK: - Visibility Control
    
    public func setVisible(_ visible: Bool) {
        logDiagnostic("SET_VISIBLE: \(visible)")
        self.isVisible = visible
        if !visible {
            invalidateInteraction()
            resetTransformsToNeutral()
            isPressed = false
            isDragging = false
        } else {
            reconcilePresentationState()
        }
    }
    
    // MARK: - Hover Lifecycle
    
    public func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        logDiagnostic("HOVER: \(hovered)")
        
        if hovered {
            assistant?.recordActivity()
            cancelIdleScheduler()
            verticalDisplacement = 0.0
            if !isPressed {
                scaleX = 1.0
                scaleY = 1.0
            }
            let duration = effectiveReducedMotion ? 0.12 : 0.18
            withAnimation(.easeInOut(duration: duration)) {
                self.currentOpacity = 1.0
            }
        } else {
            if assistant?.buddyState == .happy {
                let duration = effectiveReducedMotion ? 0.12 : 0.18
                withAnimation(.easeInOut(duration: duration)) {
                    self.currentOpacity = 0.92
                }
                startIdleScheduler()
            } else if assistant?.buddyState == .sleeping {
                let sleepOp = settingsStore?.settings.sleepOpacity ?? 0.65
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.currentOpacity = sleepOp
                }
            }
        }
    }
    
    // MARK: - State Transitions & Presentation Priority
    
    private func handleStateTransition(to newState: BuddyState) {
        let oldState = previousState
        previousState = newState
        logDiagnostic("STATE_TRANSITION: \(oldState.rawValue) -> \(newState.rawValue)")
        
        cancelAllAnimationTasks()
        verticalDisplacement = 0.0
        
        if effectiveReducedMotion {
            scaleX = 1.0
            scaleY = 1.0
            verticalDisplacement = 0.0
            if newState == .sleeping {
                currentOpacity = settingsStore?.settings.sleepOpacity ?? 0.65
            } else {
                currentOpacity = isHovered ? 1.0 : 0.92
            }
            return
        }
        
        animationGeneration += 1
        let currentGen = animationGeneration
        
        switch newState {
        case .sleeping:
            scaleX = 1.0
            scaleY = 1.0
            verticalDisplacement = 0.0
            let targetOpacity = settingsStore?.settings.sleepOpacity ?? 0.65
            withAnimation(.easeInOut(duration: 0.90)) {
                self.currentOpacity = targetOpacity
            }
            
        case .happy:
            if isDragging || isPressed {
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.currentOpacity = self.isHovered ? 1.0 : 0.92
                }
                // Drag or press priority: do NOT overwrite active scale or start idle scheduler
                return
            }
            if oldState == .sleeping {
                transitionTask = Task { @MainActor [weak self] in
                    guard let self = self, self.animationGeneration == currentGen, !Task.isCancelled else { return }
                    guard !self.isDragging, !self.isPressed else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.currentOpacity = self.isHovered ? 1.0 : 0.92
                    }
                    withAnimation(.easeInOut(duration: 0.19)) {
                        self.scaleX = 1.025
                        self.scaleY = 1.025
                    }
                    try? await Task.sleep(nanoseconds: 190_000_000)
                    guard self.animationGeneration == currentGen, !Task.isCancelled, !self.isDragging, !self.isPressed else { return }
                    withAnimation(.easeInOut(duration: 0.19)) {
                        self.scaleX = 1.0
                        self.scaleY = 1.0
                    }
                    try? await Task.sleep(nanoseconds: 190_000_000)
                    guard self.animationGeneration == currentGen, !Task.isCancelled, !self.isDragging, !self.isPressed else { return }
                    self.startIdleScheduler()
                }
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.currentOpacity = self.isHovered ? 1.0 : 0.92
                    self.scaleX = 1.0
                    self.scaleY = 1.0
                }
                startIdleScheduler()
            }
            
        case .working:
            withAnimation(.easeInOut(duration: 0.18)) {
                self.currentOpacity = self.isHovered ? 1.0 : 0.92
            }
            transitionTask = Task { @MainActor [weak self] in
                guard let self = self, self.animationGeneration == currentGen, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.verticalDisplacement = 1.2
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard self.animationGeneration == currentGen, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.verticalDisplacement = 0.0
                }
            }
            
        case .thinking:
            withAnimation(.easeInOut(duration: 0.18)) {
                self.currentOpacity = self.isHovered ? 1.0 : 0.92
            }
            transitionTask = Task { @MainActor [weak self] in
                guard let self = self, self.animationGeneration == currentGen, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    self.scaleX = 1.01
                    self.scaleY = 1.01
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard self.animationGeneration == currentGen, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.13)) {
                    self.scaleX = 1.0
                    self.scaleY = 1.0
                }
            }
            
        case .sad:
            withAnimation(.easeInOut(duration: 0.18)) {
                self.currentOpacity = self.isHovered ? 1.0 : 0.92
                self.scaleX = 1.0
                self.scaleY = 1.0
                self.verticalDisplacement = 0.0
            }
        }
    }
    
    // MARK: - Actual Voice Recording Lifetime Loop
    
    private func handleRecordingStateChange(active: Bool) {
        isActivelyRecording = active
        logDiagnostic("RECORDING_ACTIVE: \(active)")
        
        recordingTask?.cancel()
        recordingTask = nil
        
        if active {
            cancelIdleScheduler()
            
            if effectiveReducedMotion {
                recordingRingScale = 1.0
                recordingRingOpacity = 0.70
                return
            }
            
            animationGeneration += 1
            let currentGen = animationGeneration
            
            withAnimation(.easeInOut(duration: 0.18)) {
                self.recordingRingScale = 1.05
                self.recordingRingOpacity = 0.70
            }
            
            recordingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                while !Task.isCancelled {
                    guard let self = self, self.animationGeneration == currentGen else { break }
                    withAnimation(.easeInOut(duration: 0.60)) {
                        self.recordingRingScale = 1.0
                        self.recordingRingOpacity = 0.45
                    }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard self.animationGeneration == currentGen, !Task.isCancelled else { break }
                    
                    withAnimation(.easeInOut(duration: 0.60)) {
                        self.recordingRingScale = 1.05
                        self.recordingRingOpacity = 0.70
                    }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                self.recordingRingScale = 1.0
                self.recordingRingOpacity = 0.45
            }
            reconcilePresentationState()
        }
    }
    
    // MARK: - Owned Cancellable Idle Scheduler & Finite Phase Keyframes
    
    private func startIdleScheduler() {
        cancelIdleScheduler()
        guard isVisible,
              !effectiveReducedMotion,
              assistant?.buddyState == .happy,
              !isActivelyRecording,
              !(assistant?.isProcessing ?? false),
              !isDragging,
              !isHovered else {
            return
        }
        
        animationGeneration += 1
        let currentGen = animationGeneration
        
        idleTask = Task { @MainActor [weak self] in
            guard let self = self, self.animationGeneration == currentGen, !Task.isCancelled else { return }
            self.currentOpacity = 0.92
            
            // Phase 1: Wait 8 seconds -> fade to 0.76 over 700ms
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self.animationGeneration == currentGen, !Task.isCancelled, !self.isHovered, self.assistant?.buddyState == .happy else { return }
            
            withAnimation(.easeInOut(duration: 0.70)) {
                self.currentOpacity = 0.76
            }
            
            // Phase 2: Wait 10 more seconds (total 18s) -> tiny one-shot vertical gesture
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard self.animationGeneration == currentGen, !Task.isCancelled, !self.isHovered, self.assistant?.buddyState == .happy else { return }
            
            withAnimation(.easeInOut(duration: 0.60)) {
                self.verticalDisplacement = -1.0
                self.scaleY = 1.012
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.animationGeneration == currentGen, !Task.isCancelled else { return }
            
            withAnimation(.easeInOut(duration: 0.60)) {
                self.verticalDisplacement = 0.0
                self.scaleY = 1.0
            }
            
            // Phase 3: Wait 22 more seconds (total 40s) -> second tiny one-shot vertical gesture
            try? await Task.sleep(nanoseconds: 22_000_000_000)
            guard self.animationGeneration == currentGen, !Task.isCancelled, !self.isHovered, self.assistant?.buddyState == .happy else { return }
            
            withAnimation(.easeInOut(duration: 0.60)) {
                self.verticalDisplacement = -1.0
                self.scaleY = 1.012
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.animationGeneration == currentGen, !Task.isCancelled else { return }
            
            withAnimation(.easeInOut(duration: 0.60)) {
                self.verticalDisplacement = 0.0
                self.scaleY = 1.0
            }
        }
    }
    
    private func cancelIdleScheduler() {
        idleTask?.cancel()
        idleTask = nil
    }
    
    private func cancelAllAnimationTasks() {
        animationGeneration += 1
        cancelIdleScheduler()
        recordingTask?.cancel()
        recordingTask = nil
        transitionTask?.cancel()
        transitionTask = nil
    }
    
    private func handleSettingsOrSystemMotionChanged() {
        if effectiveReducedMotion {
            resetTransformsToNeutral()
            if assistant?.buddyState == .sleeping {
                currentOpacity = settingsStore?.settings.sleepOpacity ?? 0.65
            } else {
                currentOpacity = isHovered ? 1.0 : 0.92
            }
        } else {
            reconcilePresentationState()
        }
    }
    
    // MARK: - Compatibility APIs
    
    public func startBreathing(reducedMotion: Bool) {
        if reducedMotion || effectiveReducedMotion {
            scaleX = 1.0
            scaleY = 1.0
            return
        }
        reconcilePresentationState()
    }
    
    public func stopBreathing() {
        resetTransformsToNeutral()
    }
}

// MARK: - Compatibility Aliases for Paused Core Work

extension BuddyState {
    /// Alias for normal idle / awake state (.happy).
    public static let idle: BuddyState = .happy
    
    /// Alias for curious / thinking state (.thinking).
    public static let curious: BuddyState = .thinking
}

extension AgentCoordinator.JobStatus {
    /// Alias for rejected job status (.cancelled).
    public static let rejected: AgentCoordinator.JobStatus = .cancelled
}
