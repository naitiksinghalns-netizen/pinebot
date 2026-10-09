import SwiftUI
import AppKit

/// Welcome screen for first-run onboarding.
public struct WelcomeView: View {
    @ObservedObject var panelModel: PanelViewModel
    
    public init(panelModel: PanelViewModel = .shared) {
        self.panelModel = panelModel
    }
    
    public var body: some View {
        VStack(spacing: PinebotTheme.space24) {
            Spacer()
            
            // 72pt hero pineapple asset
            let hero = AssetLoader.shared.image(for: .happy)
            Image(nsImage: hero)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityLabel("Pinebot cheerful companion")
            
            VStack(spacing: PinebotTheme.space8) {
                Text("A little help, right here.")
                    .font(PinebotTheme.fontHeading)
                    .foregroundColor(PinebotTheme.textPrimary)
                    .multilineTextAlignment(.center)
                
                Text("Your tiny desktop companion for voice, screen teaching, and computer tasks.")
                    .font(PinebotTheme.fontBody)
                    .foregroundColor(PinebotTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, PinebotTheme.space16)
            }
            
            Spacer()
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelModel.navigate(to: .chooseProvider)
                }
            }) {
                Text("Get started")
                    .font(PinebotTheme.fontBodyMedium)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(PinebotTheme.amber)
                    .cornerRadius(PinebotTheme.radiusControl)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, PinebotTheme.space24)
            .padding(.bottom, PinebotTheme.space24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PinebotTheme.canvas)
    }
}
