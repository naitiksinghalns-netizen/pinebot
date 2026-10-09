import AppKit
import SwiftUI
import Combine
import PinebotKit

/// Floating companion buddy panel that cannot become key window to prevent focus stealing.
final class BuddyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Conversation and onboarding panel that CAN become key window for keyboard input and handles ESC.
final class ConversationPanel: NSPanel {
    var onEscapePressed: (() -> Void)?
    
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var companionWindow: BuddyPanel?
    private var chatPopoverWindow: ConversationPanel?
    private var captionController: CaptionPanelController?
    private var statusItem: NSStatusItem?
    
    private let assistant = PinebotAssistant.shared
    private let settingsStore = SettingsStore.shared
    private let providerManager = ProviderManager.shared
    private let overlayManager = ScreenOverlayManager.shared
    private let taskEngine = ComputerTaskEngine.shared
    private let hotkeys = ModifierHotkeyMonitor.shared
    private let panelViewModel = PanelViewModel.shared
    private let motionController = CompanionMotionController.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Accessory prevents dock clutter and focus stealing
        
        let testOnboarding = CommandLine.arguments.contains("--test-onboarding")
        if testOnboarding {
            panelViewModel.forceOnboarding()
        }
        
        setupModelWeightsDirectory()
        setupCompanionWindow()
        setupChatPopoverWindow()
        self.captionController = CaptionPanelController.shared
        setupStatusItem()
        observeRouteChanges()
        observeBuddySettings()
        
        // Start Command+Option hold monitor
        hotkeys.start()
        
        // Validate configured providers in background
        Task {
            await providerManager.validateAllConfigured()
        }
        
