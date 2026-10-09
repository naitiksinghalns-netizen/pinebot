import Foundation

/// Supported LLM providers.
public enum ProviderType: String, Codable, CaseIterable, Sendable {
    case openai = "openai"
    case claude = "claude"
    case gemini = "gemini"
    case ollama = "ollama"
    
    public var displayName: String {
        switch self {
        case .openai: return "ChatGPT / OpenAI"
        case .claude: return "Claude (Anthropic)"
        case .gemini: return "Gemini (Google)"
        case .ollama: return "Ollama (Local)"
        }
    }
}

/// Operational performance and cost tier for models.
public enum ModelTier: String, Codable, Comparable, Sendable {
    case cheapFast = "cheap_fast"
    case balanced = "balanced"
    case frontierReasoning = "frontier_reasoning"
    
    private var sortOrder: Int {
        switch self {
        case .cheapFast: return 1
        case .balanced: return 2
        case .frontierReasoning: return 3
        }
    }
    
    public var displayName: String {
        switch self {
        case .cheapFast: return "Cheap / Fast"
        case .balanced: return "Balanced"
        case .frontierReasoning: return "Frontier Reasoning"
        }
    }
    
    public static func < (lhs: ModelTier, rhs: ModelTier) -> Bool {
        return lhs.sortOrder < rhs.sortOrder
    }
}

/// Information about a discovered and validated model from a provider.
public struct ModelInfo: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let provider: ProviderType
    public let tier: ModelTier
    public let supportsVision: Bool
    public let supportsTools: Bool
    public let supportsComputerPlanning: Bool
    public let isLocal: Bool
    
    public init(
        id: String,
        displayName: String,
        provider: ProviderType,
        tier: ModelTier,
        supportsVision: Bool = true,
        supportsTools: Bool = true,
        supportsComputerPlanning: Bool? = nil,
        isLocal: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.tier = tier
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsComputerPlanning = supportsComputerPlanning ?? (supportsVision && supportsTools)
        self.isLocal = isLocal
    }
    
    public var compactDisplayName: String {
        if let parenIndex = displayName.firstIndex(of: "(") {
            let prefix = displayName[..<parenIndex].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                return prefix
            }
        }
        return displayName
    }
}
