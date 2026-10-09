import Foundation
import CoreGraphics
import AppKit

/// Types of actions executable by the computer task engine.
public enum ComputerActionType: String, Codable, Sendable, CaseIterable {
    case click
    case doubleClick
    case typeText
    case keyCombination
    case drag
    case scroll
    case wait
    case speak
    case askConfirmation
    case complete
    case fail
}

/// A structured, verifiable action emitted by the ComputerPlanner.
public struct ComputerAction: Codable, Sendable, Equatable {
    public let type: ComputerActionType
    public let observationId: UUID?
    public let displayId: CGDirectDisplayID?
    public let elementId: String?
    public let x: Double? // Normalized 0.0...1.0
    public let y: Double? // Normalized 0.0...1.0
    public let toX: Double? // For drag
    public let toY: Double? // For drag
    public let text: String? // For typeText, speak, askConfirmation, complete, fail
    public let keys: [String]? // For keyCombination (e.g. ["cmd", "c"])
    public let deltaX: Int32? // For scroll
    public let deltaY: Int32? // For scroll
    public let durationSeconds: Double? // For wait
    public let rationale: String? // Explanation for step
    public let isConsequential: Bool? // Flagged as irreversible/high-impact
    
    public init(
        type: ComputerActionType,
        observationId: UUID? = nil,
        displayId: CGDirectDisplayID? = nil,
        elementId: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        toX: Double? = nil,
        toY: Double? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        deltaX: Int32? = nil,
        deltaY: Int32? = nil,
        durationSeconds: Double? = nil,
        rationale: String? = nil,
        isConsequential: Bool? = nil
    ) {
        self.type = type
        self.observationId = observationId
        self.displayId = displayId
        self.elementId = elementId
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.text = text
        self.keys = keys
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.durationSeconds = durationSeconds
        self.rationale = rationale
        self.isConsequential = isConsequential
    }
    
    /// Checks whether this action is irreversible, high-impact, or explicitly flagged as consequential.
    public var isConsequentialAction: Bool {
        if isConsequential == true { return true }
        if type == .askConfirmation { return true }
        
        // Safety heuristics for potentially destructive actions
        if type == .typeText, let t = text?.lowercased() {
            if t.contains("rm -rf") || t.contains("drop table") || t.contains("format ") || t.contains("git push --force") {
                return true
            }
        }
        
        let rat = (rationale ?? "").lowercased()
        if rat.contains("delete") || rat.contains("remove permanent") || rat.contains("send email") || rat.contains("submit order") || rat.contains("purchase") {
            return true
        }
        
        return false
    }
}

/// A planned step in a computer task sequence.
public struct PlannedActionStep: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let stepNumber: Int
    public let action: ComputerAction
    public let rationale: String
    public var output: String?
    public var status: StepStatus
    
    public enum StepStatus: String, Codable, Sendable {
        case pending
        case waitingConfirmation
        case executing
        case completed
        case rejected
        case failed
    }
    
    public init(
        id: UUID = UUID(),
        stepNumber: Int,
        action: ComputerAction,
        rationale: String,
        output: String? = nil,
        status: StepStatus = .pending
    ) {
        self.id = id
        self.stepNumber = stepNumber
        self.action = action
        self.rationale = rationale
        self.output = output
        self.status = status
    }
}

/// Protocol defining the planner capable of taking an observation and producing the next step.
public protocol ComputerPlanner: Sendable {
    func planNextStep(
        goal: String,
        observation: ComputerObservation,
        history: [PlannedActionStep],
        teachingMode: Bool
    ) async throws -> PlannedActionStep
}

/// Errors occurring during computer planning.
public enum ComputerPlannerError: Error, LocalizedError, Sendable {
    case malformedPlan(String)
    case maxRepairAttemptsExceeded(String)
    case plannerFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .malformedPlan(let raw):
            return "Planner output malformed JSON: \(raw)"
        case .maxRepairAttemptsExceeded(let raw):
            return "Planner failed to produce valid action schema after repair: \(raw)"
        case .plannerFailed(let msg):
            return "Planner error: \(msg)"
        }
    }
}

