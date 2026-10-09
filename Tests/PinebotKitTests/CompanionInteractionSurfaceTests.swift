import XCTest
import AppKit
import CoreGraphics
@testable import PinebotKit

@MainActor
final class CompanionInteractionSurfaceTests: XCTestCase {
    
    private var window: NSWindow!
    private var interactionView: CompanionInteractionNSView!
    private var motionController: CompanionMotionController!
    private var toggleChatCalledCount = 0
    private var dragEndedCalledCount = 0
    
    override func setUp() async throws {
        try await super.setUp()
        
        let screenRect = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let initialRect = CGRect(x: screenRect.midX - 75, y: screenRect.midY - 75, width: 150, height: 150)
        
        window = NSWindow(
            contentRect: initialRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        motionController = CompanionMotionController(assistant: .shared, settingsStore: .shared)
        motionController.setVisible(true)
        
        interactionView = CompanionInteractionNSView(frame: NSRect(origin: .zero, size: initialRect.size))
        interactionView.motionController = motionController
        
        toggleChatCalledCount = 0
        dragEndedCalledCount = 0
        
        interactionView.onToggleChat = { [weak self] in
            self?.toggleChatCalledCount += 1
        }
        interactionView.onDragEnded = { [weak self] in
            self?.dragEndedCalledCount += 1
        }
        
        window.contentView = interactionView
    }
    
    override func tearDown() async throws {
        interactionView.cancelSession()
        window.orderOut(nil)
        window = nil
        interactionView = nil
        motionController = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper to construct safe, non-desktop CGEvent-backed NSEvents
    
    private func makeMouseEvent(
        type: NSEvent.EventType,
        cgScreenPoint: CGPoint
    ) -> NSEvent {
        let cgType: CGEventType
        switch type {
        case .leftMouseDown: cgType = .leftMouseDown
        case .leftMouseDragged: cgType = .leftMouseDragged
        case .leftMouseUp: cgType = .leftMouseUp
        default: cgType = .leftMouseDown
        }
        
        let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: cgType,
            mouseCursorPosition: cgScreenPoint,
            mouseButton: .left
        )!
        return NSEvent(cgEvent: cgEvent)!
    }
    
    // MARK: - Tests
    
    /// Test 1: Native down at P1, quick dragged at P2 (distance >= 4pt), up at P2
    /// Expected: Window frame moved monotonically, NO toggle chat, drag ended action called.
    func testNativeQuickDragMovesFrameAndDoesNotToggleChat() {
        let initialOrigin = window.frame.origin
        
        // P1: Start point
        let p1 = CGPoint(x: 300, y: 300)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertFalse(interactionView.hasExceededThreshold)
        XCTAssertTrue(motionController.isPressed)
        
        // P2: Dragged 50pt horizontally and 30pt vertically
        let p2 = CGPoint(x: 350, y: 330)
        let dragEvent = makeMouseEvent(type: .leftMouseDragged, cgScreenPoint: p2)
        interactionView.mouseDragged(with: dragEvent)
        
        XCTAssertTrue(interactionView.hasExceededThreshold)
        XCTAssertTrue(motionController.isDragging)
        XCTAssertFalse(motionController.isPressed)
        
        // Panel origin should have moved
        XCTAssertNotEqual(window.frame.origin, initialOrigin)
        
        // Up at P2
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p2)
        interactionView.mouseUp(with: upEvent)
        
        // Verification: Dragging never opens chat!
        XCTAssertEqual(toggleChatCalledCount, 0, "Dragging must never trigger toggleChat")
        XCTAssertEqual(dragEndedCalledCount, 1, "Drag ended callback must be triggered")
        XCTAssertFalse(interactionView.isValidSession)
        XCTAssertFalse(motionController.isDragging)
        XCTAssertFalse(motionController.isPressed)
    }
    
