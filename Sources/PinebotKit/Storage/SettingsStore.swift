import Foundation
import Combine

/// Manages persistent companion settings via UserDefaults.
public final class SettingsStore: ObservableObject, @unchecked Sendable {
    public static let shared = SettingsStore()
    
    private let key = "com.pinebot.settings"
    private let defaults = UserDefaults.standard
    
    @Published public var settings: CompanionSettings {
        didSet {
            save()
        }
    }
    
    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(CompanionSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = CompanionSettings.default
        }
    }
    
    public func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: key)
        }
    }
    
    public func updatePosition(x: Double, y: Double) {
        settings.positionX = x
        settings.positionY = y
    }
    
    public func resetToDefaults() {
        settings = CompanionSettings.default
    }
}
