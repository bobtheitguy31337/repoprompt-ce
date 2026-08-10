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
    private let interactionDelivery: (any InteractionDeliveryPort)?
    private let workflowCatalog = BuiltinWorkflowCatalog()
    private let projects = ProjectRuntimeSupervisor()
    private let eventHub = ServiceEventHub()
    private var sessions: [UUID: SessionAuthority] = [:]
    private var agents: [UUID: AgentSnapshot] = [:]
    private var tools: [UUID: ProjectToolAuthority] = [:]
    private var selections: [UUID: SessionSelectionAuthority] = [:]
    private var providerTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellationBarriers: Set<UUID> = []
    private var quiescing = false

    public init(
        store: SQLiteServiceStore,
        clock: any RuntimeClock = SystemRuntimeClock(),
        ids: any RuntimeIDGenerator = SystemRuntimeIDGenerator(),
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        commandRunner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        worktreeService: WorktreeRuntimeService? = nil,
        artifactService: ArtifactRuntimeService? = nil,
        providerAdapter: ProviderCLIAdapter? = nil,
        interactionDelivery: (any InteractionDeliveryPort)? = nil
    ) {
        self.store = store
        self.clock = clock
        self.ids = ids
        self.filesystem = filesystem
        self.commandRunner = commandRunner
        self.worktreeService = worktreeService
        self.artifactService = artifactService
        self.providerAdapter = providerAdapter
        self.interactionDelivery = interactionDelivery
    }

    public func recover() async throws {
        let unclean = try await !(store.metadata().lastCleanShutdown)
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
        for agent in try await store.agents() {
            agents[agent.sessionID] = agent
        }
        for snapshot in await sessionSnapshots() where agents[snapshot.sessionID] == nil {
            let synthesized = AgentSnapshot(agentID: snapshot.sessionID, sessionID: snapshot.sessionID, rootSessionID: snapshot.rootSessionID, parentAgentID: snapshot.parentSessionID, role: snapshot.parentSessionID == nil ? "root" : "child", state: snapshot.state, revision: 1)
            let event = try await store.persistAgent(synthesized, projectID: snapshot.projectID, actor: nil, correlationID: ids.next(), eventType: .agentStarted)
            agents[snapshot.sessionID] = synthesized
            await eventHub.publish(event)
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

    public func updateProject(projectID: UUID, input: UpdateProjectInput, actor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> ProjectSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "updateProject", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) { return try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: existing.response) }
        let current = try await projectSnapshot(projectID: projectID)
        guard current.revision == input.expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: current.revision) }
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.roots.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Project name and at least one root are required") }
        let activeSessions = await sessionSnapshots().filter { $0.projectID == projectID && ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains($0.state) }
        let requestedPaths = Set(input.roots.map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path })
        let currentPaths = Set(current.roots.map(\.canonicalPath))
        let worktrees = try await store.worktrees(projectID: projectID)
        if requestedPaths != currentPaths, !activeSessions.isEmpty || !worktrees.isEmpty {
            throw ServiceAPIError(code: .worktreeConflict, message: "Project roots cannot change while sessions or worktrees are active")
        }
        var canonicalRoots: [CanonicalRoot] = []
        var identities = Set<String>()
        for root in input.roots {
            let canonical = try filesystem.canonicalizeRoot(root.path)
            guard identities.insert(canonical.identity).inserted else { throw ServiceAPIError(code: .invalidRequest, message: "Duplicate physical project root") }
            let existingID = current.roots.first(where: { $0.canonicalPath == canonical.path })?.rootID
            canonicalRoots.append(CanonicalRoot(snapshot: ProjectRootSnapshot(rootID: existingID ?? ids.next(), logicalName: root.logicalName, canonicalPath: canonical.path, writable: root.writable), filesystemIdentity: canonical.identity))
        }
        let cursor = try await store.nextCursor()
        let snapshot = ProjectSnapshot(projectID: projectID, name: input.name, creator: current.creator, state: .active, roots: canonicalRoots.map(\.snapshot), revision: current.revision + 1, cursor: cursor)
        let event = try await store.persistProject(snapshot, eventType: .projectUpdated, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        let project = ProjectAuthority(snapshot: snapshot, roots: canonicalRoots)
        await projects.install(project)
        tools[projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
        await eventHub.publish(event)
        return snapshot
    }

    public func removeProject(projectID: UUID, expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "removeProject", key: idempotencyKey, requestDigest: requestDigest)
        if try await store.idempotencyResult(idempotency) != nil { return }
        let current = try await projectSnapshot(projectID: projectID)
        guard current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: current.revision) }
        let activeSessions = await sessionSnapshots().filter { $0.projectID == projectID && ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains($0.state) }
        let worktrees = try await store.worktrees(projectID: projectID)
        guard activeSessions.isEmpty, worktrees.isEmpty else { throw ServiceAPIError(code: .worktreeConflict, message: "Project must have no active sessions or worktrees before removal") }
        let cursor = try await store.nextCursor()
        let archived = ProjectSnapshot(projectID: projectID, name: current.name, creator: current.creator, state: .archived, roots: current.roots, revision: current.revision + 1, cursor: cursor)
        let event = try await store.persistProject(archived, eventType: .projectRemoved, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await projects.remove(projectID: projectID)
        tools[projectID] = nil
        await eventHub.publish(event)
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
            guard let rootSessionID = parent?.rootSessionID, !cancellationBarriers.contains(rootSessionID) else { throw ServiceAPIError(code: .quiescing, message: "Root session is canceling; new children are fenced") }
        }
        let sessionID = ids.next()
        let rootSessionID = parent?.rootSessionID ?? sessionID
        let seededSelection: SelectionSnapshot
        if let parentID = input.parentSessionID {
            let inherited = try await selectionSnapshot(sessionID: parentID)
            seededSelection = SelectionSnapshot(sessionID: sessionID, entries: inherited.entries, revision: 1, bindingRevision: inherited.bindingRevision)
        } else {
            let template = try await store.selectionTemplate(projectID: input.projectID)
            seededSelection = SelectionSnapshot(sessionID: sessionID, entries: template?.entries ?? [], revision: 1, bindingRevision: 1)
        }
        let cursor = try await store.nextCursor()
        var transcript: [TranscriptEntry] = []
        if let prompt = input.initialPrompt, !prompt.isEmpty { transcript.append(TranscriptEntry(entryID: ids.next(), sessionSequence: 1, kind: .human, content: prompt, actor: externalActor, timestamp: clock.now())) }
        let snapshot = SessionSnapshot(sessionID: sessionID, projectID: input.projectID, parentSessionID: input.parentSessionID, rootSessionID: rootSessionID, creator: externalActor, provider: input.provider, model: input.model, visibility: input.visibility, state: .idle, runGeneration: 0, turnEpoch: 0, revision: 1, transcript: transcript, interactions: [], cursor: cursor)
        let agent = AgentSnapshot(agentID: sessionID, sessionID: sessionID, rootSessionID: rootSessionID, parentAgentID: input.parentSessionID, role: input.parentSessionID == nil ? "root" : "child", state: snapshot.state, revision: 1)
        let events = try await store.persistNewSession(snapshot, agent: agent, actor: externalActor, correlationID: ids.next(), agentCorrelationID: ids.next(), idempotency: idempotency, initialSelection: seededSelection)
        sessions[sessionID] = SessionAuthority(snapshot: snapshot, clock: clock, ids: ids)
        agents[sessionID] = agent
        selections[sessionID] = SessionSelectionAuthority(sessionID: sessionID, template: seededSelection.entries, revision: seededSelection.revision, bindingRevision: seededSelection.bindingRevision)
        await eventHub.publish(events.session)
        await eventHub.publish(events.agent)
        return snapshot
    }

    public func spawnChildSession(parentSessionID: UUID, provider: ProviderKind? = nil, model: String? = nil, initialPrompt: String, role: String = "child", label: String? = nil) async throws -> SessionSnapshot {
        guard let parentAuthority = sessions[parentSessionID] else { throw ServiceAPIError(code: .notFound, message: "Parent session not found") }
        let parent = await parentAuthority.snapshot()
        guard !cancellationBarriers.contains(parent.rootSessionID) else { throw ServiceAPIError(code: .quiescing, message: "Root session is canceling; new children are fenced") }
        let child = try await createSession(input: CreateSessionInput(projectID: parent.projectID, parentSessionID: parentSessionID, provider: provider ?? parent.provider, model: model ?? parent.model, visibility: parent.visibility, initialPrompt: initialPrompt), externalActor: parent.creator, idempotencyKey: "agent-manage:\(ids.next().uuidString)", requestDigest: CanonicalSigning.bodyDigest(Data(initialPrompt.utf8)))
        if var agent = agents[child.sessionID] {
            agent = AgentSnapshot(agentID: agent.agentID, sessionID: agent.sessionID, rootSessionID: agent.rootSessionID, parentAgentID: agent.parentAgentID, providerNativeIdentity: agent.providerNativeIdentity, role: role, label: label, state: agent.state, revision: agent.revision + 1)
            let agentEvent = try await store.persistAgent(agent, projectID: child.projectID, actor: nil, correlationID: ids.next(), eventType: .agentUpdated)
            agents[child.sessionID] = agent
            await eventHub.publish(agentEvent)
        }
        return child
    }

    public func agentSnapshots(rootSessionID: UUID) async throws -> [AgentSnapshot] {
        guard sessions[rootSessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Root session not found") }
        return try await store.agents(rootSessionID: rootSessionID)
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
            try await session.archive(expectedRevision: expectedRevision)
            eventType = .sessionArchived
        case let .answerInteraction(interactionID, expectedRevision, payload):
            _ = try await answerInteraction(sessionID: sessionID, interactionID: interactionID, expectedRevision: expectedRevision, payload: payload, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case let .updateExecutionPermissions(expectedRevision, executionMode, providerSettings):
            _ = try await updatePermissions(sessionID: sessionID, expectedRevision: expectedRevision, mode: executionMode, providerSettings: providerSettings, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
        case let .setSessionVisibility(expectedPolicyRevision, visibility, _, _):
            try await session.updateVisibility(visibility, expectedRevision: expectedPolicyRevision)
            eventType = .visibilityUpdated
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
        case let .bindWorktree(bindingID, expectedRevision):
            _ = try await bindWorktree(sessionID: sessionID, bindingID: bindingID, expectedRevision: expectedRevision, expectedSelectionBindingRevision: selectionSnapshot(sessionID: sessionID).bindingRevision, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
            return try await commandReceipt(command: command, sessionID: sessionID)
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

    public func projectCodeMap(projectID: UUID, request: ProjectCodeMapRequest) async throws -> ProjectCodeMapSnapshot {
        guard let tool = tools[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return try await tool.codeMap(request)
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

    public func workflowSnapshot(workflowID: String) async throws -> WorkflowSnapshot {
        guard let workflow = try await workflowSnapshots().first(where: { $0.workflowID == workflowID }) else {
            throw ServiceAPIError(code: .notFound, message: "Workflow not found")
        }
        return workflow
    }

    public func providerCapabilities(preflight: Bool = false) async -> [ProviderCapability] {
        guard let providerAdapter else { return ProviderKind.allCases.map { ProviderCapability(kind: $0, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "provider runtime not configured") } }
        return preflight ? await providerAdapter.preflight() : await providerAdapter.capabilities()
    }

    public func selectionSnapshot(sessionID: UUID) async throws -> SelectionSnapshot {
        guard let selection = selections[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return await selection.snapshot()
    }

    public func projectSelectionTemplate(projectID: UUID) async throws -> ProjectSelectionTemplateSnapshot {
        _ = try await projects.authority(projectID: projectID)
        return try await store.selectionTemplate(projectID: projectID) ?? ProjectSelectionTemplateSnapshot(projectID: projectID, entries: [], revision: 1)
    }

    public func replaceProjectSelectionTemplate(projectID: UUID, entries: [LogicalSelectionEntry], expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> ProjectSelectionTemplateSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "replaceProjectSelectionTemplate", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) { return try JSONDecoder.serviceDecoder.decode(ProjectSelectionTemplateSnapshot.self, from: existing.response) }
        let project = try await projectSnapshot(projectID: projectID)
        let current = try await projectSelectionTemplate(projectID: projectID)
        guard current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Project selection template revision is stale", currentRevision: current.revision) }
        let allowedRoots = Set(project.roots.map(\.rootID))
        guard entries.allSatisfy({ allowedRoots.contains($0.rootID) }) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Selection template contains an unauthorized root") }
        let next = ProjectSelectionTemplateSnapshot(projectID: projectID, entries: entries, revision: current.revision + 1)
        let event = try await store.persistSelectionTemplate(next, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return next
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

    public func requestInteraction(sessionID: UUID, kind: InteractionSnapshot.Kind, payload: Data, expiresAt: Date? = nil) async throws -> InteractionSnapshot {
        guard let sessionAuthority = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        let session = await sessionAuthority.snapshot()
        let interaction = await InteractionSnapshot(interactionID: ids.next(), runID: sessionAuthority.activeBinding()?.runID, kind: kind, state: .pending, payload: payload, revision: 1, expiresAt: expiresAt)
        let event = try await store.persistInteraction(interaction, session: session, actor: nil, correlationID: ids.next())
        await eventHub.publish(event)
        return interaction
    }

    public func answerInteraction(sessionID: UUID, interactionID: UUID, expectedRevision: Int64, payload: Data, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> InteractionSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "answerInteraction", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: InteractionSnapshot = try await priorResult(idempotency) { return prior }
        let session = try await sessionSnapshot(sessionID: sessionID)
        guard let current = try await store.interactions(sessionID: sessionID).first(where: { $0.interactionID == interactionID }) else { throw ServiceAPIError(code: .notFound, message: "Interaction not found") }
        guard current.state == .pending, current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Interaction revision is stale", currentRevision: current.revision) }
        if let expiresAt = current.expiresAt, expiresAt <= clock.now() { throw ServiceAPIError(code: .interactionSettled, message: "Interaction expired") }
        guard let interactionDelivery else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider interaction delivery is unavailable") }
        let intent = InteractionSnapshot(interactionID: current.interactionID, runID: current.runID, agentID: current.agentID, kind: current.kind, state: .deliveryIntent, payload: payload, revision: current.revision + 1, expiresAt: current.expiresAt)
        try await store.persistInteractionDeliveryState(intent, sessionID: sessionID, actor: actor)
        do {
            try await interactionDelivery.deliverAnswer(session: session, interaction: intent, answer: payload)
        } catch {
            let interrupted = InteractionSnapshot(interactionID: current.interactionID, runID: current.runID, agentID: current.agentID, kind: current.kind, state: .interrupted, payload: payload, revision: intent.revision + 1, expiresAt: current.expiresAt)
            try await store.persistInteractionDeliveryState(interrupted, sessionID: sessionID, actor: actor)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider interaction delivery was not acknowledged", retryable: false)
        }
        let resolved = InteractionSnapshot(interactionID: current.interactionID, runID: current.runID, agentID: current.agentID, kind: current.kind, state: .resolved, payload: payload, revision: intent.revision + 1, expiresAt: current.expiresAt)
        let event = try await store.persistInteraction(resolved, session: session, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return resolved
    }

    public func worktreeSnapshots(projectID: UUID) async throws -> [WorktreeBindingSnapshot] {
        _ = try await projects.authority(projectID: projectID)
        return try await store.worktrees(projectID: projectID)
    }

    public func worktreeSnapshot(projectID: UUID, bindingID: UUID) async throws -> WorktreeBindingSnapshot {
        _ = try await projects.authority(projectID: projectID)
        guard let binding = try await store.worktree(bindingID: bindingID), binding.projectID == projectID else {
            throw ServiceAPIError(code: .notFound, message: "Worktree binding not found")
        }
        return binding
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

    public func bindWorktree(sessionID: UUID, bindingID: UUID, expectedRevision: Int64, expectedSelectionBindingRevision: Int64, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> WorktreeBindingSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "bindWorktree", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: WorktreeBindingSnapshot = try await priorResult(idempotency) { return prior }
        guard let sessionAuthority = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        guard await sessionAuthority.activeBinding() == nil else { throw ServiceAPIError(code: .runAlreadyActive, message: "A worktree cannot be rebound while a run is active") }
        let session = await sessionAuthority.snapshot()
        guard let current = try await store.worktree(bindingID: bindingID), current.projectID == session.projectID else { throw ServiceAPIError(code: .notFound, message: "Worktree binding not found") }
        guard current.sessionID == nil || current.sessionID == sessionID else { throw ServiceAPIError(code: .worktreeConflict, message: "Worktree is owned by another session") }
        guard current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Worktree revision is stale", currentRevision: current.revision) }
        guard current.ownershipState == .active else { throw ServiceAPIError(code: .worktreeConflict, message: "Worktree is not active") }
        guard let selection = selections[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Selection not found") }
        let currentSelection = await selection.snapshot()
        guard currentSelection.bindingRevision == expectedSelectionBindingRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection binding revision is stale", currentRevision: currentSelection.bindingRevision) }
        let reboundSelection = SelectionSnapshot(sessionID: sessionID, entries: currentSelection.entries, revision: currentSelection.revision, bindingRevision: currentSelection.bindingRevision + 1)
        let rebound = WorktreeBindingSnapshot(bindingID: current.bindingID, projectID: current.projectID, rootID: current.rootID, sessionID: sessionID, baseRef: current.baseRef, branch: current.branch, physicalPath: current.physicalPath, ownershipState: current.ownershipState, mergeState: current.mergeState, revision: current.revision + 1)
        guard let idempotency else { throw ServiceAPIError(code: .invalidRequest, message: "Idempotency is required for worktree binding") }
        let events = try await store.persistWorktreeBinding(rebound, selection: reboundSelection, session: session, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        _ = try await selection.rebind(expectedBindingRevision: expectedSelectionBindingRevision)
        await eventHub.publish(events.worktree)
        await eventHub.publish(events.selection)
        return rebound
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

    public func artifactContent(sessionID: UUID, artifactID: UUID, range: Range<Int>?) async throws -> (ArtifactSnapshot, Data, Range<Int>) {
        guard let artifactService else { throw ServiceAPIError(code: .capabilityMissing, message: "Artifact storage is not configured") }
        guard let artifact = try await store.artifact(id: artifactID), artifact.snapshot.sessionID == sessionID else { throw ServiceAPIError(code: .notFound, message: "Artifact not found") }
        guard artifact.snapshot.retentionState == "active" else { throw ServiceAPIError(code: .resourceDeleted, message: "Artifact is no longer retained") }
        let size = Int(artifact.snapshot.size)
        let requested = range ?? 0 ..< size
        guard requested.lowerBound >= 0, requested.lowerBound < size || (size == 0 && requested.lowerBound == 0), requested.upperBound <= size, requested.lowerBound <= requested.upperBound, requested.count <= 8_388_608 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Artifact byte range is invalid or exceeds 8 MiB")
        }
        let complete = try await artifactService.content(storageReference: artifact.storageReference, maximumBytes: size)
        return (artifact.snapshot, Data(complete[requested]), requested)
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
            let entries = try await projectTree(projectID: project.projectID, request: .init(rootID: root.rootID, maximumDepth: 12, maximumEntries: min(max(input.budget, 100), 10000)))
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
        let chatID = input.chatID ?? ids.next()
        let priorChat: OracleChatState
        if let inputChatID = input.chatID {
            guard let stored = try await store.oracleChat(chatID: inputChatID), stored.sessionID == sessionID else { throw ServiceAPIError(code: .notFound, message: "Oracle chat not found for this session") }
            priorChat = stored
        } else {
            priorChat = OracleChatState(chatID: chatID, sessionID: sessionID, turns: [], revision: 0)
        }
        let history = priorChat.turns.suffix(20).map { "Human: \($0.prompt)\nOracle: \($0.response)" }.joined(separator: "\n\n")
        let prompt = """
        You are the RepoPrompt Oracle. Answer the request using the authoritative selected context. Clearly identify uncertainty.
        Request: \(input.prompt)
        Context mode: \(input.contextMode)

        Prior Oracle conversation:
        \(history.isEmpty ? "(new chat)" : history)

        \(context)
        """
        let response = try await providerAdapter.complete(kind: session.provider, model: session.model, prompt: prompt, workingDirectory: workingRoot.canonicalPath)
        let nextChat = OracleChatState(chatID: chatID, sessionID: sessionID, turns: priorChat.turns + [OracleChatTurn(prompt: input.prompt, response: response, timestamp: clock.now())], revision: priorChat.revision + 1)
        try await store.persistOracleChat(nextChat)
        let artifact = try await createArtifact(projectID: project.projectID, sessionID: sessionID, kind: "oracle", logicalName: "oracle-\(chatID.uuidString)-r\(nextChat.revision).md", content: Data(response.utf8), actor: actor)
        return OracleSnapshot(chatID: chatID, response: response, artifactID: artifact.artifactID, revision: nextChat.revision)
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
        let roots = await sessionSnapshots().filter { $0.parentSessionID == nil && [.preparing, .running, .waiting].contains($0.state) }
        for snapshot in roots {
            cancellationBarriers.insert(snapshot.rootSessionID)
            try await cancelDescendants(rootSessionID: snapshot.rootSessionID, excluding: snapshot.sessionID, actor: nil)
            guard let session = sessions[snapshot.sessionID], let binding = await session.activeBinding() else { continue }
            providerTasks[binding.runID]?.cancel()
            providerTasks[binding.runID] = nil
            try await providerAdapter?.cancel(runID: binding.runID)
            guard await session.settle(binding: binding, terminal: .sessionInterrupted, lifecycle: .interrupted) == .accepted else { continue }
            try await finishPersistedRun(sessionID: snapshot.sessionID, binding: binding, state: "interrupted", reason: "service-quiesce")
            let cursor = try await store.nextCursor()
            let event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionInterrupted, actor: nil, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(event)
            try await updateAgentLifecycle(sessionID: snapshot.sessionID, state: .interrupted, eventType: .agentFailed, actor: nil)
        }
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
            if entry.mode == .codeMap {
                let codeMap = try await projectCodeMap(projectID: projectID, request: .init(rootID: entry.rootID, logicalPath: entry.logicalPath))
                sections.append("## \(entry.logicalPath) [codemap:\(codeMap.status)]\n```\n\(codeMap.content)\n```")
                continue
            }
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
        guard let capability = await providerAdapter.capabilities().first(where: { $0.kind == snapshot.provider && $0.enabled }) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Session provider is unavailable") }
        let resumeMode: String = switch command {
        case let .resumeSession(_, mode): mode
        default: "fresh"
        }
        guard ["fresh", "resume", "auto"].contains(resumeMode) else { throw ServiceAPIError(code: .invalidRequest, message: "Unsupported provider resume mode") }
        let previousRun = try await store.latestRun(sessionID: sessionID)
        let resumeIdentity = resumeMode == "fresh" ? nil : previousRun?.providerSessionID
        if resumeMode == "resume", !capability.supportsResume || resumeIdentity == nil {
            throw ServiceAPIError(code: .resumeUnsupported, message: "No durable provider identity is available for native resume")
        }
        let binding = try await session.beginRun(connectionGeneration: snapshot.runGeneration + 1)
        let current = await session.snapshot()
        let cursor = try await store.nextCursor()
        let persisted = replacingCursor(current, cursor: cursor)
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(persisted, eventType: .sessionResumed, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        try await updateAgentLifecycle(sessionID: sessionID, state: .running, eventType: .agentUpdated, actor: actor)
        let run = ProviderRunSnapshot(runID: binding.runID, sessionID: sessionID, provider: snapshot.provider, providerSessionID: resumeIdentity, state: "running", generation: binding.generation, turnEpoch: binding.turnEpoch, startReason: resumeIdentity == nil ? "fresh" : "resume", startedAt: clock.now())
        try await store.persistRun(run)
        let project = try await projectSnapshot(projectID: snapshot.projectID)
        guard let workingDirectory = project.roots.first?.canonicalPath else { throw ServiceAPIError(code: .rootUnauthorized, message: "Project has no roots") }
        let prompt = snapshot.transcript.last(where: { $0.kind == .human })?.content ?? "Continue the repository task."
        providerTasks[binding.runID] = Task { await self.performProviderRun(sessionID: sessionID, binding: binding, run: run, prompt: prompt, workingDirectory: workingDirectory) }
        return receipt
    }

    private func steerProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, text: String, targetTurnEpoch: Int64, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        let binding = try await session.steer(text, actor: actor, targetTurnEpoch: targetTurnEpoch)
        providerTasks[binding.runID]?.cancel()
        try await providerAdapter?.cancel(runID: binding.runID)
        let current = await session.snapshot()
        let cursor = try await store.nextCursor()
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(replacingCursor(current, cursor: cursor), eventType: .sessionUpdated, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        let project = try await projectSnapshot(projectID: current.projectID)
        guard let workingDirectory = project.roots.first?.canonicalPath else { throw ServiceAPIError(code: .rootUnauthorized, message: "Project has no roots") }
        let run = await (try? store.latestRun(sessionID: sessionID)) ?? ProviderRunSnapshot(runID: binding.runID, sessionID: sessionID, provider: current.provider, state: "running", generation: binding.generation, turnEpoch: binding.turnEpoch, startReason: "steer", startedAt: clock.now())
        providerTasks[binding.runID] = Task { await self.performProviderRun(sessionID: sessionID, binding: binding, run: run, prompt: text, workingDirectory: workingDirectory) }
        return receipt
    }

    private func cancelProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, expectedRunID: UUID?, generation: Int64, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        guard let binding = await session.activeBinding(), binding.generation == generation, expectedRunID == nil || expectedRunID == binding.runID else { throw await ServiceAPIError(code: .staleRevision, message: "Run identity is stale", currentRevision: (session.snapshot()).runGeneration) }
        let rootSessionID = await (session.snapshot()).rootSessionID
        cancellationBarriers.insert(rootSessionID)
        try await cancelDescendants(rootSessionID: rootSessionID, excluding: sessionID, actor: actor)
        providerTasks[binding.runID]?.cancel()
        providerTasks[binding.runID] = nil
        try await providerAdapter?.cancel(runID: binding.runID)
        guard await session.settle(binding: binding, terminal: .sessionCanceled, lifecycle: .canceled) == .accepted else { throw ServiceAPIError(code: .staleRevision, message: "Run is already settled") }
        try await finishPersistedRun(sessionID: sessionID, binding: binding, state: "canceled", reason: "user-cancel")
        let cursor = try await store.nextCursor()
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionCanceled, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        try await updateAgentLifecycle(sessionID: sessionID, state: .canceled, eventType: .agentFailed, actor: actor)
        return receipt
    }

    private func cancelDescendants(rootSessionID: UUID, excluding rootID: UUID, actor: ExternalActor?) async throws {
        let snapshots = await sessionSnapshots().filter { $0.rootSessionID == rootSessionID && $0.sessionID != rootID }
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.sessionID, $0) })
        func depth(_ snapshot: SessionSnapshot) -> Int {
            var current = snapshot
            var result = 0
            while let parentID = current.parentSessionID, let parent = byID[parentID] {
                result += 1
                current = parent
            }
            return result
        }
        for snapshot in snapshots.sorted(by: { depth($0) > depth($1) }) {
            guard ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains(snapshot.state), let child = sessions[snapshot.sessionID] else { continue }
            if let binding = await child.activeBinding() {
                providerTasks[binding.runID]?.cancel()
                providerTasks[binding.runID] = nil
                try await providerAdapter?.cancel(runID: binding.runID)
                _ = await child.settle(binding: binding, terminal: .sessionCanceled, lifecycle: .canceled)
                try await finishPersistedRun(sessionID: snapshot.sessionID, binding: binding, state: "canceled", reason: "root-cancel")
            } else {
                try await child.cancelWithoutActiveRun()
            }
            let cursor = try await store.nextCursor()
            let updated = await replacingCursor(child.snapshot(), cursor: cursor)
            let sessionEvent = try await store.persistSession(updated, eventType: .sessionCanceled, actor: actor, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(sessionEvent)
            if let currentAgent = agents[snapshot.sessionID] {
                let canceledAgent = AgentSnapshot(agentID: currentAgent.agentID, sessionID: currentAgent.sessionID, rootSessionID: currentAgent.rootSessionID, parentAgentID: currentAgent.parentAgentID, providerNativeIdentity: currentAgent.providerNativeIdentity, role: currentAgent.role, label: currentAgent.label, state: .canceled, revision: currentAgent.revision + 1)
                let agentEvent = try await store.persistAgent(canceledAgent, projectID: snapshot.projectID, actor: actor, correlationID: ids.next(), eventType: .agentFailed)
                agents[snapshot.sessionID] = canceledAgent
                await eventHub.publish(agentEvent)
            }
        }
    }

    private func performProviderRun(sessionID: UUID, binding: RunBindingIdentity, run: ProviderRunSnapshot, prompt: String, workingDirectory: String) async {
        guard let providerAdapter, let session = sessions[sessionID] else { return }
        let initial = await session.snapshot()
        do {
            let result = try await providerAdapter.execute(kind: initial.provider, model: initial.model, prompt: prompt, workingDirectory: workingDirectory, runID: binding.runID, resumeProviderSessionID: run.providerSessionID)
            let durableIdentity = result.providerSessionID ?? run.providerSessionID
            if let durableIdentity { try await updateAgentProviderIdentity(sessionID: sessionID, providerSessionID: durableIdentity) }
            guard !Task.isCancelled, await session.acceptProviderOutput(binding: binding, kind: .assistant, content: result.output) == .accepted else { return }
            var cursor = try await store.nextCursor()
            var event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .transcriptMessage, actor: nil, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(event)
            guard await session.settle(binding: binding, terminal: .sessionCompleted, lifecycle: .completed) == .accepted else { return }
            cursor = try await store.nextCursor()
            event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionCompleted, actor: nil, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(event)
            try await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: durableIdentity, state: "completed", generation: run.generation, turnEpoch: binding.turnEpoch, startReason: run.startReason, endReason: "completed", startedAt: run.startedAt, endedAt: clock.now()))
            try await updateAgentLifecycle(sessionID: sessionID, state: .completed, eventType: .agentCompleted, actor: nil)
        } catch {
            guard await session.settle(binding: binding, terminal: .sessionFailed, lifecycle: .failed) == .accepted else { return }
            if let cursor = try? await store.nextCursor(), let event = try? await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionFailed, actor: nil, correlationID: ids.next(), idempotency: nil) {
                await eventHub.publish(event)
            }
            try? await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: run.providerSessionID, state: "failed", generation: run.generation, turnEpoch: binding.turnEpoch, startReason: run.startReason, endReason: error is CancellationError ? "canceled" : "provider-error", startedAt: run.startedAt, endedAt: clock.now()))
            try? await updateAgentLifecycle(sessionID: sessionID, state: .failed, eventType: .agentFailed, actor: nil)
        }
        providerTasks[binding.runID] = nil
    }

    private func updateAgentLifecycle(sessionID: UUID, state: SessionLifecycleState, eventType: EventType, actor: ExternalActor?) async throws {
        guard let current = agents[sessionID], current.state != state else { return }
        let updated = AgentSnapshot(agentID: current.agentID, sessionID: current.sessionID, rootSessionID: current.rootSessionID, parentAgentID: current.parentAgentID, providerNativeIdentity: current.providerNativeIdentity, role: current.role, label: current.label, state: state, revision: current.revision + 1)
        let session = try await sessionSnapshot(sessionID: sessionID)
        let event = try await store.persistAgent(updated, projectID: session.projectID, actor: actor, correlationID: ids.next(), eventType: eventType)
        agents[sessionID] = updated
        await eventHub.publish(event)
    }

    private func updateAgentProviderIdentity(sessionID: UUID, providerSessionID: String) async throws {
        guard let current = agents[sessionID], current.providerNativeIdentity != providerSessionID else { return }
        let updated = AgentSnapshot(agentID: current.agentID, sessionID: current.sessionID, rootSessionID: current.rootSessionID, parentAgentID: current.parentAgentID, providerNativeIdentity: providerSessionID, role: current.role, label: current.label, state: current.state, revision: current.revision + 1)
        let session = try await sessionSnapshot(sessionID: sessionID)
        let event = try await store.persistAgent(updated, projectID: session.projectID, actor: nil, correlationID: ids.next(), eventType: .agentUpdated)
        agents[sessionID] = updated
        await eventHub.publish(event)
    }

    private func finishPersistedRun(sessionID: UUID, binding: RunBindingIdentity, state: String, reason: String) async throws {
        guard let run = try await store.latestRun(sessionID: sessionID), run.runID == binding.runID else { return }
        try await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: run.providerSessionID, state: state, generation: run.generation, turnEpoch: binding.turnEpoch, startReason: run.startReason, endReason: reason, startedAt: run.startedAt, endedAt: clock.now()))
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: value.state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }

    private func replacingLifecycle(_ value: SessionSnapshot, state: SessionLifecycleState, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision + 1, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }
}
