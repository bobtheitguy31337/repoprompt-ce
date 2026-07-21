import Foundation

/// The version of the RepoPrompt-specific mobile remote protocol.
///
/// This is intentionally separate from the MCP protocol version. A remote client
/// is a first-class RepoPrompt control surface, not a generic MCP client.
public enum RemoteProtocol {
    public static let currentVersion = 1
    public static let versionedPath = "/remote/v1"
}

public enum RemoteAuthorityLevel: Int, Codable, Comparable, Sendable {
    case observe = 0
    case respond = 1
    case control = 2
    case danger = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum RemoteAuthorizationScope: Codable, Hashable, Sendable {
    case device
    case session(UUID)
}

public enum RemoteElevationDuration: Codable, Sendable, Equatable {
    case once
    case session
    case limited(until: Date)
    case persistent
}

public struct RemoteAuthorityGrant: Codable, Sendable, Equatable {
    public let level: RemoteAuthorityLevel
    public let scope: RemoteAuthorizationScope
    public let duration: RemoteElevationDuration
    public let grantedAt: Date

    public init(
        level: RemoteAuthorityLevel,
        scope: RemoteAuthorizationScope = .device,
        duration: RemoteElevationDuration = .once,
        grantedAt: Date = Date()
    ) {
        self.level = level
        self.scope = scope
        self.duration = duration
        self.grantedAt = grantedAt
    }

    public func isActive(at date: Date) -> Bool {
        switch duration {
        case .once, .session, .persistent:
            return true
        case let .limited(until):
            return date < until
        }
    }
}

public struct RemoteAuthorizationState: Codable, Sendable, Equatable {
    public let defaultLevel: RemoteAuthorityLevel
    public let activeGrant: RemoteAuthorityGrant?
    public let dangerModeEnabled: Bool

    public init(
        defaultLevel: RemoteAuthorityLevel = .observe,
        activeGrant: RemoteAuthorityGrant? = nil,
        dangerModeEnabled: Bool = false
    ) {
        self.defaultLevel = defaultLevel
        self.activeGrant = activeGrant
        self.dangerModeEnabled = dangerModeEnabled
    }

    public func effectiveLevel(
        for sessionID: UUID? = nil,
        at date: Date = Date()
    ) -> RemoteAuthorityLevel {
        guard let activeGrant,
              activeGrant.isActive(at: date),
              grantApplies(activeGrant, to: sessionID)
        else {
            return defaultLevel
        }
        return max(defaultLevel, activeGrant.level)
    }

    public func allows(
        _ requiredLevel: RemoteAuthorityLevel,
        for sessionID: UUID? = nil,
        at date: Date = Date()
    ) -> Bool {
        effectiveLevel(for: sessionID, at: date) >= requiredLevel
    }

    private func grantApplies(_ grant: RemoteAuthorityGrant, to sessionID: UUID?) -> Bool {
        switch grant.scope {
        case .device:
            true
        case let .session(grantedSessionID):
            grantedSessionID == sessionID
        }
    }
}

public enum RemoteRunState: String, Codable, Sendable {
    case idle
    case opening
    case working
    case waitingForInput = "waiting_for_input"
    case blocked
    case completed
    case failed
    case cancelled
}

public enum RemoteAttentionKind: String, Codable, Sendable {
    case agentNeedsInput = "agent_needs_input"
    case approvalRequired = "approval_required"
    case completed
    case failed
}

public enum RemoteInteractionKind: String, Codable, Sendable {
    case question
    case approval
    case secretInput = "secret_input"
}

/// A pending interaction deliberately contains no answer value. Secret answers are
/// submitted as one-shot commands and are never part of snapshots, history, or events.
public struct RemoteInteractionSummary: Codable, Sendable, Equatable {
    public let id: String
    public let kind: RemoteInteractionKind
    public let title: String?
    public let prompt: String?
    public let requiresSecureEntry: Bool
    public let createdAt: Date

    public init(
        id: String,
        kind: RemoteInteractionKind,
        title: String? = nil,
        prompt: String? = nil,
        requiresSecureEntry: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.requiresSecureEntry = requiresSecureEntry
        self.createdAt = createdAt
    }
}

public struct RemoteDesktopSummary: Codable, Sendable, Equatable {
    public let instanceID: String
    public let displayName: String
    public let appVersion: String
    public let isAvailable: Bool
    public let lastSeenAt: Date?

