import Foundation
import AppKit

/// Playback state observed from real application readback.
public enum MediaPlaybackState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped
    case unknown
}

/// Result returned from executing a validated local capability.
public enum LocalActionResult: Sendable, Equatable {
    case completed(spokenSummary: String, detail: String?)
    case failed(spokenError: String, detail: String?)
    case needsPermission(reason: String)
    case needsPlanner(reason: String)
}

/// Abstract adapter for media automation and readback.
public protocol MediaAutomationAdapter: Sendable {
    var supportedBundleId: String { get }
    func play(appBundleId: String, query: String?) async throws -> (state: MediaPlaybackState, trackName: String?)
    func pause(appBundleId: String) async throws -> MediaPlaybackState
    func resume(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?)
    func togglePlayPause(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?)
    func nextTrack(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?)
    func previousTrack(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?)
    func currentPlaybackState(appBundleId: String) async throws -> MediaPlaybackState
}

/// Abstract adapter for launching and locating installed macOS applications.
public protocol AppLauncherAdapter: Sendable {
    func launchApp(bundleId: String) async throws -> Bool
    func findApp(named: String) -> (bundleId: String, localizedName: String)?
    func isAppInstalled(bundleId: String) -> Bool
}

/// Native Apple Music automation using fixed AppleScript automation with real player state and track identity readback.
public final class AppleMusicAutomationAdapter: MediaAutomationAdapter, @unchecked Sendable {
    public static let shared = AppleMusicAutomationAdapter()
    public let supportedBundleId = "com.apple.Music"
    
    public init() {}
    
