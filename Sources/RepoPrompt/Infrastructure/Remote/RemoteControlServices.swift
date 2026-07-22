import Foundation
import RepoPromptRemoteProtocol

// MARK: - Typed remote service boundary

/// A sanitized, immutable workspace record used by remote projections. The
/// adapter deliberately exposes only a repository-root summary, never a raw
/// filesystem path.
struct RemoteWorkspaceRecord: Equatable, Sendable {
    let workspaceID: UUID
    let name: String
    let repositoryRootSummary: String?
    let isOpen: Bool
    let activeSessionIDs: [UUID]
    let lastActivityAt: Date?
}

struct RemoteSessionRecord: Equatable, Sendable {
    let sessionID: UUID
    let workspaceID: UUID
    let composeTabID: UUID?
    let parentSessionID: UUID?
    let sessionName: String?
    let workflow: String?
    let agent: String?
    let model: String?
    let reasoningEffort: String?
    let runState: RemoteRunState
    let lifecycleStage: String?
    let latestMeaningfulActivity: String?
    let pendingInteraction: RemoteInteractionSummary?
    let worktreeSummary: String?
    let mergeAttention: String?
    let failureSummary: String?
    let lastUpdatedAt: Date
    let isLive: Bool
}

struct RemoteCatalogRecord: Equatable, Sendable {
    let workflows: [RemoteWorkflowDescriptor]
    let agents: [RemoteAgentDescriptor]

    static let empty = Self(workflows: [], agents: [])
}

@MainActor
protocol WorkspaceCatalogService: AnyObject {
    func allSavedWorkspaces() async -> [RemoteWorkspaceRecord]
}

@MainActor
protocol WorkspaceActivationService: AnyObject {
    func activate(workspaceID: UUID) async -> Result<RemoteWorkspaceActivationResult, RemoteWorkspaceActivationError>
}

struct RemoteWorkspaceActivationResult: Equatable, Sendable {
    let workspaceID: UUID
    let composeTabID: UUID?
    let windowID: Int?
    let reusedExistingWindow: Bool
}

enum RemoteWorkspaceActivationError: Error, Equatable, Sendable {
    case invalidWorkspaceID
    case workspaceNotFound
    case activationBlocked(String)
}

@MainActor
protocol SessionQueryService: AnyObject {
    func remoteSessions() async -> [RemoteSessionRecord]
}

@MainActor
protocol WorkflowCatalogService: AnyObject {
    func remoteCatalog() async -> RemoteCatalogRecord
}

@MainActor
protocol RemoteStateProjectionService: AnyObject {
    func snapshot() async -> RemoteSnapshot
}

/// The only production-facing composition point needed by the gateway. It
/// projects authoritative desktop services into the shared wire DTOs and keeps
/// all path/window/provider implementation details out of the protocol layer.
@MainActor
final class RemoteSnapshotBuilder {
    private let workspaceCatalog: any WorkspaceCatalogService
    private let sessionQuery: any SessionQueryService
    private let workflowCatalog: any WorkflowCatalogService

    init(
        workspaceCatalog: any WorkspaceCatalogService,
        sessionQuery: any SessionQueryService,
        workflowCatalog: any WorkflowCatalogService
    ) {
        self.workspaceCatalog = workspaceCatalog
        self.sessionQuery = sessionQuery
        self.workflowCatalog = workflowCatalog
    }