    public init(
        instanceID: String,
        displayName: String,
        appVersion: String,
        isAvailable: Bool,
        lastSeenAt: Date? = nil
    ) {
        self.instanceID = instanceID
        self.displayName = displayName
        self.appVersion = appVersion
        self.isAvailable = isAvailable
        self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteConnectionSummary: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case disconnected
        case discovering
        case connecting
        case connected
        case reconnecting
    }

    public let state: State
    public let transport: String
    public let lastConnectedAt: Date?

    public init(state: State, transport: String = "lan_https", lastConnectedAt: Date? = nil) {
        self.state = state
        self.transport = transport
        self.lastConnectedAt = lastConnectedAt
    }
}

public struct RemoteWorkspaceSummary: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let name: String
    public let repositoryRootSummary: String?
    public let isOpen: Bool
    public let activeSessionIDs: [UUID]
    public let lastActivityAt: Date?

    public init(
        workspaceID: String,
        name: String,
        repositoryRootSummary: String? = nil,
        isOpen: Bool,
        activeSessionIDs: [UUID] = [],
        lastActivityAt: Date? = nil
    ) {
        self.workspaceID = workspaceID
        self.name = name
        self.repositoryRootSummary = repositoryRootSummary
        self.isOpen = isOpen
        self.activeSessionIDs = activeSessionIDs
        self.lastActivityAt = lastActivityAt
    }
}

public struct RemoteSessionSummary: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let workspaceID: String
    public let composeTabID: UUID?
    public let parentSessionID: UUID?
    public let sessionName: String?
    public let workflow: String?
    public let agent: String?
    public let model: String?
    public let reasoningEffort: String?
    public let runState: RemoteRunState
    public let lifecycleStage: String?
    public let latestMeaningfulActivity: String?
    public let pendingInteraction: RemoteInteractionSummary?
    public let childSessionIDs: [UUID]
    public let worktreeSummary: String?
    public let mergeAttention: String?
    public let failureSummary: String?
    public let lastUpdatedAt: Date
    public let isLive: Bool

    public init(
        sessionID: UUID,
        workspaceID: String,
        composeTabID: UUID? = nil,
        parentSessionID: UUID? = nil,
        sessionName: String? = nil,
        workflow: String? = nil,
        agent: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        runState: RemoteRunState,
        lifecycleStage: String? = nil,
        latestMeaningfulActivity: String? = nil,
        pendingInteraction: RemoteInteractionSummary? = nil,
        childSessionIDs: [UUID] = [],
        worktreeSummary: String? = nil,
        mergeAttention: String? = nil,
        failureSummary: String? = nil,
        lastUpdatedAt: Date = Date(),
        isLive: Bool
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.composeTabID = composeTabID
        self.parentSessionID = parentSessionID
        self.sessionName = sessionName
        self.workflow = workflow
        self.agent = agent
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.runState = runState
        self.lifecycleStage = lifecycleStage
        self.latestMeaningfulActivity = latestMeaningfulActivity
        self.pendingInteraction = pendingInteraction
        self.childSessionIDs = childSessionIDs
        self.worktreeSummary = worktreeSummary
        self.mergeAttention = mergeAttention
        self.failureSummary = failureSummary
        self.lastUpdatedAt = lastUpdatedAt
        self.isLive = isLive
    }
}

public struct RemoteAttentionItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: RemoteAttentionKind
    public let sessionID: UUID
    public let title: String
    public let sanitizedPreview: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: RemoteAttentionKind,
        sessionID: UUID,
        title: String,
        sanitizedPreview: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.title = title
        self.sanitizedPreview = sanitizedPreview
        self.createdAt = createdAt
    }
}

public struct RemoteWorkflowDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let isBuiltIn: Bool
    public let requiredAuthority: RemoteAuthorityLevel

    public init(
        id: String,
        displayName: String,
        isBuiltIn: Bool,
        requiredAuthority: RemoteAuthorityLevel = .control
    ) {
        self.id = id
        self.displayName = displayName
        self.isBuiltIn = isBuiltIn
        self.requiredAuthority = requiredAuthority
    }
}

public struct RemoteAgentDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let models: [String]
    public let isAvailable: Bool

    public init(id: String, displayName: String, models: [String] = [], isAvailable: Bool) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.isAvailable = isAvailable
    }
}