    private func validateBundleId(_ bundleId: String) throws {
        guard bundleId == supportedBundleId else {
            throw NSError(
                domain: "PinebotAppleMusic",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "AppleMusicAutomationAdapter only supports '\(supportedBundleId)', received '\(bundleId)'."]
            )
        }
    }
    
    private func executeScript(_ source: String) throws -> String {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "PinebotAppleMusic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compile automation script."])
        }
        let output = script.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
            let num = err[NSAppleScript.errorNumber] as? Int ?? -1
            if num == -1743 {
                throw NSError(domain: "PinebotAppleMusic", code: num, userInfo: [NSLocalizedDescriptionKey: "Apple Events permission required for Music."])
            }
            throw NSError(domain: "PinebotAppleMusic", code: num, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private func parseState(_ raw: String) -> MediaPlaybackState {
        let lower = raw.lowercased()
        if lower.contains("playing") || lower.contains("kpsp") { return .playing }
        if lower.contains("paused") || lower.contains("kppr") { return .paused }
        if lower.contains("stopped") || lower.contains("kpss") { return .stopped }
        return .unknown
    }
    
    public func play(appBundleId: String, query: String?) async throws -> (state: MediaPlaybackState, trackName: String?) {
        try validateBundleId(appBundleId)
        
        if let q = query, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanQ = q.trimmingCharacters(in: .whitespacesAndNewlines)
            let escaped = cleanQ.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            
            // Search local playlists and tracks for matching query
            let script = """
            tell application id "com.apple.Music"
                activate
                set q to "\(escaped)"
                set targetFound to false
                try
                    set matchedPlaylists to (every user playlist whose name contains q)
                    if (count of matchedPlaylists) > 0 then
                        set targetPlaylist to item 1 of matchedPlaylists
                        play targetPlaylist
                        set targetFound to true
                    end if
                end try
                if not targetFound then
                    try
                        set matchedTracks to (every track of playlist 1 whose name contains q)
                        if (count of matchedTracks) > 0 then
                            set targetTrack to item 1 of matchedTracks
                            play targetTrack
                            set targetFound to true
                        end if
                    end try
                end if
                if not targetFound then
                    return "not_found"
                end if
                delay 0.3
                set pState to player state as string
                set tName to ""
                try
                    set tName to name of current track as string
                on error
                    try
                        set tName to name of targetPlaylist as string
                    end try
                end try
                return pState & "|" & tName
            end tell
            """
            let res = try executeScript(script)
            if res == "not_found" {
                throw NSError(
                    domain: "PinebotAppleMusic",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Query '\(cleanQ)' not found in local Apple Music library."]
                )
            }
            let parts = res.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let state = parseState(parts.first.map(String.init) ?? "unknown")
            let track = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return (state, track?.isEmpty == true ? nil : track)
        } else {
            let script = """
            tell application id "com.apple.Music"
                activate
                play
                delay 0.2
                set pState to player state as string
                set tName to ""
                try
                    set tName to name of current track as string
                end try
                return pState & "|" & tName
            end tell
            """
            let res = try executeScript(script)
            let parts = res.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let state = parseState(parts.first.map(String.init) ?? "unknown")
            let track = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return (state, track?.isEmpty == true ? nil : track)
        }
    }
    
    public func pause(appBundleId: String) async throws -> MediaPlaybackState {
        try validateBundleId(appBundleId)
        let script = """
        tell application id "com.apple.Music"
            pause
            delay 0.1
            return player state as string
        end tell
        """
        let res = try executeScript(script)
        return parseState(res)
    }
    
    public func resume(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        try validateBundleId(appBundleId)
        let script = """
        tell application id "com.apple.Music"
            play
            delay 0.1
            set pState to player state as string
            set tName to ""
            try
                set tName to name of current track as string
            end try
            return pState & "|" & tName
        end tell
        """
        let res = try executeScript(script)
        let parts = res.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let state = parseState(parts.first.map(String.init) ?? "unknown")
        let track = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return (state, track?.isEmpty == true ? nil : track)
    }
    
    public func togglePlayPause(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        try validateBundleId(appBundleId)
        let script = """
        tell application id "com.apple.Music"
            playpause
            delay 0.1
            set pState to player state as string
            set tName to ""
            try
                set tName to name of current track as string
            end try
            return pState & "|" & tName
        end tell
        """
        let res = try executeScript(script)
        let parts = res.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let state = parseState(parts.first.map(String.init) ?? "unknown")
        let track = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return (state, track?.isEmpty == true ? nil : track)
    }
    
    public func nextTrack(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        try validateBundleId(appBundleId)
        let script = """
        tell application id "com.apple.Music"
            set beforeId to ""
            try
                set beforeId to (id of current track as string) & "::" & (name of current track as string)
            end try
            next track
            delay 0.3
            set pState to player state as string
            set afterId to ""
            set tName to ""
            try
                set afterId to (id of current track as string) & "::" & (name of current track as string)
                set tName to name of current track as string
            end try
            if beforeId is not "" and beforeId is equal to afterId then
                return "unchanged|" & pState & "|" & tName
            else if afterId is "" then
                return "empty|" & pState & "|"
            else
                return "changed|" & pState & "|" & tName
            end if
        end tell
        """
        let res = try executeScript(script)
        let parts = res.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        let status = parts.first.map(String.init) ?? "unknown"
        let state = parts.count > 1 ? parseState(String(parts[1])) : .unknown
        let track = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        
        if status == "unchanged" {
            throw NSError(domain: "PinebotAppleMusic", code: 409, userInfo: [NSLocalizedDescriptionKey: "Track remained unchanged."])
        }
        if status == "empty" || track?.isEmpty != false {
            throw NSError(domain: "PinebotAppleMusic", code: 404, userInfo: [NSLocalizedDescriptionKey: "No track identity returned from player readback."])
        }
        return (state, track)
    }
    
    public func previousTrack(appBundleId: String) async throws -> (state: MediaPlaybackState, trackName: String?) {
        try validateBundleId(appBundleId)
        let script = """
        tell application id "com.apple.Music"
            set beforeId to ""
            try
                set beforeId to (id of current track as string) & "::" & (name of current track as string)
            end try
            previous track
            delay 0.3
            set pState to player state as string
            set afterId to ""
            set tName to ""
            try
                set afterId to (id of current track as string) & "::" & (name of current track as string)
                set tName to name of current track as string
            end try
            if beforeId is not "" and beforeId is equal to afterId then
                return "unchanged|" & pState & "|" & tName
            else if afterId is "" then
                return "empty|" & pState & "|"
            else
                return "changed|" & pState & "|" & tName
            end if
        end tell
        """
        let res = try executeScript(script)
        let parts = res.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        let status = parts.first.map(String.init) ?? "unknown"
        let state = parts.count > 1 ? parseState(String(parts[1])) : .unknown
        let track = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        
        if status == "unchanged" {
            throw NSError(domain: "PinebotAppleMusic", code: 409, userInfo: [NSLocalizedDescriptionKey: "Track remained unchanged."])
        }
        if status == "empty" || track?.isEmpty != false {
            throw NSError(domain: "PinebotAppleMusic", code: 404, userInfo: [NSLocalizedDescriptionKey: "No track identity returned from player readback."])
        }
        return (state, track)
    }
    
    public func currentPlaybackState(appBundleId: String) async throws -> MediaPlaybackState {
        try validateBundleId(appBundleId)
        let script = """
        tell application id "com.apple.Music"
            return player state as string
        end tell
        """
        let res = try executeScript(script)
        return parseState(res)
    }
}

