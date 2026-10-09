import AppKit
import Combine

/// Global monitor for modifier-only hotkeys: specifically tracks holding Command + Option to talk.
@MainActor
public final class ModifierHotkeyMonitor: ObservableObject {
    public static let shared = ModifierHotkeyMonitor()
    
    @Published public private(set) var isCommandOptionHeld: Bool = false
    
    public var onFlagsDown: (() -> Void)?
    public var onFlagsUp: (() -> Void)?
    
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isStarted = false
    
    private init() {}
    
    /// Starts monitoring for Command+Option modifier key state changes globally and locally.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        
        // Global monitor (when app is in background)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event.modifierFlags)
            }
        }
        
        // Local monitor (when app or popover is key)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event.modifierFlags)
            }
            return event
        }
    }
    
    /// Stops event monitors.
    public func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        isStarted = false
        if isCommandOptionHeld {
            isCommandOptionHeld = false
            onFlagsUp?()
        }
    }
    
    public func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isBothDown = hasCommand && hasOption
        
        if isBothDown && !isCommandOptionHeld {
            isCommandOptionHeld = true
            onFlagsDown?()
        } else if !isBothDown && isCommandOptionHeld {
            isCommandOptionHeld = false
            onFlagsUp?()
        }
    }
    
    deinit {
        // Monitors are removed via stop()
    }
}
