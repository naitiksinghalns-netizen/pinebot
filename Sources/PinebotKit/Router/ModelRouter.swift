import Foundation

/// Decision outcome produced by the Model Router.
public struct RouteDecision: Identifiable, Sendable, Equatable {
    public var id: String { selectedModel.id }
    public let selectedModel: ModelInfo
    public let routingReason: String
    public let confidence: Double
    public let classifierStatus: ClassifierStatus
    public let classification: TaskClassification
    public let escalationLevel: Int
    public let attemptedModelIds: Set<String>
    
    public init(
        selectedModel: ModelInfo,
        routingReason: String,
        confidence: Double,
        classifierStatus: ClassifierStatus,
        classification: TaskClassification,
        escalationLevel: Int = 0,
        attemptedModelIds: Set<String> = []
    ) {
        self.selectedModel = selectedModel
        self.routingReason = routingReason
        self.confidence = confidence
        self.classifierStatus = classifierStatus
        self.classification = classification
        self.escalationLevel = escalationLevel
        self.attemptedModelIds = attemptedModelIds.isEmpty ? [selectedModel.id] : attemptedModelIds.union([selectedModel.id])
    }
}

/// Specific actionable errors emitted by the ModelRouter.
public enum RouterError: LocalizedError, Equatable {
    case noModelsConnected
    case unmetCapability(reason: String)
    case modelNotFound(modelId: String)
    case maxEscalationsExceeded(lastError: String)
    case noAlternativeForEscalation(reason: String)
    case escalationNotPermitted(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .noModelsConnected:
            return "No AI models connected. Please connect ChatGPT, Claude, Gemini, or Ollama in the Providers tab."
        case .unmetCapability(let reason):
            return reason
        case .modelNotFound(let id):
            return "The selected model '\(id)' is not currently available or connected."
        case .maxEscalationsExceeded(let lastError):
            return "Exceeded maximum bounded model escalations (2). Last error: \(lastError)"
        case .noAlternativeForEscalation(let reason):
            return "No capable alternative model available for escalation: \(reason)"
        case .escalationNotPermitted(let reason):
            return reason
        }
    }
}

/// Deterministic policy router powered by the local classifier.
public final class ModelRouter: @unchecked Sendable {
    public static let shared = ModelRouter()
    
    public let classifier: LocalLearnedClassifier
    private let customClassifier: (@Sendable (String, Bool) async -> TaskClassification)?
    
    public init(
        classifier: LocalLearnedClassifier = .shared,
        customClassifier: (@Sendable (String, Bool) async -> TaskClassification)? = nil
    ) {
        self.classifier = classifier
        self.customClassifier = customClassifier
    }
    
    /// Asynchronously routes a prompt using the non-blocking classifier worker.
    public func route(
        prompt: String,
        hasScreenImage: Bool = false,
        connectedModels: [ModelInfo],
        userOverride: String = "auto",
        avoidModelIds: Set<String> = [],
        forceRequiresTools: Bool = false
    ) async throws -> RouteDecision {
        guard !connectedModels.isEmpty else {
            throw RouterError.noModelsConnected
        }
        
        let classification: TaskClassification
        if let custom = customClassifier {
            classification = await custom(prompt, hasScreenImage)
        } else {
            classification = await classifier.classify(prompt: prompt, hasScreenImage: hasScreenImage)
        }
        var finalClassification = classification
        if forceRequiresTools && !finalClassification.requiresComputerTools {
            finalClassification = TaskClassification(
                category: classification.category,
                difficulty: classification.difficulty,
                reasoningScore: classification.reasoningScore,
                requiresVision: classification.requiresVision,
                requiresComputerTools: true,
                status: classification.status,
                confidence: classification.confidence,
                rawScores: classification.rawScores
            )
        }
        
        return try makeDecision(
            prompt: prompt,
            classification: finalClassification,
            hasScreenImage: hasScreenImage,
            connectedModels: connectedModels,
            userOverride: userOverride,
            avoidModelIds: avoidModelIds
        )
    }
    
