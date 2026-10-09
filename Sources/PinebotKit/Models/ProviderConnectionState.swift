import Foundation

/// Represents the explicit connection lifecycle of an AI provider.
public enum ProviderConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(stage: String)
    case needsAuthorization(authURL: URL)
    case validating
    case connected(accountSummary: String, models: [ModelInfo])
    case failed(message: String, recovery: String)
    
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
    
    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
    
    public var statusTitle: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting(let stage):
            return "Connecting (\(stage))"
        case .needsAuthorization:
            return "Waiting for Authorization"
        case .validating:
            return "Validating Catalog"
        case .connected(let summary, _):
            return summary
        case .failed(let message, _):
            return message
        }
    }
}
