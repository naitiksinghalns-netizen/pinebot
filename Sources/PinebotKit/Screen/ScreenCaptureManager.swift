import AppKit
import CoreGraphics
import ScreenCaptureKit
import ApplicationServices

/// Errors occurring during coordinate resolution and bounds validation.
public enum ComputerCoordinateError: Error, LocalizedError, Sendable, Equatable {
    case staleObservation(expected: UUID, actual: UUID)
    case displayMismatch(expected: CGDirectDisplayID, actual: CGDirectDisplayID)
    case outOfBounds(xNorm: Double, yNorm: Double)
    case elementNotFound(String)
    case permissionsRequired([String])
    
    public var errorDescription: String? {
        switch self {
        case .staleObservation(let exp, let act):
            return "Stale observation: action targets observation \(act), but current observation is \(exp)."
        case .displayMismatch(let exp, let act):
            return "Display mismatch: action targets display \(act), but observation is on display \(exp)."
        case .outOfBounds(let x, let y):
            return "Coordinates out of bounds: (\(x), \(y)) must be normalized within [0.0, 1.0]. Will not execute out-of-bounds target."
        case .elementNotFound(let id):
            return "Observed element '\(id)' was not found in the current observation."
        case .permissionsRequired(let missing):
            return "Missing required macOS permissions: \(missing.joined(separator: ", ")). Please grant permissions in System Settings."
        }
    }
}

/// Protocol for capturing rich desktop observations.
public protocol ComputerObserverProtocol: Sendable {
    func captureObservation(
        displayID: CGDirectDisplayID?,
        maxDimension: CGFloat,
        excludePinebotWindows: Bool
    ) async throws -> ComputerObservation
}

/// Screen capture manager using ScreenCaptureKit (macOS 14+ SDK) with CoreGraphics fallback,
/// permission handling, Retina scaling, downsampling, and coordinate space mapping.
public final class ScreenCaptureManager: ComputerObserverProtocol, @unchecked Sendable {
    public static let shared = ScreenCaptureManager()
    
    public init() {}
    
    /// Checks if screen capture access is granted by macOS.
    public var hasScreenCapturePermission: Bool {
        return CGPreflightScreenCaptureAccess()
    }
    
    /// Checks accessibility permission.
    public var hasAccessibilityPermission: Bool {
        return AXIsProcessTrusted()
    }
    
    /// Returns the comprehensive permission state.
    public func checkPermissions() -> ComputerPermissionState {
        return ComputerPermissionState(
            screenRecordingGranted: hasScreenCapturePermission,
            accessibilityGranted: hasAccessibilityPermission
        )
    }
    
    /// Prompts the user for Screen Recording permission in System Settings.
    @discardableResult
    public func requestScreenCapturePermission() -> Bool {
        return CGRequestScreenCaptureAccess()
    }
    
    /// Creates a DisplayCoordinateSpace struct for a given NSScreen and captured image pixel dimensions.
    public func coordinateSpace(for screen: NSScreen, capturedPixelSize: CGSize) -> DisplayCoordinateSpace {
        let primaryHeight = ScreenCoordinateHelper.primaryScreenHeight()
        let appKitFrame = screen.frame
        let cgFrame = ScreenCoordinateHelper.displayBoundsInCoreGraphics(from: appKitFrame, primaryScreenHeight: primaryHeight)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
        let backingScale = screen.backingScaleFactor
        
        return DisplayCoordinateSpace(
            displayID: displayID,
            globalCoreGraphicsFrame: cgFrame,
            globalAppKitFrame: appKitFrame,
            primaryScreenHeight: primaryHeight,
            backingScaleFactor: backingScale,
            capturedPixelSize: capturedPixelSize
        )
    }
    
