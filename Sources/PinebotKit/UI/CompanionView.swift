import SwiftUI
import AppKit

/// SwiftUI view rendering the animated draggable pineapple companion buddy.
/// Features a stationary fixed square container with native AppKit screen-coordinate interaction surface,
/// stable center/bottom artwork anchoring, and non-interactive decorative layer.
public struct CompanionView: View {
    @ObservedObject var assistant: PinebotAssistant
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var motionController: CompanionMotionController
    
    public let onToggleChat: () -> Void
    public let onDragEnded: () -> Void
    
    public init(
        assistant: PinebotAssistant = .shared,
        settingsStore: SettingsStore = .shared,
        motionController: CompanionMotionController = .shared,
        onToggleChat: @escaping () -> Void,
        onDragEnded: @escaping () -> Void = {}
    ) {
        self.assistant = assistant
        self.settingsStore = settingsStore
        self.motionController = motionController
        self.onToggleChat = onToggleChat
        self.onDragEnded = onDragEnded
    }
    
    private var isSleeping: Bool {
        assistant.buddyState == .sleeping
    }
    
    public var body: some View {
        let buddySize = settingsStore.settings.buddySize
        let containerSize = CompanionMotionController.containerSize(for: buddySize)
        
        let nsImg = AssetLoader.shared.image(for: assistant.buddyState)
        
        // Stationary, centered, padded outer square container
        ZStack(alignment: .center) {
            // Core hero artwork with stable center/bottom anchoring (purely decorative, non-hit-target)
            Image(nsImage: nsImg)
                .resizable()
                .scaledToFit()
                .frame(width: buddySize, height: buddySize)
                .scaleEffect(x: motionController.scaleX, y: motionController.scaleY, anchor: .bottom)
                .offset(y: motionController.verticalDisplacement)
                .opacity(motionController.currentOpacity)
                .shadow(color: .black.opacity(isSleeping ? 0.08 : 0.22), radius: 5, x: 0, y: 3)
                .overlay(
                    // Actual recording only: 1.5pt green ring, 1.0 to 1.05 scale, 0.45 to 0.70 opacity
                    // Active only when user voice intent AND real SpeechManager audio recording are verified
                    Group {
                        if motionController.isActivelyRecording {
                            Circle()
                                .stroke(PinebotTheme.green, lineWidth: 1.5)
                                .frame(width: buddySize + 8, height: buddySize + 8)
                                .scaleEffect(motionController.recordingRingScale)
                                .opacity(motionController.recordingRingOpacity)
                        }
                    }
                )
                .overlay(
                    // Working indicator (gentle subtle leaf-green ring)
                    Group {
                        if assistant.buddyState == .working {
                            Circle()
                                .stroke(Color.pineEmerald.opacity(0.7), lineWidth: 2)
                                .frame(width: buddySize + 6, height: buddySize + 6)
                                .scaleEffect(1.04)
                        }
                    }
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            
            // Native interaction surface: handles event-time mouse events, dragging, hover, and accessible button
            CompanionInteractionSurface(
                motionController: motionController,
                onToggleChat: onToggleChat,
                onDragEnded: onDragEnded
            )
            .frame(width: containerSize, height: containerSize)
        }
        .frame(width: containerSize, height: containerSize, alignment: .center)
        .onAppear {
            motionController.configure(assistant: assistant, settingsStore: settingsStore)
            motionController.startBreathing(reducedMotion: settingsStore.settings.reducedMotion)
        }
        .onDisappear {
            motionController.resetDrag()
            motionController.stopBreathing()
        }
    }
}

extension Color {
    public static let pineAmber = Color(red: 224/255, green: 148/255, blue: 31/255) // Restrained warm amber
    public static let pineEmerald = Color(red: 47/255, green: 143/255, blue: 82/255) // Leaf green
    public static let amberAccent = Color(red: 245/255, green: 178/255, blue: 74/255)
    public static let warmIvory = Color(red: 253/255, green: 251/255, blue: 247/255) // Warm light surface
    public static let warmBorder = Color(red: 231/255, green: 229/255, blue: 224/255)
}
