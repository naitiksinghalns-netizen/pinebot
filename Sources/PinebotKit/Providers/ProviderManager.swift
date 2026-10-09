import Foundation
import Combine

/// Aggregates, coordinates, and publishes explicit connection states for all supported AI providers.
/// The ProviderManager is the sole authoritative state owner.
@MainActor
public final class ProviderManager: ObservableObject {
    public static let shared = ProviderManager()
    
    public private(set) var openAI: OpenAIProvider
    public private(set) var claude: ClaudeProvider
    public private(set) var gemini: GeminiProvider
    public private(set) var ollama: OllamaProvider
    
    private var customProviders: [ProviderType: LLMProvider] = [:]
    private var geminiAuthGeneration: UUID?
    private var geminiAuthTask: Task<Void, Never>?
    private var geminiProviderGeneration: UUID = UUID()
    
    private var claudeAuthGeneration: UUID?
    private var claudeAuthTask: Task<Void, Never>?
    private var claudeProviderGeneration: UUID = UUID()
    
    @Published public private(set) var openAIState: ProviderConnectionState = .disconnected
    @Published public private(set) var claudeState: ProviderConnectionState = .disconnected
    @Published public private(set) var geminiState: ProviderConnectionState = .disconnected
    @Published public private(set) var ollamaState: ProviderConnectionState = .disconnected
    
    @Published public private(set) var connectedModels: [ModelInfo] = []
    @Published public private(set) var isValidating: Bool = false
    @Published public var lastErrorMessage: String?
    
    public var isAnyConfigured: Bool {
        provider(for: .openai).isConfigured ||
        provider(for: .claude).isConfigured ||
        provider(for: .gemini).isConfigured ||
        provider(for: .ollama).isConfigured
    }
    
    public var isAnyConnected: Bool {
        !connectedModels.isEmpty
    }
    
    public init(
        openAI: OpenAIProvider? = nil,
        claude: ClaudeProvider? = nil,
        gemini: GeminiProvider? = nil,
        ollama: OllamaProvider? = nil
    ) {
        self.openAI = openAI ?? OpenAIProvider()
        self.claude = claude ?? ClaudeProvider()
        self.gemini = gemini ?? GeminiProvider()
        self.ollama = ollama ?? OllamaProvider()
        
        setupGeminiModelObserver()
        setupClaudeModelObserver()
        initializeStatesFromConfigured()
        refreshConnectedModels()
    }
    
