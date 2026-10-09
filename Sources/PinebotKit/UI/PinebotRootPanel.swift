import SwiftUI
import AppKit

/// Root shell view for the Pinebot panel.
/// Enforces 360pt width, 48pt unified header, explicit route transitions, and overflow navigation.
public struct PinebotRootPanel: View {
    @ObservedObject var panelModel: PanelViewModel
    @ObservedObject var assistant: PinebotAssistant
    @ObservedObject var providerManager: ProviderManager
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var taskEngine: ComputerTaskEngine
    
    public init(
        panelModel: PanelViewModel = .shared,
        assistant: PinebotAssistant = .shared,
        providerManager: ProviderManager = .shared,
        settingsStore: SettingsStore = .shared,
        taskEngine: ComputerTaskEngine = .shared
    ) {
        self.panelModel = panelModel
        self.assistant = assistant
        self.providerManager = providerManager
        self.settingsStore = settingsStore
        self.taskEngine = taskEngine
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Unified 48pt Header
            headerBar
            
            // Route Content
            ZStack {
                switch panelModel.currentRoute {
                case .welcome:
                    WelcomeView(panelModel: panelModel)
                case .chooseProvider:
                    ProviderChoiceView(panelModel: panelModel, providerManager: providerManager)
                case .connect(let type):
                    ProviderConnectionView(providerType: type, panelModel: panelModel, providerManager: providerManager)
                case .permissions:
                    ProviderChoiceView(panelModel: panelModel, providerManager: providerManager)
                case .chat:
                    ConversationView(assistant: assistant, providerManager: providerManager, settingsStore: settingsStore)
                case .settings:
                    PreferencesView(settingsStore: settingsStore)
                case .activity:
                    ActivityView(taskEngine: taskEngine)
                }
            }
        }
        .frame(width: 360)
        .frame(height: panelModel.currentRoute.targetHeight)
        .background(PinebotTheme.canvas)
        .cornerRadius(PinebotTheme.radiusOuter)
        .overlay(
            RoundedRectangle(cornerRadius: PinebotTheme.radiusOuter)
                .stroke(PinebotTheme.separator, lineWidth: 1)
        )
    }
    
    // MARK: - 48pt Header Bar
    
    private var headerBar: some View {
        HStack(spacing: PinebotTheme.space8) {
            if !panelModel.backStack.isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        panelModel.goBack()
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(PinebotTheme.fontCaptionMedium)
                    }
                    .foregroundColor(PinebotTheme.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go back")
            } else {
                let buddy = AssetLoader.shared.image(for: assistant.buddyState)
                Image(nsImage: buddy)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Pinebot companion")
            }
            
            Text("Pinebot")
                .font(PinebotTheme.fontTitle)
                .foregroundColor(PinebotTheme.textPrimary)
            
            Spacer()
            
            // Overflow menu
            Menu {
                Button("Chat") {
                    withAnimation { panelModel.navigate(to: .chat) }
                }
                Divider()
                Button("Accounts & Providers...") {
                    withAnimation { panelModel.navigate(to: .chooseProvider) }
                }
                Button("Computer Tasks & History...") {
                    withAnimation { panelModel.navigate(to: .activity) }
                }
                Divider()
                Button("Preferences...") {
                    withAnimation { panelModel.navigate(to: .settings) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundColor(PinebotTheme.textSecondary)
                    .accessibilityLabel("More options")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, PinebotTheme.space16)
        .frame(height: 48)
        .background(PinebotTheme.surface)
        .overlay(
            Divider().background(PinebotTheme.separator),
            alignment: .bottom
        )
    }
}

/// Backward compatibility alias for PinebotRootPanel
public typealias ChatPopoverView = PinebotRootPanel
