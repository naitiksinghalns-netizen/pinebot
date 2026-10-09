import AppKit

/// Central manager for loading and caching Pinebot companion PNG graphics.
public final class AssetLoader: @unchecked Sendable {
    public static let shared = AssetLoader()
    
    private var imageCache: [String: NSImage] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    /// Loads an NSImage for the given buddy state.
    public func image(for state: BuddyState) -> NSImage {
        let name = state.assetName
        
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = imageCache[name] {
            return cached
        }
        
        // 1. Try Bundle.module (SPM resource bundle)
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: nil) ??
                     Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            imageCache[name] = img
            return img
        }
        #endif
        
        // 2. Try Bundle.main resources
        if let url = Bundle.main.url(forResource: name, withExtension: nil) ??
                     Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            imageCache[name] = img
            return img
        }
        
        // 3. Try checking local paths in development
        let cwd = FileManager.default.currentDirectoryPath
        let candidatePaths = [
            (cwd as NSString).appendingPathComponent("work/pinebot/assets/\(name)"),
            (cwd as NSString).appendingPathComponent("assets/\(name)"),
            "work/pinebot/assets/\(name)",
            "assets/\(name)"
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                imageCache[name] = img
                return img
            }
        }
        
        // 4. Fallback generated image if somehow unavailable
        let fallback = createFallbackImage(for: state)
        imageCache[name] = fallback
        return fallback
    }
    
    private func createFallbackImage(for state: BuddyState) -> NSImage {
        let size = NSSize(width: 120, height: 120)
        let img = NSImage(size: size)
        img.lockFocus()
        
        let bounds = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 10, dy: 10))
        NSColor.systemYellow.setFill()
        path.fill()
        
        let text = NSString(string: "🍍\n\(state.rawValue)")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.brown
        ]
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attrs)
        
        img.unlockFocus()
        return img
    }
}
