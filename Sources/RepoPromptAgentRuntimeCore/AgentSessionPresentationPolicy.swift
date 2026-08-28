import Foundation
import RepoPromptServiceProtocol

/// Immutable authority facts used by every non-desktop Agent Mode client.
/// Presentation clients render this decision; they do not reconstruct run
/// state from lifecycle strings or transcript rows.
public struct AgentSessionPresentationFacts: Sendable {
    public let isRootSession: Bool
    public let sessionRevision: Int64
    public let lifecycleState: SessionLifecycleState
    public let isController: Bool
    public let composerAvailable: Bool
    public let providerAvailable: Bool
    public let supportsResume: Bool
    public let supportsSteering: Bool
    public let activeRunID: UUID?
    public let activeGeneration: Int64?
    public let activeTurnEpoch: Int64?
    public let steeringReady: Bool
    public let runPresentation: RunPresentationWireSnapshot?

    public init(
        isRootSession: Bool,
        sessionRevision: Int64,
        lifecycleState: SessionLifecycleState,
        isController: Bool,
        composerAvailable: Bool,
        providerAvailable: Bool,
        supportsResume: Bool,
        supportsSteering: Bool,
        activeRunID: UUID?,
        activeGeneration: Int64?,
        activeTurnEpoch: Int64?,
        steeringReady: Bool,
        runPresentation: RunPresentationWireSnapshot?
    ) {
        self.isRootSession = isRootSession
        self.sessionRevision = sessionRevision
        self.lifecycleState = lifecycleState
        self.isController = isController
        self.composerAvailable = composerAvailable
        self.providerAvailable = providerAvailable
        self.supportsResume = supportsResume
        self.supportsSteering = supportsSteering
        self.activeRunID = activeRunID
        self.activeGeneration = activeGeneration
        self.activeTurnEpoch = activeTurnEpoch
        self.steeringReady = steeringReady
        self.runPresentation = runPresentation
    }
}

