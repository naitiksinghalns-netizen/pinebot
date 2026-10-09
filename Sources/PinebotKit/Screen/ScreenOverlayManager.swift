import AppKit
import SwiftUI
import CoreGraphics

/// Types of visual annotations that can be rendered on the transparent screen overlay.
public enum OverlayAnnotation: Identifiable, Sendable, Equatable {
    case arrow(id: UUID = UUID(), displayId: CGDirectDisplayID, from: CGPoint, to: CGPoint, color: Color = .orange, label: String? = nil)
    case circle(id: UUID = UUID(), displayId: CGDirectDisplayID, center: CGPoint, radius: CGFloat, color: Color = .orange, label: String? = nil)
    case box(id: UUID = UUID(), displayId: CGDirectDisplayID, rect: CGRect, color: Color = .orange, label: String? = nil)
    case label(id: UUID = UUID(), displayId: CGDirectDisplayID, point: CGPoint, text: String, color: Color = .orange)
    
    public var id: UUID {
        switch self {
        case .arrow(let id, _, _, _, _, _): return id
        case .circle(let id, _, _, _, _, _): return id
        case .box(let id, _, _, _, _): return id
        case .label(let id, _, _, _, _): return id
        }
    }
    
    public var displayId: CGDirectDisplayID {
        switch self {
        case .arrow(_, let d, _, _, _, _): return d
        case .circle(_, let d, _, _, _, _): return d
        case .box(_, let d, _, _, _): return d
        case .label(_, let d, _, _, _): return d
        }
    }
}

/// Canvas view for drawing annotations on a specific display's overlay window.
/// Strictly non-interactive (allowsHitTesting false) so the underlying desktop remains fully clickable.
public struct DisplayOverlayCanvas: View {
    public let displayId: CGDirectDisplayID
    public let annotations: [OverlayAnnotation]
    
    public init(displayId: CGDirectDisplayID, annotations: [OverlayAnnotation]) {
        self.displayId = displayId
        self.annotations = annotations
    }
    
    public var body: some View {
        Canvas { context, size in
            let displayItems = annotations.filter { $0.displayId == displayId }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            
            for item in displayItems {
                switch item {
                case .arrow(_, _, let from, let to, let color, let label):
                    drawArrow(context: context, from: from, to: to, color: color, label: label, reduceMotion: reduceMotion)
                case .circle(_, _, let center, let radius, let color, let label):
                    drawCircle(context: context, center: center, radius: radius, color: color, label: label)
                case .box(_, _, let rect, let color, let label):
                    drawBox(context: context, rect: rect, color: color, label: label)
                case .label(_, _, let point, let text, let color):
                    drawLabel(context: context, point: point, text: text, color: color)
                }
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color, label: String?, reduceMotion: Bool) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        
        let dx = to.x - from.x
        let dy = to.y - from.y
        let angle = atan2(dy, dx)
        let headLength: CGFloat = 16.0
        let headAngle: CGFloat = .pi / 6
        
        let p1 = CGPoint(
            x: to.x - headLength * cos(angle - headAngle),
            y: to.y - headLength * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: to.x - headLength * cos(angle + headAngle),
            y: to.y - headLength * sin(angle + headAngle)
        )
        
        var headPath = Path()
        headPath.move(to: to)
        headPath.addLine(to: p1)
        headPath.addLine(to: p2)
        headPath.closeSubpath()
        
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 2.5)
        context.fill(headPath, with: .color(color))
        
        if let label = label, !label.isEmpty {
            let labelPoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 14)
            context.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(color), at: labelPoint)
        }
    }
    
    private func drawCircle(context: GraphicsContext, center: CGPoint, radius: CGFloat, color: Color, label: String?) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 2.5)
        
        if let label = label, !label.isEmpty {
            let labelPoint = CGPoint(x: center.x, y: center.y - radius - 12)
            context.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(color), at: labelPoint)
        }
    }
    
    private func drawBox(context: GraphicsContext, rect: CGRect, color: Color, label: String?) {
        let path = Path(roundedRect: rect, cornerRadius: 6)
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 2.5)
        
        if let label = label, !label.isEmpty {
            let labelPoint = CGPoint(x: rect.midX, y: max(14, rect.minY - 12))
            context.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(color), at: labelPoint)
        }
    }
    
    private func drawLabel(context: GraphicsContext, point: CGPoint, text: String, color: Color) {
        context.draw(Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(color), at: point)
    }
}

/// Manages transparent, click-through overlay windows across displays.
/// Overlay windows have `ignoresMouseEvents = true` so the entire desktop remains clickable.
@MainActor
public final class ScreenOverlayManager: ObservableObject {
    public static let shared = ScreenOverlayManager()
    
    @Published public private(set) var annotations: [OverlayAnnotation] = []
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var ttlTasks: [UUID: Task<Void, Never>] = [:]
    
    public init() {}
    
