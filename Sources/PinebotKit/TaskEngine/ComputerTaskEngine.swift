import AppKit
import CoreGraphics
import Combine
import ApplicationServices

/// Available tools and actions in the computer task engine.
public enum TaskTool: Codable, Sendable, Equatable {
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case type(text: String)
    case keyCombination(keys: [String])
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case scroll(deltaX: Int32, deltaY: Int32)
    case wait(seconds: Double)
    case speak(text: String)
    case askConfirmation(prompt: String)
    case complete(summary: String)
    case fail(reason: String)
    case screenshot
    case inspect
    case openApp(name: String)
    case drawOverlay(type: String, x: Double, y: Double, label: String?)
    case clearOverlay
    case draftReply(text: String, recipientHint: String?)
    
    public init(from action: ComputerAction) {
        switch action.type {
        case .click:
            self = .click(x: action.x ?? 0.5, y: action.y ?? 0.5)
        case .doubleClick:
            self = .doubleClick(x: action.x ?? 0.5, y: action.y ?? 0.5)
        case .typeText:
            self = .type(text: action.text ?? "")
        case .keyCombination:
            self = .keyCombination(keys: action.keys ?? [])
        case .drag:
            self = .drag(fromX: action.x ?? 0, fromY: action.y ?? 0, toX: action.toX ?? 0, toY: action.toY ?? 0)
        case .scroll:
            self = .scroll(deltaX: action.deltaX ?? 0, deltaY: action.deltaY ?? 0)
        case .wait:
            self = .wait(seconds: action.durationSeconds ?? 1.0)
        case .speak:
            self = .speak(text: action.text ?? "")
        case .askConfirmation:
            self = .askConfirmation(prompt: action.text ?? "")
        case .complete:
            self = .complete(summary: action.text ?? "")
        case .fail:
            self = .fail(reason: action.text ?? "")
        }
    }
    
    public var name: String {
        switch self {
        case .click: return "click"
        case .doubleClick: return "double_click"
        case .type: return "type"
        case .keyCombination: return "key_combination"
        case .drag: return "drag"
        case .scroll: return "scroll"
        case .wait: return "wait"
        case .speak: return "speak"
        case .askConfirmation: return "ask_confirmation"
        case .complete: return "complete"
        case .fail: return "fail"
        case .screenshot: return "screenshot"
        case .inspect: return "inspect"
        case .openApp: return "open_app"
        case .drawOverlay: return "draw_overlay"
        case .clearOverlay: return "clear_overlay"
        case .draftReply: return "draft_reply"
        }
    }
    
    public var requiresConfirmation: Bool {
        switch self {
        case .click, .doubleClick, .type, .drag, .openApp, .askConfirmation, .draftReply:
            return true
        case .keyCombination(let keys):
            let joined = keys.joined(separator: "+").lowercased()
            return joined.contains("delete") || joined.contains("q") || joined.contains("w")
        case .wait, .speak, .complete, .fail, .screenshot, .inspect, .scroll, .drawOverlay, .clearOverlay:
            return false
        }
    }
}

/// A single step in a computer task.
public struct TaskStep: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let stepNumber: Int
    public let action: ComputerAction
    public let tool: TaskTool
    public let rationale: String
    public var output: String?
    public var status: StepStatus
    
    public var result: String? {
        output
    }
    
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
        action: ComputerAction? = nil,
        tool: TaskTool? = nil,
        rationale: String,
        output: String? = nil,
        status: StepStatus = .pending
    ) {
        self.id = id
        self.stepNumber = stepNumber
        let resolvedAction = action ?? ComputerAction(type: .click, rationale: rationale)
        self.action = resolvedAction
        self.tool = tool ?? TaskTool(from: resolvedAction)
        self.rationale = rationale
        self.output = output
        self.status = status
    }
}

/// Explicit outcome of a computer task execution.
public enum TaskOutcome: String, Codable, Sendable, Equatable {
    case completed
    case failed
    case rejected
    case cancelled
    case needsUser
}

/// Execution status of the overall task engine.
public enum TaskEngineStatus: Equatable, Sendable {
    case idle
    case planning
    case executingStep(number: Int, total: Int, toolName: String)
    case waitingForConfirmation(step: TaskStep)
    case completed(summary: String)
    case cancelled
    case rejected(reason: String)
    case needsUser(reason: String)
    case failed(error: String)
}

