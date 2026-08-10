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
    private let commandRunner: any WorkspaceCommandRunning
    private let worktreeService: WorktreeRuntimeService?
    private let artifactService: ArtifactRuntimeService?
    private let workflowCatalog = BuiltinWorkflowCatalog()
    private let projects = ProjectRuntimeSupervisor()
    private let eventHub = ServiceEventHub()
    private var sessions: [UUID: SessionAuthority] = [:]
    private var tools: [UUID: ProjectToolAuthority] = [:]
    private var selections: [UUID: SessionSelectionAuthority] = [:]
    private var quiescing = false

    public init(
        store: SQLiteServiceStore,
        clock: any RuntimeClock = SystemRuntimeClock(),
        ids: any RuntimeIDGenerator = SystemRuntimeIDGenerator(),
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        commandRunner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        worktreeService: WorktreeRuntimeService? = nil,
        artifactService: ArtifactRuntimeService? = nil
    ) {
        self.store = store
        self.clock = clock
        self.ids = ids
        self.filesystem = filesystem
        self.commandRunner = commandRunner
        self.worktreeService = worktreeService
        self.artifactService = artifactService
    }

    public func recover() async throws {
        for snapshot in try await store.allProjects() {
            let roots = snapshot.roots.map { CanonicalRoot(snapshot: $0, filesystemIdentity: "persisted") }
            let project = ProjectAuthority(snapshot: snapshot, roots: roots)
            await projects.install(project)
            tools[snapshot.projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
        }
        for snapshot in try await store.allSessions() {
            sessions[snapshot.sessionID] = SessionAuthority(snapshot: snapshot, clock: clock, ids: ids)
            let persistedSelection = try await store.selection(sessionID: snapshot.sessionID)
            selections[snapshot.sessionID] = SessionSelectionAuthority(
                sessionID: snapshot.sessionID,
                template: persistedSelection?.entries ?? [],
                revision: persistedSelection?.revision ?? 1,
                bindingRevision: persistedSelection?.bindingRevision ?? 1
            )
        }
        try await store.installWorkflows(workflowCatalog.workflows())
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
        let project = ProjectAuthority(snapshot: snapshot, roots: canonicalRoots)
        await projects.install(project)
        tools[projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
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
        selections[sessionID] = SessionSelectionAuthority(sessionID: sessionID)
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
        case let .answerInteraction(interactionID, expectedRevision, payload):
            _ = try await answerInteraction(sessionID: sessionID, interactionID: interactionID, expectedRevision: expectedRevision, payload: payload, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case let .updateExecutionPermissions(expectedRevision, executionMode, providerSettings):
            _ = try await updatePermissions(sessionID: sessionID, expectedRevision: expectedRevision, mode: executionMode, providerSettings: providerSettings, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case .setSessionVisibility: eventType = .visibilityUpdated
        case let .updateSelection(mode, expectedRevision, operations):
            guard mode == "remove" else { throw ServiceAPIError(code: .invalidRequest, message: "Selection commands with structured entries must use the selection endpoints") }
            let snapshot = try await selectionSnapshot(sessionID: sessionID)
            let grouped = Dictionary(grouping: snapshot.entries.filter { operations.contains($0.logicalPath) }, by: \LogicalSelectionEntry.rootID)
            for (rootID, entries) in grouped {
                _ = try await removeSelection(sessionID: sessionID, rootID: rootID, logicalPaths: Set(entries.map(\.logicalPath)), expectedRevision: expectedRevision, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            }
            return try await commandReceipt(command: command, sessionID: sessionID)
        case .buildContext, .runContextBuilder, .askOracle:
            throw ServiceAPIError(code: .capabilityMissing, message: "Context Builder or Oracle runtime has not been configured")
        case let .createWorktree(rootID, baseRef, branchName):
            _ = try await createWorktree(sessionID: sessionID, rootID: rootID, baseRef: baseRef, branch: branchName, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case .bindWorktree:
            throw ServiceAPIError(code: .capabilityMissing, message: "Explicit worktree rebinding is not available")
        case let .mergeWorktree(bindingID, strategy, expectedRevision):
            _ = try await mergeWorktree(sessionID: sessionID, bindingID: bindingID, strategy: strategy, expectedRevision: expectedRevision, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
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

    public func projectTree(projectID: UUID, request: ProjectTreeRequest) async throws -> [ProjectTreeEntry] {
        guard let tool = tools[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return try await tool.tree(request)
    }

    public func projectSearch(projectID: UUID, request: ProjectSearchRequest) async throws -> [ProjectSearchHit] {
        guard let tool = tools[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return try await tool.search(request)
    }

    public func projectFile(projectID: UUID, request: ProjectFileRequest) async throws -> ProjectFileSnapshot {
        guard let tool = tools[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return try await tool.readFile(request)
    }

    public func projectDiff(projectID: UUID, request: ProjectDiffRequest) async throws -> ProjectDiffSnapshot {
        guard let tool = tools[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return try await tool.diff(request)
    }

    public func workflowSnapshots() async throws -> [WorkflowSnapshot] {
        try await store.workflows()
    }

    public func selectionSnapshot(sessionID: UUID) async throws -> SelectionSnapshot {
        guard let selection = selections[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return await selection.snapshot()
    }

    public func replaceSelection(sessionID: UUID, entries: [LogicalSelectionEntry], expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> SelectionSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "replaceSelection", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: SelectionSnapshot = try await priorResult(idempotency) { return prior }
        guard let selection = selections[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        try await validateSelection(entries, projectID: session.projectID)
        let snapshot = try await selection.replace(entries, expectedRevision: expectedRevision)
        let event = try await store.persistSelection(snapshot, projectID: session.projectID, rootSessionID: session.rootSessionID, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return snapshot
    }

    public func addSelection(sessionID: UUID, entries: [LogicalSelectionEntry], expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> SelectionSnapshot {
        let current = try await selectionSnapshot(sessionID: sessionID)
        return try await replaceSelection(sessionID: sessionID, entries: current.entries + entries, expectedRevision: expectedRevision, actor: actor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
    }

    public func removeSelection(sessionID: UUID, rootID: UUID, logicalPaths: Set<String>, expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> SelectionSnapshot {
        let current = try await selectionSnapshot(sessionID: sessionID)
        return try await replaceSelection(sessionID: sessionID, entries: current.entries.filter { $0.rootID != rootID || !logicalPaths.contains($0.logicalPath) }, expectedRevision: expectedRevision, actor: actor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
    }

    public func permissionSnapshot(sessionID: UUID) async throws -> ExecutionPermissionSnapshot? {
        guard sessions[sessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return try await store.permissions(sessionID: sessionID)
    }

    public func updatePermissions(sessionID: UUID, expectedRevision: Int64, mode: String, providerSettings: [String: String], actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> ExecutionPermissionSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "updateExecutionPermissions", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: ExecutionPermissionSnapshot = try await priorResult(idempotency) { return prior }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let current = try await store.permissions(sessionID: sessionID)
        let revision = current?.revision ?? 0
        guard revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Permission revision is stale", currentRevision: revision) }
        let snapshot = ExecutionPermissionSnapshot(sessionID: sessionID, mode: mode, providerSettings: providerSettings, revision: revision + 1, updatedActor: actor)
        let event = try await store.persistPermissions(snapshot, projectID: session.projectID, rootSessionID: session.rootSessionID, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return snapshot
    }

    public func interactionSnapshots(sessionID: UUID) async throws -> [InteractionSnapshot] {
        guard sessions[sessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return try await store.interactions(sessionID: sessionID)
    }

    public func answerInteraction(sessionID: UUID, interactionID: UUID, expectedRevision: Int64, payload: Data, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> InteractionSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "answerInteraction", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: InteractionSnapshot = try await priorResult(idempotency) { return prior }
        let session = try await sessionSnapshot(sessionID: sessionID)
        guard let current = try await store.interactions(sessionID: sessionID).first(where: { $0.interactionID == interactionID }) else { throw ServiceAPIError(code: .notFound, message: "Interaction not found") }
        guard current.state == .pending, current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Interaction revision is stale", currentRevision: current.revision) }
        let resolved = InteractionSnapshot(interactionID: current.interactionID, kind: current.kind, state: .resolved, payload: payload, revision: current.revision + 1, expiresAt: current.expiresAt)
        let event = try await store.persistInteraction(resolved, session: session, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return resolved
    }

    public func worktreeSnapshots(projectID: UUID) async throws -> [WorktreeBindingSnapshot] {
        _ = try await projects.authority(projectID: projectID)
        return try await store.worktrees(projectID: projectID)
    }

    public func createWorktree(sessionID: UUID, rootID: UUID, baseRef: String, branch: String, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> WorktreeBindingSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "createWorktree", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: WorktreeBindingSnapshot = try await priorResult(idempotency) { return prior }
        guard let worktreeService else { throw ServiceAPIError(code: .capabilityMissing, message: "Worktree storage is not configured") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let project = try await projectSnapshot(projectID: session.projectID)
        guard let root = project.roots.first(where: { $0.rootID == rootID }) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root") }
        let snapshot = try await worktreeService.create(project: project, root: root, sessionID: sessionID, baseRef: baseRef, branch: branch)
        let event = try await store.persistWorktree(snapshot, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return snapshot
    }

    public func mergeWorktree(sessionID: UUID, bindingID: UUID, strategy: String, expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> WorktreeBindingSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "mergeWorktree", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: WorktreeBindingSnapshot = try await priorResult(idempotency) { return prior }
        guard let worktreeService else { throw ServiceAPIError(code: .capabilityMissing, message: "Worktree storage is not configured") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        guard let binding = try await store.worktree(bindingID: bindingID), binding.projectID == session.projectID, binding.sessionID == sessionID else { throw ServiceAPIError(code: .notFound, message: "Worktree binding not found") }
        guard binding.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Worktree revision is stale", currentRevision: binding.revision) }
        let project = try await projectSnapshot(projectID: session.projectID)
        guard let root = project.roots.first(where: { $0.rootID == binding.rootID }) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root") }
        let merged = try await worktreeService.merge(binding, targetPath: root.canonicalPath, strategy: strategy)
        let event = try await store.persistWorktree(merged, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return merged
    }

    public func artifactSnapshots(sessionID: UUID) async throws -> [ArtifactSnapshot] {
        guard sessions[sessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return try await store.artifacts(sessionID: sessionID).map(\.snapshot)
    }

    public func artifactContent(artifactID: UUID, maximumBytes: Int) async throws -> Data {
        guard let artifactService else { throw ServiceAPIError(code: .capabilityMissing, message: "Artifact storage is not configured") }
        guard let artifact = try await store.artifact(id: artifactID) else { throw ServiceAPIError(code: .notFound, message: "Artifact not found") }
        return try await artifactService.content(storageReference: artifact.storageReference, maximumBytes: maximumBytes)
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

    private func validateSelection(_ entries: [LogicalSelectionEntry], projectID: UUID) async throws {
        let project = try await projects.authority(projectID: projectID)
        for entry in entries {
            _ = try await project.authorize(rootID: entry.rootID, logicalPath: entry.logicalPath, filesystem: filesystem)
        }
    }

    private func commandReceipt(command: SessionCommand, sessionID: UUID) async throws -> CommandReceipt {
        let cursor = try await store.nextCursor()
        return CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: ServiceCursor(storeID: cursor.storeID, globalSequence: max(0, cursor.globalSequence - 1)), status: "accepted")
    }

    private func mutationIdempotency(actor: ExternalActor, operation: String, key: String?, digest: String?) throws -> IdempotencyInput? {
        switch (key, digest) {
        case (nil, nil): nil
        case let (.some(key), .some(digest)): IdempotencyInput(actorID: actor.goblinUserID, operation: operation, key: key, requestDigest: digest)
        default: throw ServiceAPIError(code: .invalidRequest, message: "Idempotency key and request digest must be supplied together")
        }
    }

    private func priorResult<T: Decodable>(_ idempotency: IdempotencyInput) async throws -> T? {
        guard let existing = try await store.idempotencyResult(idempotency) else { return nil }
        return try JSONDecoder.serviceDecoder.decode(T.self, from: existing.response)
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: value.state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }
}
