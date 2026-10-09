import Foundation
import AppKit

/// Typed intent of a user request independent of difficulty/cost routing.
public enum RequestIntent: Equatable, Sendable {
    case cancel
    case localAction(LocalActionCommand)
    case desktopAction(goal: String)
    case question(prompt: String)
    case conversational(prompt: String)
    case clarification(prompt: String, suggestedResponse: String, pendingAction: LocalActionCommand? = nil)
}

/// Validated local capability commands that need zero model calls.
public enum LocalActionCommand: Equatable, Sendable {
    case launchApp(bundleId: String, appName: String)
    case media(MediaAction)
}

/// Commands for controlling media playback on macOS.
public enum MediaAction: Equatable, Sendable {
    case play(query: String?, bundleId: String)
    case pause(bundleId: String)
    case resume(bundleId: String)
    case togglePlayPause(bundleId: String)
    case nextTrack(bundleId: String)
    case previousTrack(bundleId: String)
}

public extension MediaAction {
    var targetBundleId: String {
        switch self {
        case .play(_, let bid): return bid
        case .pause(let bid): return bid
        case .resume(let bid): return bid
        case .togglePlayPause(let bid): return bid
        case .nextTrack(let bid): return bid
        case .previousTrack(let bid): return bid
        }
    }
    
    var query: String? {
        if case .play(let q, _) = self {
            return q
        }
        return nil
    }
}

/// State tracking the recent application context and pending action for follow-up resolution.
public struct IntentResolutionContext: Sendable {
    public var lastTargetAppBundleId: String?
    public var lastTargetAppName: String?
    public var pendingAction: LocalActionCommand?
    
    public init(
        lastTargetAppBundleId: String? = nil,
        lastTargetAppName: String? = nil,
        pendingAction: LocalActionCommand? = nil
    ) {
        self.lastTargetAppBundleId = lastTargetAppBundleId
        self.lastTargetAppName = lastTargetAppName
        self.pendingAction = pendingAction
    }
}

/// Classifier resolving user prompt into typed intent before or alongside routing.
public final class RequestIntentClassifier: Sendable {
    public static let shared = RequestIntentClassifier()
    
    private let appLauncher: AppLauncherAdapter
    
    public init(appLauncher: AppLauncherAdapter = DefaultAppLauncherAdapter.shared) {
        self.appLauncher = appLauncher
    }
    
