import Foundation

/// Browser-safe project projection for the standalone portal.
public struct PortalProjectSummary: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let name: String
    public let state: ProjectLifecycleState
    public let rootNames: [String]

    public init(projectID: UUID, name: String, state: ProjectLifecycleState, rootNames: [String]) {
        self.projectID = projectID
        self.name = name
        self.state = state
        self.rootNames = rootNames
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case name, state, rootNames
    }
}

/// Compact session projection used by the project/session sidebar.
public struct PortalSessionSummary: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let title: String
    public let provider: ProviderKind
    public let model: String?
    public let state: SessionLifecycleState
    public let revision: Int64
    public let runGeneration: Int64
    public let lastActivityAt: Date?

    public init(
        sessionID: UUID,
        projectID: UUID,
        parentSessionID: UUID?,
        title: String,
        provider: ProviderKind,
        model: String?,
        state: SessionLifecycleState,
        revision: Int64,
        runGeneration: Int64,
        lastActivityAt: Date?
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.title = title
        self.provider = provider
        self.model = model
        self.state = state
        self.revision = revision
        self.runGeneration = runGeneration
        self.lastActivityAt = lastActivityAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case title, provider, model, state, revision, runGeneration, lastActivityAt
    }
}

public struct PortalWorkflowSummary: Codable, Hashable, Sendable {
    public let workflowID: String
    public let name: String
    public let enabled: Bool

    public init(workflowID: String, name: String, enabled: Bool) {
        self.workflowID = workflowID
        self.name = name
        self.enabled = enabled
    }
}

public struct PortalBootstrapResponse: Codable, Sendable {
    public let projects: [PortalProjectSummary]
    public let sessions: [PortalSessionSummary]
    public let workflows: [PortalWorkflowSummary]

    public init(projects: [PortalProjectSummary], sessions: [PortalSessionSummary], workflows: [PortalWorkflowSummary]) {
        self.projects = projects
        self.sessions = sessions
        self.workflows = workflows
    }
}

/// Sanitized transcript row. Rich desktop presentation payloads and actor
/// records deliberately remain server-side.
public struct PortalTranscriptEntry: Codable, Hashable, Sendable {
    public let entryID: UUID
    public let sessionSequence: Int64
    public let kind: TranscriptEntry.Kind
    public let content: String
    public let timestamp: Date
    public let truncated: Bool

    public init(entryID: UUID, sessionSequence: Int64, kind: TranscriptEntry.Kind, content: String, timestamp: Date, truncated: Bool) {
        self.entryID = entryID
        self.sessionSequence = sessionSequence
        self.kind = kind
        self.content = content
        self.timestamp = timestamp
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case entryID = "entryId"
        case sessionSequence, kind, content, timestamp, truncated
    }
}

public struct PortalTranscriptPage: Codable, Sendable {
    public let session: PortalSessionSummary
    public let items: [PortalTranscriptEntry]
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool
    public let earliestSequence: Int64?
    public let latestSequence: Int64?

    public init(
        session: PortalSessionSummary,
        items: [PortalTranscriptEntry],
        hasMoreBefore: Bool,
        hasMoreAfter: Bool,
        earliestSequence: Int64?,
        latestSequence: Int64?
    ) {
        self.session = session
        self.items = items
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.earliestSequence = earliestSequence
        self.latestSequence = latestSequence
    }
}

public struct PortalCreateSessionRequest: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let projectID: UUID
    public let providerID: ProviderSettingsID
    public let model: String?
    public let initialPrompt: String

    public init(operationID: UUID, projectID: UUID, providerID: ProviderSettingsID, model: String?, initialPrompt: String) {
        self.operationID = operationID
        self.projectID = projectID
        self.providerID = providerID
        self.model = model
        self.initialPrompt = initialPrompt
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case projectID = "projectId"
        case providerID = "providerId"
        case model, initialPrompt
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
