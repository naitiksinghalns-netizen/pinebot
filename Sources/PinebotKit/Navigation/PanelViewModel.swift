import SwiftUI
import Combine

/// Manages routing and back-stack navigation for the Pinebot conversation & onboarding panel.
@MainActor
public final class PanelViewModel: ObservableObject {
    public static let shared = PanelViewModel()
    
    private let onboardingKey = "has_completed_onboarding"
    
    @Published public private(set) var currentRoute: PanelRoute
    @Published public private(set) var backStack: [PanelRoute] = []
    
    public init() {
        let completed = UserDefaults.standard.bool(forKey: onboardingKey)
        if completed {
            self.currentRoute = .chat
        } else {
            self.currentRoute = .welcome
        }
    }
    
    public var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: onboardingKey)
    }
    
    public func navigate(to route: PanelRoute) {
        guard route != currentRoute else { return }
        backStack.append(currentRoute)
        currentRoute = route
    }
    
    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        currentRoute = previous
    }
    
    public func reset(to route: PanelRoute) {
        backStack.removeAll()
        currentRoute = route
    }
    
    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        reset(to: .chat)
    }
    
    public func forceOnboarding() {
        reset(to: .welcome)
    }
}
