import AppKit
import SwiftUI
import Combine

/// Borderless non-activating floating panel displaying spoken captions.
public final class CaptionPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.ignoresMouseEvents = true // Non-blocking clicks
        self.minSize = NSSize(width: 332, height: 44)
        
        self.title = "Pinebot Speech"
        self.setAccessibilityTitle("Pinebot Speech")
        self.setAccessibilityLabel("Pinebot Speech")
        self.setAccessibilityRole(.window)
    }
}

/// Controller managing the top-right caption panel lifecycle, positioning, and auto-dismiss.
@MainActor
public final class CaptionPanelController: ObservableObject {
    public static let shared = CaptionPanelController()
    
    let panel: CaptionPanel
    private var cancellables = Set<AnyCancellable>()
    private var autoDismissTask: Task<Void, Never>?
    private var targetScreen: NSScreen?
    var currentUtteranceId: UUID?
    
    public var panelFrame: NSRect { panel.frame }
    public var isVisible: Bool { panel.isVisible }
    
    public init() {
        let initialRect = NSRect(x: 0, y: 0, width: 332, height: 120)
        self.panel = CaptionPanel(contentRect: initialRect)
        
        let hostingView = NSHostingView(rootView: CaptionView())
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        
        setupSubscriptions()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            reanchorAndSize(for: "", on: screen)
        }
    }
    
    private func setupSubscriptions() {
        // Observe speech presentation state changes
        SpeechManager.shared.$presentationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handlePresentationStateChange(state)
            }
            .store(in: &cancellables)
        
        // Safe re-anchoring when display setup changes during active speech
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self,
                      let id = self.currentUtteranceId,
                      SpeechManager.shared.presentationState.utteranceId == id,
                      let screen = NSScreen.main ?? NSScreen.screens.first else { return }
                self.targetScreen = screen
                self.reanchorAndSize(for: SpeechManager.shared.presentationState.text, on: screen)
            }
            .store(in: &cancellables)
    }
    
    func handlePresentationStateChange(_ state: SpeechPresentationState) {
        let live = SpeechManager.shared.presentationState
        
        switch state.phase {
        case .speaking:
            // Gate incoming speaking event against LIVE utterance identity and phase
            guard live.utteranceId == state.utteranceId, live.phase == .speaking else {
                // Stale queued speaking event from an earlier cancelled/finished utterance: drop!
                return
            }
            
            autoDismissTask?.cancel()
            autoDismissTask = nil
            
            if state.utteranceId != currentUtteranceId {
                // Utterance start: capture target display once and anchor with measured height
                currentUtteranceId = state.utteranceId
                let screen = NSScreen.main ?? NSScreen.screens.first
                self.targetScreen = screen
                if let screen = screen {
                    reanchorAndSize(for: state.text, on: screen)
                }
                panel.orderFrontRegardless()
            }
            // Same speaking identity advancing word ranges does NOT re-anchor or orderFront!
            UIDiagnosticLogger.log(event: "caption speak")
            
        case .finished:
            // Gate incoming finished event against LIVE utterance identity, phase, and request
            guard live.utteranceId == state.utteranceId,
                  live.phase == .finished,
                  live.requestId == state.requestId else {
                // Stale finished event: drop!
                return
            }
            
            UIDiagnosticLogger.log(event: "caption finish")
            autoDismissTask?.cancel()
            let finishedId = state.utteranceId
            let finishedRequestId = state.requestId
            autoDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s auto-dismiss
                // Gate auto-dismiss completion against live state
                guard !Task.isCancelled,
                      let self = self,
                      self.currentUtteranceId == finishedId,
                      SpeechManager.shared.presentationState.utteranceId == finishedId,
                      SpeechManager.shared.presentationState.phase == .finished,
                      SpeechManager.shared.presentationState.requestId == finishedRequestId else {
                    return
                }
                self.hidePanel()
            }
            
        case .cancelled:
            // Gate incoming cancelled event against LIVE utterance identity and phase
            guard live.utteranceId == state.utteranceId,
                  live.phase == .cancelled,
                  (currentUtteranceId == nil || currentUtteranceId == state.utteranceId) else {
                // Stale cancelled event from an earlier utterance: drop!
                return
            }
            UIDiagnosticLogger.log(event: "caption cancel")
            hidePanel()
            
        case .idle:
            // Gate incoming idle event against LIVE phase
            guard live.phase == .idle else {
                // Stale idle event while speech is active or auto-dismissing: drop!
                return
            }
            hidePanel()
        }
    }
    
    public func hidePanel() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        currentUtteranceId = nil
        targetScreen = nil
        panel.orderOut(nil)
        UIDiagnosticLogger.log(event: "caption dismiss")
    }
    
    /// Pre-measures exact caption window height using NSAttributedString.boundingRect before reveal,
    /// bounded strictly to four visible lines matching CaptionView.lineLimit(4).
    public static func measureCaptionHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 80 }
        let baseFont = NSFont.systemFont(ofSize: 14.5, weight: .medium)
        let font = baseFont.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 14.5) } ?? baseFont
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2.5
        paragraphStyle.lineBreakMode = .byWordWrapping
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        
        // 300pt card width - 28pt h-padding - 18pt indicator = 254pt text width
        let maxTextWidth: CGFloat = 254
        
        // Measure 4-line boundary to honor CaptionView.lineLimit(4)
        let sample4Lines = NSAttributedString(string: "A\nB\nC\nD", attributes: attrs)
        let max4LinesHeight = ceil(sample4Lines.boundingRect(
            with: NSSize(width: maxTextWidth, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let measuredRect = attrStr.boundingRect(
            with: NSSize(width: maxTextWidth, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        
        let boundedTextHeight = min(ceil(measuredRect.height), max4LinesHeight)
        let cardHeight = max(boundedTextHeight + 24, 44) // 20pt v-padding + 4pt margin
        return cardHeight + 32 // 16pt top + 16pt bottom gutter
    }
    
    /// Re-anchors caption panel to active display top-right with 16pt margin and measured height.
    public func reanchorAndSize(for text: String, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 332
        let measuredHeight = CaptionPanelController.measureCaptionHeight(for: text)
        
        let clampedWidth = min(panelWidth, visible.width)
        let clampedHeight = min(measuredHeight, visible.height)
        
        let desiredX = visible.maxX - panelWidth
        let desiredY = visible.maxY - measuredHeight
        
        let x = max(visible.minX, min(desiredX, visible.maxX - clampedWidth))
        let y = max(visible.minY, min(desiredY, visible.maxY - clampedHeight))
        
        panel.setFrame(NSRect(x: x, y: y, width: clampedWidth, height: clampedHeight), display: true)
    }
}
