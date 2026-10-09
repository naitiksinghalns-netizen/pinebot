import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// Represents the coordinate space of a captured display, mapping between image pixel space,
/// global CoreGraphics points, and global AppKit points across single and multi-display setups
/// with arbitrary (positive, zero, or negative) origins, Retina scaling, and downsampling.
public struct DisplayCoordinateSpace: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    /// Frame of the display in global CoreGraphics coordinates (points, top-left origin of primary screen).
    public let globalCoreGraphicsFrame: CGRect
    /// Frame of the display in global AppKit coordinates (points, bottom-left origin of primary screen).
    public let globalAppKitFrame: CGRect
    /// Height of the primary display in points, used for AppKit <-> CoreGraphics vertical flipping.
    public let primaryScreenHeight: CGFloat
    /// Native display backing scale factor (e.g., 2.0 for Retina, 1.0 for standard).
    public let backingScaleFactor: CGFloat
    /// Dimensions in pixels of the captured image buffer (after any scaling or downsampling).
    public let capturedPixelSize: CGSize
    
    public init(
        displayID: CGDirectDisplayID,
        globalCoreGraphicsFrame: CGRect,
        globalAppKitFrame: CGRect,
        primaryScreenHeight: CGFloat,
        backingScaleFactor: CGFloat,
        capturedPixelSize: CGSize
    ) {
        self.displayID = displayID
        self.globalCoreGraphicsFrame = globalCoreGraphicsFrame
        self.globalAppKitFrame = globalAppKitFrame
        self.primaryScreenHeight = primaryScreenHeight
        self.backingScaleFactor = backingScaleFactor
        self.capturedPixelSize = capturedPixelSize
    }
    
    /// Effective scale factor mapping points in the display's global CoreGraphics frame to captured image pixels.
    public var effectiveScaleX: CGFloat {
        guard globalCoreGraphicsFrame.width > 0 else { return 1.0 }
        return capturedPixelSize.width / globalCoreGraphicsFrame.width
    }
    
    /// Effective scale factor mapping points in the display's global CoreGraphics frame to captured image pixels.
    public var effectiveScaleY: CGFloat {
        guard globalCoreGraphicsFrame.height > 0 else { return 1.0 }
        return capturedPixelSize.height / globalCoreGraphicsFrame.height
    }
    
    // MARK: - Pixel <-> Global CoreGraphics
    
    /// Maps a pixel coordinate `(px, py)` in the captured image buffer to a point in global CoreGraphics space.
    public func pixelToGlobalCoreGraphics(pixel: CGPoint) -> CGPoint {
        let x = globalCoreGraphicsFrame.origin.x + (pixel.x / effectiveScaleX)
        let y = globalCoreGraphicsFrame.origin.y + (pixel.y / effectiveScaleY)
        return CGPoint(x: x, y: y)
    }
    
    /// Maps a global CoreGraphics point `(cgX, cgY)` to a pixel coordinate in the captured image buffer.
    public func globalCoreGraphicsToPixel(point: CGPoint) -> CGPoint {
        let px = (point.x - globalCoreGraphicsFrame.origin.x) * effectiveScaleX
        let py = (point.y - globalCoreGraphicsFrame.origin.y) * effectiveScaleY
        return CGPoint(x: px, y: py)
    }
    
    /// Maps a pixel rectangle in the captured image buffer to global CoreGraphics rectangle.
    public func pixelRectToGlobalCoreGraphics(pixelRect: CGRect) -> CGRect {
        let origin = pixelToGlobalCoreGraphics(pixel: pixelRect.origin)
        let width = pixelRect.width / effectiveScaleX
        let height = pixelRect.height / effectiveScaleY
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }
    
    /// Maps a global CoreGraphics rectangle to a pixel rectangle in the captured image buffer.
    public func globalCoreGraphicsToPixelRect(cgRect: CGRect) -> CGRect {
        let origin = globalCoreGraphicsToPixel(point: cgRect.origin)
        let width = cgRect.width * effectiveScaleX
        let height = cgRect.height * effectiveScaleY
        return CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }
    
    // MARK: - Pixel <-> Global AppKit
    
    /// Maps a pixel coordinate in the captured image buffer to global AppKit coordinates (bottom-left origin).
    public func pixelToGlobalAppKit(pixel: CGPoint) -> CGPoint {
        let cgPoint = pixelToGlobalCoreGraphics(pixel: pixel)
        return ScreenCoordinateHelper.coreGraphicsToAppKit(point: cgPoint, screenHeight: primaryScreenHeight)
    }
    
    /// Maps a global AppKit point (bottom-left origin) to a pixel coordinate in the captured image buffer.
    public func globalAppKitToPixel(point: CGPoint) -> CGPoint {
        let cgPoint = ScreenCoordinateHelper.appKitToCoreGraphics(point: point, screenHeight: primaryScreenHeight)
        return globalCoreGraphicsToPixel(point: cgPoint)
    }
    
    /// Maps a pixel rectangle in the captured image buffer to global AppKit rectangle.
    public func pixelRectToGlobalAppKit(pixelRect: CGRect) -> CGRect {
        let cgRect = pixelRectToGlobalCoreGraphics(pixelRect: pixelRect)
        return ScreenCoordinateHelper.coreGraphicsToAppKit(rect: cgRect, screenHeight: primaryScreenHeight)
    }
    
    /// Maps a global AppKit rectangle to a pixel rectangle in the captured image buffer.
    public func globalAppKitToPixelRect(appKitRect: CGRect) -> CGRect {
        let cgRect = ScreenCoordinateHelper.appKitToCoreGraphics(rect: appKitRect, screenHeight: primaryScreenHeight)
        return globalCoreGraphicsToPixelRect(cgRect: cgRect)
    }
}

