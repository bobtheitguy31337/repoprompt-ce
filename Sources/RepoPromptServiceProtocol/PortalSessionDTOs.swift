import Foundation

/// Browser-safe project projection for the standalone portal.
public struct PortalProjectSummary: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let name: String
    public let state: ProjectLifecycleState
    public let rootNames: [String]
    public let revision: Int64

    public init(projectID: UUID, name: String, state: ProjectLifecycleState, rootNames: [String], revision: Int64) {
        self.projectID = projectID
        self.name = name
        self.state = state
        self.rootNames = rootNames
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case name, state, rootNames, revision
    }
}

public struct PortalCreateProjectRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let name: String
    public let logicalName: String
    public let remote: String
    public let ref: String

    public init(operationID: UUID, name: String, logicalName: String, remote: String, ref: String) {
        self.operationID = operationID
        self.name = name
        self.logicalName = logicalName
        self.remote = remote
        self.ref = ref
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case name, logicalName, remote, ref
    }
}

public struct PortalAddProjectRepositoryRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64
    public let logicalName: String
    public let remote: String
    public let ref: String

    public init(operationID: UUID, expectedRevision: Int64, logicalName: String, remote: String, ref: String) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.logicalName = logicalName
        self.remote = remote
        self.ref = ref
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision, logicalName, remote, ref
    }
}

public struct PortalRenameProjectRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64
    public let name: String

    public init(operationID: UUID, expectedRevision: Int64, name: String) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision, name
    }
}

public struct PortalRemoveProjectRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64

    public init(operationID: UUID, expectedRevision: Int64) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision
    }
}

/// Compact session projection used by the project/session sidebar.
public struct PortalSessionSummary: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let title: String
    public let provider: ProviderKind
    public let providerSettingsID: ProviderSettingsID?
    public let model: String?
    public let state: SessionLifecycleState
    public let revision: Int64
    public let runGeneration: Int64
    public let turnEpoch: Int64
    public let lastActivityAt: Date?
    public let sidebarDepth: Int
    public let runPresentation: RunPresentationWireSnapshot?
    public let agentControl: AgentSessionActionSnapshotWire?
    public let contextUsage: ContextUsageWireSnapshot?

    public init(
        sessionID: UUID,
        projectID: UUID,
        parentSessionID: UUID?,
        title: String,
        provider: ProviderKind,
        providerSettingsID: ProviderSettingsID? = nil,
        model: String?,
        state: SessionLifecycleState,
        revision: Int64,
        runGeneration: Int64,
        turnEpoch: Int64,
        lastActivityAt: Date?,
        sidebarDepth: Int = 0,
        runPresentation: RunPresentationWireSnapshot? = nil,
        agentControl: AgentSessionActionSnapshotWire? = nil,
        contextUsage: ContextUsageWireSnapshot? = nil
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.title = title
        self.provider = provider
        self.providerSettingsID = providerSettingsID
        self.model = model
        self.state = state
        self.revision = revision
        self.runGeneration = runGeneration
        self.turnEpoch = turnEpoch
        self.lastActivityAt = lastActivityAt
        self.sidebarDepth = sidebarDepth
        self.runPresentation = runPresentation
        self.agentControl = agentControl
        self.contextUsage = contextUsage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        title = try container.decode(String.self, forKey: .title)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        providerSettingsID = try container.decodeIfPresent(ProviderSettingsID.self, forKey: .providerSettingsID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        state = try container.decode(SessionLifecycleState.self, forKey: .state)
        revision = try container.decode(Int64.self, forKey: .revision)
        runGeneration = try container.decode(Int64.self, forKey: .runGeneration)
        turnEpoch = try container.decode(Int64.self, forKey: .turnEpoch)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        sidebarDepth = try container.decodeIfPresent(Int.self, forKey: .sidebarDepth) ?? 0
        runPresentation = try container.decodeIfPresent(RunPresentationWireSnapshot.self, forKey: .runPresentation)
        agentControl = try container.decodeIfPresent(AgentSessionActionSnapshotWire.self, forKey: .agentControl)
        contextUsage = try container.decodeIfPresent(ContextUsageWireSnapshot.self, forKey: .contextUsage)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case title, provider
        case providerSettingsID = "providerSettingsId"
        case model, state, revision, runGeneration, turnEpoch, lastActivityAt, sidebarDepth
        case runPresentation, agentControl, contextUsage
    }
}