/// Result returned after executing a task loop.
public struct TaskExecutionResult: Sendable, Equatable {
    public let outcome: TaskOutcome
    public let success: Bool
    public let summary: String
    public let stepsCompleted: Int
    public let completedSteps: [TaskStep]
    public let observedEvidence: String?
    
    public init(
        outcome: TaskOutcome,
        success: Bool? = nil,
        summary: String,
        stepsCompleted: Int,
        completedSteps: [TaskStep],
        observedEvidence: String? = nil
    ) {
        self.outcome = outcome
        self.success = success ?? (outcome == .completed)
        self.summary = summary
        self.stepsCompleted = stepsCompleted
        self.completedSteps = completedSteps
        self.observedEvidence = observedEvidence
    }
    
    /// Backwards compatibility initializer
    public init(
        success: Bool,
        summary: String,
        stepsCompleted: Int,
        completedSteps: [TaskStep]
    ) {
        self.outcome = success ? .completed : .failed
        self.success = success
        self.summary = summary
        self.stepsCompleted = stepsCompleted
        self.completedSteps = completedSteps
        self.observedEvidence = nil
    }
}

/// Protocol for executing physical desktop actions (mouse, keyboard, app activation).
public protocol ComputerActionExecutorProtocol: Sendable {
    func execute(
        action: ComputerAction,
        at point: CGPoint?,
        toPoint: CGPoint?,
        observation: ComputerObservation
    ) async throws -> String
}

/// Default action executor posting real macOS CGEvents with keyboard mapping and safe timings.
public final class DefaultComputerActionExecutor: ComputerActionExecutorProtocol, @unchecked Sendable {
    public init() {}
    
    private func clampPoint(_ point: CGPoint, in observation: ComputerObservation) -> CGPoint {
        let maxW = observation.capturedPixelSize.width > 0 ? observation.capturedPixelSize.width : 5120
        let maxH = observation.capturedPixelSize.height > 0 ? observation.capturedPixelSize.height : 2880
        let clampedX = max(0, min(point.x, maxW))
        let clampedY = max(0, min(point.y, maxH))
        return CGPoint(x: clampedX, y: clampedY)
    }
    
