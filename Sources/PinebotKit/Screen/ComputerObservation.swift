import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

/// Permission state for computer tasks (Screen Recording and Accessibility).
public struct ComputerPermissionState: Sendable, Equatable, Codable {
    public let screenRecordingGranted: Bool
    public let accessibilityGranted: Bool
    
    public init(screenRecordingGranted: Bool, accessibilityGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }
    
    public var allGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }
    
    public var missingPermissions: [String] {
        var missing: [String] = []
        if !screenRecordingGranted { missing.append("Screen Recording") }
        if !accessibilityGranted { missing.append("Accessibility") }
        return missing
    }
}

/// A node in the bounded Accessibility (AX) element hierarchy for an observation.
public struct AXElementNode: Identifiable, Sendable, Codable, Equatable {
    public let id: String // Stable observation-local ID, e.g. "AX_1", "AX_2"
    public let role: String // e.g. "AXButton", "AXTextField", "AXStaticText", "AXWindow"
    public let roleDescription: String?
    public let title: String?
    public let value: String?
    public let descriptionText: String?
    public let globalFrame: CGRect // Global CoreGraphics coordinates
    public let normalizedFrame: CGRect // 0.0...1.0 relative to display CoreGraphics frame
    public let isEnabled: Bool
    public let isSelected: Bool
    public let supportedActions: [String] // e.g. "AXPress", "AXConfirm"
    public let children: [AXElementNode]
    
    public init(
        id: String,
        role: String,
        roleDescription: String? = nil,
        title: String? = nil,
        value: String? = nil,
        descriptionText: String? = nil,
        globalFrame: CGRect,
        normalizedFrame: CGRect,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        supportedActions: [String] = [],
        children: [AXElementNode] = []
    ) {
        self.id = id
        self.role = role
        self.roleDescription = roleDescription
        self.title = title
        self.value = value
        self.descriptionText = descriptionText
        self.globalFrame = globalFrame
        self.normalizedFrame = normalizedFrame
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.supportedActions = supportedActions
        self.children = children
    }
    
    public func findElement(id targetId: String) -> AXElementNode? {
        if self.id == targetId { return self }
        for child in children {
            if let found = child.findElement(id: targetId) {
                return found
            }
        }
        return nil
    }
}

/// Rich, grounded observation of desktop screen and application state.
public struct ComputerObservation: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let foregroundPID: pid_t?
    public let foregroundApp: String?
    public let foregroundWindow: String?
    public let permissionState: ComputerPermissionState
    public let axElements: [AXElementNode]
    public let displayId: CGDirectDisplayID
    public let image: NSImage?
    public let imageBytes: Data? // JPEG representation
    public let capturedPixelSize: CGSize
    public let coordinateSpace: DisplayCoordinateSpace
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        foregroundPID: pid_t? = nil,
        foregroundApp: String? = nil,
        foregroundWindow: String? = nil,
        permissionState: ComputerPermissionState,
        axElements: [AXElementNode] = [],
        displayId: CGDirectDisplayID,
        image: NSImage? = nil,
        imageBytes: Data? = nil,
        capturedPixelSize: CGSize,
        coordinateSpace: DisplayCoordinateSpace
    ) {
        self.id = id
        self.timestamp = timestamp
        self.foregroundPID = foregroundPID
        self.foregroundApp = foregroundApp
        self.foregroundWindow = foregroundWindow
        self.permissionState = permissionState
        self.axElements = axElements
        self.displayId = displayId
        self.image = image
        self.imageBytes = imageBytes
        self.capturedPixelSize = capturedPixelSize
        self.coordinateSpace = coordinateSpace
    }
    
    public func findElement(id targetId: String) -> AXElementNode? {
        for element in axElements {
            if let found = element.findElement(id: targetId) {
                return found
            }
        }
        return nil
    }
    
    /// Formats a concise, token-efficient text representation of the AX tree for the model.
    public func formattedAXSummary(maxDepth: Int = 4, maxElements: Int = 100) -> String {
        var count = 0
        var lines: [String] = []
        
        func traverse(_ node: AXElementNode, depth: Int) {
            guard count < maxElements, depth <= maxDepth else { return }
            count += 1
            
            let indent = String(repeating: "  ", count: depth)
            var desc = "[\(node.id)] \(node.role)"
            if let title = node.title, !title.isEmpty {
                desc += " '\(title)'"
            }
            if let val = node.value, !val.isEmpty {
                desc += " val='\(val)'"
            }
            if let dt = node.descriptionText, !dt.isEmpty && dt != node.title {
                desc += " desc='\(dt)'"
            }
            let xPct = Int(node.normalizedFrame.midX * 100)
            let yPct = Int(node.normalizedFrame.midY * 100)
            desc += " (at ~\(xPct)%x, \(yPct)%y)"
            
            if !node.supportedActions.isEmpty {
                desc += " acts=[\(node.supportedActions.joined(separator: ","))]"
            }
            lines.append("\(indent)\(desc)")
            
            for child in node.children {
                traverse(child, depth: depth + 1)
            }
        }
        
        for root in axElements {
            traverse(root, depth: 0)
        }
        
        if lines.isEmpty {
            return "(No accessibility elements found or accessibility permission not granted)"
        }
        return lines.joined(separator: "\n")
    }
}

