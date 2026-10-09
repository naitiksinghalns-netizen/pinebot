import SwiftUI
import AppKit

/// Provider selection screen presenting four 56pt vertical cards.
public struct ProviderChoiceView: View {
    @ObservedObject var panelModel: PanelViewModel
    @ObservedObject var providerManager: ProviderManager
    
    public init(
        panelModel: PanelViewModel = .shared,
        providerManager: ProviderManager = .shared
    ) {
        self.panelModel = panelModel
        self.providerManager = providerManager
    }
    
    public var body: some View {
        VStack(spacing: PinebotTheme.space16) {
            VStack(alignment: .leading, spacing: PinebotTheme.space4) {
                Text("Connect a model")
                    .font(PinebotTheme.fontTitle)
                    .foregroundColor(PinebotTheme.textPrimary)
                
                Text("Select an AI account to power Pinebot. You can change this later in Settings.")
                    .font(PinebotTheme.fontCaption)
                    .foregroundColor(PinebotTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PinebotTheme.space16)
            .padding(.top, PinebotTheme.space8)
            
            // Four 56pt vertical selectable cards
            VStack(spacing: PinebotTheme.space8) {
                providerCard(
                    type: .openai,
                    title: "ChatGPT",
                    badge: "Subscription",
                    subtitle: "Sign in with your ChatGPT account. Optional key in Advanced."
                )
                
                providerCard(
                    type: .claude,
                    title: "Claude",
                    badge: "Subscription",
                    subtitle: "Sign in with your Claude account. Optional key in Advanced."
                )
                
                providerCard(
                    type: .gemini,
                    title: "Gemini",
                    badge: "Google Account",
                    subtitle: "Sign in with your Google account. Optional key in Advanced."
                )
                
                providerCard(
                    type: .ollama,
                    title: "On this Mac",
                    badge: "Local & Private",
                    subtitle: "Local Ollama models, 100% private & offline"
                )
            }
            .padding(.horizontal, PinebotTheme.space16)
            
            Spacer()
            
            // Plain concise recovery & skip options
            HStack {
                Text("Primary account sign-in connects securely; optional API keys stay in Keychain.")
                    .font(PinebotTheme.fontCaption)
                    .foregroundColor(PinebotTheme.textSecondary)
                
                Spacer()
                
                Button("Skip / use typed chat") {
                    panelModel.completeOnboarding()
                }
                .buttonStyle(.plain)
                .font(PinebotTheme.fontCaptionMedium)
                .foregroundColor(PinebotTheme.amber)
            }
            .padding(.horizontal, PinebotTheme.space16)
            .padding(.bottom, PinebotTheme.space16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PinebotTheme.canvas)
    }
    
    private func providerCard(
        type: ProviderType,
        title: String,
        badge: String,
        subtitle: String
    ) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                panelModel.navigate(to: .connect(type))
            }
        }) {
            HStack(spacing: PinebotTheme.space12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: PinebotTheme.space6) {
                        Text(title)
                            .font(PinebotTheme.fontBodyMedium)
                            .foregroundColor(PinebotTheme.textPrimary)
                        
                        Text(badge)
                            .font(PinebotTheme.fontCaptionMedium)
                            .foregroundColor(PinebotTheme.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(PinebotTheme.green.opacity(0.12))
                            .cornerRadius(4)
                    }
                    
                    Text(subtitle)
                        .font(PinebotTheme.fontCaption)
                        .foregroundColor(PinebotTheme.textSecondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PinebotTheme.textSecondary.opacity(0.7))
                    .accessibilityLabel("Select \(title)")
            }
            .padding(.horizontal, PinebotTheme.space12)
            .frame(height: 56)
            .background(PinebotTheme.surface)
            .cornerRadius(PinebotTheme.radiusCard)
            .overlay(
                RoundedRectangle(cornerRadius: PinebotTheme.radiusCard)
                    .stroke(PinebotTheme.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