    private func setupGeminiModelObserver() {
        let currentGen = self.geminiProviderGeneration
        let currentGemini = self.gemini
        gemini.setOnModelsUpdatedHandler { [weak self, weak currentGemini] updatedModels, currentModelId in
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.geminiProviderGeneration == currentGen,
                      self.gemini === currentGemini else {
                    return
                }
                if case .connected(let accountSummary, _) = self.geminiState {
                    self.geminiState = .connected(accountSummary: accountSummary, models: updatedModels)
                    self.refreshConnectedModels()
                }
            }
        }
    }
    
    private func setupClaudeModelObserver() {
        let currentGen = self.claudeProviderGeneration
        let currentClaude = self.claude
        claude.setOnModelsUpdatedHandler { [weak self, weak currentClaude] updatedModels, currentModelId in
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.claudeProviderGeneration == currentGen,
                      self.claude === currentClaude else {
                    return
                }
                if case .connected(let accountSummary, _) = self.claudeState {
                    self.claudeState = .connected(accountSummary: accountSummary, models: updatedModels)
                    self.refreshConnectedModels()
                }
            }
        }
    }
    
    public func setProvider(_ provider: LLMProvider, for type: ProviderType) {
        customProviders[type] = provider
        if type == .gemini {
            self.geminiProviderGeneration = UUID()
            if let geminiProvider = provider as? GeminiProvider {
                self.gemini = geminiProvider
                setupGeminiModelObserver()
            }
        } else if type == .claude {
            self.claudeProviderGeneration = UUID()
            if let claudeProvider = provider as? ClaudeProvider {
                self.claude = claudeProvider
                setupClaudeModelObserver()
            }
        }
        if provider.isConfigured {
            setState(.validating, for: type)
        } else {
            setState(.disconnected, for: type)
        }
        refreshConnectedModels()
    }
    
    public func provider(for type: ProviderType) -> LLMProvider {
        if let custom = customProviders[type] {
            return custom
        }
        switch type {
        case .openai: return openAI
        case .claude: return claude
        case .gemini: return gemini
        case .ollama: return ollama
        }
    }
    
    public func state(for type: ProviderType) -> ProviderConnectionState {
        switch type {
        case .openai: return openAIState
        case .claude: return claudeState
        case .gemini: return geminiState
        case .ollama: return ollamaState
        }
    }
    
    public func setState(_ state: ProviderConnectionState, for type: ProviderType) {
        switch type {
        case .openai: openAIState = state
        case .claude: claudeState = state
        case .gemini: geminiState = state
        case .ollama: ollamaState = state
        }
    }
    
    /// Derives connectedModels strictly from current manager states that are .connected.
    /// Under NO circumstances does this function mutate connection states.
    public func refreshConnectedModels() {
        var list: [ModelInfo] = []
        
        if case .connected(_, let models) = openAIState {
            list.append(contentsOf: models)
        }
        if case .connected(_, let models) = claudeState {
            list.append(contentsOf: models)
        }
        if case .connected(_, let models) = geminiState {
            list.append(contentsOf: models)
        }
        if case .connected(_, let models) = ollamaState {
            list.append(contentsOf: models)
        }
        
        connectedModels = list
    }
    
    private func initializeStatesFromConfigured() {
        for type in ProviderType.allCases {
            let p = provider(for: type)
            if p.isConfigured {
                setState(.validating, for: type)
            } else {
                setState(.disconnected, for: type)
            }
        }
    }
    
    /// Disconnects the selected provider and purges state and credentials.
    public func disconnect(provider type: ProviderType) {
        if type == .gemini {
            geminiAuthGeneration = nil
            geminiAuthTask?.cancel()
            geminiAuthTask = nil
            geminiProviderGeneration = UUID()
        } else if type == .claude {
            claudeAuthGeneration = nil
            claudeAuthTask?.cancel()
            claudeAuthTask = nil
            claudeProviderGeneration = UUID()
        }
        let p = provider(for: type)
        p.disconnect()
        setState(.disconnected, for: type)
        refreshConnectedModels()
    }
    
    // MARK: - Gemini Authentication Management
    
    /// Starts official Google Account authentication via ACP using official Gemini CLI.
    public func startGeminiOfficialAuth() {
        // Refuse duplicate active auth if already connecting
        if let currentTask = geminiAuthTask, !currentTask.isCancelled, geminiState.isConnecting {
            return
        }
        
        let generation = UUID()
        self.geminiAuthGeneration = generation
        self.geminiProviderGeneration = UUID()
        setupGeminiModelObserver()
        setState(.connecting(stage: "Starting Google client..."), for: .gemini)
        
        geminiAuthTask = Task { @MainActor [weak self] in
            guard let self = self, self.geminiAuthGeneration == generation else { return }
            do {
                let models: [ModelInfo]
                let p = self.provider(for: .gemini)
                if let geminiP = p as? GeminiProvider {
                    models = try await geminiP.startOfficialAccountAuth { [weak self, generation] stage in
                        Task { @MainActor [weak self] in
                            guard let self = self, self.geminiAuthGeneration == generation else { return }
                            self.setState(.connecting(stage: stage), for: .gemini)
                        }
                    }
                } else {
                    models = try await p.validateAndDiscoverModels()
                }
                
                guard !Task.isCancelled, self.geminiAuthGeneration == generation else { return }
                self.setState(.connected(accountSummary: "Google Account (Personal)", models: models), for: .gemini)
                self.refreshConnectedModels()
                if self.geminiAuthGeneration == generation {
                    self.geminiAuthTask = nil
                    self.geminiAuthGeneration = nil
                }
            } catch {
                guard !Task.isCancelled, self.geminiAuthGeneration == generation else { return }
                self.setState(
                    .failed(
                        message: "Google sign-in failed",
                        recovery: error.localizedDescription
                    ),
                    for: .gemini
                )
                if self.geminiAuthGeneration == generation {
                    self.geminiAuthTask = nil
                    self.geminiAuthGeneration = nil
                }
            }
        }
    }
    
    /// Cancels any in-flight Gemini authentication task and closes agent session.
    public func cancelGeminiAuth() {
        geminiProviderGeneration = UUID()
        geminiAuthGeneration = nil
        geminiAuthTask?.cancel()
        geminiAuthTask = nil
        (provider(for: .gemini) as? GeminiProvider)?.cancelAuth()
        setState(.disconnected, for: .gemini)
        refreshConnectedModels()
    }
    
    /// Cancels any in-flight prompt completions across all providers.
    public func cancelAllGenerations() async {
        let allProviders: [LLMProvider] = [
            provider(for: .openai),
            provider(for: .claude),
            provider(for: .gemini),
            provider(for: .ollama)
        ]
        for p in allProviders {
            await p.cancelGeneration()
        }
    }
    
    /// Configures Gemini with an API key fallback.
    public func configureGeminiAPIKey(_ apiKey: String) async {
        geminiProviderGeneration = UUID()
        geminiAuthGeneration = nil
        geminiAuthTask?.cancel()
        geminiAuthTask = nil
        setState(.connecting(stage: "Verifying Gemini key"), for: .gemini)
        do {
            let p = provider(for: .gemini)
            let models: [ModelInfo]
            if let geminiP = p as? GeminiProvider {
                models = try await geminiP.configureWithAPIKey(apiKey)
            } else {
                models = try await p.validateAndDiscoverModels()
            }
            setState(.connected(accountSummary: "Gemini API Active", models: models), for: .gemini)
            refreshConnectedModels()
        } catch {
            setState(.failed(message: "Gemini key invalid", recovery: error.localizedDescription), for: .gemini)
        }
    }
    
    // MARK: - Claude Authentication Management
    
    /// Starts official Claude account authentication via unmodified Claude Code CLI.
    public func startClaudeOfficialAuth() {
        if let currentTask = claudeAuthTask, !currentTask.isCancelled, claudeState.isConnecting {
            return
        }
        
        let generation = UUID()
        self.claudeAuthGeneration = generation
        self.claudeProviderGeneration = UUID()
        setupClaudeModelObserver()
        setState(.connecting(stage: "Checking Claude CLI..."), for: .claude)
        
        claudeAuthTask = Task { @MainActor [weak self] in
            guard let self = self, self.claudeAuthGeneration == generation else { return }
            do {
                let models: [ModelInfo]
                let p = self.provider(for: .claude)
                if let claudeP = p as? ClaudeProvider {
                    models = try await claudeP.startOfficialAccountAuth { [weak self, generation] stage in
                        Task { @MainActor [weak self] in
                            guard let self = self, self.claudeAuthGeneration == generation else { return }
                            self.setState(.connecting(stage: stage), for: .claude)
                        }
                    }
                } else {
                    models = try await p.validateAndDiscoverModels()
                }
                
                guard !Task.isCancelled, self.claudeAuthGeneration == generation else { return }
                let summary = (p as? ClaudeProvider)?.statusDescription ?? "Claude Account (Official CLI)"
                self.setState(.connected(accountSummary: summary, models: models), for: .claude)
                self.refreshConnectedModels()
                if self.claudeAuthGeneration == generation {
                    self.claudeAuthTask = nil
                    self.claudeAuthGeneration = nil
                }
            } catch {
                guard !Task.isCancelled, self.claudeAuthGeneration == generation else { return }
                self.setState(
                    .failed(
                        message: "Claude sign-in failed",
                        recovery: error.localizedDescription
                    ),
                    for: .claude
                )
                if self.claudeAuthGeneration == generation {
                    self.claudeAuthTask = nil
                    self.claudeAuthGeneration = nil
                }
            }
        }
    }
    
    /// Cancels any in-flight Claude authentication task and closes session.
    public func cancelClaudeAuth() {
        claudeProviderGeneration = UUID()
        claudeAuthGeneration = nil
        claudeAuthTask?.cancel()
        claudeAuthTask = nil
        (provider(for: .claude) as? ClaudeProvider)?.cancelAuth()
        setState(.disconnected, for: .claude)
        refreshConnectedModels()
    }
    
    /// Configures Claude with a direct API key fallback.
    public func configureClaudeAPIKey(_ apiKey: String) async {
        claudeProviderGeneration = UUID()
        claudeAuthGeneration = nil
        claudeAuthTask?.cancel()
        claudeAuthTask = nil
        setState(.connecting(stage: "Verifying Claude key"), for: .claude)
        do {
            let p = provider(for: .claude)
            let models: [ModelInfo]
            if let claudeP = p as? ClaudeProvider {
                models = try await claudeP.configureWithAPIKey(apiKey)
            } else {
                models = try await p.validateAndDiscoverModels()
            }
            setState(.connected(accountSummary: "Claude API Active", models: models), for: .claude)
            refreshConnectedModels()
        } catch {
            setState(.failed(message: "Claude key invalid", recovery: error.localizedDescription), for: .claude)
            refreshConnectedModels()
        }
    }
    
    /// Explicit validation task for a single provider.
    public func validateProvider(_ type: ProviderType) async {
        let p = provider(for: type)
        setState(.validating, for: type)
        
        if type == .gemini && (p as? GeminiProvider)?.currentMode == .officialAccount {
            self.geminiProviderGeneration = UUID()
            setupGeminiModelObserver()
        } else if type == .claude && (p as? ClaudeProvider)?.currentMode == .officialAccount {
            self.claudeProviderGeneration = UUID()
            setupClaudeModelObserver()
        }
        
        do {
            let models = try await p.validateAndDiscoverModels()
            let summary: String
            switch type {
            case .openai:
                summary = (p as? OpenAIProvider)?.hasPlanSharing == true ? "ChatGPT Plan Active" : "OpenAI API Active"
            case .claude:
                let isOfficial = (p as? ClaudeProvider)?.currentMode == .officialAccount
                summary = isOfficial ? ((p as? ClaudeProvider)?.statusDescription ?? "Claude Account (Official CLI)") : "Claude API Active"
            case .gemini:
                let isOfficial = (p as? GeminiProvider)?.currentMode == .officialAccount
                summary = isOfficial ? "Google Account (Personal)" : "Gemini API Active"
            case .ollama:
                summary = "Local Models Active"
            }
            setState(.connected(accountSummary: summary, models: models), for: type)
        } catch {
            let recovery: String
            switch type {
            case .openai:
                recovery = "Check your ChatGPT subscription plan or re-enter your OpenAI API key."
            case .claude:
                let isOfficial = (p as? ClaudeProvider)?.currentMode == .officialAccount
                if isOfficial {
                    recovery = "Sign in again with your Claude account or check 'claude auth status'."
                } else {
                    recovery = "Verify your Anthropic API key at console.anthropic.com."
                }
            case .gemini:
                let isOfficial = (p as? GeminiProvider)?.currentMode == .officialAccount
                if isOfficial {
                    recovery = "Sign in again with your Google Account or use a Gemini API key."
                } else {
                    recovery = "Verify your Google AI Studio API key at aistudio.google.com."
                }
            case .ollama:
                recovery = "Run 'ollama serve' in Terminal or check http://localhost:11434."
            }
            
            if type == .ollama && !p.isConfigured {
                setState(.disconnected, for: type)
            } else {
                let errorMsg = error.localizedDescription
                setState(.failed(
                    message: "\(type.displayName) connection failed (\(errorMsg))",
                    recovery: recovery
                ), for: type)
            }
        }
        
        refreshConnectedModels()
    }
    
    /// Restores credentials in the background without SecurityAgent UI and validates connected providers.
    public func validateAllConfigured() async {
        isValidating = true
        lastErrorMessage = nil
        
        // 1. OpenAI Background Non-Interactive Restoration (discovers tokens even if metadata was missing)
        await openAI.restoreConnection()
        if openAI.isConnected {
            await validateProvider(.openai)
        } else if openAI.statusDescription.contains("Locked") {
            setState(.failed(message: "Keychain Access Locked", recovery: "Click Connect to approve Keychain access for OpenAI."), for: .openai)
        } else {
            setState(.disconnected, for: .openai)
        }
        
        // 2. Gemini Background Non-Interactive Restoration
        await gemini.restoreConnection()
        if gemini.isConfigured {
            await validateProvider(.gemini)
        } else if gemini.statusDescription.contains("Locked") {
            setState(.failed(message: "Keychain Access Locked", recovery: "Click Connect to approve Keychain access for Gemini."), for: .gemini)
        } else {
            setState(.disconnected, for: .gemini)
        }
        
        // 3. Claude Background Non-Interactive Restoration
        await claude.restoreConnection()
        if claude.isConfigured {
            await validateProvider(.claude)
        } else if claude.statusDescription.contains("Locked") {
            setState(.failed(message: "Keychain Access Locked", recovery: "Click Connect to approve Keychain access for Claude."), for: .claude)
        } else {
            setState(.disconnected, for: .claude)
        }
        
        // 4. Ollama Local Reachability
        await validateProvider(.ollama)
        
        refreshConnectedModels()
        isValidating = false
    }
}
