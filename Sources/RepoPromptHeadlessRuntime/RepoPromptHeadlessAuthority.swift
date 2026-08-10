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
    private let providerAdapter: ProviderCLIAdapter?
    private let workflowCatalog = BuiltinWorkflowCatalog()
    private let projects = ProjectRuntimeSupervisor()
    private let eventHub = ServiceEventHub()
    private var sessions: [UUID: SessionAuthority] = [:]
    private var tools: [UUID: ProjectToolAuthority] = [:]
    private var selections: [UUID: SessionSelectionAuthority] = [:]
    private var providerTasks: [UUID: Task<Void, Never>] = [:]
    private var quiescing = false

    public init(
        store: SQLiteServiceStore,
        clock: any RuntimeClock = SystemRuntimeClock(),
        ids: any RuntimeIDGenerator = SystemRuntimeIDGenerator(),
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        commandRunner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        worktreeService: WorktreeRuntimeService? = nil,
        artifactService: ArtifactRuntimeService? = nil,
        providerAdapter: ProviderCLIAdapter? = nil
    ) {
        self.store = store
        self.clock = clock
        self.ids = ids
        self.filesystem = filesystem
        self.commandRunner = commandRunner
        self.worktreeService = worktreeService
        self.artifactService = artifactService
        self.providerAdapter = providerAdapter
    }

    public func recover() async throws {
        let unclean = !(try await store.metadata().lastCleanShutdown)
        try await providerAdapter?.recoverProcessFamilies()
        for snapshot in try await store.allProjects() {
            let roots = snapshot.roots.map { CanonicalRoot(snapshot: $0, filesystemIdentity: "persisted") }
            let project = ProjectAuthority(snapshot: snapshot, roots: roots)
            await projects.install(project)
            tools[snapshot.projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
        }
        for storedSnapshot in try await store.allSessions() {
            var snapshot = storedSnapshot
            if unclean, [.preparing, .running, .waiting].contains(snapshot.state) {
                let cursor = try await store.nextCursor()
                snapshot = replacingLifecycle(snapshot, state: .interrupted, cursor: cursor)
                let event = try await store.persistSession(snapshot, eventType: .serviceRecovery, actor: nil, correlationID: ids.next(), idempotency: nil)
                await eventHub.publish(event)
            }
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
        case let .resumeSession(expectedRunID, _):
            guard expectedRunID == nil else { throw ServiceAPIError(code: .staleRevision, message: "No inactive run may match an expected run ID") }
            return try await startProviderRun(command: command, sessionID: sessionID, session: session, actor: externalActor, idempotency: idempotency)
        case let .cancelSession(expectedRunID, generation):
            return try await cancelProviderRun(command: command, sessionID: sessionID, session: session, expectedRunID: expectedRunID, generation: generation, actor: externalActor, idempotency: idempotency)
        case let .steerSession(text, targetTurnEpoch):
            return try await steerProviderRun(command: command, sessionID: sessionID, session: session, text: text, targetTurnEpoch: targetTurnEpoch, actor: externalActor, idempotency: idempotency)
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
        case let .buildContext(expectedSelectionRevision, include):
            _ = try await buildContext(sessionID: sessionID, expectedSelectionRevision: expectedSelectionRevision, include: include, actor: externalActor)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case let .runContextBuilder(expectedSelectionRevision, instructions, budget):
            _ = try await runContextBuilder(sessionID: sessionID, input: .init(expectedSelectionRevision: expectedSelectionRevision, instructions: instructions, budget: budget), actor: externalActor)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case let .askOracle(chatID, prompt, contextMode):
            _ = try await askOracle(sessionID: sessionID, input: .init(chatID: chatID, prompt: prompt, contextMode: contextMode), actor: externalActor)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case let .createWorktree(rootID, baseRef, branchName):
            _ = try await createWorktree(sessionID: sessionID, rootID: rootID, baseRef: baseRef, branch: branchName, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case .bindWorktree:
            throw ServiceAPIError(code: .capabilityMissing, message: "Explicit worktree rebinding is not available")
        case let .mergeWorktree(bindingID, strategy, expectedRevision):
            _ = try await mergeWorktree(sessionID: sessionID, bindingID: bindingID, strategy: strategy, expectedRevision: expectedRevision, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case .retrySession:
            return try await startProviderRun(command: command, sessionID: sessionID, session: session, actor: externalActor, idempotency: idempotency)
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

    public func refreshProject(projectID: UUID, expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> ProjectSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "refreshProject", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) { return try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: existing.response) }
        let current = try await projectSnapshot(projectID: projectID)
        guard current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: current.revision) }
        var roots: [CanonicalRoot] = []
        var degraded = false
        for root in current.roots {
            do {
                let canonical = try filesystem.canonicalizeRoot(root.canonicalPath)
                roots.append(CanonicalRoot(snapshot: root, filesystemIdentity: canonical.identity))
            } catch {
                degraded = true
                roots.append(CanonicalRoot(snapshot: root, filesystemIdentity: "unavailable"))
            }
        }
        let cursor = try await store.nextCursor()
        let snapshot = ProjectSnapshot(projectID: current.projectID, name: current.name, creator: current.creator, state: degraded ? .degraded : .active, roots: current.roots, revision: current.revision + 1, cursor: cursor)
        let event = try await store.persistProject(snapshot, eventType: .projectRefreshed, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        let project = ProjectAuthority(snapshot: snapshot, roots: roots)
        await projects.install(project)
        tools[projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
        await eventHub.publish(event)
        return snapshot
    }

    public func workflowSnapshots() async throws -> [WorkflowSnapshot] {
        try await store.workflows()
    }

    public func providerCapabilities(preflight: Bool = false) async -> [ProviderCapability] {
        guard let providerAdapter else { return ProviderKind.allCases.map { ProviderCapability(kind: $0, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "provider runtime not configured") } }
        return preflight ? await providerAdapter.preflight() : await providerAdapter.capabilities()
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

    public func buildContext(sessionID: UUID, expectedSelectionRevision: Int64, include: [String], actor: ExternalActor) async throws -> ArtifactSnapshot {
        let session = try await sessionSnapshot(sessionID: sessionID)
        let selection = try await selectionSnapshot(sessionID: sessionID)
        guard selection.revision == expectedSelectionRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection revision is stale", currentRevision: selection.revision) }
        let content = try await materializedContext(projectID: session.projectID, selection: selection, include: include)
        return try await createArtifact(projectID: session.projectID, sessionID: sessionID, kind: "context", logicalName: "context-r\(selection.revision).md", content: Data(content.utf8), actor: actor)
    }

    public func runContextBuilder(sessionID: UUID, input: ContextBuilderInput, actor: ExternalActor) async throws -> SelectionSnapshot {
        guard let providerAdapter else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider runtime is not configured") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let current = try await selectionSnapshot(sessionID: sessionID)
        guard current.revision == input.expectedSelectionRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection revision is stale", currentRevision: current.revision) }
        let project = try await projectSnapshot(projectID: session.projectID)
        guard let workingRoot = project.roots.first else { throw ServiceAPIError(code: .rootUnauthorized, message: "Project has no roots") }
        var inventory: [String] = []
        for root in project.roots {
            let entries = try await projectTree(projectID: project.projectID, request: .init(rootID: root.rootID, maximumDepth: 12, maximumEntries: min(max(input.budget, 100), 10_000)))
            inventory.append(contentsOf: entries.filter { !$0.isDirectory }.map { "\(root.rootID.uuidString)\t\($0.logicalPath)" })
        }
        let prompt = """
        You are RepoPrompt Context Builder. Select the smallest set of repository files that satisfies the instructions.
        Return only a JSON array of objects with string fields rootID and path. Do not return markdown.
        Instructions: \(input.instructions)
        Repository inventory:
        \(inventory.joined(separator: "\n"))
        """
        let output = try await providerAdapter.complete(kind: session.provider, model: session.model, prompt: prompt, workingDirectory: workingRoot.canonicalPath)
        let proposals = try decodeContextBuilderOutput(output)
        let entries = proposals.map { LogicalSelectionEntry(rootID: $0.rootID, logicalPath: $0.path, mode: .full) }
        return try await replaceSelection(sessionID: sessionID, entries: entries, expectedRevision: input.expectedSelectionRevision, actor: actor)
    }

    public func askOracle(sessionID: UUID, input: OracleInput, actor: ExternalActor) async throws -> OracleSnapshot {
        guard let providerAdapter else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider runtime is not configured") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let project = try await projectSnapshot(projectID: session.projectID)
        guard let workingRoot = project.roots.first else { throw ServiceAPIError(code: .rootUnauthorized, message: "Project has no roots") }
        let selection = try await selectionSnapshot(sessionID: sessionID)
        let context = try await materializedContext(projectID: project.projectID, selection: selection, include: ["files"])
        let prompt = """
        You are the RepoPrompt Oracle. Answer the request using the authoritative selected context. Clearly identify uncertainty.
        Request: \(input.prompt)
        Context mode: \(input.contextMode)

        \(context)
        """
        let response = try await providerAdapter.complete(kind: session.provider, model: session.model, prompt: prompt, workingDirectory: workingRoot.canonicalPath)
        let artifact = try await createArtifact(projectID: project.projectID, sessionID: sessionID, kind: "oracle", logicalName: "oracle-\(input.chatID?.uuidString ?? "new").md", content: Data(response.utf8), actor: actor)
        return OracleSnapshot(chatID: input.chatID ?? ids.next(), response: response, artifactID: artifact.artifactID)
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

    public func childSessionSnapshots(parentSessionID: UUID) async throws -> [SessionSnapshot] {
        guard sessions[parentSessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return await sessionSnapshots().filter { $0.parentSessionID == parentSessionID }
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
        let availableProviders = await providerCapabilities().filter(\.enabled).map(\.kind)
        return ServiceCapabilities(protocolMinimum: 1, protocolMaximum: 1, schemaVersion: meta.schemaVersion, storeID: meta.storeID, replayFloor: meta.replayFloor, providers: availableProviders, eventTypes: EventType.allCases)
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

    private struct ContextBuilderProposal: Decodable {
        let rootID: UUID
        let path: String
    }

    private func decodeContextBuilderOutput(_ output: String) throws -> [ContextBuilderProposal] {
        guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start <= end else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder provider did not return a JSON selection")
        }
        return try JSONDecoder.serviceDecoder.decode([ContextBuilderProposal].self, from: Data(output[start ... end].utf8))
    }

    private func materializedContext(projectID: UUID, selection: SelectionSnapshot, include: [String]) async throws -> String {
        var sections = ["# RepoPrompt Context", "selection-revision: \(selection.revision)"]
        for entry in selection.entries {
            let file = try await projectFile(projectID: projectID, request: .init(rootID: entry.rootID, logicalPath: entry.logicalPath, maximumBytes: 1_048_576))
            let content: String
            if entry.mode == .slices, !entry.ranges.isEmpty {
                let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                content = entry.ranges.flatMap { range in range.compactMap { index in lines.indices.contains(index - 1) ? String(lines[index - 1]) : nil } }.joined(separator: "\n")
            } else {
                content = file.content
            }
            sections.append("## \(entry.logicalPath)\n```\n\(content)\n```")
        }
        if include.contains("transcript") { sections.append("transcript: included-by-session-endpoint") }
        return sections.joined(separator: "\n\n")
    }

    private func createArtifact(projectID: UUID, sessionID: UUID?, kind: String, logicalName: String, content: Data, actor: ExternalActor?) async throws -> ArtifactSnapshot {
        guard let artifactService else { throw ServiceAPIError(code: .capabilityMissing, message: "Artifact storage is not configured") }
        let cursor = try await store.nextCursor()
        let stored = try await artifactService.store(projectID: projectID, sessionID: sessionID, kind: kind, logicalName: logicalName, content: content, cursor: cursor)
        let event = try await store.persistArtifact(stored.0, storageReference: stored.storageReference, actor: actor, correlationID: ids.next())
        await eventHub.publish(event)
        return stored.0
    }

    private func startProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        guard let providerAdapter else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider runtime is not configured") }
        let snapshot = await session.snapshot()
        guard await providerAdapter.capabilities().contains(where: { $0.kind == snapshot.provider && $0.enabled }) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Session provider is unavailable") }
        let binding = try await session.beginRun(connectionGeneration: snapshot.runGeneration + 1)
        let current = await session.snapshot()
        let cursor = try await store.nextCursor()
        let persisted = replacingCursor(current, cursor: cursor)
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(persisted, eventType: .sessionResumed, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        let project = try await projectSnapshot(projectID: snapshot.projectID)
        guard let workingDirectory = project.roots.first?.canonicalPath else { throw ServiceAPIError(code: .rootUnauthorized, message: "Project has no roots") }
        let prompt = snapshot.transcript.last(where: { $0.kind == .human })?.content ?? "Continue the repository task."
        providerTasks[binding.runID] = Task { await self.performProviderRun(sessionID: sessionID, binding: binding, prompt: prompt, workingDirectory: workingDirectory) }
        return receipt
    }

    private func steerProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, text: String, targetTurnEpoch: Int64, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        let binding = try await session.steer(text, actor: actor, targetTurnEpoch: targetTurnEpoch)
        providerTasks[binding.runID]?.cancel()
        let current = await session.snapshot()
        let cursor = try await store.nextCursor()
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(replacingCursor(current, cursor: cursor), eventType: .sessionUpdated, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        let project = try await projectSnapshot(projectID: current.projectID)
        guard let workingDirectory = project.roots.first?.canonicalPath else { throw ServiceAPIError(code: .rootUnauthorized, message: "Project has no roots") }
        providerTasks[binding.runID] = Task { await self.performProviderRun(sessionID: sessionID, binding: binding, prompt: text, workingDirectory: workingDirectory) }
        return receipt
    }

    private func cancelProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, expectedRunID: UUID?, generation: Int64, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        guard let binding = await session.activeBinding(), binding.generation == generation, expectedRunID == nil || expectedRunID == binding.runID else { throw ServiceAPIError(code: .staleRevision, message: "Run identity is stale", currentRevision: (await session.snapshot()).runGeneration) }
        providerTasks[binding.runID]?.cancel()
        providerTasks[binding.runID] = nil
        guard await session.settle(binding: binding, terminal: .sessionCanceled, lifecycle: .canceled) == .accepted else { throw ServiceAPIError(code: .staleRevision, message: "Run is already settled") }
        let cursor = try await store.nextCursor()
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(replacingCursor(await session.snapshot(), cursor: cursor), eventType: .sessionCanceled, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        return receipt
    }

    private func performProviderRun(sessionID: UUID, binding: RunBindingIdentity, prompt: String, workingDirectory: String) async {
        guard let providerAdapter, let session = sessions[sessionID] else { return }
        let initial = await session.snapshot()
        do {
            let output = try await providerAdapter.complete(kind: initial.provider, model: initial.model, prompt: prompt, workingDirectory: workingDirectory)
            guard !Task.isCancelled, await session.acceptProviderOutput(binding: binding, kind: .assistant, content: output) == .accepted else { return }
            var cursor = try await store.nextCursor()
            var event = try await store.persistSession(replacingCursor(await session.snapshot(), cursor: cursor), eventType: .transcriptMessage, actor: nil, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(event)
            guard await session.settle(binding: binding, terminal: .sessionCompleted, lifecycle: .completed) == .accepted else { return }
            cursor = try await store.nextCursor()
            event = try await store.persistSession(replacingCursor(await session.snapshot(), cursor: cursor), eventType: .sessionCompleted, actor: nil, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(event)
        } catch {
            guard await session.settle(binding: binding, terminal: .sessionFailed, lifecycle: .failed) == .accepted else { return }
            if let cursor = try? await store.nextCursor(), let event = try? await store.persistSession(replacingCursor(await session.snapshot(), cursor: cursor), eventType: .sessionFailed, actor: nil, correlationID: ids.next(), idempotency: nil) {
                await eventHub.publish(event)
            }
        }
        providerTasks[binding.runID] = nil
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: value.state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }

    private func replacingLifecycle(_ value: SessionSnapshot, state: SessionLifecycleState, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision + 1, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }
}