public enum AgentSessionPresentationPolicy {
    public static func evaluate(_ facts: AgentSessionPresentationFacts) -> AgentSessionActionSnapshotWire {
        let presentation = facts.runPresentation
        let terminal = normalized(presentation?.terminalSettlementCode)
        let active = facts.activeRunID != nil
        let phase = active ? presentation?.phase : nil
        let display = displayState(facts: facts, phase: phase, terminal: terminal)
        let status = active
            ? presentation?.runningStatusText.flatMap(nonEmpty) ?? statusText(display)
            : statusText(display)

        func denied(_ code: String, _ text: String) -> AgentSessionActionWire {
            .init(allowed: false, reasonCode: code, reasonText: text)
        }

        func commonDenial() -> AgentSessionActionWire? {
            if !facts.isRootSession {
                return denied("root_session_only", "Only root Agent sessions can be controlled here.")
            }
            if facts.lifecycleState == .archived {
                return denied("session_archived", "This session is archived.")
            }
            if !facts.isController {
                return denied("not_controller", "Only the session controller can perform this action.")
            }
            return nil
        }

        let submit: AgentSessionActionWire
        if let denial = commonDenial() {
            submit = denial
        } else if facts.lifecycleState == .waiting || phase == .waiting {
            submit = denied("waiting_for_interaction", "Answer the pending interaction before submitting another turn.")
        } else if active {
            submit = denied("run_active", "A provider run is already active.")
        } else if !facts.providerAvailable {
            submit = denied("provider_unavailable", "The selected provider is unavailable.")
        } else if !facts.composerAvailable {
            submit = denied("composer_unavailable", "The composer catalog is unavailable.")
        } else {
            submit = .init(allowed: true, expectedSessionRevision: facts.sessionRevision)
        }

        let steer: AgentSessionActionWire
        if let denial = commonDenial() {
            steer = denial
        } else if facts.lifecycleState == .waiting || phase == .waiting {
            steer = denied("waiting_for_interaction", "Answer the pending interaction before steering the run.")
        } else if !active {
            steer = denied("run_inactive", "There is no active run that can be steered.")
        } else if !facts.supportsSteering {
            steer = denied("steering_unsupported", "The selected provider does not support steering.")
        } else if !facts.steeringReady {
            steer = denied("steering_not_ready", "The provider control channel is not ready yet.")
        } else {
            steer = .init(allowed: true, targetTurnEpoch: facts.activeTurnEpoch ?? presentation?.turnEpoch)
        }

        let cancel: AgentSessionActionWire
        if let denial = commonDenial() {
            cancel = denial
        } else if phase == .cancelling {
            cancel = denied("cancelling", "Cancellation is already in progress.")
        } else if !active {
            cancel = denied("run_inactive", "There is no active provider run to cancel.")
        } else {
            cancel = .init(
                allowed: true,
                expectedRunID: facts.activeRunID,
                expectedGeneration: facts.activeGeneration ?? presentation?.generation
            )
        }

        let resumable = facts.lifecycleState == .canceled || facts.lifecycleState == .interrupted
            || terminal == "canceled" || terminal == "cancelled" || terminal == "interrupted"
        let resume: AgentSessionActionWire
        if let denial = commonDenial() {
            resume = denial
        } else if active {
            resume = denied("run_active", "A provider run is already active.")
        } else if resumable, facts.supportsResume, facts.providerAvailable {
            resume = .init(allowed: true, expectedRunID: presentation?.runID)
        } else {
            resume = denied("no_resumable_run", "There is no interrupted provider run that can be resumed.")
        }

        let retryable = facts.lifecycleState == .failed
            || terminal == "provider_error" || terminal == "provider_launch_failed"
            || terminal == "failed" || terminal == "error"
        let retry: AgentSessionActionWire
        if let denial = commonDenial() {
            retry = denial
        } else if active {
            retry = denied("run_active", "A provider run is already active.")
        } else if retryable, let runID = presentation?.runID {
            retry = .init(allowed: true, sourceRunID: runID)
        } else {
            retry = denied("no_retryable_run", "There is no failed run to retry.")
        }

        let archive: AgentSessionActionWire
        if let denial = commonDenial() {
            archive = denial
        } else if active {
            archive = denied("run_active", "An active session cannot be archived.")
        } else {
            archive = .init(allowed: true, expectedSessionRevision: facts.sessionRevision)
        }

        return .init(
            displayState: display,
            statusText: status,
            submitTurn: submit,
            steer: steer,
            resume: resume,
            cancel: cancel,
            retry: retry,
            archive: archive
        )
    }

    private static func displayState(
        facts: AgentSessionPresentationFacts,
        phase: RunPresentationPhaseWire?,
        terminal: String?
    ) -> AgentSessionDisplayStateWire {
        if facts.lifecycleState == .archived { return .archived }
        if let phase {
            switch phase {
            case .preparing: return .preparing
            case .thinking: return .thinking
            case .working: return .working
            case .waiting: return .waiting
            case .cancelling: return .cancelling
            }
        }
        switch facts.lifecycleState {
        case .preparing: return .preparing
        case .running: return .working
        case .waiting: return .waiting
        case .completed: return .completed
        case .failed: return .failed
        case .canceled, .interrupted: return .cancelled
        case .archived: return .archived
        case .idle:
            switch terminal {
            case "completed", "succeeded", "success": return .completed
            case "canceled", "cancelled", "interrupted": return .cancelled
            case "provider_error", "provider_launch_failed", "failed", "error": return .failed
            default: return .idle
            }
        }
    }

    private static func statusText(_ state: AgentSessionDisplayStateWire) -> String {
        switch state {
        case .idle: "Ready for a new turn"
        case .preparing: "Preparing the provider run"
        case .thinking: "Thinking"
        case .working: "Working"
        case .waiting: "Waiting for your response"
        case .cancelling: "Cancelling"
        case .completed: "Run completed"
        case .failed: "Run failed"
        case .cancelled: "Run cancelled"
        case .archived: "Session archived"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
