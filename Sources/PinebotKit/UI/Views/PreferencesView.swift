import SwiftUI
import AppKit
import AVFoundation

/// Settings and preferences view.
public struct PreferencesView: View {
    @ObservedObject var settingsStore: SettingsStore
    
    public init(settingsStore: SettingsStore = .shared) {
        self.settingsStore = settingsStore
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PinebotTheme.space16) {
                // Size
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Companion Size")
                            .font(PinebotTheme.fontBodyMedium)
                            .foregroundColor(PinebotTheme.textPrimary)
                        Spacer()
                        Text("\(Int(settingsStore.settings.buddySize)) pt")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                    }
                    Slider(value: $settingsStore.settings.buddySize, in: 80...160, step: 5)
                        .onChange(of: settingsStore.settings.buddySize) { _, _ in settingsStore.save() }
                }
                .padding(PinebotTheme.space12)
                .background(PinebotTheme.surface)
                .cornerRadius(PinebotTheme.radiusCard)
                
                // Sleep delay
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Inactivity Sleep Timeout")
                            .font(PinebotTheme.fontBodyMedium)
                            .foregroundColor(PinebotTheme.textPrimary)
                        Spacer()
                        Text("\(Int(settingsStore.settings.idleSleepDelay)) s")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                    }
                    Slider(value: $settingsStore.settings.idleSleepDelay, in: 15...300, step: 15)
                        .onChange(of: settingsStore.settings.idleSleepDelay) { _, _ in settingsStore.save() }
                }
                .padding(PinebotTheme.space12)
                .background(PinebotTheme.surface)
                .cornerRadius(PinebotTheme.radiusCard)
                
                // Opacity
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Sleep Opacity")
                            .font(PinebotTheme.fontBodyMedium)
                            .foregroundColor(PinebotTheme.textPrimary)
                        Spacer()
                        Text("\(Int(settingsStore.settings.sleepOpacity * 100))%")
                            .font(PinebotTheme.fontCaption)
                            .foregroundColor(PinebotTheme.textSecondary)
                    }
                    Slider(value: $settingsStore.settings.sleepOpacity, in: 0.2...0.8, step: 0.05)
                        .onChange(of: settingsStore.settings.sleepOpacity) { _, _ in settingsStore.save() }
                }
                .padding(PinebotTheme.space12)
                .background(PinebotTheme.surface)
                .cornerRadius(PinebotTheme.radiusCard)
                
                // Toggles & Voice
                VStack(spacing: PinebotTheme.space12) {
                    Toggle("Spoken Voice Responses (TTS)", isOn: $settingsStore.settings.speechOutputEnabled)
                        .font(PinebotTheme.fontBody)
                        .foregroundColor(PinebotTheme.textPrimary)
                        .onChange(of: settingsStore.settings.speechOutputEnabled) { _, isEnabled in
                            settingsStore.save()
                            if !isEnabled {
                                SpeechManager.shared.stopSpeaking()
                            }
                        }
                    
                    if settingsStore.settings.speechOutputEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Voice")
                                    .font(PinebotTheme.fontBodyMedium)
                                    .foregroundColor(PinebotTheme.textPrimary)
                                Spacer()
                                Button(action: {
                                    SpeechManager.shared.speak(
                                        text: "Hello! I am your Pinebot desktop companion.",
                                        requestId: UUID().uuidString
                                    )
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "speaker.wave.2.fill")
                                        Text("Preview")
                                    }
                                    .font(PinebotTheme.fontCaption)
                                }
                                .buttonStyle(.borderless)
                            }
                            
                            Picker("Voice", selection: $settingsStore.settings.preferredVoiceId) {
                                Text("Automatic (Default)").tag("")
                                ForEach(availableEnglishVoices, id: \.identifier) { voice in
                                    Text(voiceLabel(for: voice)).tag(voice.identifier)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .onChange(of: settingsStore.settings.preferredVoiceId) { _, _ in
                                settingsStore.save()
                            }
                        }
                    }
                    
                    Divider().background(PinebotTheme.separator)
                    
                    Toggle("Require Tool Confirmation", isOn: $settingsStore.settings.requireToolConfirmation)
                        .font(PinebotTheme.fontBody)
                        .foregroundColor(PinebotTheme.textPrimary)
                        .onChange(of: settingsStore.settings.requireToolConfirmation) { _, _ in settingsStore.save() }
                    
                    Divider().background(PinebotTheme.separator)
                    
                    Toggle("Reduced Motion", isOn: $settingsStore.settings.reducedMotion)
                        .font(PinebotTheme.fontBody)
                        .foregroundColor(PinebotTheme.textPrimary)
                        .onChange(of: settingsStore.settings.reducedMotion) { _, _ in settingsStore.save() }
                }
                .padding(PinebotTheme.space12)
                .background(PinebotTheme.surface)
                .cornerRadius(PinebotTheme.radiusCard)
            }
            .padding(PinebotTheme.space16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PinebotTheme.canvas)
    }
    
    private var availableEnglishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
            .sorted { v1, v2 in
                if v1.quality.rawValue != v2.quality.rawValue {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }
    
    private func voiceLabel(for voice: AVSpeechSynthesisVoice) -> String {
        var qualitySuffix = ""
        if voice.quality == .premium {
            qualitySuffix = " (Premium)"
        } else if voice.quality == .enhanced {
            qualitySuffix = " (Enhanced)"
        }
        return "\(voice.name) (\(voice.language))\(qualitySuffix)"
    }
}