    /// Asynchronously captures a rich ComputerObservation of the display and foreground app state.
    /// Excludes Pinebot overlay and panel windows to prevent visual occlusion.
    public func captureObservation(
        displayID: CGDirectDisplayID? = nil,
        maxDimension: CGFloat = 1280.0,
        excludePinebotWindows: Bool = true
    ) async throws -> ComputerObservation {
        let perms = checkPermissions()
        guard perms.screenRecordingGranted else {
            throw ComputerCoordinateError.permissionsRequired(perms.missingPermissions)
        }
        
        let targetDisplayId = displayID ?? CGMainDisplayID()
        
        // 1. Capture screen via ScreenCaptureKit or fallback
        var capturedImage: NSImage
        var capturedSpace: DisplayCoordinateSpace
        
        if #available(macOS 14.0, *) {
            do {
                let sck = try await captureDisplaySCK(
                    displayID: targetDisplayId,
                    downsampleMax: maxDimension,
                    excludePinebotWindows: excludePinebotWindows
                )
                capturedImage = sck.image
                capturedSpace = sck.space
            } catch {
                // Fall back to CGWindowListCreateImage if SCK fails
                guard let fallback = captureMainScreenWithSpace() else {
                    throw error
                }
                capturedImage = fallback.image
                capturedSpace = fallback.space
            }
        } else {
            guard let fallback = captureMainScreenWithSpace() else {
                throw NSError(domain: "PinebotScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to capture display."])
            }
            capturedImage = fallback.image
            capturedSpace = fallback.space
        }
        
        // 2. Compress to JPEG bytes for model consumption
        var jpegData: Data? = nil
        if let tiff = capturedImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
        
        // 3. Inspect frontmost application
        let frontApp = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }
        let pid = frontApp?.processIdentifier
        let appName = frontApp?.localizedName
        
        // 4. Background read bounded AX tree
        var axElements: [AXElementNode] = []
        if let p = pid, perms.accessibilityGranted {
            axElements = await AXTreeReader.readFrontmostAXTree(
                pid: p,
                displayFrame: capturedSpace.globalCoreGraphicsFrame
            )
        }
        
        return ComputerObservation(
            id: UUID(),
            timestamp: Date(),
            foregroundPID: pid,
            foregroundApp: appName,
            foregroundWindow: axElements.first?.title,
            permissionState: perms,
            axElements: axElements,
            displayId: capturedSpace.displayID,
            image: capturedImage,
            imageBytes: jpegData,
            capturedPixelSize: capturedSpace.capturedPixelSize,
            coordinateSpace: capturedSpace
        )
    }
    
    /// Captures the specified display using ScreenCaptureKit (macOS 14+) with asynchronous capture.
    @available(macOS 14.0, *)
    public func captureDisplaySCK(
        displayID: CGDirectDisplayID,
        downsampleMax: CGFloat? = nil,
        excludePinebotWindows: Bool = true
    ) async throws -> (image: NSImage, space: DisplayCoordinateSpace) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw NSError(domain: "PinebotScreenCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found in ScreenCaptureKit."])
        }
        
        var excludedWindows: [SCWindow] = []
        if excludePinebotWindows {
            let pinebotPIDs = [ProcessInfo.processInfo.processIdentifier]
            excludedWindows = content.windows.filter { win in
                pinebotPIDs.contains(win.owningApplication?.processID ?? 0)
            }
        }
        
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        
        // Find matching NSScreen to determine backing scale factor and AppKit frame
        let matchingScreen = NSScreen.screens.first { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
            return id == scDisplay.displayID
        } ?? NSScreen.main ?? NSScreen.screens.first!
        
        let scale = matchingScreen.backingScaleFactor
        var pixelWidth = Int(CGFloat(scDisplay.width) * scale)
        var pixelHeight = Int(CGFloat(scDisplay.height) * scale)
        
        if let maxDim = downsampleMax, maxDim > 0 {
            let maxCurrent = CGFloat(max(pixelWidth, pixelHeight))
            if maxCurrent > maxDim {
                let downscale = maxDim / maxCurrent
                pixelWidth = max(1, Int(CGFloat(pixelWidth) * downscale))
                pixelHeight = max(1, Int(CGFloat(pixelHeight) * downscale))
            }
        }
        
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        config.scalesToFit = true
        
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let actualPixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: scDisplay.width, height: scDisplay.height))
        let space = coordinateSpace(for: matchingScreen, capturedPixelSize: actualPixelSize)
        
        return (image, space)
    }
    
    /// Captures the main display as an NSImage, returning the image and its coordinate space.
    public func captureMainScreenWithSpace() -> (image: NSImage, space: DisplayCoordinateSpace)? {
        guard let mainScreen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let primaryHeight = ScreenCoordinateHelper.primaryScreenHeight()
        let appKitFrame = mainScreen.frame
        let cgFrame = ScreenCoordinateHelper.displayBoundsInCoreGraphics(from: appKitFrame, primaryScreenHeight: primaryHeight)
        
        guard let cgImage = CGWindowListCreateImage(
            cgFrame,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }
        
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        let logicalSize = NSSize(width: appKitFrame.width, height: appKitFrame.height)
        let nsImage = NSImage(cgImage: cgImage, size: logicalSize)
        let space = coordinateSpace(for: mainScreen, capturedPixelSize: pixelSize)
        
        return (nsImage, space)
    }
    
    /// Captures the main display as an NSImage.
    public func captureMainScreen() -> NSImage? {
        return captureMainScreenWithSpace()?.image
    }
    
    /// Prepares downscaled JPEG representation and base64 string for LLM vision models.
    public func captureForVision(maxDimension: CGFloat = 1280.0) -> (image: NSImage, base64: String, space: DisplayCoordinateSpace)? {
        guard let fullCapture = captureMainScreenWithSpace() else { return nil }
        let fullImage = fullCapture.image
        
        let originalLogicalSize = fullImage.size
        guard originalLogicalSize.width > 0 && originalLogicalSize.height > 0 else { return nil }
        
        let scale = min(maxDimension / originalLogicalSize.width, maxDimension / originalLogicalSize.height, 1.0)
        let targetSize = NSSize(width: originalLogicalSize.width * scale, height: originalLogicalSize.height * scale)
        
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        fullImage.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalLogicalSize),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        
        guard let tiffData = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        
        let actualPixelWidth = rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) : targetSize.width
        let actualPixelHeight = rep.pixelsHigh > 0 ? CGFloat(rep.pixelsHigh) : targetSize.height
        let capturedPixelSize = CGSize(width: actualPixelWidth, height: actualPixelHeight)
        
        guard let mainScreen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let visionSpace = coordinateSpace(for: mainScreen, capturedPixelSize: capturedPixelSize)
        
        let base64 = jpegData.base64EncodedString()
        return (resized, base64, visionSpace)
    }
    
    // MARK: - Strict Coordinate Resolution & Validation
    
    /// Validates target observation, display ID, and normalized coordinates within [0.0, 1.0].
    /// NEVER silently clamps invalid coordinates; throws typed errors.
    public static func convertAndValidateCoordinates(
        observation: ComputerObservation,
        targetObservationId: UUID,
        targetDisplayId: CGDirectDisplayID,
        xNorm: Double,
        yNorm: Double
    ) throws -> CGPoint {
        guard observation.id == targetObservationId else {
            throw ComputerCoordinateError.staleObservation(expected: observation.id, actual: targetObservationId)
        }
        guard observation.displayId == targetDisplayId else {
            throw ComputerCoordinateError.displayMismatch(expected: observation.displayId, actual: targetDisplayId)
        }
        guard xNorm >= 0.0 && xNorm <= 1.0 && yNorm >= 0.0 && yNorm <= 1.0 else {
            throw ComputerCoordinateError.outOfBounds(xNorm: xNorm, yNorm: yNorm)
        }
        
        let cgFrame = observation.coordinateSpace.globalCoreGraphicsFrame
        let cgX = cgFrame.origin.x + CGFloat(xNorm) * cgFrame.width
        let cgY = cgFrame.origin.y + CGFloat(yNorm) * cgFrame.height
        return CGPoint(x: cgX, y: cgY)
    }
    
    /// Resolves an element ID from the current observation to its global CoreGraphics center point.
    public static func resolveElementCoordinates(
        observation: ComputerObservation,
        elementId: String
    ) throws -> (point: CGPoint, node: AXElementNode) {
        guard let node = observation.findElement(id: elementId) else {
            throw ComputerCoordinateError.elementNotFound(elementId)
        }
        let midX = node.globalFrame.midX
        let midY = node.globalFrame.midY
        return (CGPoint(x: midX, y: midY), node)
    }
    
    /// Transforms a global CoreGraphics point to an AppKit screen-local point for a specific display window.
    public static func globalCGToAppKitScreenLocal(
        cgPoint: CGPoint,
        screen: NSScreen,
        primaryScreenHeight: CGFloat
    ) -> CGPoint {
        let appKitGlobal = ScreenCoordinateHelper.coreGraphicsToAppKit(point: cgPoint, screenHeight: primaryScreenHeight)
        return CGPoint(x: appKitGlobal.x - screen.frame.origin.x, y: appKitGlobal.y - screen.frame.origin.y)
    }
}