/// Computer planner implementation backed by an LLM provider.
/// Works with any vision-capable or structured-output model without requiring raw function-calling support.
public final class ProviderComputerPlanner: ComputerPlanner, @unchecked Sendable {
    private let provider: LLMProvider
    private let model: String
    
    public init(provider: LLMProvider, model: String) {
        self.provider = provider
        self.model = model
    }
    
    public func planNextStep(
        goal: String,
        observation: ComputerObservation,
        history: [PlannedActionStep],
        teachingMode: Bool
    ) async throws -> PlannedActionStep {
        let systemPrompt = buildSystemPrompt(teachingMode: teachingMode)
        let userPrompt = buildUserPrompt(goal: goal, observation: observation, history: history)
        
        let response = try await provider.generateCompletion(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            image: observation.image,
            model: model
        )
        
        do {
            let action = try Self.parseAction(from: response, currentObservation: observation)
            return PlannedActionStep(
                stepNumber: history.count + 1,
                action: action,
                rationale: action.rationale ?? "Step \(history.count + 1)"
            )
        } catch {
            // One-shot repair attempt
            let repairPrompt = """
            Your previous response failed JSON schema parsing:
            \(error.localizedDescription)
            
            Previous response was:
            \(response)
            
            Please output ONLY a valid JSON object matching the required schema with no extra text or markdown fences.
            """
            
            let repairedResponse = try await provider.generateCompletion(
                prompt: repairPrompt,
                systemPrompt: systemPrompt,
                image: nil,
                model: model
            )
            
            do {
                let action = try Self.parseAction(from: repairedResponse, currentObservation: observation)
                return PlannedActionStep(
                    stepNumber: history.count + 1,
                    action: action,
                    rationale: action.rationale ?? "Step \(history.count + 1) (repaired)"
                )
            } catch {
                throw ComputerPlannerError.maxRepairAttemptsExceeded(repairedResponse)
            }
        }
    }
    
    private func buildSystemPrompt(teachingMode: Bool) -> String {
        var base = """
        You are Pinebot's Desktop Computer Agent on macOS.
        Your job is to analyze the desktop screen observation and emit the next single action to accomplish the user's goal.
        
        Output MUST be a single raw JSON object matching this schema:
        {
          "type": "click" | "doubleClick" | "typeText" | "keyCombination" | "drag" | "scroll" | "wait" | "speak" | "askConfirmation" | "complete" | "fail",
          "observationId": "<exact UUID from observation>",
          "displayId": <exact displayId as integer>,
          "elementId": "<optional AX element ID from observation AX tree>",
          "x": <float 0.0 to 1.0, normalized coordinate relative to display top-left>,
          "y": <float 0.0 to 1.0, normalized coordinate relative to display top-left>,
          "toX": <float 0.0 to 1.0, required for drag>,
          "toY": <float 0.0 to 1.0, required for drag>,
          "text": "<string for typeText, speak, askConfirmation, complete, or fail>",
          "keys": ["cmd", "c"], // Array of keys for keyCombination
          "deltaX": 0, // Integer for horizontal scroll
          "deltaY": -100, // Integer for vertical scroll
          "durationSeconds": 1.0, // Float for wait
          "rationale": "Clear 1-sentence explanation of what this action does and why",
          "isConsequential": false // Set true if this action sends an external message, deletes files, submits payments, or closes unsaved work
        }
        
        RULES:
        1. Coordinate normalization: (0.0, 0.0) is the top-left of the display, (1.0, 1.0) is bottom-right.
        2. Always echo the exact `observationId` and `displayId` provided in the observation.
        3. If an interactive AX element matches your target, provide its `elementId` (e.g. "AX_3").
        4. When the task is successfully accomplished, emit `{"type": "complete", "text": "Summary of what was done"}`.
        5. If impossible or an unrecoverable error occurs, emit `{"type": "fail", "text": "Reason for failure"}`.
        6. Any irreversible action (sending emails/messages, deleting files, purchasing) MUST have `"isConsequential": true` or `"type": "askConfirmation"`.
        """
        
        if teachingMode {
            base += """
            
            TEACHING MODE ACTIVE:
            The user wants you to guide and teach them! For each step, explain clearly what to do and why.
            Prefer highlighting elements and explaining the UI rather than blindly taking over.
            """
        }
        
        return base
    }
    
