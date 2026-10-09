import SwiftUI
import AppKit

/// Main conversation interface.
public struct ConversationView: View {
    @ObservedObject var assistant: PinebotAssistant
    @ObservedObject var providerManager: ProviderManager
    @ObservedObject var settingsStore: SettingsStore
    
    @State private var inputPrompt: String = ""
    @State private var composerHeight: CGFloat = 44.0
    
    public init(
        assistant: PinebotAssistant = .shared,
        providerManager: ProviderManager = .shared,
        settingsStore: SettingsStore = .shared
    ) {
        self.assistant = assistant
        self.providerManager = providerManager
        self.settingsStore = settingsStore
    }
    
    private var isConnected: Bool {
        !providerManager.connectedModels.isEmpty
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Main content: either friendly empty state or message history
            if assistant.messages.isEmpty {
                emptyStateView
            } else {
                messageHistoryView
            }
            
            // Listening banner
            if assistant.isListeningToVoice {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(PinebotTheme.green)
                        .accessibilityLabel("Listening indicator")
                    Text("Listening... (release ⌘⌥ when done)")
                        .font(PinebotTheme.fontCaptionMedium)
                        .foregroundColor(PinebotTheme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, PinebotTheme.space16)
                .padding(.vertical, 6)
                .background(PinebotTheme.green.opacity(0.12))
            }
            
            // Bottom composer bar
            composerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PinebotTheme.canvas)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: PinebotTheme.space16) {
            Spacer()
            
            VStack(spacing: PinebotTheme.space8) {
                Text("What shall we do?")
                    .font(PinebotTheme.fontTitle)
                    .foregroundColor(PinebotTheme.textPrimary)
                
                if !isConnected {
                    Text("No AI account connected yet. Select one from the menu.")
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.amber)
                } else {
                    Text("Hold ⌘⌥ anywhere to talk, or choose a starter:")
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.textSecondary)
                }
            }
            
            VStack(spacing: PinebotTheme.space8) {
                starterChip(
                    label: "Explain my screen",
                    icon: "macwindow",
                    action: {
                        assistant.attachScreenToNextMessage = true
                        inputPrompt = "Look at my screen and explain what's visible."
                        submitPrompt()
                    }
                )
                
                starterChip(
                    label: "Help me write",
                    icon: "text.quote",
                    action: {
                        inputPrompt = "Help me write a concise draft about: "
                    }
                )
                
                starterChip(
                    label: "Do a task",
                    icon: "sparkles",
                    action: {
                        inputPrompt = "Inspect frontmost application and outline next steps."
                        submitPrompt()
                    }
                )
            }
            .padding(.horizontal, PinebotTheme.space24)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func starterChip(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: PinebotTheme.space12) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(PinebotTheme.amber)
                    .accessibilityLabel(label)
                
                Text(label)
                    .font(PinebotTheme.fontBodyMedium)
                    .foregroundColor(PinebotTheme.textPrimary)
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(PinebotTheme.textSecondary)
                    .accessibilityLabel("Open starter")
            }
            .padding(.horizontal, PinebotTheme.space16)
            .frame(height: 44)
            .background(PinebotTheme.surface)
            .cornerRadius(PinebotTheme.radiusCard)
            .overlay(
                RoundedRectangle(cornerRadius: PinebotTheme.radiusCard)
                    .stroke(PinebotTheme.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Message History
    
    private var messageHistoryView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PinebotTheme.space12) {
                    ForEach(assistant.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, PinebotTheme.space16)
                .padding(.vertical, PinebotTheme.space12)
            }
            .onChange(of: assistant.messages.count) { _, _ in
                if let last = assistant.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: PinebotTheme.space8) {
            if msg.sender == .pinebot {
                let buddy = AssetLoader.shared.image(for: assistant.buddyState)
                Image(nsImage: buddy)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
                    .accessibilityLabel("Pinebot companion")
            }
            
            VStack(alignment: msg.sender == .user ? .trailing : .leading, spacing: 4) {
                // Attached screenshot thumbnail
                if let img = msg.attachedImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 110)
                        .cornerRadius(PinebotTheme.radiusControl)
                        .overlay(
                            RoundedRectangle(cornerRadius: PinebotTheme.radiusControl)
                                .stroke(PinebotTheme.separator, lineWidth: 1)
                        )
                        .accessibilityLabel("Attached screen capture")
                }
                
                if msg.sender == .user {
                    Text(msg.text)
                        .font(PinebotTheme.fontBody)
                        .foregroundColor(PinebotTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(PinebotTheme.surfaceSubtle)
                        .cornerRadius(PinebotTheme.radiusCard)
                        .textSelection(.enabled)
                } else {
                    MarkdownTextView(content: msg.text, baseFontSize: 13.0, isPinebotMessage: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(PinebotTheme.surface)
                        .cornerRadius(PinebotTheme.radiusCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: PinebotTheme.radiusCard)
                                .stroke(PinebotTheme.separator, lineWidth: 1)
                        )
                }
                
                // Compact model attribution pill with optional classifier details
                if let route = msg.routeDecision {
                    ModelRouteFooterView(route: route)
                }
            }
            .frame(maxWidth: .infinity, alignment: msg.sender == .user ? .trailing : .leading)
        }
    }
    
    // MARK: - Composer Bar
    
    private var composerBar: some View {
        VStack(spacing: PinebotTheme.space4) {
            // Attached Screen Chip
            if assistant.attachScreenToNextMessage {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10))
                        .foregroundColor(PinebotTheme.green)
                        .accessibilityLabel("Screen attached indicator")
                    Text("Screen attached")
                        .font(PinebotTheme.fontCaptionMedium)
                        .foregroundColor(PinebotTheme.green)
                    Spacer()
                    Button(action: {
                        assistant.attachScreenToNextMessage = false
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(PinebotTheme.textSecondary)
                            .accessibilityLabel("Remove screen attachment")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(PinebotTheme.green.opacity(0.12))
                .cornerRadius(PinebotTheme.radiusControl)
                .padding(.horizontal, PinebotTheme.space12)
            }
            
            // Text area and controls
            HStack(alignment: .bottom, spacing: PinebotTheme.space8) {
                // Attach screen toggle button
                Button(action: {
                    assistant.attachScreenToNextMessage.toggle()
                }) {
                    Image(systemName: assistant.attachScreenToNextMessage ? "camera.fill" : "camera")
                        .font(.system(size: 14))
                        .foregroundColor(assistant.attachScreenToNextMessage ? PinebotTheme.green : PinebotTheme.textSecondary)
                        .accessibilityLabel("Attach screen capture")
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                
                // Small model / Auto control
                Menu {
                    Button("Auto (Learned Router)") {
                        settingsStore.settings.modelOverride = "auto"
                        settingsStore.save()
                    }
                    Divider()
                    ForEach(providerManager.connectedModels) { model in
                        Button(model.displayName) {
                            settingsStore.settings.modelOverride = model.id
                            settingsStore.save()
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(settingsStore.settings.modelOverride == "auto" ? "Auto" : settingsStore.settings.modelOverride)
                            .font(PinebotTheme.fontCaption)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .accessibilityLabel("Model selector")
                    }
                    .foregroundColor(PinebotTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(PinebotTheme.surfaceSubtle)
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 80)
                .padding(.bottom, 6)
                
                // Multiline composer (44-100pt, Return sends, Shift+Return newline)
                MultilineComposer(
                    text: $inputPrompt,
                    onSubmit: submitPrompt
                )
                .frame(minHeight: 32, maxHeight: 90)
                
                // Send or STOP button
                if assistant.isProcessing {
                    Button(action: {
                        assistant.stopCurrentProcessing()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                                .accessibilityLabel("Stop generating")
                            Text("Stop")
                                .font(PinebotTheme.fontCaptionMedium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(PinebotTheme.error)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: submitPrompt) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PinebotTheme.separator : PinebotTheme.amber)
                            .accessibilityLabel("Send message")
                    }
                    .buttonStyle(.plain)
                    .disabled(inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.bottom, 2)
                }
            }
            .padding(.horizontal, PinebotTheme.space12)
            .padding(.vertical, PinebotTheme.space8)
            .background(PinebotTheme.surface)
            .cornerRadius(PinebotTheme.radiusCard)
            .overlay(
                RoundedRectangle(cornerRadius: PinebotTheme.radiusCard)
                    .stroke(PinebotTheme.separator, lineWidth: 1)
            )
            .padding(.horizontal, PinebotTheme.space12)
            .padding(.bottom, PinebotTheme.space8)
        }
        .background(PinebotTheme.canvas)
    }
    
    private func submitPrompt() {
        let trimmed = inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputPrompt = ""
        assistant.submitUserPrompt(trimmed)
    }
}

/// Multiline text editor intercepting Return for send and Shift+Return for newline.
struct MultilineComposer: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(PinebotTheme.textPrimary)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineComposer
        
        init(parent: MultilineComposer) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                textView.string = ""
                return true
            }
            return false
        }
    }
}

/// Compact model attribution footer with optional classifier details.
private struct ModelRouteFooterView: View {
    let route: RouteDecision
    @State private var showDetails: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(route.selectedModel.compactDisplayName)
                    .font(PinebotTheme.fontCaption)
                    .foregroundColor(PinebotTheme.textSecondary)
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDetails.toggle()
                    }
                }) {
                    Text(showDetails ? "Hide Details" : "Details")
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.amber.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            
            if showDetails {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routing: \(route.classification.status.displayLabel)")
                    Text("Category: \(route.classification.category.rawValue)")
                    Text("Difficulty: \(route.classification.difficulty.rawValue)")
                    Text("Model ID: \(route.selectedModel.id)")
                }
                .font(PinebotTheme.fontCaption)
                .foregroundColor(PinebotTheme.textSecondary.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(PinebotTheme.surfaceSubtle)
                .cornerRadius(PinebotTheme.radiusControl)
            }
        }
    }
}