    /// Normalizes polite phrases ("can you please", "could you", "please") to bare command intent.
    public func normalizePoliteInput(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let prefixes = [
            "can you please ", "could you please ", "would you please ", "will you please ",
            "can you ", "could you ", "would you mind ", "will you ",
            "please ", "kindly "
        ]
        
        var changed = true
        while changed {
            changed = false
            let lower = s.lowercased()
            for p in prefixes {
                if lower.starts(with: p) {
                    s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }
        
        let suffixes = [
            ", please", " please", ", thank you", " thank you", ", thanks", " thanks"
        ]
        for suf in suffixes {
            if s.lowercased().hasSuffix(suf) {
                s = String(s.dropLast(suf.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return s
    }
    
    /// Classifies user input into typed intent, distinguishing questions from actions.
    public func classifyIntent(prompt: String, context: IntentResolutionContext = IntentResolutionContext()) -> RequestIntent {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizePoliteInput(trimmed)
        let lower = normalized.lowercased()
        
        // 1. Pending clarification follow-up (e.g. user answered "yes" to "Use Apple Music instead?")
        if let pending = context.pendingAction {
            if isAffirmativeResponse(lower) {
                return .localAction(pending)
            }
            if isNegativeResponse(lower) {
                return .cancel
            }
        }
        
        // 2. Explicit bare cancellation (Must NOT match "stop music" or "stop playing")
        if isBareCancelIntent(lower) {
            return .cancel
        }
        
        // 3. Informational questions ("how do I...", "how can I play music", "how do I play music on YouTube")
        // MUST run before all action target resolution so questions with app/service names don't route to desktopAction/planner!
        if isInformationalQuestion(lower) {
            return .question(prompt: trimmed)
        }
        
        // 4. Resolve explicit media commands, requiring media grammar AND resolving target
        if let mediaAction = resolveMediaAction(lower, rawPrompt: trimmed, context: context) {
            switch mediaAction {
            case .action(let cmd):
                return .localAction(.media(cmd))
            case .desktopAction(let goal):
                return .desktopAction(goal: goal)
            case .appNotInstalled(let requestedApp, let fallbackAction):
                return .clarification(
                    prompt: trimmed,
                    suggestedResponse: "\(requestedApp) is not installed on this Mac. Would you like to use Apple Music instead?",
                    pendingAction: .media(fallbackAction)
                )
            }
        }
        
        // 5. Non-media pause or stop tasks (e.g. "pause downloads", "stop server")
        if isNonMediaControlTask(lower) {
            return .desktopAction(goal: trimmed)
        }
        
        // 6. Local App Launch Commands ("open Safari", "launch Calculator")
        if let launchAction = resolveAppLaunch(lower, rawPrompt: trimmed) {
            switch launchAction {
            case .action(let bundleId, let appName):
                return .localAction(.launchApp(bundleId: bundleId, appName: appName))
            case .appNotInstalled(let requestedApp):
                return .clarification(
                    prompt: trimmed,
                    suggestedResponse: "The application '\(requestedApp)' is not installed on this Mac.",
                    pendingAction: nil
                )
            }
        }
        
        // 7. Desktop / Computer Action intent
        if isDesktopAction(lower) {
            return .desktopAction(goal: trimmed)
        }
        
        // 8. Default to conversational prompt (unresolved intent preserving learned routing)
        return .conversational(prompt: trimmed)
    }
    
    // MARK: - Private Matching Helpers
    
    private func isBareCancelIntent(_ lower: String) -> Bool {
        let exactPhrases: Set<String> = [
            "stop", "cancel", "nevermind", "never mind", "quiet", "be quiet", "shut up", "halt",
            "pause speaking", "stop speaking", "stop talking", "shut down",
            "stop it", "stop that", "stop now", "cancel that", "cancel it", "cancel this", "stop this"
        ]
        return exactPhrases.contains(lower)
    }
    
    private func isAffirmativeResponse(_ lower: String) -> Bool {
        let affirmative: Set<String> = [
            "yes", "yeah", "yep", "sure", "ok", "okay", "yes please", "do it", "go ahead",
            "use apple music", "apple music", "play in apple music", "play it in apple music",
            "play it", "sounds good", "please do"
        ]
        return affirmative.contains(lower)
    }
    
    private func isNegativeResponse(_ lower: String) -> Bool {
        let negative: Set<String> = [
            "no", "nope", "cancel", "never mind", "nevermind", "don't", "no thanks", "no thank you"
        ]
        return negative.contains(lower)
    }
    
    private func isNonMediaControlTask(_ lower: String) -> Bool {
        let nonMediaPrefixes = ["pause ", "stop ", "resume "]
        for p in nonMediaPrefixes {
            if lower.starts(with: p) {
                let remainder = String(lower.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let mediaWords = ["music", "the music", "song", "the song", "track", "the track", "playback", "audio", "apple music", "spotify", "playing"]
                if !mediaWords.contains(remainder) {
                    return true
                }
            }
        }
        return false
    }
    
    private func isInformationalQuestion(_ lower: String) -> Bool {
        let questionStarters = [
            "how do i", "how do we", "how can i", "how can we", "how to",
            "what is", "what are", "what does", "why is", "why does", "why do",
            "explain", "tell me about", "who is", "where is",
            "instructions for", "guide on", "how does", "is it possible to"
        ]
        for starter in questionStarters {
            if lower.starts(with: starter) {
                return true
            }
        }
        if lower.hasSuffix("?") {
            let questionWords = ["how", "what", "why", "when", "where", "who", "which", "whose"]
            for qw in questionWords {
                if lower.starts(with: qw) || lower.contains(" \(qw) ") {
                    return true
                }
            }
        }
        return false
    }
    
    private enum MediaTarget {
        case appleMusic
        case spotify
        case web(String)
        case unsupportedApp(String)
    }
    
    private struct StrippedMediaCommand {
        let command: String
        let target: MediaTarget
    }
    
    private func extractMediaTarget(from lower: String, context: IntentResolutionContext) -> StrippedMediaCommand {
        let targetMappings: [(phrases: [String], target: MediaTarget)] = [
            ([" in apple music", " on apple music", " in music", " on music"], .appleMusic),
            ([" in spotify", " on spotify"], .spotify),
            ([" on youtube", " in youtube"], .web("YouTube")),
            ([" on browser", " in browser", " in safari", " on safari"], .web("Browser")),
            ([" in tidal", " on tidal"], .unsupportedApp("Tidal")),
            ([" in soundcloud", " on soundcloud"], .unsupportedApp("SoundCloud")),
            ([" in pandora", " on pandora"], .unsupportedApp("Pandora"))
        ]
        
        for mapping in targetMappings {
            for phrase in mapping.phrases {
                if lower.hasSuffix(phrase) {
                    let stripped = String(lower.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return StrippedMediaCommand(command: stripped, target: mapping.target)
                } else if lower.contains(phrase + " ") {
                    let stripped = lower.replacingOccurrences(of: phrase, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return StrippedMediaCommand(command: stripped, target: mapping.target)
                }
            }
        }
        
        let target: MediaTarget = (context.lastTargetAppBundleId == "com.apple.Music") ? .appleMusic : .appleMusic
        return StrippedMediaCommand(command: lower, target: target)
    }
    
    private enum ParsedMediaGrammar {
        case pause
        case resume
        case toggle
        case next
        case previous
        case play(query: String?)
    }
    
    private func parseMediaGrammar(from command: String) -> ParsedMediaGrammar? {
        // 1. Pause commands
        if command == "pause" || command == "pause music" || command == "pause the music" || command == "pause playback" || command == "pause song" {
            return .pause
        }
        
        // 2. Stop music commands (treated as pause in media playback)
        if command == "stop music" || command == "stop the music" || command == "stop playing" || command == "stop playback" {
            return .pause
        }
        
        // 3. Resume commands
        if command == "resume" || command == "resume music" || command == "resume the music" || command == "resume playback" || command == "unpause" || command == "unpause music" {
            return .resume
        }
        
        // 4. Next / Previous track commands
        if command == "next" || command == "next song" || command == "next track" || command == "skip" || command == "skip song" || command == "skip track" {
            return .next
        }
        if command == "previous" || command == "previous song" || command == "previous track" || command == "prev song" || command == "prev track" {
            return .previous
        }
        
        // 5. Toggle playback
        if command == "toggle music" || command == "toggle playback" || command == "toggle play" {
            return .toggle
        }
        
        // 6. Play commands
        if command == "play" || command == "play music" || command == "play the music" || command == "play some music" {
            return .play(query: nil)
        }
        
        if command.starts(with: "play ") {
            var rawQuery = String(command.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawQuery.starts(with: "some ") {
                rawQuery = String(rawQuery.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Reject non-media commands like "play chess", "play game"
            let nonMediaPlayWords = ["chess", "game", "poker", "cards", "tennis", "video", "clip", "dvd", "movie"]
            for nonMedia in nonMediaPlayWords {
                if rawQuery == nonMedia || rawQuery.starts(with: "\(nonMedia) ") {
                    return nil
                }
            }
            
            let q = (rawQuery.isEmpty || rawQuery == "music" || rawQuery == "the music") ? nil : rawQuery
            return .play(query: q)
        }
        
        return nil
    }
    
    private enum MediaResolution {
        case action(MediaAction)
        case desktopAction(String)
        case appNotInstalled(String, MediaAction)
    }
    
    private func resolveMediaAction(_ lower: String, rawPrompt: String, context: IntentResolutionContext) -> MediaResolution? {
        let stripped = extractMediaTarget(from: lower, context: context)
        guard let grammar = parseMediaGrammar(from: stripped.command) else {
            return nil
        }
        
        switch stripped.target {
        case .web, .unsupportedApp:
            return .desktopAction(rawPrompt)
            
        case .spotify:
            if !appLauncher.isAppInstalled(bundleId: "com.spotify.client") {
                let fallbackAction: MediaAction
                switch grammar {
                case .play(let q): fallbackAction = .play(query: q, bundleId: "com.apple.Music")
                case .pause: fallbackAction = .pause(bundleId: "com.apple.Music")
                case .resume: fallbackAction = .resume(bundleId: "com.apple.Music")
                case .toggle: fallbackAction = .togglePlayPause(bundleId: "com.apple.Music")
                case .next: fallbackAction = .nextTrack(bundleId: "com.apple.Music")
                case .previous: fallbackAction = .previousTrack(bundleId: "com.apple.Music")
                }
                return .appNotInstalled("Spotify", fallbackAction)
            }
            return .desktopAction(rawPrompt)
            
        case .appleMusic:
            let cmd: MediaAction
            switch grammar {
            case .play(let q): cmd = .play(query: q, bundleId: "com.apple.Music")
            case .pause: cmd = .pause(bundleId: "com.apple.Music")
            case .resume: cmd = .resume(bundleId: "com.apple.Music")
            case .toggle: cmd = .togglePlayPause(bundleId: "com.apple.Music")
            case .next: cmd = .nextTrack(bundleId: "com.apple.Music")
            case .previous: cmd = .previousTrack(bundleId: "com.apple.Music")
            }
            return .action(cmd)
        }
    }
    
    private enum AppLaunchResolution {
        case action(bundleId: String, appName: String)
        case appNotInstalled(String)
    }
    
    private func resolveAppLaunch(_ lower: String, rawPrompt: String) -> AppLaunchResolution? {
        let launchPrefixes = ["open ", "launch ", "switch to ", "bring up "]
        for prefix in launchPrefixes {
            if lower.starts(with: prefix) {
                let appNamePart = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if appNamePart.contains("website") || appNamePart.contains("url") || appNamePart.contains("tab") {
                    return nil
                }
                
                if let app = appLauncher.findApp(named: appNamePart) {
                    return .action(bundleId: app.bundleId, appName: app.localizedName)
                } else {
                    return .appNotInstalled(appNamePart.capitalized)
                }
            }
        }
        return nil
    }
    
    private func isDesktopAction(_ lower: String) -> Bool {
        let actionKeywords = [
            "click", "double click", "right click", "drag", "drop",
            "type ", "fill out", "enter text", "scroll",
            "take a screenshot", "capture screen", "close window"
        ]
        for kw in actionKeywords {
            if lower.starts(with: kw) || lower.contains(" \(kw) ") {
                return true
            }
        }
        return false
    }
}