/// Helper that reads the Accessibility tree of the frontmost application safely in the background.
/// Bounded in depth, element count, and time, ensuring MainActor is never frozen.
public enum AXTreeReader {
    
    public static func readFrontmostAXTree(
        pid: pid_t,
        displayFrame: CGRect,
        maxDepth: Int = 5,
        maxCount: Int = 120,
        timeoutSeconds: Double = 0.5
    ) async -> [AXElementNode] {
        return await Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(pid)
            var elementCounter = 0
            let startTime = Date()
            
            func isTimeExceeded() -> Bool {
                Date().timeIntervalSince(startTime) > timeoutSeconds
            }
            
            func readNode(element: AXUIElement, depth: Int) -> AXElementNode? {
                guard depth <= maxDepth, elementCounter < maxCount, !isTimeExceeded() else {
                    return nil
                }
                
                elementCounter += 1
                let nodeId = "AX_\(elementCounter)"
                
                let role = copyStringAttribute(element, attribute: kAXRoleAttribute) ?? "AXUnknown"
                let roleDesc = copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute)
                let title = copyStringAttribute(element, attribute: kAXTitleAttribute)
                let value = copyValueAttribute(element, attribute: kAXValueAttribute)
                let descriptionText = copyStringAttribute(element, attribute: kAXDescriptionAttribute)
                
                var globalFrame: CGRect = .zero
                var posValue: AnyObject?
                var sizeValue: AnyObject?
                
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
                   let pos = posValue, CFGetTypeID(pos) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    if AXValueGetValue(pos as! AXValue, .cgPoint, &point) {
                        globalFrame.origin = point
                    }
                }
                
                if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
                   let sz = sizeValue, CFGetTypeID(sz) == AXValueGetTypeID() {
                    var size = CGSize.zero
                    if AXValueGetValue(sz as! AXValue, .cgSize, &size) {
                        globalFrame.size = size
                    }
                }
                
                // Compute normalized frame relative to display frame
                let normX = displayFrame.width > 0 ? (globalFrame.origin.x - displayFrame.origin.x) / displayFrame.width : 0
                let normY = displayFrame.height > 0 ? (globalFrame.origin.y - displayFrame.origin.y) / displayFrame.height : 0
                let normW = displayFrame.width > 0 ? globalFrame.width / displayFrame.width : 0
                let normH = displayFrame.height > 0 ? globalFrame.height / displayFrame.height : 0
                let normalizedFrame = CGRect(x: normX, y: normY, width: normW, height: normH)
                
                var actions: [String] = []
                var actionsRef: CFArray?
                if AXUIElementCopyActionNames(element, &actionsRef) == .success, let actList = actionsRef as? [String] {
                    actions = actList
                }
                
                // Read children
                var childNodes: [AXElementNode] = []
                var childrenRef: AnyObject?
                if depth < maxDepth && !isTimeExceeded(),
                   AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        if isTimeExceeded() || elementCounter >= maxCount { break }
                        if let childNode = readNode(element: child, depth: depth + 1) {
                            childNodes.append(childNode)
                        }
                    }
                }
                
                return AXElementNode(
                    id: nodeId,
                    role: role,
                    roleDescription: roleDesc,
                    title: title,
                    value: value,
                    descriptionText: descriptionText,
                    globalFrame: globalFrame,
                    normalizedFrame: normalizedFrame,
                    isEnabled: true,
                    isSelected: false,
                    supportedActions: actions,
                    children: childNodes
                )
            }
            
            // Start reading from frontmost window or app
            var windowsRef: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
                var roots: [AXElementNode] = []
                for win in windows.prefix(2) {
                    if let root = readNode(element: win, depth: 0) {
                        roots.append(root)
                    }
                }
                return roots
            } else if let root = readNode(element: appElement, depth: 0) {
                return [root]
            }
            
            return []
        }.value
    }
    
    private static func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var valueRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success, let val = valueRef else { return nil }
        if let str = val as? String {
            return str
        }
        if let num = val as? NSNumber {
            return num.stringValue
        }
        return nil
    }
    
    private static func copyValueAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var valueRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success, let val = valueRef else { return nil }
        if let str = val as? String {
            return str
        }
        if let num = val as? NSNumber {
            return num.stringValue
        }
        return nil
    }
}