/// Default application launcher using NSWorkspace with running application readback.
public final class DefaultAppLauncherAdapter: AppLauncherAdapter, @unchecked Sendable {
    public static let shared = DefaultAppLauncherAdapter()
    
    public init() {}
    
    private let knownAppMap: [String: (bundleId: String, name: String)] = [
        "music": ("com.apple.Music", "Music"),
        "apple music": ("com.apple.Music", "Apple Music"),
        "safari": ("com.apple.Safari", "Safari"),
        "notes": ("com.apple.Notes", "Notes"),
        "calculator": ("com.apple.calculator", "Calculator"),
        "terminal": ("com.apple.Terminal", "Terminal"),
        "system settings": ("com.apple.systempreferences", "System Settings"),
        "settings": ("com.apple.systempreferences", "System Settings"),
        "calendar": ("com.apple.iCal", "Calendar"),
        "mail": ("com.apple.mail", "Mail"),
        "messages": ("com.apple.MobileSMS", "Messages"),
        "finder": ("com.apple.finder", "Finder")
    ]
    
    public func isAppInstalled(bundleId: String) -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }
    
    public func findApp(named rawName: String) -> (bundleId: String, localizedName: String)? {
        let cleaned = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = knownAppMap[cleaned] {
            return (direct.bundleId, direct.name)
        }
        
        // Search through running applications
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, name.lowercased() == cleaned, let bid = app.bundleIdentifier {
                return (bid, name)
            }
        }
        
        // Attempt URL resolution
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleaned) {
            let displayName = FileManager.default.displayName(atPath: url.path)
            return (cleaned, displayName)
        }
        
        return nil
    }
    
    public func launchApp(bundleId: String) async throws -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw NSError(domain: "PinebotAppLauncher", code: 404, userInfo: [NSLocalizedDescriptionKey: "Application bundle '\(bundleId)' is not installed."])
        }
        
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        
        // Readback: verify application is actually running
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
            if isRunning {
                return true
            }
        }
        
        // Explicit false on readback timeout!
        return false
    }
}

/// Central registry dispatching validated finite local actions with keyed adapters.
public final class LocalCapabilityRegistry: @unchecked Sendable {
    public static let shared = LocalCapabilityRegistry()
    
    private let adapters: [String: MediaAutomationAdapter]
    public let appLauncher: AppLauncherAdapter
    
    public init(
        mediaAdapters: [MediaAutomationAdapter] = [AppleMusicAutomationAdapter.shared],
        appLauncher: AppLauncherAdapter = DefaultAppLauncherAdapter.shared
    ) {
        var dict: [String: MediaAutomationAdapter] = [:]
        for a in mediaAdapters {
            dict[a.supportedBundleId] = a
        }
        self.adapters = dict
        self.appLauncher = appLauncher
    }
    
    public convenience init(
        mediaAdapter: MediaAutomationAdapter,
        appLauncher: AppLauncherAdapter = DefaultAppLauncherAdapter.shared
    ) {
        self.init(mediaAdapters: [mediaAdapter], appLauncher: appLauncher)
    }
    