    public func execute(
        action: ComputerAction,
        at point: CGPoint?,
        toPoint: CGPoint?,
        observation: ComputerObservation
    ) async throws -> String {
        switch action.type {
        case .click:
            guard let pt = point else {
                throw NSError(domain: "PinebotExecutor", code: 400, userInfo: [NSLocalizedDescriptionKey: "Click target point missing."])
            }
            let clamped = clampPoint(pt, in: observation)
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clamped, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clamped, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 50_000_000)
            up?.post(tap: .cghidEventTap)
            return "Left clicked at (\(Int(clamped.x)), \(Int(clamped.y)))."
            
        case .doubleClick:
            guard let pt = point else {
                throw NSError(domain: "PinebotExecutor", code: 400, userInfo: [NSLocalizedDescriptionKey: "Double-click target point missing."])
            }
            let clamped = clampPoint(pt, in: observation)
            let d1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clamped, mouseButton: .left)
            let u1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clamped, mouseButton: .left)
            let d2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clamped, mouseButton: .left)
            let u2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clamped, mouseButton: .left)
            d2?.setIntegerValueField(.mouseEventClickState, value: 2)
            u2?.setIntegerValueField(.mouseEventClickState, value: 2)
            
            d1?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 30_000_000)
            u1?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 40_000_000)
            d2?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 30_000_000)
            u2?.post(tap: .cghidEventTap)
            return "Double clicked at (\(Int(clamped.x)), \(Int(clamped.y)))."
            
        case .drag:
            guard let from = point, let to = toPoint else {
                throw NSError(domain: "PinebotExecutor", code: 400, userInfo: [NSLocalizedDescriptionKey: "Drag requires valid start and destination points."])
            }
            let clampedFrom = clampPoint(from, in: observation)
            let clampedTo = clampPoint(to, in: observation)
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clampedFrom, mouseButton: .left)
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: clampedTo, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clampedTo, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 100_000_000)
            drag?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 100_000_000)
            up?.post(tap: .cghidEventTap)
            return "Dragged from (\(Int(clampedFrom.x)), \(Int(clampedFrom.y))) to (\(Int(clampedTo.x)), \(Int(clampedTo.y)))."
            
        case .typeText:
            let text = action.text ?? ""
            for character in text {
                if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                    var utf16Char = Array(String(character).utf16)
                    event.keyboardSetUnicodeString(stringLength: utf16Char.count, unicodeString: &utf16Char)
                    event.post(tap: .cghidEventTap)
                }
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            return "Typed \(text.count) characters."
            
        case .keyCombination:
            let keys = action.keys ?? []
            guard !keys.isEmpty else {
                return "No keys specified."
            }
            var flags: CGEventFlags = []
            var mainKeyCode: CGKeyCode = 0
            
            for key in keys {
                let k = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                switch k {
                case "cmd", "command": flags.insert(.maskCommand)
                case "shift": flags.insert(.maskShift)
                case "opt", "option", "alt": flags.insert(.maskAlternate)
                case "ctrl", "control": flags.insert(.maskControl)
                case "return", "enter": mainKeyCode = 0x24
                case "tab": mainKeyCode = 0x30
                case "space": mainKeyCode = 0x31
                case "escape", "esc": mainKeyCode = 0x35
                case "delete", "backspace": mainKeyCode = 0x33
                case "up": mainKeyCode = 0x7E
                case "down": mainKeyCode = 0x7D
                case "left": mainKeyCode = 0x7B
                case "right": mainKeyCode = 0x7C
                case "a": mainKeyCode = 0x00
                case "c": mainKeyCode = 0x08
                case "v": mainKeyCode = 0x09
                case "x": mainKeyCode = 0x07
                case "z": mainKeyCode = 0x06
                case "f": mainKeyCode = 0x03
                case "w": mainKeyCode = 0x0D
                case "q": mainKeyCode = 0x0C
                default:
                    if let first = k.first, let ascii = first.asciiValue {
                        mainKeyCode = CGKeyCode(ascii)
                    }
                }
            }
            
            let down = CGEvent(keyboardEventSource: nil, virtualKey: mainKeyCode, keyDown: true)
            down?.flags = flags
            down?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 30_000_000)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: mainKeyCode, keyDown: false)
            up?.flags = flags
            up?.post(tap: .cghidEventTap)
            
            // Clean up: reset modifier flags to prevent stuck modifiers
            if !flags.isEmpty {
                let resetEvent = CGEvent(source: nil)
                resetEvent?.flags = []
                resetEvent?.post(tap: .cghidEventTap)
            }
            return "Sent key combination: \(keys.joined(separator: "+"))."
            
        case .scroll:
            let dx = action.deltaX ?? 0
            let dy = action.deltaY ?? 0
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            event?.post(tap: .cghidEventTap)
            return "Scrolled by delta (\(dx), \(dy))."
            
        case .wait:
            let seconds = action.durationSeconds ?? 1.0
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "Waited \(seconds) seconds."
            
        case .speak:
            return "Spoken: \(action.text ?? "")"
            
        case .askConfirmation, .complete, .fail:
            return action.text ?? "Finished"
        }
    }
}

/// Fallback computer planner when no model provider is connected or available.
/// Strictly reports unavailable/needsUser, never emits fake completion or synthetic success.
public final class FallbackComputerPlanner: ComputerPlanner, @unchecked Sendable {
    public init() {}
    
    public func planNextStep(
        goal: String,
        observation: ComputerObservation,
        history: [PlannedActionStep],
        teachingMode: Bool
    ) async throws -> PlannedActionStep {
        let errorMsg = "No capable AI provider connected for desktop automation. Please connect ChatGPT, Claude, or Gemini in Accounts with computer planning support."
        return PlannedActionStep(
            stepNumber: history.count + 1,
            action: ComputerAction(
                type: .fail,
                text: errorMsg,
                rationale: "Automated desktop control requires an active AI provider supporting vision and planning."
            ),
            rationale: "Provider unavailable",
            output: errorMsg,
            status: .failed
        )
    }
}

/// Bounded computer task engine with strict observe -> plan -> validate -> authorize -> execute loop.
@MainActor
public final class ComputerTaskEngine: ObservableObject {
    public static let shared = ComputerTaskEngine()
    
    @Published public private(set) var status: TaskEngineStatus = .idle
    @Published public private(set) var steps: [TaskStep] = []
    @Published public private(set) var currentGoal: String?
    @Published public private(set) var draftedReply: String?
    
    private let observer: ComputerObserverProtocol
    private var planner: ComputerPlanner?
    private let overlay: ScreenOverlayManager
    private let speech: SpeechManagerProtocol
    private let coordinator: AgentCoordinator
    private let executor: ComputerActionExecutorProtocol
    
