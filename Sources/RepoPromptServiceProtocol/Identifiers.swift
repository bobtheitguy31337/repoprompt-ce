import Foundation

public struct ServiceCursor: Codable, Hashable, Sendable, Comparable {
    public let storeID: UUID
    public let globalSequence: Int64

    public init(storeID: UUID, globalSequence: Int64) {
        self.storeID = storeID
        self.globalSequence = globalSequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        precondition(lhs.storeID == rhs.storeID, "cursors from different stores are not comparable")
        return lhs.globalSequence < rhs.globalSequence
    }
}

public struct ExternalActor: Codable, Hashable, Sendable {
    public let goblinUserID: String
    public let username: String
    public let displayName: String

    public init(goblinUserID: String, username: String, displayName: String) {
        self.goblinUserID = goblinUserID
        self.username = username
        self.displayName = displayName
    }
}

public enum Visibility: String, Codable, Sendable { case privateSession = "private", collaborative }
public enum ProviderKind: String, Codable, CaseIterable, Sendable { case codex, claudeCompatible, openCodeACP, cursorACP, headlessAdapter, mcp }
public enum SessionLifecycleState: String, Codable, Sendable { case preparing, idle, running, waiting, completed, failed, canceled, interrupted, archived }
public enum ProjectLifecycleState: String, Codable, Sendable { case active, degraded, archived }

public struct GoblinAuthorizationDecision: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let decisionID: UUID
    public let actor: ExternalActor
    public let sessionID: UUID?
    public let projectID: UUID?
    public let operation: String
    public let requestDigest: String
    public let policyRevision: Int64
    public let controllerRevision: Int64
    public let membershipRevision: Int64
    public let issuedAt: Date
    public let expiresAt: Date
    public let requestID: UUID
    public let correlationID: UUID
    public let keyID: String
    public let signature: String

    public init(
        decisionID: UUID,
        actor: ExternalActor,
        sessionID: UUID? = nil,
        projectID: UUID? = nil,
        operation: String,
        requestDigest: String,
        policyRevision: Int64,
        controllerRevision: Int64,
        membershipRevision: Int64,
        issuedAt: Date,
        expiresAt: Date,
        requestID: UUID,
        correlationID: UUID,
        keyID: String,
        signature: String
    ) {
        schemaVersion = 1
        self.decisionID = decisionID
        self.actor = actor
        self.sessionID = sessionID
        self.projectID = projectID
        self.operation = operation
        self.requestDigest = requestDigest
        self.policyRevision = policyRevision
        self.controllerRevision = controllerRevision
        self.membershipRevision = membershipRevision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.requestID = requestID
        self.correlationID = correlationID
        self.keyID = keyID
        self.signature = signature
    }
}
