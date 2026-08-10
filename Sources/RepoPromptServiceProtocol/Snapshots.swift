import Foundation

public struct ProjectRootSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalName: String
    public let canonicalPath: String
    public let writable: Bool
    public let revision: Int64

    public init(rootID: UUID, logicalName: String, canonicalPath: String, writable: Bool, revision: Int64 = 1) {
        self.rootID = rootID
        self.logicalName = logicalName
        self.canonicalPath = canonicalPath
        self.writable = writable
        self.revision = revision
    }
}

public struct ProjectSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let name: String
    public let creator: ExternalActor
    public let state: ProjectLifecycleState
    public let roots: [ProjectRootSnapshot]
    public let revision: Int64
    public let cursor: ServiceCursor

    public init(projectID: UUID, name: String, creator: ExternalActor, state: ProjectLifecycleState, roots: [ProjectRootSnapshot], revision: Int64, cursor: ServiceCursor) {
        schemaVersion = 1
        self.projectID = projectID
        self.name = name
        self.creator = creator
        self.state = state
        self.roots = roots
        self.revision = revision
        self.cursor = cursor
    }
}

public struct InteractionSnapshot: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case question, approval }
    public enum State: String, Codable, Sendable { case pending, deliveryIntent, resolved, expired, interrupted }
    public let interactionID: UUID
    public let runID: UUID?
    public let agentID: UUID?
    public let kind: Kind
    public let state: State
    public let payload: Data
    public let revision: Int64
    public let expiresAt: Date?

    public init(interactionID: UUID, runID: UUID? = nil, agentID: UUID? = nil, kind: Kind, state: State, payload: Data, revision: Int64, expiresAt: Date?) {
        self.interactionID = interactionID
        self.runID = runID
        self.agentID = agentID
        self.kind = kind
        self.state = state
        self.payload = payload
        self.revision = revision
        self.expiresAt = expiresAt
    }
}

public struct TranscriptEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case human, assistant, system, reasoning, progress, tool }
    public let entryID: UUID
    public let sessionSequence: Int64
    public let kind: Kind
    public let content: String
    public let actor: ExternalActor?
    public let timestamp: Date

    public init(entryID: UUID, sessionSequence: Int64, kind: Kind, content: String, actor: ExternalActor?, timestamp: Date) {
        self.entryID = entryID
        self.sessionSequence = sessionSequence
        self.kind = kind
        self.content = content
        self.actor = actor
        self.timestamp = timestamp
    }
}

public struct AgentSnapshot: Codable, Hashable, Sendable {
    public let agentID: UUID
    public let sessionID: UUID
    public let rootSessionID: UUID
    public let parentAgentID: UUID?
    public let providerNativeIdentity: String?
    public let role: String
    public let label: String?
    public let state: SessionLifecycleState
    public let revision: Int64

    public init(agentID: UUID, sessionID: UUID, rootSessionID: UUID, parentAgentID: UUID?, providerNativeIdentity: String? = nil, role: String, label: String? = nil, state: SessionLifecycleState, revision: Int64) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.rootSessionID = rootSessionID
        self.parentAgentID = parentAgentID
        self.providerNativeIdentity = providerNativeIdentity
        self.role = role
        self.label = label
        self.state = state
        self.revision = revision
    }
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let rootSessionID: UUID
    public let creator: ExternalActor
    public let provider: ProviderKind
    public let model: String?
    public let visibility: Visibility
    public let state: SessionLifecycleState
    public let runGeneration: Int64
    public let turnEpoch: Int64
    public let revision: Int64
    public let transcript: [TranscriptEntry]
    public let interactions: [InteractionSnapshot]
    public let cursor: ServiceCursor

    public init(sessionID: UUID, projectID: UUID, parentSessionID: UUID?, rootSessionID: UUID, creator: ExternalActor, provider: ProviderKind, model: String?, visibility: Visibility, state: SessionLifecycleState, runGeneration: Int64, turnEpoch: Int64, revision: Int64, transcript: [TranscriptEntry], interactions: [InteractionSnapshot], cursor: ServiceCursor) {
        schemaVersion = 1
        self.sessionID = sessionID
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.rootSessionID = rootSessionID
        self.creator = creator
        self.provider = provider
        self.model = model
        self.visibility = visibility
        self.state = state
        self.runGeneration = runGeneration
        self.turnEpoch = turnEpoch
        self.revision = revision
        self.transcript = transcript
        self.interactions = interactions
        self.cursor = cursor
    }
}

public struct AuthoritativeSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let storeID: UUID
    public let projects: [ProjectSnapshot]
    public let sessions: [SessionSnapshot]
    public let cursor: ServiceCursor

    public init(storeID: UUID, projects: [ProjectSnapshot], sessions: [SessionSnapshot], cursor: ServiceCursor) {
        schemaVersion = 1
        self.storeID = storeID
        self.projects = projects
        self.sessions = sessions
        self.cursor = cursor
    }
}
