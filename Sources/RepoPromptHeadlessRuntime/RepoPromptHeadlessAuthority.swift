import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public actor RepoPromptHeadlessAuthority {
    private let store: SQLiteServiceStore
    private let clock: any RuntimeClock
    private let ids: any RuntimeIDGenerator
    private let filesystem: any FilesystemAuthorityPort
    private let projects = ProjectRuntimeSupervisor()
    private let eventHub = ServiceEventHub()
    private var sessions: [UUID: SessionAuthority] = [:]
    private var quiescing = false

    public init(store: SQLiteServiceStore, clock: any RuntimeClock = SystemRuntimeClock(), ids: any RuntimeIDGenerator = SystemRuntimeIDGenerator(), filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority()) {
        self.store = store
        self.clock = clock
        self.ids = ids
        self.filesystem = filesystem
    }

    public func recover() async throws {
        for snapshot in try await store.allProjects() {
            let roots = snapshot.roots.map { CanonicalRoot(snapshot: $0, filesystemIdentity: "persisted") }
            await projects.install(ProjectAuthority(snapshot: snapshot, roots: roots))
        }
        for snapshot in try await store.allSessions() {
            sessions[snapshot.sessionID] = SessionAuthority(snapshot: snapshot, clock: clock, ids: ids)
        }
    }

    public func createProject(input: CreateProjectInput, externalActor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> ProjectSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: externalActor.goblinUserID, operation: "createProject", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) {
            return try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: existing.response)
        }
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.roots.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Project name and at least one root are required") }
        let projectID = ids.next()
        var canonicalRoots: [CanonicalRoot] = []
        var seenIdentities = Set<String>()
        for root in input.roots {
            let canonical = try filesystem.canonicalizeRoot(root.path)
            guard seenIdentities.insert(canonical.identity).inserted else { throw ServiceAPIError(code: .invalidRequest, message: "Duplicate physical project root") }
            canonicalRoots.append(CanonicalRoot(snapshot: ProjectRootSnapshot(rootID: ids.next(), logicalName: root.logicalName, canonicalPath: canonical.path, writable: root.writable), filesystemIdentity: canonical.identity))
        }
        let cursor = try await store.nextCursor()
        let snapshot = ProjectSnapshot(projectID: projectID, name: input.name, creator: externalActor, state: .active, roots: canonicalRoots.map(\.snapshot), revision: 1, cursor: cursor)
        let event = try await store.persistProject(snapshot, eventType: .projectCreated, actor: externalActor, correlationID: ids.next(), idempotency: idempotency)
        await projects.install(ProjectAuthority(snapshot: snapshot, roots: canonicalRoots))
        await eventHub.publish(event)
        return snapshot
    }

    public func createSession(input: CreateSessionInput, externalActor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> SessionSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: externalActor.goblinUserID, operation: "startSession", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) {
            return try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: existing.response)
        }
        _ = try await projects.authority(projectID: input.projectID)
        var parent: SessionSnapshot?
        if let parentID = input.parentSessionID {
            guard let parentAuthority = sessions[parentID] else { throw ServiceAPIError(code: .notFound, message: "Parent session not found") }
            parent = await parentAuthority.snapshot()
            guard parent?.projectID == input.projectID else { throw ServiceAPIError(code: .rootUnauthorized, message: "Child session cannot cross project runtime") }
        }
        let sessionID = ids.next()
        let rootSessionID = parent?.rootSessionID ?? sessionID
        let cursor = try await store.nextCursor()
        var transcript: [TranscriptEntry] = []
        if let prompt = input.initialPrompt, !prompt.isEmpty { transcript.append(TranscriptEntry(entryID: ids.next(), sessionSequence: 1, kind: .human, content: prompt, actor: externalActor, timestamp: clock.now())) }
        let snapshot = SessionSnapshot(sessionID: sessionID, projectID: input.projectID, parentSessionID: input.parentSessionID, rootSessionID: rootSessionID, creator: externalActor, provider: input.provider, model: input.model, visibility: input.visibility, state: .idle, runGeneration: 0, turnEpoch: 0, revision: 1, transcript: transcript, interactions: [], cursor: cursor)
        let event = try await store.persistSession(snapshot, eventType: .sessionCreated, actor: externalActor, correlationID: ids.next(), idempotency: idempotency)
        sessions[sessionID] = SessionAuthority(snapshot: snapshot, clock: clock, ids: ids)
        await eventHub.publish(event)
        return snapshot
    }

    public func execute(command: SessionCommand, sessionID: UUID, externalActor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> CommandReceipt {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: externalActor.goblinUserID, operation: command.operation, key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) {
            return try JSONDecoder.serviceDecoder.decode(CommandReceipt.self, from: existing.response)
        }
        guard let session = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        let before = await session.snapshot()
        guard before.parentSessionID == nil else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "External commands may target only root sessions") }
        let eventType: EventType
        switch command {
        case let .sendFollowup(text, expectedRevision):
            try await session.appendHumanMessage(text, actor: externalActor, expectedRevision: expectedRevision)
            eventType = .transcriptMessage
        case .resumeSession:
            _ = try await session.beginRun(connectionGeneration: before.runGeneration + 1)
            eventType = .sessionResumed
        case let .cancelSession(_, generation):
            guard generation == before.runGeneration else { throw ServiceAPIError(code: .staleRevision, message: "Run generation is stale", currentRevision: before.runGeneration) }
            eventType = .sessionCanceled
        case let .steerSession(_, targetTurnEpoch):
            guard targetTurnEpoch == before.turnEpoch else { throw ServiceAPIError(code: .staleRevision, message: "Turn epoch is stale", currentRevision: before.turnEpoch) }
            eventType = .sessionUpdated
        case let .archiveSession(expectedRevision):
            guard expectedRevision == before.revision else { throw ServiceAPIError(code: .staleRevision, message: "Session revision is stale", currentRevision: before.revision) }
            eventType = .sessionArchived
        case .answerInteraction: eventType = .interactionResolved
        case .updateExecutionPermissions: eventType = .permissionUpdated
        case .setSessionVisibility: eventType = .visibilityUpdated
        case .updateSelection: eventType = .selectionUpdated
        case .buildContext, .runContextBuilder, .askOracle: eventType = .contextUpdated
        case .createWorktree: eventType = .worktreeCreated
        case .bindWorktree, .mergeWorktree: eventType = .worktreeUpdated
        case .retrySession: eventType = .sessionResumed
        }
        let current = await session.snapshot()
        let cursor = try await store.nextCursor()
        let persisted = replacingCursor(current, cursor: cursor)
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(
            persisted,
            eventType: eventType,
            actor: externalActor,
            correlationID: ids.next(),
            idempotency: idempotency,
            idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt)
        )
        await eventHub.publish(event)
        return receipt
    }

    public func projectSnapshot(projectID: UUID) async throws -> ProjectSnapshot {
        try await projects.authority(projectID: projectID).snapshot()
    }

    public func sessionSnapshot(sessionID: UUID) async throws -> SessionSnapshot {
        guard let session = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return await session.snapshot()
    }

    public func projectSnapshots() async -> [ProjectSnapshot] {
        await projects.snapshots()
    }

    public func sessionSnapshots() async -> [SessionSnapshot] {
        var values: [SessionSnapshot] = []
        for session in sessions.values {
            await values.append(session.snapshot())
        }
        return values.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    public func events(after cursor: ServiceCursor?, limit: Int, projectID: UUID? = nil, sessionID: UUID? = nil) async throws -> EventPage {
        let page = try await store.events(after: cursor, limit: limit)
        let filtered = page.events.filter { (projectID == nil || $0.projectID == projectID) && (sessionID == nil || $0.sessionID == sessionID) }
        return EventPage(storeID: page.storeID, events: filtered, nextCursor: page.nextCursor, replayFloor: page.replayFloor)
    }

    public func subscribe(after cursor: ServiceCursor?) async throws -> AsyncThrowingStream<EventEnvelope, Error> {
        // Register first so publications racing the durable replay are buffered, then
        // deduplicate anything present in both the transaction log and live stream.
        let live = await eventHub.subscribe()
        let firstReplayPage = try await store.events(after: cursor, limit: 1000)
        let replayCeiling = try await store.nextCursor().globalSequence - 1
        return AsyncThrowingStream { continuation in
            let producer = Task {
                var deliveredSequence = cursor?.globalSequence ?? firstReplayPage.replayFloor
                var page = firstReplayPage
                do {
                    while deliveredSequence < replayCeiling {
                        for event in page.events where event.globalSequence > deliveredSequence && event.globalSequence <= replayCeiling {
                            continuation.yield(event)
                            deliveredSequence = event.globalSequence
                        }
                        guard deliveredSequence < replayCeiling else { break }
                        guard !page.events.isEmpty else {
                            throw ServiceAPIError(code: .persistenceUnavailable, message: "Durable event replay ended below its captured watermark")
                        }
                        page = try await store.events(after: page.nextCursor, limit: 1000)
                    }
                    for try await event in live {
                        guard event.storeID == firstReplayPage.storeID, event.globalSequence > deliveredSequence else { continue }
                        continuation.yield(event)
                        deliveredSequence = event.globalSequence
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    public func capabilities() async throws -> ServiceCapabilities {
        let meta = try await store.metadata()
        return ServiceCapabilities(protocolMinimum: 1, protocolMaximum: 1, schemaVersion: meta.schemaVersion, storeID: meta.storeID, replayFloor: meta.replayFloor, providers: ProviderKind.allCases, eventTypes: EventType.allCases)
    }

    public func authoritativeSnapshot() async throws -> AuthoritativeSnapshot {
        let meta = try await store.metadata()
        let cursor = ServiceCursor(storeID: meta.storeID, globalSequence: meta.nextGlobalSequence - 1)
        return await AuthoritativeSnapshot(storeID: meta.storeID, projects: projectSnapshots(), sessions: sessionSnapshots(), cursor: cursor)
    }

    public func quiesce() async throws {
        quiescing = true
        try await store.checkpoint()
    }

    public func isReady() -> Bool {
        !quiescing
    }

    private func ensureWritable() throws {
        if quiescing { throw ServiceAPIError(code: .quiescing, message: "Service is quiescing", retryable: true) }
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: value.state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }
}
