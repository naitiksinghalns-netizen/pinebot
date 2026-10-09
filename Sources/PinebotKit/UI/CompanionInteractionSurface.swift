import AppKit
import SwiftUI
import Combine

/// Transparent native NSView overlay handling AppKit screen-coordinate drag tracking,
/// event-time coordinate sampling, single accessible button traits, and hover state.
public struct CompanionInteractionSurface: NSViewRepresentable {
    public let motionController: CompanionMotionController
    public let onToggleChat: () -> Void
    public let onDragEnded: () -> Void
    
    public init(
        motionController: CompanionMotionController = .shared,
        onToggleChat: @escaping () -> Void,
        onDragEnded: @escaping () -> Void = {}
    ) {
        self.motionController = motionController
        self.onToggleChat = onToggleChat
        self.onDragEnded = onDragEnded
    }
    
    public func makeNSView(context: Context) -> CompanionInteractionNSView {
        let view = CompanionInteractionNSView()
        view.motionController = motionController
        view.onToggleChat = onToggleChat
        view.onDragEnded = onDragEnded
        return view
    }
    
    public func updateNSView(_ nsView: CompanionInteractionNSView, context: Context) {
        nsView.motionController = motionController
        nsView.onToggleChat = onToggleChat
        nsView.onDragEnded = onDragEnded
        if !motionController.isVisible {
            nsView.cancelSession()
        }
    }
}

/// Native AppKit NSView that intercepts pointer-down, drag, up, and hover events
/// with true event-time CoreGraphics to AppKit screen coordinate conversion.
public final class CompanionInteractionNSView: NSView {
    public var motionController: CompanionMotionController? {
        didSet {
            setupControllerObservers()
        }
    }
    public var onToggleChat: (() -> Void)?
    public var onDragEnded: (() -> Void)?
    
    private var trackingArea: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()
    
    // Per-interaction session tracking
    public private(set) var startAppKitPoint: CGPoint? = nil
    public private(set) var startPanelOrigin: CGPoint? = nil
    public private(set) var hasExceededThreshold: Bool = false
    public private(set) var isValidSession: Bool = false
    public private(set) var capturedInteractionGeneration: Int? = nil
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
    // MARK: - Controller & Screen Observers
    
