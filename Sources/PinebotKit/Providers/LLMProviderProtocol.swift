import AppKit

/// Common protocol implemented by all AI model providers.
public protocol LLMProvider: AnyObject, Sendable {
    var type: ProviderType { get }
    var isConfigured: Bool { get }
    var isConnected: Bool { get }
    var statusDescription: String { get }
    var discoveredModels: [ModelInfo] { get }
    
    /// Validates authentication and discovers available models.
    func validateAndDiscoverModels() async throws -> [ModelInfo]
    
    /// Generates text completion for a prompt, optional system instruction, and optional screen image.
    func generateCompletion(
        prompt: String,
        systemPrompt: String?,
        image: NSImage?,
        model: String
    ) async throws -> String
    
    /// Disconnects and purges credentials.
    func disconnect()
    
    /// Cancels any active generation for this provider.
    func cancelGeneration() async
}

extension LLMProvider {
    public func cancelGeneration() async {}
}