public struct PortalWorkflowSummary: Codable, Hashable, Sendable {
    public let workflowID: String
    public let name: String
    public let source: ServerWorkflowSource
    public let enabled: Bool
    public let visible: Bool
    public let featuredOrder: Int?
    public let rowRevision: Int64

    public init(
        workflowID: String,
        name: String,
        source: ServerWorkflowSource = .builtin,
        enabled: Bool,
        visible: Bool = true,
        featuredOrder: Int? = nil,
        rowRevision: Int64 = 1
    ) {
        self.workflowID = workflowID
        self.name = name
        self.source = source
        self.enabled = enabled
        self.visible = visible
        self.featuredOrder = featuredOrder
        self.rowRevision = rowRevision
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID, name, source, enabled, visible, featuredOrder, rowRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try container.decode(String.self, forKey: .workflowID)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(ServerWorkflowSource.self, forKey: .source) ?? .builtin
        enabled = try container.decode(Bool.self, forKey: .enabled)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        featuredOrder = try container.decodeIfPresent(Int.self, forKey: .featuredOrder)
        rowRevision = try container.decodeIfPresent(Int64.self, forKey: .rowRevision) ?? 1
    }
}

/// Browser-safe projection of the canonical MCP tool catalog. Availability is
/// service-managed; this DTO deliberately carries no client-side enable toggle.
public struct PortalToolSummary: Codable, Hashable, Sendable {
    public let name: String
    public let scope: String
    public let capability: String
    public let admissionClass: String

    public init(name: String, scope: String, capability: String, admissionClass: String) {
        self.name = name
        self.scope = scope
        self.capability = capability
        self.admissionClass = admissionClass
    }
}

public struct PortalBootstrapResponse: Codable, Sendable {
    public let projects: [PortalProjectSummary]
    public let sessions: [PortalSessionSummary]
    public let workflows: [PortalWorkflowSummary]
    public let tools: [PortalToolSummary]
    public let workflowRepositoryRevision: Int64
    public let includeSessionCleanupGuidance: Bool
    public let projectSources: ProjectSourceCapabilities?

    public init(
        projects: [PortalProjectSummary],
        sessions: [PortalSessionSummary],
        workflows: [PortalWorkflowSummary],
        tools: [PortalToolSummary] = [],
        workflowRepositoryRevision: Int64 = 0,
        includeSessionCleanupGuidance: Bool = true,
        projectSources: ProjectSourceCapabilities? = nil
    ) {
        self.projects = projects
        self.sessions = sessions
        self.workflows = workflows
        self.tools = tools
        self.workflowRepositoryRevision = workflowRepositoryRevision
        self.includeSessionCleanupGuidance = includeSessionCleanupGuidance
        self.projectSources = projectSources
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, workflows, tools, workflowRepositoryRevision, includeSessionCleanupGuidance, projectSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([PortalProjectSummary].self, forKey: .projects)
        sessions = try container.decode([PortalSessionSummary].self, forKey: .sessions)
        workflows = try container.decode([PortalWorkflowSummary].self, forKey: .workflows)
        tools = try container.decodeIfPresent([PortalToolSummary].self, forKey: .tools) ?? []
        workflowRepositoryRevision = try container.decodeIfPresent(Int64.self, forKey: .workflowRepositoryRevision) ?? 0
        includeSessionCleanupGuidance = try container.decodeIfPresent(Bool.self, forKey: .includeSessionCleanupGuidance) ?? true
        projectSources = try container.decodeIfPresent(ProjectSourceCapabilities.self, forKey: .projectSources)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(workflows, forKey: .workflows)
        try container.encode(tools, forKey: .tools)
        try container.encode(workflowRepositoryRevision, forKey: .workflowRepositoryRevision)
        try container.encode(includeSessionCleanupGuidance, forKey: .includeSessionCleanupGuidance)
        try container.encodeIfPresent(projectSources, forKey: .projectSources)
    }
}

/// Browser envelope around the same semantic transcript presentation used by
/// first-party Agent Mode clients. The server remains authoritative for block
/// grouping, tool presentation, interactions, and terminal state.
public struct PortalSessionPresentationPage: Codable, Sendable {
    public let session: PortalSessionSummary
    public let presentation: AgentTranscriptPresentationPageWire
    public let sidebarSessions: [PortalSessionSummary]