public struct RemoteSnapshot: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let desktop: RemoteDesktopSummary
    public let connection: RemoteConnectionSummary
    public let authorization: RemoteAuthorizationState
    public let workspaces: [RemoteWorkspaceSummary]
    public let sessions: [RemoteSessionSummary]
    public let attentionItems: [RemoteAttentionItem]
    public let workflowCatalog: [RemoteWorkflowDescriptor]
    public let agentCatalog: [RemoteAgentDescriptor]
    public let eventCursor: UInt64

    public init(
        protocolVersion: Int = RemoteProtocol.currentVersion,
        desktop: RemoteDesktopSummary,
        connection: RemoteConnectionSummary,
        authorization: RemoteAuthorizationState,
        workspaces: [RemoteWorkspaceSummary] = [],
        sessions: [RemoteSessionSummary] = [],
        attentionItems: [RemoteAttentionItem] = [],
        workflowCatalog: [RemoteWorkflowDescriptor] = [],
        agentCatalog: [RemoteAgentDescriptor] = [],
        eventCursor: UInt64 = 0
    ) {
        self.protocolVersion = protocolVersion
        self.desktop = desktop
        self.connection = connection
        self.authorization = authorization
        self.workspaces = workspaces
        self.sessions = sessions
        self.attentionItems = attentionItems
        self.workflowCatalog = workflowCatalog
        self.agentCatalog = agentCatalog
        self.eventCursor = eventCursor
    }
}

public enum RemoteEventType: String, Codable, Sendable {
    case workspaceOpening = "workspace_opening"
    case workspaceReady = "workspace_ready"
    case sessionCreated = "session_created"
    case sessionUpdated = "session_updated"
    case runStarted = "run_started"
    case runProgressed = "run_progressed"
    case runWaitingForInput = "run_waiting_for_input"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runCancelled = "run_cancelled"
    case transcriptItemsAppended = "transcript_items_appended"
    case interactionCreated = "interaction_created"
    case interactionResolved = "interaction_resolved"
    case childSessionCreated = "child_session_created"
    case catalogChanged = "catalog_changed"
    case authorizationChanged = "authorization_changed"
}

public enum RemoteEventPayload: Codable, Sendable, Equatable {
    case empty
    case session(RemoteSessionSummary)
    case attention(RemoteAttentionItem)
    case authorization(RemoteAuthorizationState)
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case session
        case attention
        case authorization
        case text
    }

    private enum Kind: String, Codable {
        case empty
        case session
        case attention
        case authorization
        case text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try container.encode(Kind.empty, forKey: .kind)
        case let .session(value):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(value, forKey: .session)
        case let .attention(value):
            try container.encode(Kind.attention, forKey: .kind)
            try container.encode(value, forKey: .attention)
        case let .authorization(value):
            try container.encode(Kind.authorization, forKey: .kind)
            try container.encode(value, forKey: .authorization)
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .empty:
            self = .empty
        case .session:
            self = .session(try container.decode(RemoteSessionSummary.self, forKey: .session))
        case .attention:
            self = .attention(try container.decode(RemoteAttentionItem.self, forKey: .attention))
        case .authorization:
            self = .authorization(try container.decode(RemoteAuthorizationState.self, forKey: .authorization))
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }
}

public struct RemoteEvent: Codable, Sendable, Equatable {
    public let desktopInstanceID: String
    public let sequence: UInt64
    public let eventID: UUID
    public let timestamp: Date
    public let type: RemoteEventType
    public let payloadVersion: Int
    public let workspaceID: String?
    public let sessionID: UUID?
    public let payload: RemoteEventPayload

    public init(
        desktopInstanceID: String,
        sequence: UInt64 = 0,
        eventID: UUID = UUID(),
        timestamp: Date = Date(),
        type: RemoteEventType,
        payloadVersion: Int = 1,
        workspaceID: String? = nil,
        sessionID: UUID? = nil,
        payload: RemoteEventPayload = .empty
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.sequence = sequence
        self.eventID = eventID
        self.timestamp = timestamp
        self.type = type
        self.payloadVersion = payloadVersion
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.payload = payload
    }

    public func assigning(sequence: UInt64) -> Self {
        Self(
            desktopInstanceID: desktopInstanceID,
            sequence: sequence,
            eventID: eventID,
            timestamp: timestamp,
            type: type,
            payloadVersion: payloadVersion,
            workspaceID: workspaceID,
            sessionID: sessionID,
            payload: payload
        )
    }
}