    private func buildUserPrompt(goal: String, observation: ComputerObservation, history: [PlannedActionStep]) -> String {
        var prompt = """
        GOAL: \(goal)
        
        CURRENT OBSERVATION:
        - Observation ID: \(observation.id.uuidString)
        - Display ID: \(observation.displayId)
        - Foreground App: \(observation.foregroundApp ?? "Unknown") (PID: \(observation.foregroundPID ?? 0))
        - Window Title: \(observation.foregroundWindow ?? "None")
        - Display Resolution: \(Int(observation.capturedPixelSize.width))x\(Int(observation.capturedPixelSize.height)) px
        
        ACCESSIBILITY ELEMENT HIERARCHY:
        \(observation.formattedAXSummary(maxDepth: 3, maxElements: 40))
        """
        
        if !history.isEmpty {
            prompt += "\n\nACTION HISTORY:"
            for step in history {
                prompt += "\n- Step \(step.stepNumber): [\(step.action.type.rawValue)] \(step.rationale) -> Output: \(step.output ?? "None") (Status: \(step.status.rawValue))"
            }
        }
        
        prompt += "\n\nEmit the next single action as a JSON object:"
        return prompt
    }
    
    public static func parseAction(from text: String, currentObservation: ComputerObservation) throws -> ComputerAction {
        // Strip markdown code fences if model enclosed JSON
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Find first '{' and last '}'
        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[firstBrace...lastBrace])
        }
        
        guard let data = cleaned.data(using: .utf8) else {
            throw ComputerPlannerError.malformedPlan("Could not convert string to UTF-8 data")
        }
        
        let decoder = JSONDecoder()
        
        // 1. Try decoding Anthropic Claude Computer Use schema {"action": "...", "coordinate": [...]}
        if let claudeAction = try? decoder.decode(ClaudeComputerUseAction.self, from: data),
           !claudeAction.action.isEmpty {
            let converted = claudeAction.toComputerAction(screenPixelSize: currentObservation.capturedPixelSize)
            return ComputerAction(
                type: converted.type,
                observationId: converted.observationId ?? currentObservation.id,
                displayId: converted.displayId ?? currentObservation.displayId,
                elementId: converted.elementId,
                x: converted.x,
                y: converted.y,
                toX: converted.toX,
                toY: converted.toY,
                text: converted.text,
                keys: converted.keys,
                deltaX: converted.deltaX,
                deltaY: converted.deltaY,
                durationSeconds: converted.durationSeconds,
                rationale: converted.rationale,
                isConsequential: converted.isConsequential
            )
        }
        
        // 2. Try native Pinebot ComputerAction schema
        var action = try decoder.decode(ComputerAction.self, from: data)
        
        // If model omitted observationId or displayId, fill from current observation
        if action.observationId == nil || action.displayId == nil {
            action = ComputerAction(
                type: action.type,
                observationId: action.observationId ?? currentObservation.id,
                displayId: action.displayId ?? currentObservation.displayId,
                elementId: action.elementId,
                x: action.x,
                y: action.y,
                toX: action.toX,
                toY: action.toY,
                text: action.text,
                keys: action.keys,
                deltaX: action.deltaX,
                deltaY: action.deltaY,
                durationSeconds: action.durationSeconds,
                rationale: action.rationale,
                isConsequential: action.isConsequential
            )
        }
        
        return action
    }
}