    func build(
        desktop: RemoteDesktopSummary,
        connection: RemoteConnectionSummary,
        authorization: RemoteAuthorizationState,
        eventCursor: UInt64 = 0
    ) async -> RemoteSnapshot {
        let workspaces = await workspaceCatalog.allSavedWorkspaces()
            .map {
                RemoteWorkspaceSummary(
                    workspaceID: $0.workspaceID.uuidString,
                    name: $0.name,
                    repositoryRootSummary: $0.repositoryRootSummary,
                    isOpen: $0.isOpen,
                    activeSessionIDs: $0.activeSessionIDs,
                    lastActivityAt: $0.lastActivityAt
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let records = await sessionQuery.remoteSessions()
        let childIDsByParent = records.reduce(into: [UUID: [UUID]]()) { result, record in
            guard let parent = record.parentSessionID else { return }
            result[parent, default: []].append(record.sessionID)
        }
        let sessions = records.map {
            RemoteSessionSummary(
                sessionID: $0.sessionID,
                workspaceID: $0.workspaceID.uuidString,
                composeTabID: $0.composeTabID,
                parentSessionID: $0.parentSessionID,
                sessionName: $0.sessionName,
                workflow: $0.workflow,
                agent: $0.agent,
                model: $0.model,
                reasoningEffort: $0.reasoningEffort,
                runState: $0.runState,
                lifecycleStage: $0.lifecycleStage,
                latestMeaningfulActivity: $0.latestMeaningfulActivity,
                pendingInteraction: $0.pendingInteraction,
                childSessionIDs: childIDsByParent[$0.sessionID, default: []].sorted { $0.uuidString < $1.uuidString },
                worktreeSummary: $0.worktreeSummary,
                mergeAttention: $0.mergeAttention,
                failureSummary: $0.failureSummary,
                lastUpdatedAt: $0.lastUpdatedAt,
                isLive: $0.isLive
            )
        }
        .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }

        let attentionItems = sessions.compactMap { session -> RemoteAttentionItem? in
            guard let interaction = session.pendingInteraction else {
                switch session.runState {
                case .failed:
                    return RemoteAttentionItem(id: session.sessionID, kind: .failed, sessionID: session.sessionID, title: "Agent failed", sanitizedPreview: session.failureSummary)
                case .completed:
                    return RemoteAttentionItem(id: session.sessionID, kind: .completed, sessionID: session.sessionID, title: "Agent completed")
                default:
                    return nil
                }
            }
            let kind: RemoteAttentionKind = interaction.kind == .approval ? .approvalRequired : .agentNeedsInput
            return RemoteAttentionItem(
                id: UUID(uuidString: interaction.id) ?? session.sessionID,
                kind: kind,
                sessionID: session.sessionID,
                title: interaction.title ?? (kind == .approvalRequired ? "Approval required" : "Agent needs you"),
                sanitizedPreview: interaction.prompt
            )
        }

        let catalog = await workflowCatalog.remoteCatalog()
        return RemoteSnapshot(
            desktop: desktop,
            connection: connection,
            authorization: authorization,
            workspaces: workspaces,
            sessions: sessions,
            attentionItems: attentionItems,
            workflowCatalog: catalog.workflows,
            agentCatalog: catalog.agents,
            eventCursor: eventCursor
        )
    }
}

// MARK: - Existing desktop state adapters

@MainActor
final class WorkspaceManagerRemoteCatalogService: WorkspaceCatalogService {
    private let managers: [WorkspaceManagerViewModel]

    init(manager: WorkspaceManagerViewModel) {
        managers = [manager]
    }

    init(managers: [WorkspaceManagerViewModel]) {
        self.managers = managers
    }

    func allSavedWorkspaces() async -> [RemoteWorkspaceRecord] {
        var records: [UUID: RemoteWorkspaceRecord] = [:]
        for manager in managers {
            for workspace in manager.workspaces where !workspace.isEphemeral {
                let current = RemoteWorkspaceRecord(
                    workspaceID: workspace.id,
                    name: workspace.name,
                    repositoryRootSummary: workspace.repoPaths.first
                        .map { URL(fileURLWithPath: $0).lastPathComponent },
                    isOpen: WindowStatesManager.shared.countWindowsShowing(workspaceId: workspace.id) > 0,
                    activeSessionIDs: workspace.composeTabs.compactMap(\.activeAgentSessionID),
                    lastActivityAt: workspace.lastUsed
                )
                if let existing = records[workspace.id] {
                    records[workspace.id] = RemoteWorkspaceRecord(
                        workspaceID: existing.workspaceID,
                        name: existing.name,
                        repositoryRootSummary: existing.repositoryRootSummary ?? current.repositoryRootSummary,
                        isOpen: existing.isOpen || current.isOpen,
                        activeSessionIDs: Array(Set(existing.activeSessionIDs + current.activeSessionIDs))
                            .sorted { $0.uuidString < $1.uuidString },
                        lastActivityAt: max(existing.lastActivityAt ?? .distantPast, current.lastActivityAt ?? .distantPast)
                    )
                } else {
                    records[workspace.id] = current
                }
            }
        }
        return Array(records.values)
    }
}

@MainActor
final class WorkspaceManagerRemoteActivationService: WorkspaceActivationService {
    private weak var manager: WorkspaceManagerViewModel?

