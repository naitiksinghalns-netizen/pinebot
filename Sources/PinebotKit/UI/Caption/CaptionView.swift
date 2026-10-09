import SwiftUI
import AppKit

/// Compact top-right caption view rendering spoken speech with active word highlighting.
public struct CaptionView: View {
    @ObservedObject private var speech = SpeechManager.shared
    @ObservedObject private var settingsStore = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    
    public init() {}
    
    private var shouldReduceMotion: Bool {
        settingsStore.settings.reducedMotion || systemReduceMotion
    }
    
    public var body: some View {
        Group {
            if !speech.presentationState.text.isEmpty && speech.presentationState.phase != .idle && speech.presentationState.phase != .cancelled {
                HStack(alignment: .top, spacing: 10) {
                    // Small animated / pulsing speech indicator
                    Circle()
                        .fill(speech.presentationState.phase == .speaking ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    
                    Text(attributedCaption(
                        text: speech.presentationState.text,
                        range: speech.presentationState.currentRange,
                        phase: speech.presentationState.phase
                    ))
                    .lineLimit(4)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(width: 300, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
                )
                .padding(16) // Consistent 16pt transparent gutter around the 300pt card (total 332pt width)
                .animation(shouldReduceMotion ? nil : .easeInOut(duration: 0.15), value: speech.presentationState.currentRange)
                .transition(shouldReduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    private func attributedCaption(text: String, range: NSRange?, phase: SpeechPresentationPhase) -> AttributedString {
        var attr = AttributedString(text)
        // Uniform font and weight across all highlight states to prevent layout reflow / jitter
        attr.font = .system(size: 14.5, weight: .medium, design: .rounded)
        
        if phase == .finished {
            // Once finished, display all text in clear readable tone
            attr.foregroundColor = Color(nsColor: .labelColor).opacity(0.9)
            return attr
        }
        
        // Base unhighlighted styling
        attr.foregroundColor = Color(nsColor: .labelColor).opacity(0.55)
        
        guard let range = range,
              let strRange = Range(range, in: text),
              let attrRange = Range(strRange, in: attr) else {
            return attr
        }
        
        // Active speaking word styling (color change only, maintaining exact glyph geometry)
        attr[attrRange].foregroundColor = Color(nsColor: .labelColor)
        return attr
    }
}