    public init(
        session: PortalSessionSummary,
        presentation: AgentTranscriptPresentationPageWire,
        sidebarSessions: [PortalSessionSummary] = []
    ) {
        self.session = session
        self.presentation = presentation
        self.sidebarSessions = sidebarSessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(PortalSessionSummary.self, forKey: .session)
        presentation = try container.decode(AgentTranscriptPresentationPageWire.self, forKey: .presentation)
        sidebarSessions = try container.decodeIfPresent([PortalSessionSummary].self, forKey: .sidebarSessions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(session, forKey: .session)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(sidebarSessions, forKey: .sidebarSessions)
    }

    private enum CodingKeys: String, CodingKey {
        case session, presentation, sidebarSessions
    }
}

public struct PortalCreateSessionRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let projectID: UUID
    public let providerID: ProviderSettingsID?
    public let routingTarget: AgentRoutingTarget?
    public let model: String?
    public let initialPrompt: String

    public init(
        operationID: UUID,
        projectID: UUID,
        providerID: ProviderSettingsID? = nil,
        routingTarget: AgentRoutingTarget? = nil,
        model: String?,
        initialPrompt: String
    ) {
        self.operationID = operationID
        self.projectID = projectID
        self.providerID = providerID
        self.routingTarget = routingTarget
        self.model = model
        self.initialPrompt = initialPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case projectID = "projectId"
        case providerID = "providerId"
        case routingTarget, model, initialPrompt
    }
}

public struct PortalSendMessageRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64
    public let text: String

    public init(operationID: UUID, expectedRevision: Int64, text: String) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision, text
    }
}

/// Browser-authenticated wrapper for the same structured Agent Mode session
/// start contract used by first-party clients.
public struct PortalStartAgentSessionRequest: Codable, Sendable {
    public let operationID: UUID
    public let start: AgentStartSessionWire

    public init(operationID: UUID, start: AgentStartSessionWire) {
        self.operationID = operationID
        self.start = start
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case start
    }
}

/// Browser-authenticated wrapper for a structured Agent Mode follow-up.
public struct PortalSubmitAgentTurnRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let turn: AgentTurnSubmissionWire

    public init(operationID: UUID, turn: AgentTurnSubmissionWire) {
        self.operationID = operationID
        self.turn = turn
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case turn
    }
}

/// Portal projection of a durable structured submission receipt. The session
/// summary is included for new-session acceptance so the browser can switch
/// destinations without inventing a local session shape.
public struct PortalAgentSubmissionReceipt: Codable, Hashable, Sendable {
    public let submissionID: UUID
    public let operation: String
    public let acceptedAt: Date
    public let sessionID: UUID
    public let sessionRevision: Int64
    public let requestAnchorID: UUID
    public let runID: UUID?
    public let generation: Int64?
    public let turnEpoch: Int64?
    public let runPhase: String?
    public let selectedConfiguration: AgentTurnConfigurationWire
    public let session: PortalSessionSummary?

    public init(_ receipt: SubmissionReceipt, session: PortalSessionSummary? = nil) {
        submissionID = receipt.submissionID
        operation = receipt.operation
        acceptedAt = receipt.acceptedAt
        sessionID = receipt.sessionID
        sessionRevision = receipt.sessionRevision
        requestAnchorID = receipt.requestAnchorID
        runID = receipt.runID
        generation = receipt.generation
        turnEpoch = receipt.turnEpoch
        runPhase = receipt.runPhase
        selectedConfiguration = receipt.selectedConfiguration
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case submissionID = "submissionId"
        case operation, acceptedAt
        case sessionID = "sessionId"
        case sessionRevision
        case requestAnchorID = "requestAnchorId"
        case runID = "runId"
        case generation, turnEpoch, runPhase, selectedConfiguration, session
    }
}

public struct PortalInteractionAnswerRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64
    public let response: AgentPresentationInteractionResponseWire

    public init(
        operationID: UUID,
        expectedRevision: Int64,
        response: AgentPresentationInteractionResponseWire
    ) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
        self.response = response
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision, response
    }
}

public struct PortalSessionActionRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let expectedRevision: Int64?

    public init(operationID: UUID, expectedRevision: Int64? = nil) {
        self.operationID = operationID
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case expectedRevision
    }
}