    /// Synchronously routes a prompt using synchronous classification fallback.
    public func route(
        prompt: String,
        hasScreenImage: Bool = false,
        connectedModels: [ModelInfo],
        userOverride: String = "auto",
        avoidModelIds: Set<String> = [],
        forceRequiresTools: Bool = false
    ) throws -> RouteDecision {
        guard !connectedModels.isEmpty else {
            throw RouterError.noModelsConnected
        }
        
        let classification = classifier.classify(prompt: prompt, hasScreenImage: hasScreenImage)
        var finalClassification = classification
        if forceRequiresTools && !finalClassification.requiresComputerTools {
            finalClassification = TaskClassification(
                category: classification.category,
                difficulty: classification.difficulty,
                reasoningScore: classification.reasoningScore,
                requiresVision: classification.requiresVision,
                requiresComputerTools: true,
                status: classification.status,
                confidence: classification.confidence,
                rawScores: classification.rawScores
            )
        }
        
        return try makeDecision(
            prompt: prompt,
            classification: finalClassification,
            hasScreenImage: hasScreenImage,
            connectedModels: connectedModels,
            userOverride: userOverride,
            avoidModelIds: avoidModelIds
        )
    }
    
    private func makeDecision(
        prompt: String,
        classification: TaskClassification,
        hasScreenImage: Bool,
        connectedModels: [ModelInfo],
        userOverride: String,
        avoidModelIds: Set<String>
    ) throws -> RouteDecision {
        let needsVision = classification.requiresVision || hasScreenImage
        let needsTools = classification.requiresComputerTools
        
        // 1. Manual user override check
        if userOverride != "auto" {
            guard let overridden = connectedModels.first(where: { $0.id == userOverride }) else {
                throw RouterError.modelNotFound(modelId: userOverride)
            }
            
            // Validate that the manually overridden model actually satisfies required capabilities
            if needsVision && !overridden.supportsVision {
                throw RouterError.unmetCapability(
                    reason: "Manual override '\(overridden.displayName)' does not support vision, but this task requires screen analysis. Please choose a vision-capable model (like GPT-4o, Claude Sonnet, or Gemini) or switch to Auto."
                )
            }
            if needsTools && !overridden.supportsComputerPlanning {
                throw RouterError.unmetCapability(
                    reason: "Manual override '\(overridden.displayName)' does not support computer task planning, but this task requires tool actions. Please select a planning-capable model or switch to Auto."
                )
            }
            
            return RouteDecision(
                selectedModel: overridden,
                routingReason: "Manual override selected by user (\(overridden.displayName))",
                confidence: 1.0,
                classifierStatus: classification.status,
                classification: classification,
                escalationLevel: 0
            )
        }
        
        // 2. Filter available candidates (excluding previously failed models)
        var candidates = connectedModels.filter { !avoidModelIds.contains($0.id) }
        if candidates.isEmpty {
            candidates = connectedModels
        }
        
        // 3. Strictly enforce required capabilities (never silently pick an incapable model)
        if needsVision {
            let visionCandidates = candidates.filter { $0.supportsVision }
            guard !visionCandidates.isEmpty else {
                let connectedNames = connectedModels.map { $0.displayName }.joined(separator: ", ")
                throw RouterError.unmetCapability(
                    reason: "Task requires vision/screen analysis, but none of the connected models (\(connectedNames)) support image inputs. Please connect a vision-capable model (e.g. GPT-4o, Claude 3.5/3.7 Sonnet, or Gemini) in the Providers tab."
                )
            }
            candidates = visionCandidates
        }
        
        if needsTools {
            let toolCandidates = candidates.filter { $0.supportsComputerPlanning }
            guard !toolCandidates.isEmpty else {
                let connectedNames = connectedModels.map { $0.displayName }.joined(separator: ", ")
                throw RouterError.unmetCapability(
                    reason: "Task requires computer tool actions, but none of the connected models (\(connectedNames)) support computer task planning. Please connect a vision/planning capable model in the Providers tab."
                )
            }
            candidates = toolCandidates
        }
        
        // 4. Map task difficulty to target tier
        let targetTier: ModelTier
        switch classification.difficulty {
        case .simple:
            targetTier = .cheapFast
        case .medium:
            targetTier = .balanced
        case .complex:
            targetTier = .frontierReasoning
        }
        
        // 5. Select best candidate matching target tier, or closest available tier
        let selectedModel = selectBestCandidate(from: candidates, preferredTier: targetTier)
        
        let reason: String
        switch classification.difficulty {
        case .simple:
            if selectedModel.isLocal {
                reason = "Routed to local Ollama (\(selectedModel.displayName)): simple query, private & zero-cost."
            } else {
                reason = "Routed to \(selectedModel.displayName): simple query (\(classification.category.rawValue)), minimizing latency & cost."
            }
        case .medium:
            reason = "Routed to \(selectedModel.displayName): moderate complexity task (\(classification.category.rawValue))."
        case .complex:
            reason = "Routed to \(selectedModel.displayName): complex task (\(classification.category.rawValue), reasoning demand: \(String(format: "%.2f", classification.reasoningScore))). Frontier model selected."
        }
        
        return RouteDecision(
            selectedModel: selectedModel,
            routingReason: reason,
            confidence: classification.confidence,
            classifierStatus: classification.status,
            classification: classification,
            escalationLevel: 0
        )
    }
    
