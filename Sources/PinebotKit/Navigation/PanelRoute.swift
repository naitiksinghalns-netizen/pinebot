import Foundation

/// Explicit navigation routes for the Pinebot panel.
public enum PanelRoute: Equatable, Sendable {
    case welcome
    case chooseProvider
    case connect(ProviderType)
    case permissions
    case chat
    case settings
    case activity
    
    public var targetHeight: CGFloat {
        switch self {
        case .welcome: return 420.0
        case .chooseProvider: return 470.0
        case .connect: return 500.0
        case .permissions: return 430.0
        case .chat: return 520.0
        case .settings: return 500.0
        case .activity: return 480.0
        }
    }
}
