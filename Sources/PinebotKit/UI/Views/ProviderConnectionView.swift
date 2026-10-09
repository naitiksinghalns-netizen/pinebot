import SwiftUI
import AppKit

/// Focused setup view for one selected AI provider.
public struct ProviderConnectionView: View {
    public let providerType: ProviderType
    
    @ObservedObject var panelModel: PanelViewModel
    @ObservedObject var providerManager: ProviderManager
    
    @State private var apiKeyInput: String = ""
    @State private var endpointInput: String = "http://localhost:11434"
    @State private var isAuthInProgress: Bool = false
    @State private var showGeminiAPIKey: Bool = false
    @State private var showClaudeAPIKey: Bool = false
    @State private var showOpenAIAPIKey: Bool = false
    
    public init(
        providerType: ProviderType,
        panelModel: PanelViewModel = .shared,
        providerManager: ProviderManager = .shared
    ) {
        self.providerType = providerType
        self.panelModel = panelModel
        self.providerManager = providerManager
    }
    
    private var currentState: ProviderConnectionState {
        providerManager.state(for: providerType)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: PinebotTheme.space16) {
                    VStack(alignment: .leading, spacing: PinebotTheme.space4) {
                        Text(providerTitle)
                            .font(PinebotTheme.fontTitle)
                            .foregroundColor(PinebotTheme.textPrimary)
                        
                        Text(providerDescription)
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PinebotTheme.space8)
                    
                    // Connection state banner
                    stateBannerView
                    
                    // Provider form
                    VStack(spacing: PinebotTheme.space12) {
                        switch providerType {
                        case .openai:
                            openAIForm
                        case .claude:
                            claudeForm
                        case .gemini:
                            geminiForm
                        case .ollama:
                            ollamaForm
                        }
                    }
                }
                .padding(.horizontal, PinebotTheme.space16)
                .padding(.vertical, PinebotTheme.space8)
            }
            
            Divider().background(PinebotTheme.separator)
            
            // Bottom action bar
            HStack {
                Button("Back") {
                    panelModel.goBack()
                }
                .buttonStyle(.plain)
                .font(PinebotTheme.fontBody)
                .foregroundColor(PinebotTheme.textSecondary)
                
                Spacer()
                
                if currentState.isConnected {
                    Button(action: {
                        panelModel.completeOnboarding()
                    }) {
                        Text("Start using Pinebot")
                            .font(PinebotTheme.fontBodyMedium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(PinebotTheme.green)
                            .cornerRadius(PinebotTheme.radiusControl)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PinebotTheme.space16)
            .padding(.vertical, PinebotTheme.space12)
            .background(PinebotTheme.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PinebotTheme.canvas)
    }
    
    private var providerTitle: String {
        switch providerType {
        case .openai: return "Connect ChatGPT"
        case .claude: return "Connect Claude"
        case .gemini: return "Connect Gemini"
        case .ollama: return "Connect Local Ollama"
        }
    }
    
    private var providerDescription: String {
        switch providerType {
        case .openai:
            return "Sign in with your ChatGPT account to use models included with your plan. Optional API keys are under Advanced."
        case .claude:
            return "Sign in with your official Anthropic Claude account via Claude Code CLI. Optional API keys are under Advanced."
        case .gemini:
            return "Sign in with your Google account to access Gemini models. Optional API keys are under Advanced."
        case .ollama:
            return "Run models locally on your Mac without internet access or fees."
        }
    }
    
    @ViewBuilder
    private var stateBannerView: some View {
        switch currentState {
        case .disconnected, .connecting:
            EmptyView()
            
        case .needsAuthorization:
            HStack(spacing: 8) {
                Image(systemName: "safari")
                    .foregroundColor(PinebotTheme.amber)
                Text("Complete authorization in Safari, then return here.")
                    .font(PinebotTheme.fontCaption)
                    .foregroundColor(PinebotTheme.textPrimary)
                Spacer()
            }
            .padding(10)
            .background(PinebotTheme.amber.opacity(0.1))
            .cornerRadius(PinebotTheme.radiusCard)
            
        case .validating:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("Validating models catalog...")
                    .font(PinebotTheme.fontCaption)
                    .foregroundColor(PinebotTheme.textSecondary)
                Spacer()
            }
            .padding(10)
            .background(PinebotTheme.surface)
            .cornerRadius(PinebotTheme.radiusCard)
            
        case .connected(let summary, let models):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(PinebotTheme.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary)
                        .font(PinebotTheme.fontCaptionMedium)
                        .foregroundColor(PinebotTheme.textPrimary)
                    Text("\(models.count) model\(models.count > 1 ? "s" : "") ready")
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.textSecondary)
                }
                Spacer()
                Button("Disconnect") {
                    providerManager.disconnect(provider: providerType)
                }
                .buttonStyle(.plain)
                .font(PinebotTheme.fontCaptionMedium)
                .foregroundColor(PinebotTheme.error)
            }
            .padding(10)
            .background(PinebotTheme.green.opacity(0.1))
            .cornerRadius(PinebotTheme.radiusCard)
            
        case .failed(let message, let recovery):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(PinebotTheme.error)
                    Text(message)
                        .font(PinebotTheme.fontCaptionMedium)
                        .foregroundColor(PinebotTheme.textPrimary)
                    Spacer()
                    Button("Retry") {
                        Task {
                            await providerManager.validateProvider(providerType)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(PinebotTheme.fontCaptionMedium)
                    .foregroundColor(PinebotTheme.amber)
                }
                Text(recovery)
                    .font(PinebotTheme.fontCaption)
                    .foregroundColor(PinebotTheme.textSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PinebotTheme.error.opacity(0.08))
            .cornerRadius(PinebotTheme.radiusCard)
        }
    }
    
    // MARK: - Forms
    
    private var openAIForm: some View {
        VStack(spacing: PinebotTheme.space12) {
            if isAuthInProgress {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for authorization in Safari...")
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.textSecondary)
                    
                    Button("Cancel") {
                        isAuthInProgress = false
                        providerManager.setState(.disconnected, for: .openai)
                    }
                    .buttonStyle(.plain)
                    .font(PinebotTheme.fontCaptionMedium)
                    .foregroundColor(PinebotTheme.error)
                }
                .padding(.vertical, 12)
            } else {
                if currentState.isConnected {
                    VStack(spacing: 8) {
                        Button(action: startChatGPTAuth) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Switch ChatGPT Account")
                                    .font(PinebotTheme.fontBodyMedium)
                            }
                            .foregroundColor(PinebotTheme.amber)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(PinebotTheme.surface)
                            .cornerRadius(PinebotTheme.radiusControl)
                        }
                        .buttonStyle(.plain)
                        
                        Text("ChatGPT Account • Eligible models ready")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    VStack(spacing: 6) {
                        Button(action: startChatGPTAuth) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .accessibilityLabel("Sign in with ChatGPT")
                                Text("Sign in with ChatGPT")
                                    .font(PinebotTheme.fontBodyMedium)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(PinebotTheme.amber)
                            .cornerRadius(PinebotTheme.radiusControl)
                        }
                        .buttonStyle(.plain)
                        
                        Text("Primary: ChatGPT Account (Plus, Pro, Team)")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                // Advanced Collapsible API Key Fallback
                VStack(spacing: 8) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showOpenAIAPIKey.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showOpenAIAPIKey ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Advanced: Use OpenAI API Key (Optional)")
                                .font(PinebotTheme.fontCaptionMedium)
                            Spacer()
                        }
                        .foregroundColor(PinebotTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    
                    if showOpenAIAPIKey {
                        HStack(spacing: 8) {
                            SecureField("sk-...", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .font(PinebotTheme.fontCaption)
                            
                            Button("Connect") {
                                saveOpenAIKey()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(PinebotTheme.amber)
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
    
    private func startChatGPTAuth() {
        isAuthInProgress = true
        providerManager.setState(.connecting(stage: "Starting loopback on 127.0.0.1"), for: .openai)
        
        Task {
            do {
                let models = try await providerManager.openAI.startChatGPTAuth { authURL in
                    Task { @MainActor in
                        providerManager.setState(.needsAuthorization(authURL: authURL), for: .openai)
                        NSWorkspace.shared.open(authURL)
                    }
                }
                isAuthInProgress = false
                let summary = providerManager.openAI.hasPlanSharing ? "ChatGPT Plan Active" : "OpenAI API Active"
                providerManager.setState(.connected(accountSummary: summary, models: models), for: .openai)
                providerManager.refreshConnectedModels()
            } catch {
                isAuthInProgress = false
                providerManager.setState(
                    .failed(message: "ChatGPT authorization failed", recovery: error.localizedDescription),
                    for: .openai
                )
            }
        }
    }
    
    private func saveOpenAIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        providerManager.setState(.connecting(stage: "Verifying key with OpenAI"), for: .openai)
        
        Task {
            do {
                let models = try await providerManager.openAI.configureWithAPIKey(key)
                apiKeyInput = ""
                providerManager.setState(.connected(accountSummary: "OpenAI API Active", models: models), for: .openai)
                providerManager.refreshConnectedModels()
            } catch {
                providerManager.setState(.failed(message: "Invalid OpenAI key", recovery: error.localizedDescription), for: .openai)
            }
        }
    }
    
    private var claudeForm: some View {
        VStack(spacing: PinebotTheme.space12) {
            if case .connecting(let stage) = currentState {
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(stage)
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Cancel") {
                        providerManager.cancelClaudeAuth()
                    }
                    .buttonStyle(.plain)
                    .font(PinebotTheme.fontCaptionMedium)
                    .foregroundColor(PinebotTheme.error)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(PinebotTheme.surface)
                .cornerRadius(PinebotTheme.radiusCard)
            } else {
                if currentState.isConnected {
                    VStack(spacing: 8) {
                        Button(action: {
                            providerManager.startClaudeOfficialAuth()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Switch Claude Account")
                                    .font(PinebotTheme.fontBodyMedium)
                            }
                            .foregroundColor(PinebotTheme.amber)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(PinebotTheme.surface)
                            .cornerRadius(PinebotTheme.radiusControl)
                        }
                        .buttonStyle(.plain)
                        
                        Text("Official Claude Account (CLI) • Eligible Claude models ready")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    let hasCLI = ClaudeCodeRuntimeLocator().locateClaudeCLI() != nil
                    
                    if !hasCLI {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(PinebotTheme.amber)
                            Text("Official Claude Code CLI not found. Install components or use an API key.")
                                .font(PinebotTheme.fontCaption)
                                .foregroundColor(PinebotTheme.textSecondary)
                        }
                        .padding(8)
                        .background(PinebotTheme.surface)
                        .cornerRadius(PinebotTheme.radiusControl)
                    }
                    
                    VStack(spacing: 6) {
                        Button(action: {
                            providerManager.startClaudeOfficialAuth()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .accessibilityLabel("Sign in with Claude")
                                Text("Sign in with Claude")
                                    .font(PinebotTheme.fontBodyMedium)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(hasCLI ? PinebotTheme.amber : PinebotTheme.textSecondary)
                            .cornerRadius(PinebotTheme.radiusControl)
                        }
                        .buttonStyle(.plain)
                        
                        Text("Official Anthropic Claude Account • Requires Claude Pro or Team/Max subscription")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                // Advanced Collapsible API Key Fallback
                VStack(spacing: 8) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showClaudeAPIKey.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showClaudeAPIKey ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Advanced: Use Anthropic API Key (Optional)")
                                .font(PinebotTheme.fontCaptionMedium)
                            Spacer()
                        }
                        .foregroundColor(PinebotTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    
                    if showClaudeAPIKey {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("sk-ant-...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(PinebotTheme.fontCaption)
                                
                                Button("Connect") {
                                    let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    apiKeyInput = ""
                                    Task {
                                        await providerManager.configureClaudeAPIKey(key)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(PinebotTheme.amber)
                                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            
                            Button("Open Anthropic Console") {
                                providerManager.claude.openOfficialApp()
                            }
                            .buttonStyle(.plain)
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.amber)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var geminiForm: some View {
        VStack(spacing: PinebotTheme.space12) {
            if case .connecting(let stage) = currentState {
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(stage)
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Cancel") {
                        providerManager.cancelGeminiAuth()
                    }
                    .buttonStyle(.plain)
                    .font(PinebotTheme.fontCaptionMedium)
                    .foregroundColor(PinebotTheme.error)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(PinebotTheme.surface)
                .cornerRadius(PinebotTheme.radiusCard)
            } else {
                if currentState.isConnected {
                    // When connected, hide redundant Sign-in button; provide Switch Account button
                    VStack(spacing: 8) {
                        Button(action: {
                            providerManager.startGeminiOfficialAuth()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Switch Google Account")
                                    .font(PinebotTheme.fontBodyMedium)
                            }
                            .foregroundColor(PinebotTheme.amber)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(PinebotTheme.surface)
                            .cornerRadius(PinebotTheme.radiusControl)
                        }
                        .buttonStyle(.plain)
                        
                        Text("Personal Google Account • Eligible Gemini models ready")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    // Primary: Sign in with Google (when disconnected or failed)
                    VStack(spacing: 6) {
                        Button(action: {
                            providerManager.startGeminiOfficialAuth()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .accessibilityLabel("Sign in with Google")
                                Text("Sign in with Google")
                                    .font(PinebotTheme.fontBodyMedium)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(PinebotTheme.amber)
                            .cornerRadius(PinebotTheme.radiusControl)
                        }
                        .buttonStyle(.plain)
                        
                        Text("Personal Google Account • Sign in with your Google account")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                // Advanced Collapsible API Key Fallback
                VStack(spacing: 8) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showGeminiAPIKey.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showGeminiAPIKey ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Advanced: Use Google AI Studio API Key (Optional)")
                                .font(PinebotTheme.fontCaptionMedium)
                            Spacer()
                        }
                        .foregroundColor(PinebotTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    
                    if showGeminiAPIKey {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("AIza...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(PinebotTheme.fontCaption)
                                
                                Button("Connect") {
                                    let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    apiKeyInput = ""
                                    Task {
                                        await providerManager.configureGeminiAPIKey(key)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(PinebotTheme.amber)
                                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            
                            Button("Open Google AI Studio") {
                                providerManager.gemini.openOfficialApp()
                            }
                            .buttonStyle(.plain)
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.amber)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 4)
                
                if currentState.isConnected {
                    HStack(spacing: 12) {
                        Button("Test Models") {
                            Task {
                                await providerManager.validateProvider(.gemini)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(PinebotTheme.fontCaptionMedium)
                        .foregroundColor(PinebotTheme.green)
                        
                        Spacer()
                        
                        Button("Open Gemini Web") {
                            providerManager.gemini.openGeminiWeb()
                        }
                        .buttonStyle(.plain)
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.amber)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
    
    private var ollamaForm: some View {
        VStack(spacing: PinebotTheme.space12) {
            HStack(spacing: 8) {
                TextField("http://localhost:11434", text: $endpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(PinebotTheme.fontCaption)
                
                Button("Discover") {
                    providerManager.setState(.connecting(stage: "Connecting to Ollama daemon"), for: .ollama)
                    Task {
                        do {
                            let models = try await providerManager.ollama.configure(endpoint: endpointInput)
                            providerManager.setState(.connected(accountSummary: "Local Models Active", models: models), for: .ollama)
                            providerManager.refreshConnectedModels()
                        } catch {
                            providerManager.setState(.failed(message: "Could not reach Ollama", recovery: "Ensure Ollama is running ('ollama serve')"), for: .ollama)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(PinebotTheme.green)
            }
        }
    }
}