    /// Adds an annotation partitioned by display ID with local screen coordinates.
    /// Optionally schedules an auto-fade after `ttlSeconds`.
    public func addAnnotation(_ annotation: OverlayAnnotation, ttlSeconds: Double? = nil) {
        annotations.append(annotation)
        ensureOverlayVisible()
        
        if let ttl = ttlSeconds, ttl > 0 {
            let id = annotation.id
            ttlTasks[id]?.cancel()
            ttlTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.removeAnnotation(id: id)
            }
        }
    }
    
    /// Adds an annotation from model-observed normalized target coordinates on an observation.
    public func addAnnotationForObservation(
        type: String, // "box", "circle", "arrow"
        observation: ComputerObservation,
        xNorm: Double,
        yNorm: Double,
        widthNorm: Double? = nil,
        heightNorm: Double? = nil,
        label: String? = nil,
        ttlSeconds: Double? = 10.0
    ) {
        guard let screen = NSScreen.screens.first(where: {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
            return id == observation.displayId
        }) ?? NSScreen.main else {
            return
        }
        
        let primaryHeight = observation.coordinateSpace.primaryScreenHeight
        let cgFrame = observation.coordinateSpace.globalCoreGraphicsFrame
        
        // Transform normalized coords to CoreGraphics global point
        let cgX = cgFrame.origin.x + CGFloat(xNorm) * cgFrame.width
        let cgY = cgFrame.origin.y + CGFloat(yNorm) * cgFrame.height
        let cgPoint = CGPoint(x: cgX, y: cgY)
        
        // Transform global CG to screen-local AppKit coords for this window
        let localPoint = ScreenCaptureManager.globalCGToAppKitScreenLocal(
            cgPoint: cgPoint,
            screen: screen,
            primaryScreenHeight: primaryHeight
        )
        
        let color: Color = .orange
        let annotation: OverlayAnnotation
        
        switch type {
        case "circle":
            let r: CGFloat = widthNorm != nil ? CGFloat(widthNorm!) * screen.frame.width / 2.0 : 32.0
            annotation = .circle(displayId: observation.displayId, center: localPoint, radius: r, color: color, label: label)
        case "arrow":
            let start = CGPoint(x: localPoint.x - 40, y: localPoint.y + 40)
            annotation = .arrow(displayId: observation.displayId, from: start, to: localPoint, color: color, label: label)
        default: // "box"
            let w: CGFloat = widthNorm != nil ? CGFloat(widthNorm!) * screen.frame.width : 64.0
            let h: CGFloat = heightNorm != nil ? CGFloat(heightNorm!) * screen.frame.height : 36.0
            let rect = CGRect(x: localPoint.x - w / 2, y: localPoint.y - h / 2, width: w, height: h)
            annotation = .box(displayId: observation.displayId, rect: rect, color: color, label: label)
        }
        
        addAnnotation(annotation, ttlSeconds: ttlSeconds)
    }
    
    /// Highlights a specific resolved CoreGraphics point with a box on the transparent overlay.
    public func highlightObservationTarget(
        _ observation: ComputerObservation,
        cgPoint: CGPoint,
        widthNorm: Double? = nil,
        heightNorm: Double? = nil,
        label: String? = nil,
        ttlSeconds: Double? = 10.0
    ) {
        guard let screen = NSScreen.screens.first(where: {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
            return id == observation.displayId
        }) ?? NSScreen.main else {
            return
        }
        
        let primaryHeight = observation.coordinateSpace.primaryScreenHeight
        let localPoint = ScreenCaptureManager.globalCGToAppKitScreenLocal(
            cgPoint: cgPoint,
            screen: screen,
            primaryScreenHeight: primaryHeight
        )
        
        let w: CGFloat = widthNorm != nil ? CGFloat(widthNorm!) * screen.frame.width : 64.0
        let h: CGFloat = heightNorm != nil ? CGFloat(heightNorm!) * screen.frame.height : 36.0
        let rect = CGRect(x: localPoint.x - w / 2, y: localPoint.y - h / 2, width: w, height: h)
        let annotation = OverlayAnnotation.box(displayId: observation.displayId, rect: rect, color: .orange, label: label)
        addAnnotation(annotation, ttlSeconds: ttlSeconds)
    }
    
    /// Removes a specific annotation.
    public func removeAnnotation(id: UUID) {
        ttlTasks[id]?.cancel()
        ttlTasks.removeValue(forKey: id)
        annotations.removeAll { $0.id == id }
        if annotations.isEmpty {
            hideOverlay()
        }
    }
    
    /// Clears all active annotations and hides overlay windows.
    public func clear() {
        for (_, task) in ttlTasks {
            task.cancel()
        }
        ttlTasks.removeAll()
        annotations.removeAll()
        hideOverlay()
    }
    
    private func ensureOverlayVisible() {
        createOrUpdateWindows()
        for (_, win) in overlayWindows {
            win.orderFront(nil)
        }
    }
    
    private func hideOverlay() {
        for (_, win) in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
    
    private func createOrUpdateWindows() {
        var activeDisplayIds = Set<CGDirectDisplayID>()
        
        for screen in NSScreen.screens {
            let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            activeDisplayIds.insert(displayId)
            
            if let existing = overlayWindows[displayId] {
                if existing.frame != screen.frame {
                    existing.setFrame(screen.frame, display: true)
                }
                continue
            }
            
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.ignoresMouseEvents = true // Non-blocking: entire desktop remains clickable
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            
            let hosting = NSHostingView(
                rootView: DisplayOverlayCanvas(
                    displayId: displayId,
                    annotations: annotations
                )
            )
            window.contentView = hosting
            overlayWindows[displayId] = window
        }
        
        // Remove windows for disconnected displays
        overlayWindows = overlayWindows.filter { activeDisplayIds.contains($0.key) }
    }
}
