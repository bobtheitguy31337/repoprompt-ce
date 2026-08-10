import Foundation

public struct ServiceEventSigningKey: Sendable {
    public let keyID: String
    public let secret: Data

    public init(keyID: String, secret: Data) {
        self.keyID = keyID
        self.secret = secret
    }
}

public enum EventType: String, Codable, CaseIterable, Sendable {
    case projectCreated = "project.created", projectUpdated = "project.updated", projectRemoved = "project.removed", projectRefreshed = "project.refreshed", workflowUpdated = "workflow.updated"
    case sessionCreated = "session.created", sessionUpdated = "session.updated", sessionWaiting = "session.waiting", sessionCompleted = "session.completed", sessionFailed = "session.failed", sessionCanceled = "session.canceled", sessionInterrupted = "session.interrupted", sessionResumed = "session.resumed", sessionArchived = "session.archived"
    case agentStarted = "agent.started", agentUpdated = "agent.updated", agentCompleted = "agent.completed", agentFailed = "agent.failed"
    case transcriptMessage = "transcript.message", transcriptProgress = "transcript.progress"
    case toolStarted = "tool.started", toolUpdated = "tool.updated", toolCompleted = "tool.completed", toolFailed = "tool.failed"
    case selectionUpdated = "selection.updated", contextUpdated = "context.updated", artifactCreated = "artifact.created", diffUpdated = "diff.updated"
    case interactionRequested = "interaction.requested", interactionResolved = "interaction.resolved"
    case permissionUpdated = "permission.updated", controllerUpdated = "controller.updated", visibilityUpdated = "visibility.updated"
    case worktreeCreated = "worktree.created", worktreeUpdated = "worktree.updated", worktreeFailed = "worktree.failed"
    case serviceRecovery = "service.recovery", serviceDiagnostic = "service.diagnostic"
}

public struct EventEnvelope: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let eventID: UUID
    public let storeID: UUID
    public let globalSequence: Int64
    public let timestamp: Date
    public let projectID: UUID
    public let sessionID: UUID?
    public let agentID: UUID?
    public let parentAgentID: UUID?
    public let rootSessionID: UUID?
    public let runID: UUID?
    public let sessionSequence: Int64?
    public let eventType: EventType
    public let payloadVersion: Int
    public let generation: Int64?
    public let turnEpoch: Int64?
    public let actor: ExternalActor?
    public let correlationID: UUID
    public let causationID: UUID?
    public let payload: Data
    public let digest: String
    public let keyID: String
    public let signature: String

    public var cursor: ServiceCursor {
        ServiceCursor(storeID: storeID, globalSequence: globalSequence)
    }

    public init(protocolVersion: Int = 1, eventID: UUID, storeID: UUID, globalSequence: Int64, timestamp: Date, projectID: UUID, sessionID: UUID?, agentID: UUID?, parentAgentID: UUID?, rootSessionID: UUID?, runID: UUID?, sessionSequence: Int64?, eventType: EventType, payloadVersion: Int = 1, generation: Int64?, turnEpoch: Int64?, actor: ExternalActor?, correlationID: UUID, causationID: UUID?, payload: Data, digest: String, keyID: String, signature: String) {
        self.protocolVersion = protocolVersion
        self.eventID = eventID
        self.storeID = storeID
        self.globalSequence = globalSequence
        self.timestamp = timestamp
        self.projectID = projectID
        self.sessionID = sessionID
        self.agentID = agentID
        self.parentAgentID = parentAgentID
        self.rootSessionID = rootSessionID
        self.runID = runID
        self.sessionSequence = sessionSequence
        self.eventType = eventType
        self.payloadVersion = payloadVersion
        self.generation = generation
        self.turnEpoch = turnEpoch
        self.actor = actor
        self.correlationID = correlationID
        self.causationID = causationID
        self.payload = payload
        self.digest = digest
        self.keyID = keyID
        self.signature = signature
    }
}

public struct EventPage: Codable, Sendable {
    public let storeID: UUID
    public let events: [EventEnvelope]
    public let nextCursor: ServiceCursor
    public let replayFloor: Int64
    public init(storeID: UUID, events: [EventEnvelope], nextCursor: ServiceCursor, replayFloor: Int64) {
        self.storeID = storeID
        self.events = events
        self.nextCursor = nextCursor
        self.replayFloor = replayFloor
    }
}
