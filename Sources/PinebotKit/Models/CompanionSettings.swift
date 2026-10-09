import Foundation

/// Persistent user settings for the Pinebot companion and task engine.
public struct CompanionSettings: Codable, Sendable, Equatable {
    /// Size of the companion buddy window in points (default: 110pt, range: 80...160).
    public var buddySize: Double
    
    /// Idle delay in seconds before transitioning into sleep (default: 60s, range: 15...300).
    public var idleSleepDelay: Double
    
    /// Opacity when sleeping (default: 0.65, range: 0.3...0.95).
    public var sleepOpacity: Double
    
    /// Whether gentle breathing and bouncing animations are suppressed.
    public var reducedMotion: Bool
    
    /// Whether voice responses should be synthesized out loud.
    public var speechOutputEnabled: Bool
    
    /// Stored companion window position X (nil if using default centered/docked position).
    public var positionX: Double?
    
    /// Stored companion window position Y.
    public var positionY: Double?
    
    /// Maximum number of tool execution steps allowed per computer task (bounded loop).
    public var maxTaskSteps: Int
    
    /// Maximum execution time in seconds for a task loop before forced timeout.
    public var taskTimeoutSeconds: Double
    
    /// Require explicit user confirmation before executing physical clicks/typing.
    public var requireToolConfirmation: Bool
    
    /// User manual model override ("auto" or a specific model identifier like "gpt-4o", "claude-3-7-sonnet").
    public var modelOverride: String
    
    /// Optional user selected voice identifier ("" for system/natural British default).
    public var preferredVoiceId: String
    
    public init(
        buddySize: Double = 80.0,
        idleSleepDelay: Double = 60.0,
        sleepOpacity: Double = 0.30,
        reducedMotion: Bool = false,
        speechOutputEnabled: Bool = true,
        positionX: Double? = nil,
        positionY: Double? = nil,
        maxTaskSteps: Int = 10,
        taskTimeoutSeconds: Double = 60.0,
        requireToolConfirmation: Bool = true,
        modelOverride: String = "auto",
        preferredVoiceId: String = ""
    ) {
        self.buddySize = buddySize
        self.idleSleepDelay = idleSleepDelay
        self.sleepOpacity = sleepOpacity
        self.reducedMotion = reducedMotion
        self.speechOutputEnabled = speechOutputEnabled
        self.positionX = positionX
        self.positionY = positionY
        self.maxTaskSteps = maxTaskSteps
        self.taskTimeoutSeconds = taskTimeoutSeconds
        self.requireToolConfirmation = requireToolConfirmation
        self.modelOverride = modelOverride
        self.preferredVoiceId = preferredVoiceId
    }
    
    private enum CodingKeys: String, CodingKey {
        case buddySize, idleSleepDelay, sleepOpacity, reducedMotion
        case speechOutputEnabled, positionX, positionY, maxTaskSteps
        case taskTimeoutSeconds, requireToolConfirmation, modelOverride
        case preferredVoiceId
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buddySize = try container.decodeIfPresent(Double.self, forKey: .buddySize) ?? 80.0
        idleSleepDelay = try container.decodeIfPresent(Double.self, forKey: .idleSleepDelay) ?? 60.0
        sleepOpacity = try container.decodeIfPresent(Double.self, forKey: .sleepOpacity) ?? 0.30
        reducedMotion = try container.decodeIfPresent(Bool.self, forKey: .reducedMotion) ?? false
        speechOutputEnabled = try container.decodeIfPresent(Bool.self, forKey: .speechOutputEnabled) ?? true
        positionX = try container.decodeIfPresent(Double.self, forKey: .positionX)
        positionY = try container.decodeIfPresent(Double.self, forKey: .positionY)
        maxTaskSteps = try container.decodeIfPresent(Int.self, forKey: .maxTaskSteps) ?? 10
        taskTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .taskTimeoutSeconds) ?? 60.0
        requireToolConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requireToolConfirmation) ?? true
        modelOverride = try container.decodeIfPresent(String.self, forKey: .modelOverride) ?? "auto"
        preferredVoiceId = try container.decodeIfPresent(String.self, forKey: .preferredVoiceId) ?? ""
    }
    
    public static let `default` = CompanionSettings()
}