/// Anthropic Claude Computer Use Tool schema representation (bidirectional translation to/from ComputerAction).
public struct ClaudeComputerUseAction: Codable, Sendable, Equatable {
    public let action: String
    public let coordinate: [Int]? // [x, y] in screen pixels
    public let text: String?
    
    public init(action: String, coordinate: [Int]? = nil, text: String? = nil) {
        self.action = action
        self.coordinate = coordinate
        self.text = text
    }
    
    /// Converts an Anthropic Claude Computer Use tool call into Pinebot's ComputerAction.
    /// Uses screenPixelSize (from observation) to convert pixel coordinates into normalized [0.0, 1.0].
    public func toComputerAction(screenPixelSize: CGSize) -> ComputerAction {
        let normX: Double? = coordinate.flatMap { $0.count >= 2 && screenPixelSize.width > 0 ? Double($0[0]) / Double(screenPixelSize.width) : nil }
        let normY: Double? = coordinate.flatMap { $0.count >= 2 && screenPixelSize.height > 0 ? Double($0[1]) / Double(screenPixelSize.height) : nil }
        
        switch action {
        case "left_click", "click":
            return ComputerAction(type: .click, x: normX, y: normY, rationale: "Claude Computer Use left_click")
        case "double_click":
            return ComputerAction(type: .doubleClick, x: normX, y: normY, rationale: "Claude Computer Use double_click")
        case "right_click":
            return ComputerAction(type: .click, x: normX, y: normY, rationale: "Claude Computer Use right_click")
        case "left_click_drag":
            return ComputerAction(type: .drag, toX: normX, toY: normY, rationale: "Claude Computer Use drag")
        case "type":
            return ComputerAction(type: .typeText, text: text, rationale: "Claude Computer Use type")
        case "key":
            let keys = text?.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return ComputerAction(type: .keyCombination, keys: keys, rationale: "Claude Computer Use key: \(text ?? "")")
        case "wait":
            return ComputerAction(type: .wait, durationSeconds: 1.0, rationale: "Claude Computer Use wait")
        case "screenshot":
            return ComputerAction(type: .wait, durationSeconds: 0.2, rationale: "Claude Computer Use screenshot")
        default:
            return ComputerAction(type: .wait, durationSeconds: 0.5, rationale: "Claude action: \(action)")
        }
    }
    
    /// Converts Pinebot's ComputerAction into Anthropic Claude Computer Use schema.
    public static func from(action: ComputerAction, screenPixelSize: CGSize) -> ClaudeComputerUseAction {
        let pixelX = action.x.map { Int($0 * Double(screenPixelSize.width)) }
        let pixelY = action.y.map { Int($0 * Double(screenPixelSize.height)) }
        let coords: [Int]? = (pixelX != nil && pixelY != nil) ? [pixelX!, pixelY!] : nil
        
        switch action.type {
        case .click:
            return ClaudeComputerUseAction(action: "left_click", coordinate: coords)
        case .doubleClick:
            return ClaudeComputerUseAction(action: "double_click", coordinate: coords)
        case .typeText:
            return ClaudeComputerUseAction(action: "type", text: action.text)
        case .keyCombination:
            let keyStr = action.keys?.joined(separator: "+") ?? action.text
            return ClaudeComputerUseAction(action: "key", text: keyStr)
        case .drag:
            let toX = action.toX.map { Int($0 * Double(screenPixelSize.width)) }
            let toY = action.toY.map { Int($0 * Double(screenPixelSize.height)) }
            let toCoords = (toX != nil && toY != nil) ? [toX!, toY!] : nil
            return ClaudeComputerUseAction(action: "left_click_drag", coordinate: toCoords)
        case .wait:
            return ClaudeComputerUseAction(action: "wait")
        default:
            return ClaudeComputerUseAction(action: action.type.rawValue, text: action.text)
        }
    }
}