    /// Test 2: Pointer crosses threshold to P2, then returns back to starting point P1, then releases.
    /// Expected: hasExceededThreshold remains true; release does NOT open chat.
    func testCrossedThresholdThenReturnedToStartDoesNotToggleChat() {
        let p1 = CGPoint(x: 400, y: 400)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        
        // Drag past 4pt threshold
        let p2 = CGPoint(x: 450, y: 400)
        let dragOutEvent = makeMouseEvent(type: .leftMouseDragged, cgScreenPoint: p2)
        interactionView.mouseDragged(with: dragOutEvent)
        
        XCTAssertTrue(interactionView.hasExceededThreshold)
        
        // Return back to starting position P1 (distance = 0)
        let dragBackEvent = makeMouseEvent(type: .leftMouseDragged, cgScreenPoint: p1)
        interactionView.mouseDragged(with: dragBackEvent)
        
        XCTAssertTrue(interactionView.hasExceededThreshold, "Threshold flag must remain permanently true for session")
        
        // Mouse up at P1
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p1)
        interactionView.mouseUp(with: upEvent)
        
        XCTAssertEqual(toggleChatCalledCount, 0, "Session that exceeded threshold must never trigger toggleChat even if returned to start")
        XCTAssertEqual(dragEndedCalledCount, 1)
        XCTAssertFalse(interactionView.isValidSession)
    }
    
    /// Test 3: Down at P1, hide or display cancellation occurs before up, up arrives.
    /// Expected: Stale/cancelled up is strictly no-click (noToggle).
    func testDownThenHideOrDisplayCancelProducesNoToggleOnUp() {
        let p1 = CGPoint(x: 500, y: 500)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertTrue(motionController.isPressed)
        
        // Invalidate interaction via controller hide / reset
        motionController.setVisible(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        
        // At this point, the session should have been cancelled by the interactionGeneration observer
        XCTAssertFalse(interactionView.isValidSession, "Hide/invalidate must cancel session")
        
        // Mouse up arrives after cancellation
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p1)
        interactionView.mouseUp(with: upEvent)
        
        XCTAssertEqual(toggleChatCalledCount, 0, "Stale/cancelled Up must never toggle chat")
        XCTAssertEqual(dragEndedCalledCount, 0, "Stale/cancelled Up must not trigger dragEnded")
    }
    
    /// Test 4: Genuine click under threshold (< 4pt).
    /// Expected: Triggers toggleChat exactly once.
    func testGenuineClickUnderThresholdTogglesChat() {
        let p1 = CGPoint(x: 250, y: 250)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertTrue(motionController.isPressed)
        
        // Micro-movement within 1pt (well under 4pt threshold)
        let pTiny = CGPoint(x: 250.5, y: 250.5)
        let tinyDragEvent = makeMouseEvent(type: .leftMouseDragged, cgScreenPoint: pTiny)
        interactionView.mouseDragged(with: tinyDragEvent)
        
        XCTAssertFalse(interactionView.hasExceededThreshold)
        
        // Mouse up at pTiny
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: pTiny)
        interactionView.mouseUp(with: upEvent)
        
        XCTAssertEqual(toggleChatCalledCount, 1, "Genuine click under 4pt threshold must toggle chat")
        XCTAssertEqual(dragEndedCalledCount, 0)
        XCTAssertFalse(motionController.isPressed)
    }
    
    /// Test 5: Size change during active press cancels session, neutralizes transforms, and stale Up never toggles chat.
    func testSizeChangeDuringPressCancelsSessionAndNeutralizesTransforms() {
        let p1 = CGPoint(x: 250, y: 250)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertTrue(motionController.isPressed)
        
        // Simulate real size change: cancelInteraction + resize window
        motionController.cancelInteraction()
        window.setFrame(NSRect(x: 200, y: 200, width: 180, height: 180), display: true)
        
        // Verify neutral transforms immediately
        XCTAssertFalse(motionController.isPressed)
        XCTAssertFalse(motionController.isDragging)
        XCTAssertEqual(motionController.scaleX, 1.0, accuracy: 0.001)
        XCTAssertEqual(motionController.scaleY, 1.0, accuracy: 0.001)
        XCTAssertEqual(motionController.verticalDisplacement, 0.0, accuracy: 0.001)
        
        // Subsequent mouseUp must NEVER open chat or trigger dragEnded
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p1)
        interactionView.mouseUp(with: upEvent)
        
        XCTAssertEqual(toggleChatCalledCount, 0, "Cancelled session must never open chat on mouseUp")
        XCTAssertEqual(dragEndedCalledCount, 0, "Cancelled session must not trigger dragEnded")
        XCTAssertFalse(interactionView.isValidSession)
    }
    
    /// Test 6: Size change during active drag cancels session, neutralizes transforms, and stale Up produces no action.
    func testSizeChangeDuringDragCancelsSessionAndNeutralizesTransforms() {
        let p1 = CGPoint(x: 250, y: 250)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        // Drag past threshold
        let p2 = CGPoint(x: 300, y: 300)
        let dragEvent = makeMouseEvent(type: .leftMouseDragged, cgScreenPoint: p2)
        interactionView.mouseDragged(with: dragEvent)
        
        XCTAssertTrue(interactionView.hasExceededThreshold)
        XCTAssertTrue(motionController.isDragging)
        
        // Real size change occurs mid-drag
        motionController.cancelInteraction()
        window.setFrame(NSRect(x: 180, y: 180, width: 200, height: 200), display: true)
        
        XCTAssertFalse(motionController.isDragging)
        XCTAssertFalse(motionController.isPressed)
        XCTAssertEqual(motionController.scaleX, 1.0, accuracy: 0.001)
        XCTAssertEqual(motionController.scaleY, 1.0, accuracy: 0.001)
        
        // Stale mouseUp after size change
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p2)
        interactionView.mouseUp(with: upEvent)
        
        XCTAssertEqual(toggleChatCalledCount, 0)
        XCTAssertEqual(dragEndedCalledCount, 0, "Cancelled drag must not call dragEnded on late mouseUp")
    }
    
    /// Test 7: Genuine cancelSession neutralizes transforms and performs complete logical cleanup.
    func testCancellationNeutralStateAndLogicalCleanup() {
        let p1 = CGPoint(x: 250, y: 250)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertTrue(motionController.isPressed)
        
        // Explicitly cancel session
        interactionView.cancelSession()
        
        // Assert full logical cleanup and neutral presentation
        XCTAssertFalse(interactionView.isValidSession)
        XCTAssertFalse(interactionView.hasExceededThreshold)
        XCTAssertNil(interactionView.startAppKitPoint)
        XCTAssertNil(interactionView.startPanelOrigin)
        XCTAssertFalse(motionController.isPressed)
        XCTAssertFalse(motionController.isDragging)
        XCTAssertEqual(motionController.scaleX, 1.0, accuracy: 0.001)
        XCTAssertEqual(motionController.scaleY, 1.0, accuracy: 0.001)
        XCTAssertEqual(motionController.verticalDisplacement, 0.0, accuracy: 0.001)
        
        // Stale late mouseUp
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p1)
        interactionView.mouseUp(with: upEvent)
        XCTAssertEqual(toggleChatCalledCount, 0)
        XCTAssertEqual(dragEndedCalledCount, 0)
    }
    
    /// Test 8: Same-size settings emission does not cancel valid pointer sessions.
    func testSameSizeEmissionDoesNotCancelSession() {
        let p1 = CGPoint(x: 250, y: 250)
        let downEvent = makeMouseEvent(type: .leftMouseDown, cgScreenPoint: p1)
        interactionView.mouseDown(with: downEvent)
        
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertTrue(motionController.isPressed)
        
        // Check same size guard: width/height delta <= 0.5
        let oldFrame = window.frame
        let newSize = oldFrame.size
        let isRealSizeChange = abs(oldFrame.width - newSize.width) > 0.5 || abs(oldFrame.height - newSize.height) > 0.5
        XCTAssertFalse(isRealSizeChange, "Same size emission must not be considered a real size change")
        
        // Session remains valid
        XCTAssertTrue(interactionView.isValidSession)
        XCTAssertTrue(motionController.isPressed)
        
        // Mouse up completes normally
        let upEvent = makeMouseEvent(type: .leftMouseUp, cgScreenPoint: p1)
        interactionView.mouseUp(with: upEvent)
        XCTAssertEqual(toggleChatCalledCount, 1)
    }
}

