import Foundation

/// Represents the visual emotional and operational state of the Pinebot pineapple buddy.
public enum BuddyState: String, CaseIterable, Codable, Sendable {
    /// Normal idle state, happy and awake (image-1.png).
    case happy = "happy"
    
    /// Inactivity sleep state with reduced opacity (image-2.png).
    case sleeping = "sleeping"
    
    /// Actively running a computer task or executing tool calls (image-3.png).
    case working = "working"
    
    /// Thinking, routing model, or listening to voice (image-4.png).
    case thinking = "thinking"
    
    /// Encountered an error, validation failure, or task failure (image-5.png).
    case sad = "sad"
    
    /// The corresponding asset filename bundled with Pinebot.
    public var assetName: String {
        switch self {
        case .happy:
            return "image-1.png"
        case .sleeping:
            return "image-2.png"
        case .working:
            return "image-3.png"
        case .thinking:
            return "image-4.png"
        case .sad:
            return "image-5.png"
        }
    }
    
    /// Human-friendly display label.
    public var displayName: String {
        switch self {
        case .happy:
            return "Happy & Ready"
        case .sleeping:
            return "Sleeping (Zzz)"
        case .working:
            return "Working on Task"
        case .thinking:
            return "Thinking & Listening"
        case .sad:
            return "Needs Help / Error"
        }
    }
}