    /// Executes a media command with player state readback.
    /// Never claims 'Playing' unless state is .playing; reports paused or failed truthfully.
    public func executeMediaAction(_ action: MediaAction) async -> LocalActionResult {
        let bundleId = action.targetBundleId
        guard let adapter = adapters[bundleId] else {
            return .failed(
                spokenError: "Media player is not supported locally.",
                detail: "No automation adapter registered for '\(bundleId)'."
            )
        }
        
        do {
            switch action {
            case .play(let query, let bid):
                let (state, trackName) = try await adapter.play(appBundleId: bid, query: query)
                let appName = bid == "com.apple.Music" ? "Apple Music" : "Music"
                
                if state == .playing {
                    if let track = trackName, !track.isEmpty {
                        return .completed(spokenSummary: "Playing \(track) in \(appName).", detail: "Started playback of '\(track)' in \(appName).")
                    } else {
                        return .completed(spokenSummary: "Playing in \(appName).", detail: "Started playback in \(appName).")
                    }
                } else if state == .paused {
                    // Play was requested but player is paused: report truthful failure
                    return .failed(spokenError: "Apple Music remained paused.", detail: "Playback did not begin; player is paused.")
                } else {
                    return .failed(spokenError: "Apple Music is not playing.", detail: "Observed state: \(state.rawValue).")
                }
                
            case .pause(let bid):
                let state = try await adapter.pause(appBundleId: bid)
                let appName = bid == "com.apple.Music" ? "Apple Music" : "Music"
                if state == .paused || state == .stopped {
                    return .completed(spokenSummary: "Paused \(appName).", detail: "Playback paused.")
                } else {
                    return .failed(spokenError: "Could not pause music.", detail: "State: \(state.rawValue)")
                }
                
            case .resume(let bid):
                let (state, trackName) = try await adapter.resume(appBundleId: bid)
                let appName = bid == "com.apple.Music" ? "Apple Music" : "Music"
                if state == .playing {
                    if let track = trackName, !track.isEmpty {
                        return .completed(spokenSummary: "Resumed \(track) in \(appName).", detail: "Resumed playback of '\(track)'.")
                    } else {
                        return .completed(spokenSummary: "Resumed \(appName).", detail: "Playback resumed.")
                    }
                } else {
                    return .failed(spokenError: "Could not resume music.", detail: "State: \(state.rawValue)")
                }
                
            case .togglePlayPause(let bid):
                let (state, _) = try await adapter.togglePlayPause(appBundleId: bid)
                let appName = bid == "com.apple.Music" ? "Apple Music" : "Music"
                if state == .playing {
                    return .completed(spokenSummary: "Playing in \(appName).", detail: "Toggled to playing.")
                } else if state == .paused {
                    return .completed(spokenSummary: "Paused \(appName).", detail: "Toggled to paused.")
                } else {
                    return .failed(spokenError: "Could not toggle playback.", detail: "Observed state: \(state.rawValue).")
                }
                
            case .nextTrack(let bid):
                let (_, trackName) = try await adapter.nextTrack(appBundleId: bid)
                if let track = trackName, !track.isEmpty {
                    return .completed(spokenSummary: "Skipped to \(track).", detail: "Playing next track: '\(track)'.")
                } else {
                    return .failed(spokenError: "Could not skip track.", detail: "No next track identity returned from player readback.")
                }
                
            case .previousTrack(let bid):
                let (state, trackName) = try await adapter.previousTrack(appBundleId: bid)
                if let track = trackName, !track.isEmpty {
                    if state == .playing {
                        return .completed(spokenSummary: "Playing \(track).", detail: "Playing previous track: '\(track)'.")
                    } else if state == .paused {
                        return .completed(spokenSummary: "Selected \(track).", detail: "Selected previous track: '\(track)' (paused).")
                    } else {
                        return .completed(spokenSummary: "Selected \(track).", detail: "Selected previous track: '\(track)'.")
                    }
                } else {
                    return .failed(spokenError: "Could not return to previous track.", detail: "No previous track identity returned from player readback.")
                }
            }
        } catch {
            let nsErr = error as NSError
            if nsErr.code == -1743 {
                return .needsPermission(reason: "Pinebot needs permission to control Apple Music in System Settings > Privacy & Security > Automation.")
            }
            if nsErr.code == 404, let q = action.query {
                return .needsPlanner(reason: "Searching Apple Music catalog for '\(q)' requires desktop planner.")
            }
            if nsErr.code == 409 {
                switch action {
                case .nextTrack:
                    return .failed(spokenError: "Could not skip track.", detail: "Track remained unchanged.")
                case .previousTrack:
                    return .failed(spokenError: "Could not return to previous track.", detail: "Track remained unchanged.")
                default:
                    return .failed(spokenError: "Action could not be completed.", detail: "Track remained unchanged.")
                }
            }
            return .failed(spokenError: "Could not control music.", detail: error.localizedDescription)
        }
    }
    
    /// Launches an application by bundle identifier or localized name with launch readback.
    public func executeAppLaunch(bundleId: String, appName: String) async -> LocalActionResult {
        do {
            let success = try await appLauncher.launchApp(bundleId: bundleId)
            if success {
                return .completed(spokenSummary: "Opened \(appName).", detail: "Launched application: \(appName) (\(bundleId)).")
            } else {
                return .failed(spokenError: "Could not open \(appName).", detail: "Application launch readback timed out.")
            }
        } catch {
            return .failed(spokenError: "Could not open \(appName).", detail: error.localizedDescription)
        }
    }
}
