import AppKit
import Foundation

/// Bounded numeric-only diagnostic logger for own-app window states and speech lifecycle.
/// Logs to /private/tmp/pinebot-ui-state.log capped at 100KB with strictly no transcripts or credentials.
@MainActor
public enum UIDiagnosticLogger {
    public static let logPath = "/private/tmp/pinebot-ui-state.log"
    public static let maxLogSizeBytes = 100 * 1024 // 100KB cap
    
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    public static func log(event: String) {
        let timestamp = dateFormatter.string(from: Date())
        let speechState = SpeechManager.shared.presentationState
        let speechPhase = speechState.phase.rawValue
        let speechGen = SpeechManager.shared.currentGeneration
        
        var lines: [String] = []
        lines.append("[\(timestamp)] EVENT: \(event) | speechPhase=\(speechPhase) speechGen=\(speechGen)")
        
        let windows = NSApplication.shared.windows
        lines.append("  totalWindows=\(windows.count)")
        for (idx, win) in windows.enumerated() {
            let title = win.title.isEmpty ? "<unnamed>" : win.title
            let f = win.frame
            let vis = win.isVisible ? 1 : 0
            let alpha = String(format: "%.2f", win.alphaValue)
            let isKey = win.isKeyWindow ? 1 : 0
            let isMain = win.isMainWindow ? 1 : 0
            let level = win.level.rawValue
            lines.append("  win[\(idx)] title=\"\(title)\" frame=(\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))) vis=\(vis) alpha=\(alpha) key=\(isKey) main=\(isMain) level=\(level)")
        }
        lines.append("")
        
        let block = lines.joined(separator: "\n") + "\n"
        writeBounded(block)
    }
    
    private static func writeBounded(_ text: String) {
        let fileURL = URL(fileURLWithPath: logPath)
        guard let data = text.data(using: .utf8) else { return }
        
        let fileManager = FileManager.default
        if let attrs = try? fileManager.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64, size > UInt64(maxLogSizeBytes) {
            // Trim oldest half when 100KB cap is reached
            if let existing = try? Data(contentsOf: fileURL) {
                let keepBytes = maxLogSizeBytes / 2
                let startOffset = max(0, existing.count - keepBytes)
                let subdata = existing.subdata(in: startOffset..<existing.count)
                // Find next newline boundary
                if let newlineIdx = subdata.firstIndex(of: 0x0A) {
                    let pruned = subdata.subdata(in: (newlineIdx + 1)..<subdata.count)
                    try? pruned.write(to: fileURL, options: .atomic)
                } else {
                    try? subdata.write(to: fileURL, options: .atomic)
                }
            }
        }
        
        if fileManager.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
