import SwiftUI
import AppKit

/// Task execution and activity log view.
public struct ActivityView: View {
    @ObservedObject var taskEngine: ComputerTaskEngine
    
    public init(taskEngine: ComputerTaskEngine = .shared) {
        self.taskEngine = taskEngine
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PinebotTheme.space16) {
                if let goal = taskEngine.currentGoal {
                    VStack(alignment: .leading, spacing: PinebotTheme.space8) {
                        HStack {
                            Text("Current Task")
                                .font(PinebotTheme.fontCaptionMedium)
                                .foregroundColor(PinebotTheme.textSecondary)
                            Spacer()
                            Button("Cancel") {
                                taskEngine.cancel()
                            }
                            .buttonStyle(.plain)
                            .font(PinebotTheme.fontCaptionMedium)
                            .foregroundColor(PinebotTheme.error)
                        }
                        
                        Text(goal)
                            .font(PinebotTheme.fontBodyMedium)
                            .foregroundColor(PinebotTheme.textPrimary)
                    }
                    .padding(PinebotTheme.space12)
                    .background(PinebotTheme.surface)
                    .cornerRadius(PinebotTheme.radiusCard)
                }
                
                Text("ACTIVITY LOG")
                    .font(PinebotTheme.fontCaptionMedium)
                    .foregroundColor(PinebotTheme.textSecondary)
                
                if taskEngine.steps.isEmpty {
                    Text("No active or past tasks in this session.")
                        .font(PinebotTheme.fontBody)
                        .foregroundColor(PinebotTheme.textSecondary)
                        .padding(.vertical, PinebotTheme.space8)
                } else {
                    ForEach(taskEngine.steps) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Step \(step.stepNumber): \(step.tool.name)")
                                    .font(PinebotTheme.fontBodyMedium)
                                    .foregroundColor(PinebotTheme.textPrimary)
                                Spacer()
                            }
                            
                            Text(step.rationale)
                                .font(PinebotTheme.fontCaption)
                                .foregroundColor(PinebotTheme.textSecondary)
                            
                            if let result = step.result {
                                Text(result)
                                    .font(PinebotTheme.fontMonospace)
                                    .foregroundColor(PinebotTheme.green)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(PinebotTheme.space12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PinebotTheme.surface)
                        .cornerRadius(PinebotTheme.radiusCard)
                    }
                }
            }
            .padding(PinebotTheme.space16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PinebotTheme.canvas)
    }
}