/// Helper for translating coordinates between macOS AppKit (bottom-left origin)
/// and CoreGraphics/ScreenCapture/Retina (top-left origin), and clamping across multi-display layouts.
public struct ScreenCoordinateHelper {
    
    /// Returns the primary display height in points for coordinate space inversions.
    public static func primaryScreenHeight() -> CGFloat {
        #if canImport(AppKit)
        if let first = NSScreen.screens.first {
            return first.frame.height
        }
        if let main = NSScreen.main {
            return main.frame.height
        }
        #endif
        return 1080.0
    }
    
    /// Converts a point from AppKit bottom-left origin coordinates to CoreGraphics top-left origin coordinates.
    public static func appKitToCoreGraphics(point: CGPoint, screenHeight: CGFloat) -> CGPoint {
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
    
    /// Converts a point from CoreGraphics top-left origin coordinates to AppKit bottom-left origin coordinates.
    public static func coreGraphicsToAppKit(point: CGPoint, screenHeight: CGFloat) -> CGPoint {
        return CGPoint(x: point.x, y: screenHeight - point.y)
    }
    
    /// Converts a rectangle from AppKit coordinates to CoreGraphics coordinates.
    public static func appKitToCoreGraphics(rect: CGRect, screenHeight: CGFloat) -> CGRect {
        let flippedY = screenHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }
    
    /// Converts a rectangle from CoreGraphics coordinates to AppKit coordinates.
    public static func coreGraphicsToAppKit(rect: CGRect, screenHeight: CGFloat) -> CGRect {
        let flippedY = screenHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }
    
    /// Computes the global CoreGraphics frame for a display given its AppKit frame.
    public static func displayBoundsInCoreGraphics(from appKitScreenFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        return appKitToCoreGraphics(rect: appKitScreenFrame, screenHeight: primaryScreenHeight)
    }
    
    /// Scales coordinates by the display's Retina backing scale factor.
    public static func scaleForRetina(point: CGPoint, scale: CGFloat) -> CGPoint {
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }
    
    /// Unscales coordinates from physical Retina pixel dimensions to logical AppKit points.
    public static func unscaleFromRetina(point: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return point }
        return CGPoint(x: point.x / scale, y: point.y / scale)
    }
    
    /// Clamps an item frame to stay fully visible inside screen bounds, with a margin padding.
    public static func clamp(point: CGPoint, size: CGSize, within screenBounds: CGRect, margin: CGFloat = 8.0) -> CGPoint {
        let minX = screenBounds.minX + margin
        let maxX = screenBounds.maxX - size.width - margin
        let minY = screenBounds.minY + margin
        let maxY = screenBounds.maxY - size.height - margin
        
        let clampedX: CGFloat
        if maxX < minX {
            clampedX = minX
        } else {
            clampedX = min(max(point.x, minX), maxX)
        }
        
        let clampedY: CGFloat
        if maxY < minY {
            clampedY = minY
        } else {
            clampedY = min(max(point.y, minY), maxY)
        }
        
        return CGPoint(x: clampedX, y: clampedY)
    }
}