    private func setupControllerObservers() {
        cancellables.removeAll()
        guard let mc = motionController else { return }
        
        mc.$interactionGeneration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, let liveMc = self.motionController else { return }
                if self.isValidSession, let captured = self.capturedInteractionGeneration, captured != liveMc.interactionGeneration {
                    self.cancelSession()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cancelSession()
            }
            .store(in: &cancellables)
    }
    
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelSession()
        }
    }
    
    public override func viewDidHide() {
        super.viewDidHide()
        cancelSession()
    }
    
    // MARK: - Event Coordinate Conversion
    
    /// Converts event-time CoreGraphics global screen coordinates to AppKit global screen coordinates (bottom-left origin).
    /// Returns nil if coordinates or window are missing; never falls back to NSEvent.mouseLocation.
    public func appKitScreenPoint(from event: NSEvent) -> CGPoint? {
        if let cgLoc = event.cgEvent?.location {
            let primaryHeight = ScreenCoordinateHelper.primaryScreenHeight()
            return ScreenCoordinateHelper.coreGraphicsToAppKit(point: cgLoc, screenHeight: primaryHeight)
        }
        guard let window = self.window else { return nil }
        let windowPoint = event.locationInWindow
        return window.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
    }
    
    // MARK: - Mouse Events
    
    public override func mouseDown(with event: NSEvent) {
        guard let window = self.window,
              let mc = motionController,
              mc.isVisible else {
            cancelSession()
            return
        }
        
        guard let screenPoint = appKitScreenPoint(from: event) else {
            cancelSession()
            return
        }
        
        startAppKitPoint = screenPoint
        startPanelOrigin = window.frame.origin
        hasExceededThreshold = false
        isValidSession = true
        
        // Begin press once on mouseDown
        mc.handlePointerDown()
        
        // Capture interaction generation token AFTER press begins
        capturedInteractionGeneration = mc.interactionGeneration
        
        mc.logDiagnostic("DOWN: screenPt=(\(Int(screenPoint.x)), \(Int(screenPoint.y))) origin=(\(Int(window.frame.origin.x)), \(Int(window.frame.origin.y))) gen=\(mc.interactionGeneration)")
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard isValidSession,
              let window = self.window,
              let mc = motionController,
              mc.isVisible,
              capturedInteractionGeneration == mc.interactionGeneration,
              let startPt = startAppKitPoint,
              let startOrigin = startPanelOrigin else {
            cancelSession()
            return
        }
        
        guard let currentPt = appKitScreenPoint(from: event) else {
            cancelSession()
            return
        }
        
        let deltaX = currentPt.x - startPt.x
        let deltaY = currentPt.y - startPt.y
        let distance = hypot(deltaX, deltaY)
        
        if distance >= CompanionMotionController.dragThreshold {
            hasExceededThreshold = true // One permanent exceeded flag even if pointer returns to start
        }
        
        if hasExceededThreshold {
            let rawOrigin = CGPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY)
            let targetScreen = CompanionMotionController.targetScreen(for: currentPt, fallback: window.screen)
            let clampedOrigin: CGPoint
            if let visible = targetScreen?.visibleFrame {
                clampedOrigin = CompanionMotionController.clamp(origin: rawOrigin, size: window.frame.size, within: visible)
            } else {
                clampedOrigin = rawOrigin
            }
            
            mc.logDiagnostic("DRAG: currentPt=(\(Int(currentPt.x)), \(Int(currentPt.y))) delta=(\(Int(deltaX)), \(Int(deltaY))) dist=\(String(format: "%.1f", distance)) newOrigin=(\(Int(clampedOrigin.x)), \(Int(clampedOrigin.y)))")
            
            window.setFrameOrigin(clampedOrigin)
            mc.notifyDragMoved(clampedOrigin: clampedOrigin)
        }
    }
    
    public override func mouseUp(with event: NSEvent) {
        guard isValidSession,
              let mc = motionController,
              mc.isVisible,
              capturedInteractionGeneration == mc.interactionGeneration,
              let startPt = startAppKitPoint else {
            cancelSession()
            return
        }
        
        guard let currentPt = appKitScreenPoint(from: event) else {
            cancelSession()
            return
        }
        
        let dist = hypot(currentPt.x - startPt.x, currentPt.y - startPt.y)
        mc.logDiagnostic("UP: currentPt=(\(Int(currentPt.x)), \(Int(currentPt.y))) dist=\(String(format: "%.1f", dist)) exceeded=\(hasExceededThreshold)")
        
        // Release press once on mouseUp
        mc.handlePointerUp()
        
        // An up after cancelled or exceeded threshold can NEVER click!
        let isClick = !hasExceededThreshold && (dist < CompanionMotionController.dragThreshold)
        
        if isClick {
            mc.logDiagnostic("ACTION: toggleChat")
            onToggleChat?()
        } else {
            mc.logDiagnostic("ACTION: dragEnded")
            onDragEnded?()
        }
        
        resetSession()
    }
    
    public func cancelSession() {
        if isValidSession {
            motionController?.logDiagnostic("CANCEL_SESSION")
        }
        let wasActive = isValidSession
        startAppKitPoint = nil
        startPanelOrigin = nil
        hasExceededThreshold = false
        isValidSession = false
        capturedInteractionGeneration = nil
        if wasActive {
            motionController?.cancelInteraction()
        }
    }
    
    private func resetSession() {
        let wasActive = isValidSession
        startAppKitPoint = nil
        startPanelOrigin = nil
        hasExceededThreshold = false
        isValidSession = false
        capturedInteractionGeneration = nil
        if wasActive {
            motionController?.resetDrag()
        }
    }
    
    // MARK: - Hover Tracking
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    
    public override func mouseEntered(with event: NSEvent) {
        motionController?.setHovered(true)
    }
    
    public override func mouseExited(with event: NSEvent) {
        motionController?.setHovered(false)
    }
    
    // MARK: - Single Accessible Target
    
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? { "Open Pinebot chat" }
    public override func accessibilityHelp() -> String? { "Activates the Pinebot companion panel and opens chat" }
    public override func accessibilityPerformPress() -> Bool {
        onToggleChat?()
        return true
    }
}