    private func selectBestCandidate(from candidates: [ModelInfo], preferredTier: ModelTier) -> ModelInfo {
        // Look for exact tier match
        let exactMatches = candidates.filter { $0.tier == preferredTier }
        if !exactMatches.isEmpty {
            // For cheap/fast tier, prefer local models if available
            if preferredTier == .cheapFast, let local = exactMatches.first(where: { $0.isLocal }) {
                return local
            }
            return exactMatches.first!
        }
        
        // If preferred tier not found:
        // If simple was preferred, pick lowest tier available
        if preferredTier == .cheapFast {
            return candidates.sorted { $0.tier < $1.tier }.first!
        }
        
        // If complex was preferred, pick highest tier available
        if preferredTier == .frontierReasoning {
            return candidates.sorted { $0.tier > $1.tier }.first!
        }
        
        return candidates.first!
    }
    
    /// Bounded escalation: escalates to next tier after an execution failure, up to max 2 escalations.
    /// Strictly filters candidates to preserve required capabilities (vision and tools).
    /// Typed error handling:
    /// - auth / cancel must NOT trigger expensive reasoning escalation.
    /// - quota fallback (429 / rate limit) chooses an eligible peer at the same tier first before quality escalation.
    /// - execution / quality failure triggers justified quality escalation.
    public func escalate(
        currentDecision: RouteDecision,
        error: String,
        connectedModels: [ModelInfo]
    ) throws -> RouteDecision {
        // 1. Cancellation must never trigger model escalation
        let isCancel = error.localizedCaseInsensitiveContains("cancel") ||
                       error.localizedCaseInsensitiveContains("stopped")
        if isCancel {
            throw CancellationError()
        }
        
        // 2. Auth failures must not trigger expensive reasoning escalation
        let isAuth = error.localizedCaseInsensitiveContains("401") ||
                     error.localizedCaseInsensitiveContains("unauthorized") ||
                     error.localizedCaseInsensitiveContains("authentication") ||
                     error.localizedCaseInsensitiveContains("invalid api key") ||
                     error.localizedCaseInsensitiveContains("token expired") ||
                     error.localizedCaseInsensitiveContains("not authenticated") ||
                     error.localizedCaseInsensitiveContains("re-authenticate")
        if isAuth {
            throw RouterError.escalationNotPermitted(
                reason: "Authentication failure (\(error)). Re-authentication required; reasoning escalation suppressed."
            )
        }
        
        let nextEscalationLevel = currentDecision.escalationLevel + 1
        guard nextEscalationLevel <= 2 else {
            throw RouterError.maxEscalationsExceeded(lastError: error)
        }
        
        var avoid = currentDecision.attemptedModelIds
        avoid.insert(currentDecision.selectedModel.id)
        
        // Strictly filter candidates to preserve required capabilities
        let needsVision = currentDecision.classification.requiresVision
        let needsTools = currentDecision.classification.requiresComputerTools
        
        var capableModels = connectedModels
        if needsVision {
            capableModels = capableModels.filter { $0.supportsVision }
        }
        if needsTools {
            capableModels = capableModels.filter { $0.supportsComputerPlanning }
        }
        
        guard !capableModels.isEmpty else {
            let capStr = needsVision ? "vision-capable " : (needsTools ? "planning-capable " : "")
            throw RouterError.noAlternativeForEscalation(
                reason: "No \(capStr)model available after \(currentDecision.selectedModel.displayName) failed with: \(error)"
            )
        }
        
        var remaining = capableModels.filter { !avoid.contains($0.id) }
        if remaining.isEmpty {
            // If all capable models have been attempted across levels, allow recycling capable models excluding the immediate current failure
            remaining = capableModels.filter { $0.id != currentDecision.selectedModel.id }
        }
        
        guard !remaining.isEmpty else {
            let capStr = needsVision ? "vision-capable " : (needsTools ? "planning-capable " : "")
            throw RouterError.noAlternativeForEscalation(
                reason: "No alternative \(capStr)model available after \(currentDecision.selectedModel.displayName) failed with: \(error)"
            )
        }
        
        // 3. Quota / Rate limit (429): Quota fallback chooses eligible peer at same tier first!
        let isRateLimit = error.localizedCaseInsensitiveContains("429") ||
                          error.localizedCaseInsensitiveContains("rate limit") ||
                          error.localizedCaseInsensitiveContains("quota") ||
                          error.localizedCaseInsensitiveContains("resource exhausted") ||
                          error.localizedCaseInsensitiveContains("too many requests") ||
                          error.localizedCaseInsensitiveContains("out of credits")
        
        let nextModel: ModelInfo
        let reason: String
        
        if isRateLimit {
            // First look for eligible peer at the SAME tier
            let sameTierPeers = remaining.filter { $0.tier == currentDecision.selectedModel.tier }
            if let peer = sameTierPeers.first {
                nextModel = peer
                reason = "Quota fallback to peer model \(peer.displayName) (same tier: \(peer.tier.displayName)) following rate limit: \(error)"
            } else {
                // If no peer at same tier, fallback to closest available tier (prefer balanced before frontier)
                if currentDecision.selectedModel.tier == .cheapFast,
                   let balanced = remaining.filter({ $0.tier == .balanced }).first {
                    nextModel = balanced
                    reason = "Quota fallback to \(balanced.displayName) following rate limit: \(error)"
                } else {
                    let sorted = remaining.sorted { $0.tier > $1.tier }
                    nextModel = sorted.first!
                    reason = "Quota fallback to \(nextModel.displayName) following rate limit: \(error)"
                }
            }
        } else {
            // 4. Justified quality escalation following execution / reasoning failure
            let sorted = remaining.sorted { $0.tier > $1.tier }
            nextModel = sorted.first!
            reason = "Escalated to \(nextModel.displayName) (Level \(nextEscalationLevel)) following failure: \(error)"
        }
        
        var nextAttempted = avoid
        nextAttempted.insert(nextModel.id)
        return RouteDecision(
            selectedModel: nextModel,
            routingReason: reason,
            confidence: currentDecision.confidence * 0.9,
            classifierStatus: currentDecision.classifierStatus,
            classification: currentDecision.classification,
            escalationLevel: nextEscalationLevel,
            attemptedModelIds: nextAttempted
        )
    }
}