    private var isCancelled: Bool = false
    private let maxSteps = 25
    private var currentJobId: UUID?
    private var currentExecutionId: UUID?
    private var activeExecutionTask: Task<TaskExecutionResult, Error>?
    
    public init(
        observer: ComputerObserverProtocol = ScreenCaptureManager.shared,
        planner: ComputerPlanner? = nil,
        overlay: ScreenOverlayManager = .shared,
        speech: SpeechManagerProtocol = SpeechManager.shared,
        coordinator: AgentCoordinator = .shared,
        executor: ComputerActionExecutorProtocol = DefaultComputerActionExecutor()
    ) {
        self.observer = observer
        self.planner = planner
        self.overlay = overlay
        self.speech = speech
        self.coordinator = coordinator
        self.executor = executor
    }
    
    public func setPlanner(_ planner: ComputerPlanner) {
        self.planner = planner
    }
    
    /// Cancels any active task immediately, resolving any pending tool confirmations and releasing leases.
    public func cancel() {
        isCancelled = true
        currentExecutionId = nil
        activeExecutionTask?.cancel()
        activeExecutionTask = nil
        status = .cancelled
        
        for (_, cont) in confirmationContinuations {
            cont.resume(returning: false)
        }
        confirmationContinuations.removeAll()
        
        overlay.clear()
        speech.stopSpeaking()
        
        if let jobId = currentJobId {
            let jId = jobId
            currentJobId = nil
            Task {
                await coordinator.releaseDesktopLease(jobId: jId)
                await coordinator.finishJob(jobId: jId, status: .cancelled)
            }
        }
    }
    
    /// Resets the engine state.
    public func reset() {
        cancel()
        isCancelled = false
        currentExecutionId = nil
        status = .idle
        currentGoal = nil
        steps = []
        draftedReply = nil
    }
    
    /// Executes a computer task via the autonomous observe -> plan -> validate -> authorize -> execute loop.
    @discardableResult
    public func executeTask(
        goal: String,
        planner: ComputerPlanner? = nil,
        teachingMode: Bool = false,
        requireConfirmation: Bool = true,
        parentJobId: UUID? = nil
    ) async throws -> TaskExecutionResult {
        // Enforce coordinator child agent depth and concurrency limits
        let jobId = try await coordinator.spawnJob(description: goal, parentJobId: parentJobId)
        self.currentJobId = jobId
        
        let executionId = UUID()
        self.currentExecutionId = executionId
        self.isCancelled = false
        self.currentGoal = goal
        self.steps = []
        self.status = .planning
        
        let effectivePlanner = planner ?? self.planner ?? FallbackComputerPlanner()
        
        let task = Task<TaskExecutionResult, Error> { @MainActor [weak self] in
            guard let self = self else { throw CancellationError() }
            return try await self.runExecutionLoop(
                executionId: executionId,
                jobId: jobId,
                goal: goal,
                effectivePlanner: effectivePlanner,
                teachingMode: teachingMode,
                requireConfirmation: requireConfirmation
            )
        }
        self.activeExecutionTask = task
        
        do {
            let result = try await task.value
            if self.currentExecutionId == executionId {
                self.activeExecutionTask = nil
            }
            return result
        } catch {
            if self.currentExecutionId == executionId {
                self.activeExecutionTask = nil
            }
            throw error
        }
    }
    
    private func runExecutionLoop(
        executionId: UUID,
        jobId: UUID,
        goal: String,
        effectivePlanner: ComputerPlanner,
        teachingMode: Bool,
        requireConfirmation: Bool
    ) async throws -> TaskExecutionResult {
        var completedSteps: [PlannedActionStep] = []
        var stepCount = 0
        
        while stepCount < maxSteps {
            guard !self.isCancelled, !Task.isCancelled, self.currentExecutionId == executionId else {
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .cancelled)
                return TaskExecutionResult(outcome: .cancelled, summary: "Task cancelled.", stepsCompleted: stepCount, completedSteps: steps)
            }
            
            stepCount += 1
            
            // 1. Capture fresh ComputerObservation
            let observation: ComputerObservation
            do {
                observation = try await observer.captureObservation(
                    displayID: nil,
                    maxDimension: 1280.0,
                    excludePinebotWindows: true
                )
            } catch {
                guard self.currentExecutionId == executionId else { throw CancellationError() }
                let errText = "Observation capture failed: \(error.localizedDescription)"
                status = .failed(error: errText)
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .failed(errText))
                throw error
            }
            
