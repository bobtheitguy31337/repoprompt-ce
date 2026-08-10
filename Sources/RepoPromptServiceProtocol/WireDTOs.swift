import Foundation

public struct Page<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let nextPageToken: String?
    public let cursor: ServiceCursor

    public init(items: [Item], nextPageToken: String?, cursor: ServiceCursor) {
        self.items = items
        self.nextPageToken = nextPageToken
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case items, nextPageToken, cursor
    }
}

public struct ProjectRootWireSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalName: String
    public let writable: Bool
    public let revision: Int64

    public init(_ value: ProjectRootSnapshot) {
        rootID = value.rootID
        logicalName = value.logicalName
        writable = value.writable
        revision = value.revision
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalName, writable, revision
    }
}

public struct ProjectWireSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let name: String
    public let creator: ExternalActor
    public let state: ProjectLifecycleState
    public let roots: [ProjectRootWireSnapshot]
    public let revision: Int64
    public let cursor: ServiceCursor

    public init(_ value: ProjectSnapshot) {
        schemaVersion = value.schemaVersion
        projectID = value.projectID
        name = value.name
        creator = value.creator
        state = value.state
        roots = value.roots.map(ProjectRootWireSnapshot.init)
        revision = value.revision
        cursor = value.cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID = "projectId"
        case name, creator, state, roots, revision, cursor
    }
}

public struct WorktreeWireSnapshot: Codable, Hashable, Sendable {
    public let bindingID: UUID
    public let projectID: UUID
    public let rootID: UUID
    public let sessionID: UUID?
    public let baseRef: String
    public let branch: String
    public let ownershipState: WorktreeBindingSnapshot.OwnershipState
    public let mergeState: WorktreeBindingSnapshot.MergeState
    public let revision: Int64

    public init(_ value: WorktreeBindingSnapshot) {
        bindingID = value.bindingID
        projectID = value.projectID
        rootID = value.rootID
        sessionID = value.sessionID
        baseRef = value.baseRef
        branch = value.branch
        ownershipState = value.ownershipState
        mergeState = value.mergeState
        revision = value.revision
    }

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case projectID = "projectId"
        case rootID = "rootId"
        case sessionID = "sessionId"
        case baseRef, branch, ownershipState, mergeState, revision
    }
}

public struct AuthoritativeWireSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let storeID: UUID
    public let projects: [ProjectWireSnapshot]
    public let sessions: [SessionSnapshot]
    public let cursor: ServiceCursor

    public init(_ value: AuthoritativeSnapshot) {
        schemaVersion = value.schemaVersion
        storeID = value.storeID
        projects = value.projects.map(ProjectWireSnapshot.init)
        sessions = value.sessions
        cursor = value.cursor
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeID = "storeId"
        case projects, sessions, cursor
    }
}

public struct ProtocolVersionRange: Codable, Hashable, Sendable {
    public let minimum: Int
    public let maximum: Int
    public init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey { case minimum, maximum }
}

public struct ProviderCatalogItem: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let enabled: Bool
    public let version: String?
    public let protocolVersion: String?
    public let supportsResume: Bool
    public let supportsSteering: Bool
    public let reasonUnavailable: String?

    public init(kind: ProviderKind, enabled: Bool, version: String?, protocolVersion: String?, supportsResume: Bool, supportsSteering: Bool, reasonUnavailable: String?) {
        self.kind = kind
        self.enabled = enabled
        self.version = version
        self.protocolVersion = protocolVersion
        self.supportsResume = supportsResume
        self.supportsSteering = supportsSteering
        self.reasonUnavailable = reasonUnavailable
    }

    private enum CodingKeys: String, CodingKey {
        case kind, enabled, version, protocolVersion, supportsResume, supportsSteering, reasonUnavailable
    }
}

public struct ModelCatalogItem: Codable, Hashable, Sendable {
    public let id: String
    public let provider: ProviderKind
    public let displayName: String
    public let enabled: Bool

    public init(id: String, provider: ProviderKind, displayName: String, enabled: Bool) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, provider, displayName, enabled }
}

public struct ExecutionModeCatalogItem: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let allowsWorkspaceWrites: Bool
    public let allowsUnrestrictedHostAccess: Bool
    public let providers: [ProviderKind]

    public init(id: String, displayName: String, allowsWorkspaceWrites: Bool, allowsUnrestrictedHostAccess: Bool, providers: [ProviderKind]) {
        self.id = id
        self.displayName = displayName
        self.allowsWorkspaceWrites = allowsWorkspaceWrites
        self.allowsUnrestrictedHostAccess = allowsUnrestrictedHostAccess
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, allowsWorkspaceWrites, allowsUnrestrictedHostAccess, providers
    }
}

public struct ServiceCapabilitiesResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let protocolRange: ProtocolVersionRange
    public let schemaVersion: Int
    public let storeID: UUID
    public let replayFloor: Int64
    public let providers: [ProviderCatalogItem]
    public let models: [ModelCatalogItem]
    public let workflows: [WorkflowSnapshot]
    public let executionModes: [ExecutionModeCatalogItem]
    public let eventTypes: [EventType]

    public init(protocolVersion: Int = 1, protocolRange: ProtocolVersionRange, schemaVersion: Int, storeID: UUID, replayFloor: Int64, providers: [ProviderCatalogItem], models: [ModelCatalogItem], workflows: [WorkflowSnapshot], executionModes: [ExecutionModeCatalogItem], eventTypes: [EventType]) {
        self.protocolVersion = protocolVersion
        self.protocolRange = protocolRange
        self.schemaVersion = schemaVersion
        self.storeID = storeID
        self.replayFloor = replayFloor
        self.providers = providers
        self.models = models
        self.workflows = workflows
        self.executionModes = executionModes
        self.eventTypes = eventTypes
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case protocolRange = "protocol"
        case schemaVersion
        case storeID = "storeId"
        case replayFloor, providers, models, workflows, executionModes, eventTypes
    }
}