        // First launch or test flag automatically displays onboarding anchored beside buddy
        if testOnboarding || !panelViewModel.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showChatPopover()
            }
        }
        UIDiagnosticLogger.log(event: "launch")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCompanion()
        return true
    }
    
    func showCompanion() {
        guard let panel = companionWindow else { return }
        panel.orderFrontRegardless()
        motionController.setVisible(true)
        UIDiagnosticLogger.log(event: "showCompanion")
    }
    
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == chatPopoverWindow {
            showCompanion()
        }
    }
    
    private func setupModelWeightsDirectory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let targetDir = appSupport.appendingPathComponent("Pinebot/models")
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        let cwd = FileManager.default.currentDirectoryPath
        let candidateModelDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("models"),
            URL(fileURLWithPath: cwd).appendingPathComponent("work/pinebot/models"),
            URL(fileURLWithPath: cwd).appendingPathComponent("models")
        ].compactMap { $0 }
        
        let sourceModelDir = candidateModelDirs.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.onnx").path)
        }
        
        if let sourceDir = sourceModelDir {
            let modelFile = sourceDir.appendingPathComponent("model.onnx")
            let tokFile = sourceDir.appendingPathComponent("tokenizer.json")
            
            if FileManager.default.fileExists(atPath: modelFile.path) {
                let destModel = targetDir.appendingPathComponent("model.onnx")
                if !FileManager.default.fileExists(atPath: destModel.path) {
                    try? FileManager.default.copyItem(at: modelFile, to: destModel)
                }
            }
            if FileManager.default.fileExists(atPath: tokFile.path) {
                let destTok = targetDir.appendingPathComponent("tokenizer.json")
                if !FileManager.default.fileExists(atPath: destTok.path) {
                    try? FileManager.default.copyItem(at: tokFile, to: destTok)
                }
            }
        }
    }
    
    private func setupCompanionWindow() {
        guard let screen = NSScreen.main else { return }
        
        let size = CompanionMotionController.containerSize(for: settingsStore.settings.buddySize)
        let panelSize = CGSize(width: size, height: size)
        let initialX: CGFloat
        let initialY: CGFloat
        
        if let savedX = settingsStore.settings.positionX,
           let savedY = settingsStore.settings.positionY {
            let clamped = CompanionMotionController.clamp(
                origin: CGPoint(x: savedX, y: savedY),
                size: panelSize,
                within: screen.visibleFrame
            )
            initialX = clamped.x
            initialY = clamped.y
        } else {
            // Default to bottom right near dock
            initialX = screen.visibleFrame.maxX - size - 40
            initialY = screen.visibleFrame.minY + 60
        }
        
        let panel = BuddyPanel(
            contentRect: NSRect(x: initialX, y: initialY, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.title = "Pinebot Buddy"
        panel.setAccessibilityTitle("Pinebot Buddy")
        panel.setAccessibilityLabel("Pinebot Buddy")
        panel.setAccessibilityRole(.window)
        
        let companionView = CompanionView(
            assistant: assistant,
            settingsStore: settingsStore,
            motionController: motionController,
            onToggleChat: { [weak self] in
                self?.toggleChatPopover()
            },
            onDragEnded: { [weak self, weak panel] in
                guard let self = self, let panel = panel else { return }
                self.settingsStore.updatePosition(x: panel.frame.origin.x, y: panel.frame.origin.y)
            }
        )
        
        let hosting = NSHostingView(rootView: companionView)
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.companionWindow = panel
    }
    
    private func setupChatPopoverWindow() {
        let width: CGFloat = 360
        let height: CGFloat = panelViewModel.currentRoute.targetHeight
        
        let panel = ConversationPanel(
            contentRect: NSRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.title = "Pinebot Conversation"
        panel.setAccessibilityTitle("Pinebot Conversation")
        panel.setAccessibilityLabel("Pinebot Conversation")
        panel.setAccessibilityRole(.window)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.delegate = self
        panel.onEscapePressed = { [weak self] in
            self?.hideChatPopover()
        }
        
        let rootView = PinebotRootPanel(
            panelModel: panelViewModel,
            assistant: assistant,
            providerManager: providerManager,
            settingsStore: settingsStore,
            taskEngine: taskEngine
        )
        
        panel.contentView = NSHostingView(rootView: rootView)
        self.chatPopoverWindow = panel
    }
    
    private func observeRouteChanges() {
        panelViewModel.$currentRoute
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newRoute in
                self?.adjustPanelHeight(newRoute.targetHeight)
            }
            .store(in: &cancellables)
    }
    
    private func observeBuddySettings() {
        settingsStore.$settings
            .map(\.buddySize)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSize in
                self?.updateCompanionPanelSize(newSize)
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.clampCompanionPanelToCurrentScreen()
            }
            .store(in: &cancellables)
    }
    
    private func updateCompanionPanelSize(_ buddySize: Double) {
        guard let panel = companionWindow else { return }
        let newSide = CompanionMotionController.containerSize(for: buddySize)
        let newSize = CGSize(width: newSide, height: newSide)
        
        let oldFrame = panel.frame
        // Ignore initial same-size settings emission rather than cancelling valid gestures unnecessarily
        guard abs(oldFrame.width - newSize.width) > 0.5 || abs(oldFrame.height - newSize.height) > 0.5 else {
            return
        }
        
        // Before a REAL size change, invalidate/cancel pointer ownership and neutralize transforms
        motionController.cancelInteraction()
        
        // Preserve center
        let oldCenterX = oldFrame.midX
        let oldCenterY = oldFrame.midY
        
        var newOrigin = CGPoint(
            x: oldCenterX - (newSize.width / 2.0),
            y: oldCenterY - (newSize.height / 2.0)
        )
        
        // Prefer existing panel screen/frame (or nearest intersecting screen on removal), NOT mouse screen!
        let targetScreen = CompanionMotionController.screenForWindow(frame: oldFrame, panelScreen: panel.screen)
        if let visible = targetScreen?.visibleFrame {
            newOrigin = CompanionMotionController.clamp(origin: newOrigin, size: newSize, within: visible)
        }
        
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: false)
        panel.orderFrontRegardless()
        settingsStore.updatePosition(x: newOrigin.x, y: newOrigin.y)
    }
    
    private func clampCompanionPanelToCurrentScreen() {
        guard let panel = companionWindow else { return }
        motionController.resetDrag()
        
        // Prefer existing panel screen/frame (or nearest intersecting screen on removal), NOT mouse screen!
        let targetScreen = CompanionMotionController.screenForWindow(frame: panel.frame, panelScreen: panel.screen)
        guard let visible = targetScreen?.visibleFrame else { return }
        
        let clampedOrigin = CompanionMotionController.clamp(origin: panel.frame.origin, size: panel.frame.size, within: visible)
        if clampedOrigin != panel.frame.origin {
            panel.setFrameOrigin(clampedOrigin)
            settingsStore.updatePosition(x: clampedOrigin.x, y: clampedOrigin.y)
        }
    }
    
    private func adjustPanelHeight(_ targetHeight: CGFloat) {
        guard let panel = chatPopoverWindow, panel.isVisible else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        
        let maxHeight = max(200, visible.height - 16)
        let clampedHeight = min(targetHeight, maxHeight)
        
        var frame = panel.frame
        let diff = clampedHeight - frame.height
        frame.origin.y -= diff // Keep top anchored, expand/contract downwards
        frame.size.height = clampedHeight
        
        // Clamp within visible screen boundaries
        if frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        if frame.maxY > visible.maxY - 8 {
            frame.origin.y = visible.maxY - 8 - frame.size.height
        }
        if frame.minX < visible.minX + 8 {
            frame.origin.x = visible.minX + 8
        }
        if frame.maxX > visible.maxX - 8 {
            frame.origin.x = visible.maxX - 8 - frame.size.width
        }
        
        panel.setFrame(frame, display: true, animate: false)
    }
    
    private func toggleChatPopover() {
        guard let popover = chatPopoverWindow else { return }
        if popover.isVisible {
            hideChatPopover()
        } else {
            showChatPopover()
        }
    }
    
    private func hideChatPopover() {
        chatPopoverWindow?.orderOut(nil)
        showCompanion()
        UIDiagnosticLogger.log(event: "hideChatPopover")
    }
    
    private func showChatPopover() {
        guard let popover = chatPopoverWindow, let companion = companionWindow else { return }
        
        let buddyFrame = companion.frame
        let screen = companion.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        
        let width: CGFloat = 360
        let height = panelViewModel.currentRoute.targetHeight
        
        // Placement: anchor beside buddy, prefer left side with 12pt margin; flip to right if constrained
        var x = buddyFrame.minX - width - 12
        if x < visible.minX + 8 {
            x = buddyFrame.maxX + 12
        }
        // Clamp X within visible screen
        if x + width > visible.maxX - 8 {
            x = visible.maxX - width - 8
        }
        x = max(x, visible.minX + 8)
        
        // Vertical placement: align top with buddy top, clamp within visible screen
        var y = buddyFrame.maxY - height
        if y < visible.minY + 8 {
            y = visible.minY + 8
        }
        if y + height > visible.maxY - 8 {
            y = visible.maxY - height - 8
        }
        
        popover.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: false)
        popover.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🍍"
            button.toolTip = "Pinebot Desktop Companion"
            button.setAccessibilityTitle("Pinebot Desktop Companion")
            button.setAccessibilityLabel("Pinebot Desktop Companion")
            button.setAccessibilityRole(.button)
        }
        
        let menu = NSMenu()
        menu.title = "Pinebot Status Menu"
        menu.setAccessibilityTitle("Pinebot Status Menu")
        menu.setAccessibilityLabel("Pinebot Status Menu")
        menu.addItem(NSMenuItem(title: "Toggle Pinebot Companion", action: #selector(toggleCompanion), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Open Chat & Assistant", action: #selector(openChat), keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Hold ⌘⌥ to Talk", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Screen Overlay", action: #selector(clearOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Pinebot", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func toggleCompanion() {
        guard let panel = companionWindow else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            motionController.setVisible(false)
        } else {
            panel.orderFrontRegardless()
            motionController.setVisible(true)
        }
    }
    
    @objc private func openChat() {
        toggleChatPopover()
    }
    
    @objc private func clearOverlay() {
        overlayManager.clear()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// Application Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