            guard !self.isCancelled, !Task.isCancelled, self.currentExecutionId == executionId else {
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .cancelled)
                return TaskExecutionResult(outcome: .cancelled, summary: "Task cancelled.", stepsCompleted: stepCount, completedSteps: steps)
            }
            
            // 2. Call Planner
            status = .planning
            let plannedStep: PlannedActionStep
            do {
                plannedStep = try await effectivePlanner.planNextStep(
                    goal: goal,
                    observation: observation,
                    history: completedSteps,
                    teachingMode: teachingMode
                )
            } catch {
                guard self.currentExecutionId == executionId else { throw CancellationError() }
                let errText = "Planning failed: \(error.localizedDescription)"
                status = .failed(error: errText)
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .failed(errText))
                throw error
            }
            
            guard !self.isCancelled, !Task.isCancelled, self.currentExecutionId == executionId else {
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .cancelled)
                return TaskExecutionResult(outcome: .cancelled, summary: "Task cancelled.", stepsCompleted: stepCount, completedSteps: steps)
            }
            
            let action = plannedStep.action
            
            // Check terminal conditions
            if action.type == .complete {
                let evidence = extractObservedEvidence(from: observation)
                let finalStep = TaskStep(
                    stepNumber: stepCount,
                    action: action,
                    tool: .complete(summary: action.text ?? "Complete"),
                    rationale: action.rationale ?? "Task completed",
                    output: action.text ?? "Task completed",
                    status: .completed
                )
                steps.append(finalStep)
                let summary = action.text ?? "Task successfully completed."
                status = .completed(summary: summary)
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .completed)
                return TaskExecutionResult(
                    outcome: .completed,
                    summary: summary,
                    stepsCompleted: stepCount,
                    completedSteps: steps,
                    observedEvidence: evidence
                )
            }
            
            if action.type == .fail {
                let failStep = TaskStep(
                    stepNumber: stepCount,
                    action: action,
                    tool: .fail(reason: action.text ?? "Failed"),
                    rationale: action.rationale ?? "Task cannot be completed",
                    output: action.text ?? "Task failed",
                    status: .failed
                )
                steps.append(failStep)
                let errorMsg = action.text ?? "Task cannot be completed."
                let isNeedsUser = errorMsg.localizedCaseInsensitiveContains("no capable") ||
                                  errorMsg.localizedCaseInsensitiveContains("unavailable") ||
                                  errorMsg.localizedCaseInsensitiveContains("connect")
                let outcome: TaskOutcome = isNeedsUser ? .needsUser : .failed
                if isNeedsUser {
                    status = .needsUser(reason: errorMsg)
                } else {
                    status = .failed(error: errorMsg)
                }
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .failed(errorMsg))
                return TaskExecutionResult(
                    outcome: outcome,
                    summary: errorMsg,
                    stepsCompleted: stepCount,
                    completedSteps: steps
                )
            }
            
            // 3. Strict Coordinate & Target Validation
            var resolvedPoint: CGPoint? = nil
            var resolvedToPoint: CGPoint? = nil
            
            do {
                if let elId = action.elementId {
                    let resolved = try ScreenCaptureManager.resolveElementCoordinates(observation: observation, elementId: elId)
                    resolvedPoint = resolved.point
                } else if let x = action.x, let y = action.y {
                    resolvedPoint = try ScreenCaptureManager.convertAndValidateCoordinates(
                        observation: observation,
                        targetObservationId: action.observationId ?? observation.id,
                        targetDisplayId: action.displayId ?? observation.displayId,
                        xNorm: x,
                        yNorm: y
                    )
                }
                
                if let toX = action.toX, let toY = action.toY {
                    resolvedToPoint = try ScreenCaptureManager.convertAndValidateCoordinates(
                        observation: observation,
                        targetObservationId: action.observationId ?? observation.id,
                        targetDisplayId: action.displayId ?? observation.displayId,
                        xNorm: toX,
                        yNorm: toY
                    )
                }
            } catch {
                guard self.currentExecutionId == executionId else { throw CancellationError() }
                status = .failed(error: error.localizedDescription)
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .failed(error.localizedDescription))
                throw error
            }
            
            // 4. Consequential Action Authorization
            var currentStep = TaskStep(
                stepNumber: stepCount,
                action: action,
                rationale: plannedStep.rationale,
                status: .pending
            )
            steps.append(currentStep)
            let stepIndex = steps.count - 1
            
            let requiresAuth = action.isConsequentialAction || (requireConfirmation && currentStep.tool.requiresConfirmation)
            if requiresAuth {
                currentStep.status = .waitingConfirmation
                steps[stepIndex] = currentStep
                status = .waitingForConfirmation(step: currentStep)
                
                let approved = await waitForConfirmation(stepId: currentStep.id)
                guard self.currentExecutionId == executionId else {
                    await coordinator.releaseDesktopLease(jobId: jobId)
                    await coordinator.finishJob(jobId: jobId, status: .cancelled)
                    return TaskExecutionResult(outcome: .cancelled, summary: "Task cancelled.", stepsCompleted: stepCount, completedSteps: steps)
                }
                
                guard approved else {
                    // Rejection terminates the task immediately as .rejected
                    currentStep.status = .rejected
                    currentStep.output = "Action rejected or skipped by user."
                    steps[stepIndex] = currentStep
                    let rejectMsg = "User declined action: \(currentStep.rationale)"
                    status = .rejected(reason: rejectMsg)
                    await coordinator.releaseDesktopLease(jobId: jobId)
                    await coordinator.finishJob(jobId: jobId, status: .cancelled)
                    return TaskExecutionResult(
                        outcome: .rejected,
                        summary: rejectMsg,
                        stepsCompleted: stepCount,
                        completedSteps: steps
                    )
                }
            }
            
            // 5. Teaching Mode
            if teachingMode {
                if let pt = resolvedPoint {
                    overlay.highlightObservationTarget(
                        observation,
                        cgPoint: pt,
                        widthNorm: 0.05,
                        heightNorm: 0.05,
                        label: action.rationale ?? "Target"
                    )
                }
                
                let spoken = action.rationale ?? action.text ?? "Notice this step."
                speech.speak(text: spoken)
                
                try await Task.sleep(nanoseconds: 600_000_000)
                overlay.clear()
            }
            
            guard !self.isCancelled, !Task.isCancelled, self.currentExecutionId == executionId else {
                await coordinator.releaseDesktopLease(jobId: jobId)
                await coordinator.finishJob(jobId: jobId, status: .cancelled)
                return TaskExecutionResult(outcome: .cancelled, summary: "Task cancelled.", stepsCompleted: stepCount, completedSteps: steps)
            }
            
            // 6. Execute physical action under exclusive lease
            currentStep.status = .executing
            steps[stepIndex] = currentStep
            status = .executingStep(number: stepCount, total: maxSteps, toolName: currentStep.tool.name)
            
            _ = try await coordinator.acquireDesktopLease(jobId: jobId)
            
            do {
                let output = try await executor.execute(
                    action: action,
                    at: resolvedPoint,
                    toPoint: resolvedToPoint,
                    observation: observation
                )
                await coordinator.releaseDesktopLease(jobId: jobId)
                
                guard self.currentExecutionId == executionId else {
                    return TaskExecutionResult(outcome: .cancelled, summary: "Task superseded.", stepsCompleted: stepCount, completedSteps: steps)
                }
                
                currentStep.status = .completed
                currentStep.output = output
                steps[stepIndex] = currentStep
                
                completedSteps.append(PlannedActionStep(
                    id: currentStep.id,
                    stepNumber: stepCount,
                    action: action,
                    rationale: currentStep.rationale,
                    output: output,
                    status: .completed
                ))
            } catch {
                await coordinator.releaseDesktopLease(jobId: jobId)
                guard self.currentExecutionId == executionId else { throw CancellationError() }
                currentStep.status = .failed
                currentStep.output = "Error: \(error.localizedDescription)"
                steps[stepIndex] = currentStep
                status = .failed(error: error.localizedDescription)
                await coordinator.finishJob(jobId: jobId, status: .failed(error.localizedDescription))
                throw error
            }
        }
        
        let limitMsg = "Bounded step limit reached (max \(maxSteps) steps)."
        status = .failed(error: limitMsg)
        await coordinator.finishJob(jobId: jobId, status: .failed(limitMsg))
        return TaskExecutionResult(
            outcome: .failed,
            summary: limitMsg,
            stepsCompleted: stepCount,
            completedSteps: steps
        )
    }
    
    private func extractObservedEvidence(from observation: ComputerObservation) -> String {
        var details: [String] = []
        if let app = observation.foregroundApp {
            details.append("Active app: \(app)")
        }
        if let win = observation.foregroundWindow {
            details.append("Window: '\(win)'")
        }
        if !observation.axElements.isEmpty {
            let names = observation.axElements.prefix(3).compactMap { $0.title ?? $0.role }.joined(separator: ", ")
            details.append("Top elements: [\(names)]")
        }
        return details.isEmpty ? "Screen state verified at \(Int(observation.capturedPixelSize.width))x\(Int(observation.capturedPixelSize.height))" : details.joined(separator: "; ")
    }
    
    /// Overload preserving backwards compatibility for pre-planned initial step sequences.
    public func executeTask(
        goal: String,
        initialSteps: [TaskStep],
        requireConfirmation: Bool = true,
        childDepth: Int = 0
    ) async throws {
        guard childDepth <= 1 else {
            throw NSError(domain: "PinebotTaskEngine", code: 403, userInfo: [NSLocalizedDescriptionKey: "Child agent depth limit reached."])
        }
        isCancelled = false
        currentGoal = goal
        steps = initialSteps
        status = .planning
        
        var stepCount = 0
        for index in 0..<steps.count {
            if isCancelled {
                status = .cancelled
                return
            }
            
            stepCount += 1
            guard stepCount <= 10 else {
                status = .failed(error: "Bounded step limit reached (max 10 steps).")
                return
            }
            
            var currentStep = steps[index]
            status = .executingStep(number: currentStep.stepNumber, total: steps.count, toolName: currentStep.tool.name)
            
            if requireConfirmation && currentStep.tool.requiresConfirmation {
                currentStep.status = .waitingConfirmation
                steps[index] = currentStep
                status = .waitingForConfirmation(step: currentStep)
                
                let confirmed = await waitForConfirmation(stepId: currentStep.id)
                guard confirmed else {
                    currentStep.status = .rejected
                    currentStep.output = "User skipped or rejected this action."
                    steps[index] = currentStep
                    let rejectMsg = "User declined action: \(currentStep.rationale)"
                    status = .rejected(reason: rejectMsg)
                    return
                }
            }
            
            currentStep.status = .executing
            steps[index] = currentStep
            
            do {
                let output = try await runLegacyTool(currentStep.tool)
                currentStep.output = output
                currentStep.status = .completed
                steps[index] = currentStep
            } catch {
                currentStep.status = .failed
                currentStep.output = "Error: \(error.localizedDescription)"
                steps[index] = currentStep
                status = .failed(error: "Step \(currentStep.stepNumber) failed: \(error.localizedDescription)")
                return
            }
        }
        
        status = .completed(summary: "Successfully completed task: \(goal)")
    }
    
    private func runLegacyTool(_ tool: TaskTool) async throws -> String {
        switch tool {
        case .screenshot:
            let obs = try await observer.captureObservation(displayID: nil, maxDimension: 1280.0, excludePinebotWindows: true)
            return "Screenshot captured successfully (\(Int(obs.capturedPixelSize.width))x\(Int(obs.capturedPixelSize.height))px)."
        case .inspect:
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
                .joined(separator: ", ")
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            return "Active frontmost app: \(front). Running apps: \(running)."
        case .clearOverlay:
            overlay.clear()
            return "Screen overlay cleared."
        case .draftReply(let text, _):
            self.draftedReply = text
            return "Drafted reply for user review."
        case .openApp(let name):
            throw NSError(domain: "PinebotTaskEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Legacy action 'openApp(\(name))' is unsupported without physical computer action executor."])
        case .drawOverlay:
            throw NSError(domain: "PinebotTaskEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Legacy action 'drawOverlay' is unsupported without physical computer action executor."])
        default:
            throw NSError(domain: "PinebotTaskEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported legacy tool: '\(tool.name)'."])
        }
    }
    
    // MARK: - Confirmation Mechanism
    
    private var confirmationContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    
    private func waitForConfirmation(stepId: UUID) async -> Bool {
        return await withCheckedContinuation { continuation in
            confirmationContinuations[stepId] = continuation
        }
    }
    
    public func confirmStep(stepId: UUID, approved: Bool) {
        if let cont = confirmationContinuations.removeValue(forKey: stepId) {
            cont.resume(returning: approved)
        }
    }
}