    init(manager: WorkspaceManagerViewModel) {
        self.manager = manager
    }

    func activate(workspaceID: UUID) async -> Result<RemoteWorkspaceActivationResult, RemoteWorkspaceActivationError> {
        guard let manager else { return .failure(.workspaceNotFound) }
        guard let workspace = manager.workspace(withID: workspaceID) else {
            return .failure(.workspaceNotFound)
        }

        let existingWindow = WindowStatesManager.shared.findWindowState(showing: workspaceID)
        let result = await manager.switchWorkspace(to: workspace, saveState: true, reason: "remote")
        guard result.didSwitch || manager.activeWorkspaceID == workspaceID else {
            return .failure(.activationBlocked(result.message ?? "Workspace activation was blocked."))
        }

        return .success(
            RemoteWorkspaceActivationResult(
                workspaceID: workspaceID,
                composeTabID: workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
                windowID: existingWindow?.windowID,
                reusedExistingWindow: existingWindow != nil
            )
        )
    }
}

@MainActor
final class AgentModeRemoteSessionQueryService: SessionQueryService {
    private let contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)]

    init(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel) {
        contexts = [(agentMode, workspaceManager)]
    }

    init(contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)]) {
        self.contexts = contexts
    }

    func remoteSessions() async -> [RemoteSessionRecord] {
        var records: [UUID: RemoteSessionRecord] = [:]
        for context in contexts {
            let workspaceID = context.agentMode.sessionIndexOwner?.workspaceID
                ?? context.workspaceManager.activeWorkspaceID
            guard let workspaceID else { continue }
            let liveByTabID = context.agentMode.sessions
            for entry in context.agentMode.sessionIndex.values {
                let live = liveByTabID[entry.tabID]
                let runState = live.map { Self.mapRunState($0.runState) }
                    ?? Self.mapPersistedRunState(entry.lastRunStateRaw)
                let record = RemoteSessionRecord(
                    sessionID: entry.id,
                    workspaceID: workspaceID,
                    composeTabID: entry.tabID,
                    parentSessionID: entry.parentSessionID,
                    sessionName: entry.name,
                    workflow: nil,
                    agent: entry.agentKindRaw,
                    model: entry.agentModelRaw,
                    reasoningEffort: entry.agentReasoningEffortRaw,
                    runState: runState,
                    lifecycleStage: live?.runState.rawValue,
                    latestMeaningfulActivity: live?.runningStatusText ?? live?.waitingPrompt,
                    pendingInteraction: Self.pendingInteraction(for: live),
                    worktreeSummary: entry.worktreeBindingSummaries.isEmpty ? nil : "Worktree configured",
                    mergeAttention: entry.activeWorktreeMergeSummaries.isEmpty ? nil : "Merge review available",
                    failureSummary: runState == .failed ? "Agent run failed" : nil,
                    lastUpdatedAt: max(entry.savedAt, live?.activeAgentRunStartedAt ?? .distantPast),
                    isLive: live != nil
                )
                if let existing = records[record.sessionID], existing.lastUpdatedAt >= record.lastUpdatedAt {
                    continue
                }
                records[record.sessionID] = record
            }
        }
        return Array(records.values)
    }

    private static func mapRunState(_ state: AgentSessionRunState) -> RemoteRunState {
        switch state {
        case .idle: .idle
        case .running: .working
        case .waitingForUser, .waitingForQuestion, .waitingForApproval: .waitingForInput
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    private static func mapPersistedRunState(_ rawValue: String?) -> RemoteRunState {
        switch rawValue {
        case AgentSessionRunState.running.rawValue: .working
        case AgentSessionRunState.waitingForUser.rawValue,
             AgentSessionRunState.waitingForQuestion.rawValue,
             AgentSessionRunState.waitingForApproval.rawValue: .waitingForInput
        case AgentSessionRunState.completed.rawValue: .completed
        case AgentSessionRunState.cancelled.rawValue: .cancelled
        case AgentSessionRunState.failed.rawValue: .failed
        default: .idle
        }
    }

    private static func pendingInteraction(for session: AgentModeViewModel.TabSession?) -> RemoteInteractionSummary? {
        guard let session else { return nil }
        if let pending = session.pendingAskUser {
            return RemoteInteractionSummary(
                id: pending.id.uuidString,
                kind: .question,
                title: pending.interaction.title,
                prompt: pending.currentQuestion?.question,
                createdAt: pending.interaction.askedAt
            )
        }
        if let pending = session.pendingUserInputRequest,
           let question = pending.questions.first
        {
            return RemoteInteractionSummary(
                id: pending.id.uuidString,
                kind: question.isSecret ? .secretInput : .question,
                title: question.header,
                prompt: question.question,
                requiresSecureEntry: question.isSecret,
                createdAt: pending.askedAt
            )
        }
        if let pending = session.pendingMCPElicitationRequest {
            return RemoteInteractionSummary(
                id: pending.id.uuidString,
                kind: .question,
                title: pending.title,
                prompt: pending.prompt ?? pending.message,
                createdAt: Date()
            )
        }
        if session.pendingApproval != nil {
            return RemoteInteractionSummary(
                id: session.pendingApproval?.id.uuidString ?? "",
                kind: .approval,
                title: "Approval required",
                prompt: "Review this request in RepoPrompt.",
                createdAt: session.activeAgentRunStartedAt ?? Date()
            )
        }
        return nil
    }
}

@MainActor
final class StaticRemoteCatalogService: WorkflowCatalogService {
    var catalog: RemoteCatalogRecord

    init(catalog: RemoteCatalogRecord = .empty) {
        self.catalog = catalog
    }

    func remoteCatalog() async -> RemoteCatalogRecord { catalog }
}

/// Projects the desktop's live workflow and provider stores into the compact
/// catalog used by mobile. The catalog contains identifiers and display
/// metadata only; templates, credentials, and provider configuration remain
/// on the Mac.
@MainActor
final class DesktopRemoteCatalogService: WorkflowCatalogService {
    func remoteCatalog() async -> RemoteCatalogRecord {
        let workflows = AgentWorkflowStore.shared.allWorkflows.map {
            RemoteWorkflowDescriptor(
                id: $0.id,
                displayName: $0.displayName,
                isBuiltIn: $0.isBuiltIn,
                requiredAuthority: .control
            )
        }

        let availability = AgentModelCatalog.AvailabilityContext.current
        let agents = AgentModelCatalog
            .selectableAgents(availability: availability)
            .map { agent in
                RemoteAgentDescriptor(
                    id: agent.rawValue,
                    displayName: agent.displayName,
                    models: AgentModelCatalog
                        .options(for: agent, availability: availability)
                        .map(\.rawValue),
                    isAvailable: true
                )
            }

        return RemoteCatalogRecord(workflows: workflows, agents: agents)
    }
}

@MainActor
final class AppRemoteStateProjectionService: RemoteStateProjectionService {
    private let builder: RemoteSnapshotBuilder
    private let desktop: RemoteDesktopSummary
    private let connection: RemoteConnectionSummary
    private let authorization: RemoteAuthorizationState

    init(
        builder: RemoteSnapshotBuilder,
        desktop: RemoteDesktopSummary,
        connection: RemoteConnectionSummary = .init(state: .connected),
        authorization: RemoteAuthorizationState = .init()
    ) {
        self.builder = builder
        self.desktop = desktop
        self.connection = connection
        self.authorization = authorization
    }

    func snapshot() async -> RemoteSnapshot {
        await builder.build(
            desktop: desktop,
            connection: connection,
            authorization: authorization
        )
    }
}
