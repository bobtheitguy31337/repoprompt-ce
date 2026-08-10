import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public actor RepoPromptHeadlessAuthority {
    private struct InFlightProjectSourceOperation {
        let requestDigest: String
        var waiters: [UUID: CheckedContinuation<ProjectSourceOperationWireSnapshot, Error>]
    }

    private let store: SQLiteServiceStore
    private let clock: any RuntimeClock
    private let ids: any RuntimeIDGenerator
    private let filesystem: any FilesystemAuthorityPort
    private let commandRunner: any WorkspaceCommandRunning
    private let worktreeService: WorktreeRuntimeService?
    private let artifactService: ArtifactRuntimeService?
    private let providerAdapter: (any AgentProviderDispatcher)?
    private let interactionDelivery: (any InteractionDeliveryPort)?
    private let contextBuilderRuntime: (any ContextBuilderRuntimeService)?
    private let oracleRuntime: (any OracleRuntimeService)?
    private let projectSourceService: ProjectSourceProvisioningService?
    private let workflowCatalog = BuiltinWorkflowCatalog()
    private let projects = ProjectRuntimeSupervisor()
    private let eventHub = ServiceEventHub()
    private var sessions: [UUID: SessionAuthority] = [:]
    private var agents: [UUID: AgentSnapshot] = [:]
    private var tools: [UUID: ProjectToolAuthority] = [:]
    private var selections: [UUID: SessionSelectionAuthority] = [:]
    private var providerTasks: [UUID: Task<Void, Never>] = [:]
    private var providerToolInvocations: [UUID: [String: ToolInvocationSnapshot]] = [:]
    private var providerControlReadyRuns: Set<UUID> = []
    private var cancellationBarriers: Set<UUID> = []
    private var inFlightProjectSourceOperations: [String: InFlightProjectSourceOperation] = [:]
    private var projectRepositoryMutationBarriers: Set<UUID> = []
    private var quiescing = false

    public init(
        store: SQLiteServiceStore,
        clock: any RuntimeClock = SystemRuntimeClock(),
        ids: any RuntimeIDGenerator = SystemRuntimeIDGenerator(),
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        commandRunner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        worktreeService: WorktreeRuntimeService? = nil,
        artifactService: ArtifactRuntimeService? = nil,
        providerAdapter: (any AgentProviderDispatcher)? = nil,
        interactionDelivery: (any InteractionDeliveryPort)? = nil,
        contextBuilderRuntime: (any ContextBuilderRuntimeService)? = nil,
        oracleRuntime: (any OracleRuntimeService)? = nil,
        projectSourceService: ProjectSourceProvisioningService? = nil
    ) {
        self.store = store
        self.clock = clock
        self.ids = ids
        self.filesystem = filesystem
        self.commandRunner = commandRunner
        self.worktreeService = worktreeService
        self.artifactService = artifactService
        self.providerAdapter = providerAdapter
        self.interactionDelivery = interactionDelivery ?? (providerAdapter as? any InteractionDeliveryPort)
        self.contextBuilderRuntime = contextBuilderRuntime ?? providerAdapter.map { ProviderContextBuilderRuntimeService(providers: $0) }
        self.oracleRuntime = oracleRuntime ?? providerAdapter.map { ProviderOracleRuntimeService(providers: $0) }
        self.projectSourceService = projectSourceService
    }

    public func recover() async throws {
        let unclean = try await !(store.metadata().lastCleanShutdown)
        try await providerAdapter?.recoverProcessFamilies()
        for snapshot in try await store.allProjects() {
            let persistedIdentities = try await store.projectRootIdentities(projectID: snapshot.projectID)
            let roots = snapshot.roots.map { root in
                let persisted = persistedIdentities[root.rootID]
                let identity = if let persisted, !["pending", "legacy-import"].contains(persisted) {
                    persisted
                } else {
                    (try? filesystem.canonicalizeRoot(root.canonicalPath).identity) ?? "unavailable"
                }
                return CanonicalRoot(snapshot: root, filesystemIdentity: identity)
            }
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
            try await store.installInitialPolicies(
                permissions: ExecutionPermissionSnapshot(sessionID: snapshot.sessionID, mode: "workspaceWrite", providerSettings: [:], revision: 1, updatedActor: snapshot.creator),
                collaboration: CollaborationMetadataSnapshot(sessionID: snapshot.sessionID, visibility: snapshot.visibility, collaborativeSteeringEnabled: false, controllerUserID: snapshot.creator.goblinUserID, policyRevision: 1, controllerRevision: 1, membershipRevision: 1)
            )
        }
        for agent in try await store.agents() {
            agents[agent.sessionID] = agent
        }
        for snapshot in try await sessionSnapshots() where agents[snapshot.sessionID] == nil {
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
        let projectName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, projectName.utf8.count <= 200,
              projectName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw ServiceAPIError(code: .invalidRequest, message: "Project name is invalid") }
        let projectID = ids.next()
        var canonicalRoots: [CanonicalRoot] = []
        var seenIdentities = Set<String>()
        for root in input.roots {
            let canonical = try filesystem.canonicalizeRoot(root.path)
            guard seenIdentities.insert(canonical.identity).inserted else { throw ServiceAPIError(code: .invalidRequest, message: "Duplicate physical project root") }
            canonicalRoots.append(CanonicalRoot(snapshot: ProjectRootSnapshot(rootID: ids.next(), logicalName: root.logicalName, canonicalPath: canonical.path, writable: root.writable), filesystemIdentity: canonical.identity))
        }
        let cursor = try await store.nextCursor()
        let snapshot = ProjectSnapshot(projectID: projectID, name: projectName, creator: externalActor, state: .active, roots: canonicalRoots.map(\.snapshot), revision: 1, cursor: cursor)
        let event = try await store.persistProject(snapshot, rootIdentities: Dictionary(uniqueKeysWithValues: canonicalRoots.map { ($0.snapshot.rootID, $0.filesystemIdentity) }), eventType: .projectCreated, actor: externalActor, correlationID: ids.next(), idempotency: idempotency)
        let project = ProjectAuthority(snapshot: snapshot, roots: canonicalRoots)
        await projects.install(project)
        tools[projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
        await eventHub.publish(event)
        return snapshot
    }

    public func projectSourceCapabilities() async -> ProjectSourceCapabilities? {
        await projectSourceService?.capabilities()
    }

    public func createProjectFromSource(
        input: ProjectSourceOperationInput,
        externalActor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> ProjectSourceOperationWireSnapshot {
        let scope = externalActor.goblinUserID + "\u{0}" + idempotencyKey
        if var existing = inFlightProjectSourceOperations[scope] {
            guard existing.requestDigest == requestDigest else {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Idempotency key was reused with a different request")
            }
            let waiterID = UUID()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    existing.waiters[waiterID] = continuation
                    inFlightProjectSourceOperations[scope] = existing
                }
            }, onCancel: {
                Task { await self.cancelProjectSourceWaiter(scope: scope, waiterID: waiterID) }
            })
        }
        inFlightProjectSourceOperations[scope] = .init(requestDigest: requestDigest, waiters: [:])
        do {
            let result = try await performCreateProjectFromSource(
                input: input,
                externalActor: externalActor,
                idempotencyKey: idempotencyKey,
                requestDigest: requestDigest
            )
            let waiters = inFlightProjectSourceOperations.removeValue(forKey: scope)?.waiters ?? [:]
            waiters.values.forEach { $0.resume(returning: result) }
            return result
        } catch {
            let waiters = inFlightProjectSourceOperations.removeValue(forKey: scope)?.waiters ?? [:]
            waiters.values.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func cancelProjectSourceWaiter(scope: String, waiterID: UUID) {
        guard var flight = inFlightProjectSourceOperations[scope],
              let waiter = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        inFlightProjectSourceOperations[scope] = flight
        waiter.resume(throwing: CancellationError())
    }

    private func performCreateProjectFromSource(
        input: ProjectSourceOperationInput,
        externalActor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> ProjectSourceOperationWireSnapshot {
        try ensureWritable()
        guard let projectSourceService else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Project source operations are not configured")
        }
        let idempotency = IdempotencyInput(
            actorID: externalActor.goblinUserID,
            operation: "createProjectFromSource",
            key: idempotencyKey,
            requestDigest: requestDigest
        )
        if let existing = try await store.idempotencyResult(idempotency) {
            let snapshot = try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: existing.response)
            return ProjectSourceOperationWireSnapshot(
                operationID: input.operationID,
                projectID: snapshot.projectID,
                state: .completed,
                progressRevision: 4,
                messageCode: "project_source_completed",
                project: ProjectWireSnapshot(snapshot)
            )
        }

        let projectID = ids.next()
        let rootID = ids.next()
        func progress(_ state: ProjectSourceOperationState, revision: Int64, code: String, error: ServiceErrorCode? = nil) async {
            let snapshot = ProjectSourceOperationWireSnapshot(
                operationID: input.operationID,
                projectID: projectID,
                state: state,
                progressRevision: revision,
                messageCode: code,
                errorCode: error
            )
            guard let payload = try? JSONEncoder.serviceEncoder.encode(snapshot),
                  let event = try? await store.persistServiceDiagnostic(
                      projectID: projectID,
                      actor: externalActor,
                      correlationID: input.operationID,
                      payload: payload
                  )
            else { return }
            await eventHub.publish(event)
        }

        await progress(.validating, revision: 1, code: "project_source_validating")
        do {
            switch input.source {
            case .configuredRoot:
                await progress(.validating, revision: 2, code: "project_source_connecting")
            case .gitClone:
                await progress(.cloning, revision: 2, code: "project_source_cloning")
            }
            let root = try await projectSourceService.provision(input: input, projectID: projectID, rootID: rootID)
            await progress(.promoting, revision: 3, code: "project_source_promoting")
            let cursor = try await store.nextCursor()
            let snapshot = ProjectSnapshot(
                projectID: projectID,
                name: input.name.trimmingCharacters(in: .whitespacesAndNewlines),
                creator: externalActor,
                state: .active,
                roots: [root.snapshot],
                revision: 1,
                cursor: cursor
            )
            let event = try await store.persistProject(
                snapshot,
                rootIdentities: [root.snapshot.rootID: root.filesystemIdentity],
                eventType: .projectCreated,
                actor: externalActor,
                correlationID: input.operationID,
                idempotency: idempotency
            )
            let project = ProjectAuthority(snapshot: snapshot, roots: [root])
            await projects.install(project)
            tools[projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
            await eventHub.publish(event)
            await progress(.completed, revision: 4, code: "project_source_completed")
            return ProjectSourceOperationWireSnapshot(
                operationID: input.operationID,
                projectID: projectID,
                state: .completed,
                progressRevision: 4,
                messageCode: "project_source_completed",
                project: ProjectWireSnapshot(snapshot)
            )
        } catch {
            await projectSourceService.abandonProvisionedClone(projectID: projectID)
            let code = (error as? ServiceAPIError)?.code ?? .dependencyUnavailable
            await progress(.failed, revision: 4, code: "project_source_failed", error: code)
            throw error
        }
    }

    public func addProjectRepository(
        projectID: UUID,
        input: AddProjectRepositoryInput,
        externalActor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> ProjectSourceOperationWireSnapshot {
        let scope = projectID.uuidString + "\u{0}" + externalActor.goblinUserID + "\u{0}" + idempotencyKey
        if var existing = inFlightProjectSourceOperations[scope] {
            guard existing.requestDigest == requestDigest else {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Idempotency key was reused with a different request")
            }
            let waiterID = UUID()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    existing.waiters[waiterID] = continuation
                    inFlightProjectSourceOperations[scope] = existing
                }
            }, onCancel: {
                Task { await self.cancelProjectSourceWaiter(scope: scope, waiterID: waiterID) }
            })
        }
        inFlightProjectSourceOperations[scope] = .init(requestDigest: requestDigest, waiters: [:])
        do {
            let result = try await performAddProjectRepository(
                projectID: projectID,
                input: input,
                externalActor: externalActor,
                idempotencyKey: idempotencyKey,
                requestDigest: requestDigest
            )
            let waiters = inFlightProjectSourceOperations.removeValue(forKey: scope)?.waiters ?? [:]
            waiters.values.forEach { $0.resume(returning: result) }
            return result
        } catch {
            let waiters = inFlightProjectSourceOperations.removeValue(forKey: scope)?.waiters ?? [:]
            waiters.values.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func performAddProjectRepository(
        projectID: UUID,
        input: AddProjectRepositoryInput,
        externalActor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> ProjectSourceOperationWireSnapshot {
        try ensureWritable()
        guard let projectSourceService else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Project source operations are not configured")
        }
        let idempotency = IdempotencyInput(
            actorID: externalActor.goblinUserID,
            operation: "addProjectRepository:\(projectID.uuidString)",
            key: idempotencyKey,
            requestDigest: requestDigest
        )
        if let existing = try await store.idempotencyResult(idempotency) {
            return try JSONDecoder.serviceDecoder.decode(ProjectSourceOperationWireSnapshot.self, from: existing.response)
        }

        let logicalName = input.logicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.schemaVersion == 1, input.expectedRevision >= 1,
              !logicalName.isEmpty, logicalName.utf8.count <= 128,
              logicalName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw ServiceAPIError(code: .invalidRequest, message: "Repository addition is invalid") }
        let initial = try await projectSnapshot(projectID: projectID)
        guard initial.revision == input.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: initial.revision)
        }
        guard !initial.roots.contains(where: { $0.logicalName == logicalName }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Repository logical name is already in use")
        }
        try await ensureProjectHasNoActiveProviderRun(projectID: projectID)
        guard projectRepositoryMutationBarriers.insert(projectID).inserted else {
            throw ServiceAPIError(code: .runAlreadyActive, message: "A repository mutation is already active for this project")
        }
        defer { projectRepositoryMutationBarriers.remove(projectID) }

        let operationID = ids.next()
        let rootID = ids.next()
        func progress(_ state: ProjectSourceOperationState, revision: Int64, code: String, error: ServiceErrorCode? = nil) async {
            let snapshot = ProjectSourceOperationWireSnapshot(
                operationID: operationID,
                projectID: projectID,
                state: state,
                progressRevision: revision,
                messageCode: code,
                errorCode: error
            )
            guard let payload = try? JSONEncoder.serviceEncoder.encode(snapshot),
                  let event = try? await store.persistServiceDiagnostic(
                      projectID: projectID,
                      actor: externalActor,
                      correlationID: operationID,
                      payload: payload
                  )
            else { return }
            await eventHub.publish(event)
        }

        await progress(.validating, revision: 1, code: "project_repository_validating")
        do {
            await progress(.cloning, revision: 2, code: "project_repository_cloning")
            let root = try await projectSourceService.provisionRepository(
                input: input,
                operationID: operationID,
                projectID: projectID,
                rootID: rootID
            )
            await progress(.promoting, revision: 3, code: "project_repository_promoting")
            let current = try await projectSnapshot(projectID: projectID)
            try await ensureProjectHasNoActiveProviderRun(projectID: projectID)
            guard current.revision == input.expectedRevision else {
                throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: current.revision)
            }
            guard !current.roots.contains(where: { $0.logicalName == logicalName || $0.canonicalPath == root.snapshot.canonicalPath }) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Repository root is already attached")
            }
            var identities = try await store.projectRootIdentities(projectID: projectID)
            identities[rootID] = root.filesystemIdentity
            let cursor = try await store.nextCursor()
            let snapshot = ProjectSnapshot(
                projectID: projectID,
                name: current.name,
                creator: current.creator,
                state: .active,
                roots: current.roots + [root.snapshot],
                revision: current.revision + 1,
                cursor: cursor
            )
            let result = ProjectSourceOperationWireSnapshot(
                operationID: operationID,
                projectID: projectID,
                state: .completed,
                progressRevision: 4,
                messageCode: "project_repository_completed",
                project: ProjectWireSnapshot(snapshot)
            )
            let event = try await store.persistProject(
                snapshot,
                rootIdentities: identities,
                eventType: .projectUpdated,
                actor: externalActor,
                correlationID: operationID,
                idempotency: idempotency,
                expectedRevision: input.expectedRevision,
                idempotencyResponse: JSONEncoder.serviceEncoder.encode(result),
                idempotencyStatus: 201
            )
            let canonicalRoots = try snapshot.roots.map { snapshotRoot -> CanonicalRoot in
                guard let identity = identities[snapshotRoot.rootID] else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Project root identity is unavailable")
                }
                return CanonicalRoot(snapshot: snapshotRoot, filesystemIdentity: identity)
            }
            let project = ProjectAuthority(snapshot: snapshot, roots: canonicalRoots)
            await projects.install(project)
            tools[projectID] = ProjectToolAuthority(project: project, filesystem: filesystem, commandRunner: commandRunner)
            await eventHub.publish(event)
            await progress(.completed, revision: 4, code: "project_repository_completed")
            return result
        } catch {
            await projectSourceService.abandonProvisionedRepository(rootID: rootID)
            let code = (error as? ServiceAPIError)?.code ?? .dependencyUnavailable
            await progress(.failed, revision: 4, code: "project_repository_failed", error: code)
            throw error
        }
    }

    public func renameProject(
        projectID: UUID,
        input: RenameProjectInput,
        actor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> ProjectSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "renameProject", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) {
            return try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: existing.response)
        }
        let current = try await projectSnapshot(projectID: projectID)
        guard current.revision == input.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: current.revision)
        }
        let projectName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, projectName.utf8.count <= 200,
              projectName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw ServiceAPIError(code: .invalidRequest, message: "Project name is invalid") }
        let cursor = try await store.nextCursor()
        let snapshot = ProjectSnapshot(
            projectID: projectID,
            name: projectName,
            creator: current.creator,
            state: current.state,
            roots: current.roots,
            revision: current.revision + 1,
            cursor: cursor
        )
        let event = try await store.persistProject(
            snapshot,
            eventType: .projectUpdated,
            actor: actor,
            correlationID: ids.next(),
            idempotency: idempotency,
            expectedRevision: input.expectedRevision
        )
        let identities = try await store.projectRootIdentities(projectID: projectID)
        let roots = snapshot.roots.compactMap { root in identities[root.rootID].map { CanonicalRoot(snapshot: root, filesystemIdentity: $0) } }
        let project = ProjectAuthority(snapshot: snapshot, roots: roots)
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
        let projectName = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, projectName.utf8.count <= 200,
              projectName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw ServiceAPIError(code: .invalidRequest, message: "Project name is invalid") }
        let activeSessions = try await sessionSnapshots().filter { $0.projectID == projectID && ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains($0.state) }
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
        let snapshot = ProjectSnapshot(projectID: projectID, name: projectName, creator: current.creator, state: .active, roots: canonicalRoots.map(\.snapshot), revision: current.revision + 1, cursor: cursor)
        let event = try await store.persistProject(snapshot, rootIdentities: Dictionary(uniqueKeysWithValues: canonicalRoots.map { ($0.snapshot.rootID, $0.filesystemIdentity) }), eventType: .projectUpdated, actor: actor, correlationID: ids.next(), idempotency: idempotency)
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
        let activeSessions = try await sessionSnapshots().filter { $0.projectID == projectID && ![SessionLifecycleState.completed, .failed, .canceled, .archived].contains($0.state) }
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
        guard input.parentSessionID == nil else {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Child sessions must be created through the authority-managed agent lifecycle")
        }
        let frozenInput = try input.frozenForExecution()
        let created = try await createAuthoritySession(input: frozenInput, externalActor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
        guard frozenInput.hasInitialProviderIntent, let session = sessions[created.sessionID] else { return created }
        let current = await session.snapshot()
        guard current.state == .idle else { return current }
        let command = SessionCommand.resumeSession(expectedRunID: nil, providerResumeMode: .fresh)
        let initialRun = IdempotencyInput(
            actorID: externalActor.goblinUserID,
            operation: command.operation,
            key: "\(idempotencyKey):initial-run",
            requestDigest: requestDigest
        )
        if try await store.idempotencyResult(initialRun) == nil {
            _ = try await startProviderRun(command: command, sessionID: created.sessionID, session: session, actor: externalActor, idempotency: initialRun)
        }
        return try await sessionSnapshot(sessionID: created.sessionID)
    }

    /// Admits a legacy embedded-host identity into the durable authority. This
    /// is intentionally exact-ID: macOS JSON sessions keep their public links,
    /// while subsequent lifecycle, transcript, policy, interaction and
    /// worktree mutations have only one owner.
    @discardableResult
    public func ensureEmbeddedSession(_ seed: EmbeddedSessionSeed) async throws -> AuthoritySessionSnapshot {
        try ensureWritable()
        let isInitialImport = sessions[seed.sessionID] == nil
        if isInitialImport {
            if let existingProject = await projectSnapshots().first(where: { $0.projectID == seed.projectID }) {
                guard Set(existingProject.roots.map(\.canonicalPath)) == Set(seed.roots.map(\.canonicalPath)) else {
                    throw ServiceAPIError(code: .worktreeConflict, message: "Embedded project identity is already bound to different roots")
                }
            } else {
                var canonicalRoots: [CanonicalRoot] = []
                var identities = Set<String>()
                for root in seed.roots {
                    let canonical = try filesystem.canonicalizeRoot(root.canonicalPath)
                    guard identities.insert(canonical.identity).inserted else {
                        throw ServiceAPIError(code: .invalidRequest, message: "Duplicate physical project root")
                    }
                    canonicalRoots.append(CanonicalRoot(
                        snapshot: ProjectRootSnapshot(
                            rootID: root.rootID,
                            logicalName: root.logicalName,
                            canonicalPath: canonical.path,
                            writable: root.writable,
                            revision: root.revision
                        ),
                        filesystemIdentity: canonical.identity
                    ))
                }
                let cursor = try await store.nextCursor()
                let project = ProjectSnapshot(
                    projectID: seed.projectID,
                    name: seed.projectName,
                    creator: seed.creator,
                    state: .active,
                    roots: canonicalRoots.map(\.snapshot),
                    revision: 1,
                    cursor: cursor
                )
                let event = try await store.persistProject(
                    project,
                    rootIdentities: Dictionary(uniqueKeysWithValues: canonicalRoots.map { ($0.snapshot.rootID, $0.filesystemIdentity) }),
                    eventType: .projectCreated,
                    actor: seed.creator,
                    correlationID: ids.next(),
                    idempotency: nil
                )
                let projectAuthority = ProjectAuthority(snapshot: project, roots: canonicalRoots)
                await projects.install(projectAuthority)
                tools[seed.projectID] = ProjectToolAuthority(project: projectAuthority, filesystem: filesystem, commandRunner: commandRunner)
                await eventHub.publish(event)
            }

            if let parentSessionID = seed.parentSessionID {
                guard sessions[parentSessionID] != nil else {
                    throw ServiceAPIError(code: .notFound, message: "Embedded parent session must be admitted before its child")
                }
            }
            let cursor = try await store.nextCursor()
            let snapshot = SessionSnapshot(
                sessionID: seed.sessionID,
                projectID: seed.projectID,
                parentSessionID: seed.parentSessionID,
                rootSessionID: seed.rootSessionID,
                creator: seed.creator,
                provider: seed.provider,
                model: seed.model,
                visibility: seed.visibility,
                state: .idle,
                runGeneration: 0,
                turnEpoch: 0,
                revision: 1,
                transcript: seed.transcript,
                interactions: [],
                cursor: cursor
            )
            let agent = AgentSnapshot(
                agentID: seed.sessionID,
                sessionID: seed.sessionID,
                rootSessionID: seed.rootSessionID,
                parentAgentID: seed.parentSessionID,
                role: seed.parentSessionID == nil ? "root" : "child",
                state: .idle,
                revision: 1
            )
            let permissions = ExecutionPermissionSnapshot(
                sessionID: seed.sessionID,
                mode: seed.permissionMode,
                providerSettings: seed.providerSettings,
                revision: 1,
                updatedActor: seed.creator
            )
            let collaboration = CollaborationMetadataSnapshot(
                sessionID: seed.sessionID,
                visibility: seed.visibility,
                collaborativeSteeringEnabled: false,
                controllerUserID: seed.creator.goblinUserID,
                policyRevision: 1,
                controllerRevision: 1,
                membershipRevision: 1
            )
            let initialSelection = SelectionSnapshot(sessionID: seed.sessionID, entries: [], revision: 1)
            let key = "embedded-import:\(seed.sessionID.uuidString)"
            let idempotency = IdempotencyInput(
                actorID: seed.creator.goblinUserID,
                operation: "embeddedSessionImport",
                key: key,
                requestDigest: CanonicalSigning.bodyDigest(Data(key.utf8))
            )
            let events = try await store.persistNewSession(
                snapshot,
                agent: agent,
                actor: seed.creator,
                correlationID: ids.next(),
                agentCorrelationID: ids.next(),
                idempotency: idempotency,
                initialSelection: initialSelection,
                initialPermissions: permissions,
                initialCollaboration: collaboration
            )
            sessions[seed.sessionID] = SessionAuthority(snapshot: snapshot, clock: clock, ids: ids)
            agents[seed.sessionID] = agent
            selections[seed.sessionID] = SessionSelectionAuthority(sessionID: seed.sessionID, template: [], revision: 1, bindingRevision: 1)
            await eventHub.publish(events.session)
            await eventHub.publish(events.agent)
        }

        // Legacy JSON is imported exactly once. Existing durable sessions are
        // never refreshed from UI-owned transcript, permission, interaction,
        // or worktree properties.
        if isInitialImport {
            for binding in seed.worktrees {
                guard binding.projectID == seed.projectID, binding.sessionID == seed.sessionID else {
                    throw ServiceAPIError(code: .worktreeConflict, message: "Embedded worktree binding does not belong to the admitted session")
                }
                let event = try await store.persistWorktree(binding, actor: seed.creator, correlationID: ids.next())
                await eventHub.publish(event)
            }
        }
        return try await authoritySessionSnapshot(sessionID: seed.sessionID)
    }

    /// Appends one human turn and launches it through the same provider
    /// dispatcher used by the Linux service. The authority assigns the run,
    /// generation, turn epoch, transcript ID, and terminal fence.
    public func startEmbeddedProviderRun(
        sessionID: UUID,
        actor: ExternalActor,
        userMessage: String,
        providerPrompt: String,
        presentationPayload: Data? = nil,
        resumeMode: ProviderResumeMode = .auto,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> AuthoritySessionSnapshot {
        try ensureWritable()
        guard let session = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Session not found")
        }
        let before = await session.snapshot()
        try await session.appendHumanMessage(
            userMessage,
            actor: actor,
            expectedRevision: before.revision,
            presentationPayload: presentationPayload
        )
        let cursor = try await store.nextCursor()
        let transcriptEvent = try await store.persistSession(
            replacingCursor(await session.snapshot(), cursor: cursor),
            eventType: .transcriptMessage,
            actor: actor,
            correlationID: ids.next(),
            idempotency: nil
        )
        await eventHub.publish(transcriptEvent)
        let command = SessionCommand.resumeSession(expectedRunID: nil, providerResumeMode: resumeMode)
        let idempotency = IdempotencyInput(
            actorID: actor.goblinUserID,
            operation: "embeddedProviderRun",
            key: idempotencyKey,
            requestDigest: requestDigest
        )
        _ = try await startProviderRun(
            command: command,
            sessionID: sessionID,
            session: session,
            actor: actor,
            idempotency: idempotency,
            providerPrompt: providerPrompt
        )
        return try await authoritySessionSnapshot(sessionID: sessionID)
    }

    public func steerEmbeddedProviderRun(
        sessionID: UUID,
        text: String,
        targetTurnEpoch: Int64,
        actor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> AuthoritySessionSnapshot {
        guard let session = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Session not found")
        }
        let command = SessionCommand.steerSession(text: text, targetTurnEpoch: targetTurnEpoch)
        _ = try await steerProviderRun(
            command: command,
            sessionID: sessionID,
            session: session,
            text: text,
            targetTurnEpoch: targetTurnEpoch,
            actor: actor,
            idempotency: .init(
                actorID: actor.goblinUserID,
                operation: command.operation,
                key: idempotencyKey,
                requestDigest: requestDigest
            )
        )
        return try await authoritySessionSnapshot(sessionID: sessionID)
    }

    public func cancelEmbeddedProviderRun(
        sessionID: UUID,
        binding: RunBindingSnapshot,
        actor: ExternalActor,
        idempotencyKey: String,
        requestDigest: String
    ) async throws -> AuthoritySessionSnapshot {
        guard let session = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Session not found")
        }
        let command = SessionCommand.cancelSession(
            expectedRunID: binding.runID,
            expectedGeneration: binding.generation
        )
        _ = try await cancelProviderRun(
            command: command,
            sessionID: sessionID,
            session: session,
            expectedRunID: binding.runID,
            generation: binding.generation,
            actor: actor,
            idempotency: .init(
                actorID: actor.goblinUserID,
                operation: command.operation,
                key: idempotencyKey,
                requestDigest: requestDigest
            )
        )
        return try await authoritySessionSnapshot(sessionID: sessionID)
    }

    public func authoritySessionSnapshot(sessionID: UUID) async throws -> AuthoritySessionSnapshot {
        guard let sessionAuthority = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Session not found")
        }
        let session = try await sessionSnapshot(sessionID: sessionID)
        guard let permissions = try await store.permissions(sessionID: sessionID) else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Session permissions are missing")
        }
        let binding = await sessionAuthority.activeBinding()
        let run = try await store.latestRun(sessionID: sessionID)
        let worktrees = try await store.worktrees(projectID: session.projectID).filter { $0.sessionID == sessionID }
        return AuthoritySessionSnapshot(
            session: session,
            activeRun: run,
            activeBinding: binding.map(Self.bindingSnapshot),
            permissions: permissions,
            interactions: try await store.interactions(sessionID: sessionID),
            worktrees: worktrees
        )
    }

    private func createAuthoritySession(input: CreateSessionInput, externalActor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> SessionSnapshot {
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
        let permissions = ExecutionPermissionSnapshot(sessionID: sessionID, mode: "workspaceWrite", providerSettings: [:], revision: 1, updatedActor: externalActor)
        let collaboration = CollaborationMetadataSnapshot(sessionID: sessionID, visibility: input.visibility, collaborativeSteeringEnabled: false, controllerUserID: externalActor.goblinUserID, policyRevision: 1, controllerRevision: 1, membershipRevision: 1)
        let events = try await store.persistNewSession(snapshot, agent: agent, actor: externalActor, correlationID: ids.next(), agentCorrelationID: ids.next(), idempotency: idempotency, initialSelection: seededSelection, initialPermissions: permissions, initialCollaboration: collaboration)
        sessions[sessionID] = SessionAuthority(snapshot: snapshot, clock: clock, ids: ids)
        agents[sessionID] = agent
        selections[sessionID] = SessionSelectionAuthority(sessionID: sessionID, template: seededSelection.entries, revision: seededSelection.revision, bindingRevision: seededSelection.bindingRevision)
        await eventHub.publish(events.session)
        await eventHub.publish(events.agent)
        if input.parentSessionID == nil, let worktreeService {
            let project = try await projectSnapshot(projectID: input.projectID)
            if let root = project.roots.first(where: \.writable) {
                let branch = "repoprompt/session-\(sessionID.uuidString.lowercased().prefix(12))"
                let binding = try await worktreeService.create(project: project, root: root, sessionID: sessionID, baseRef: "HEAD", branch: branch)
                let worktreeEvent = try await store.persistWorktree(binding, actor: externalActor, correlationID: ids.next())
                await eventHub.publish(worktreeEvent)
            }
        }
        return snapshot
    }

    public func spawnChildSession(parentSessionID: UUID, provider: ProviderKind? = nil, model: String? = nil, initialPrompt: String, role: String = "child", label: String? = nil) async throws -> SessionSnapshot {
        guard let parentAuthority = sessions[parentSessionID] else { throw ServiceAPIError(code: .notFound, message: "Parent session not found") }
        let parent = await parentAuthority.snapshot()
        guard !cancellationBarriers.contains(parent.rootSessionID) else { throw ServiceAPIError(code: .quiescing, message: "Root session is canceling; new children are fenced") }
        let child = try await createAuthoritySession(input: CreateSessionInput(projectID: parent.projectID, parentSessionID: parentSessionID, provider: provider ?? parent.provider, model: model ?? parent.model, visibility: parent.visibility, initialPrompt: initialPrompt), externalActor: parent.creator, idempotencyKey: "agent-manage:\(ids.next().uuidString)", requestDigest: CanonicalSigning.bodyDigest(Data(initialPrompt.utf8)))
        if var agent = agents[child.sessionID] {
            agent = AgentSnapshot(agentID: agent.agentID, sessionID: agent.sessionID, rootSessionID: agent.rootSessionID, parentAgentID: agent.parentAgentID, providerNativeIdentity: agent.providerNativeIdentity, role: role, label: label, state: agent.state, revision: agent.revision + 1)
            let agentEvent = try await store.persistAgent(agent, projectID: child.projectID, actor: nil, correlationID: ids.next(), eventType: .agentUpdated)
            agents[child.sessionID] = agent
            await eventHub.publish(agentEvent)
        }
        return child
    }

    /// Starts a provider run for an authority-created child without weakening the public
    /// root-only command contract. MCP/Agent Mode adapters call this only after the parent
    /// session has created and durably bound the child through `spawnChildSession`.
    public func startChildAgentRun(sessionID: UUID) async throws -> CommandReceipt {
        try ensureWritable()
        guard let session = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Child session not found")
        }
        let snapshot = await session.snapshot()
        guard snapshot.parentSessionID != nil else {
            throw ServiceAPIError(
                code: .authorizationDecisionRejected,
                message: "Managed child entry point may not target a root session"
            )
        }
        let command = SessionCommand.resumeSession(expectedRunID: nil, providerResumeMode: .fresh)
        let idempotency = IdempotencyInput(
            actorID: snapshot.creator.goblinUserID,
            operation: "agentRun",
            key: "agent-run:\(ids.next().uuidString)",
            requestDigest: CanonicalSigning.bodyDigest(Data(sessionID.uuidString.utf8))
        )
        return try await startProviderRun(
            command: command,
            sessionID: sessionID,
            session: session,
            actor: snapshot.creator,
            idempotency: idempotency
        )
    }

    public func cancelChildAgentRun(sessionID: UUID) async throws -> CommandReceipt {
        try ensureWritable()
        guard let session = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Child session not found")
        }
        let snapshot = await session.snapshot()
        guard snapshot.parentSessionID != nil else {
            throw ServiceAPIError(
                code: .authorizationDecisionRejected,
                message: "Managed child entry point may not target a root session"
            )
        }
        let run = try await store.latestRun(sessionID: sessionID)
        let command = SessionCommand.cancelSession(
            expectedRunID: run?.runID,
            expectedGeneration: snapshot.runGeneration
        )
        let idempotency = IdempotencyInput(
            actorID: snapshot.creator.goblinUserID,
            operation: "agentCancel",
            key: "agent-cancel:\(ids.next().uuidString)",
            requestDigest: CanonicalSigning.bodyDigest(Data(sessionID.uuidString.utf8))
        )
        return try await cancelProviderRun(
            command: command,
            sessionID: sessionID,
            session: session,
            expectedRunID: run?.runID,
            generation: snapshot.runGeneration,
            actor: snapshot.creator,
            idempotency: idempotency
        )
    }

    public func agentSnapshots(rootSessionID: UUID) async throws -> [AgentSnapshot] {
        guard sessions[rootSessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Root session not found") }
        return try await store.agents(rootSessionID: rootSessionID)
    }

    public func execute(command: SessionCommand, sessionID: UUID, externalActor: ExternalActor, idempotencyKey: String, requestDigest: String, authorizationDecision: GoblinAuthorizationDecision? = nil) async throws -> CommandReceipt {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: externalActor.goblinUserID, operation: command.operation, key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) {
            return try JSONDecoder.serviceDecoder.decode(CommandReceipt.self, from: existing.response)
        }
        guard let session = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        let before = await session.snapshot()
        guard before.parentSessionID == nil else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "External commands may target only root sessions") }
        if let authorizationDecision {
            guard authorizationDecision.sessionID == sessionID,
                  authorizationDecision.operation == command.operation,
                  authorizationDecision.actor.goblinUserID == externalActor.goblinUserID,
                  authorizationDecision.requestDigest == requestDigest
            else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Verified Goblin authorization decision is not bound to this command") }
        } else {
            try await authorizeExternalCommand(command, session: before, actor: externalActor)
        }
        let eventType: EventType
        switch command {
        case let .sendFollowup(text, expectedRevision):
            try await session.appendHumanMessage(text, actor: externalActor, expectedRevision: expectedRevision)
            eventType = .transcriptMessage
        case let .resumeSession(expectedRunID, _):
            if let expectedRunID {
                guard try await store.latestRun(sessionID: sessionID)?.runID == expectedRunID else {
                    throw ServiceAPIError(code: .staleRevision, message: "Most recent run identity is stale")
                }
            }
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
        case let .setSessionVisibility(expectedPolicyRevision, visibility, collaborativeSteeringEnabled, controllerUserID):
            let receipt = try await CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: store.nextCursor(), status: "accepted")
            _ = try await updateCollaborationMetadata(sessionID: sessionID, input: .init(expectedPolicyRevision: expectedPolicyRevision, visibility: visibility, collaborativeSteeringEnabled: collaborativeSteeringEnabled, controllerUserID: controllerUserID), actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt), authorizationDecision: authorizationDecision)
            return receipt
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
        case let .abortConflictedMerge(bindingID, leaseID, expectedRevision):
            _ = try await abortConflictedMerge(sessionID: sessionID, bindingID: bindingID, leaseID: leaseID, expectedRevision: expectedRevision, actor: externalActor, idempotencyKey: idempotencyKey, requestDigest: requestDigest)
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

    public func projectGit(
        projectID: UUID,
        rootID: UUID,
        arguments: [String],
        maximumBytes: Int = 2_097_152
    ) async throws -> String {
        let project = try await projects.authority(projectID: projectID)
        let root = try await project.root(rootID: rootID)
        let forbidden = Set(["push", "fetch", "pull", "clone", "remote", "credential"])
        guard let operation = arguments.first, !forbidden.contains(operation.lowercased()) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Network or credential Git operations are unavailable")
        }
        return try await commandRunner.run(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: root.snapshot.canonicalPath,
            maximumBytes: maximumBytes
        )
    }

    public func refreshProject(projectID: UUID, expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String, requestDigest: String) async throws -> ProjectSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "refreshProject", key: idempotencyKey, requestDigest: requestDigest)
        if let existing = try await store.idempotencyResult(idempotency) { return try JSONDecoder.serviceDecoder.decode(ProjectSnapshot.self, from: existing.response) }
        let current = try await projectSnapshot(projectID: projectID)
        guard current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Project revision is stale", currentRevision: current.revision) }
        var roots: [CanonicalRoot] = []
        var availableRootIdentities: [UUID: String] = [:]
        var degraded = false
        for root in current.roots {
            do {
                let canonical = try filesystem.canonicalizeRoot(root.canonicalPath)
                roots.append(CanonicalRoot(snapshot: root, filesystemIdentity: canonical.identity))
                availableRootIdentities[root.rootID] = canonical.identity
            } catch {
                degraded = true
                roots.append(CanonicalRoot(snapshot: root, filesystemIdentity: "unavailable"))
            }
        }
        let cursor = try await store.nextCursor()
        let snapshot = ProjectSnapshot(projectID: current.projectID, name: current.name, creator: current.creator, state: degraded ? .degraded : .active, roots: current.roots, revision: current.revision + 1, cursor: cursor)
        let event = try await store.persistProject(snapshot, rootIdentities: availableRootIdentities, eventType: .projectRefreshed, actor: actor, correlationID: ids.next(), idempotency: idempotency)
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

    public func sessionContext(sessionID: UUID) async throws -> SessionContextSnapshot {
        let selection = try await selectionSnapshot(sessionID: sessionID)
        return try await store.sessionContext(sessionID: sessionID)
            ?? SessionContextSnapshot(
                sessionID: sessionID,
                prompt: "",
                selectionRevision: selection.revision,
                contextRevision: 1
            )
    }

    public func beginToolInvocation(sessionID: UUID, toolName: String, argumentDigest: String, actor: ExternalActor) async throws -> ToolInvocationSnapshot {
        try ensureWritable()
        let snapshot = try await sessionSnapshot(sessionID: sessionID)
        let invocation = ToolInvocationSnapshot(invocationID: ids.next(), toolName: toolName, state: "running", argumentDigest: argumentDigest)
        let event = try await store.persistToolInvocation(invocation, session: snapshot, actor: actor, correlationID: invocation.invocationID, eventType: .toolStarted)
        await eventHub.publish(event)
        return invocation
    }

    public func finishToolInvocation(sessionID: UUID, invocation: ToolInvocationSnapshot, resultDigest: String?, errorCode: ServiceErrorCode?, actor: ExternalActor) async throws {
        let snapshot = try await sessionSnapshot(sessionID: sessionID)
        let failed = errorCode != nil
        let terminal = ToolInvocationSnapshot(invocationID: invocation.invocationID, toolName: invocation.toolName, state: failed ? "failed" : "completed", argumentDigest: invocation.argumentDigest, resultDigest: resultDigest, errorCode: errorCode)
        let event = try await store.persistToolInvocation(terminal, session: snapshot, actor: actor, correlationID: invocation.invocationID, eventType: failed ? .toolFailed : .toolCompleted)
        await eventHub.publish(event)
    }

    public func publishProgress(sessionID: UUID, text: String, actor: ExternalActor, expectedRevision: Int64) async throws -> SessionSnapshot {
        try ensureWritable()
        guard let session = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        try await session.appendExternalEntry(kind: .progress, text: text, actor: actor, expectedRevision: expectedRevision)
        let cursor = try await store.nextCursor()
        let snapshot = await replacingCursor(session.snapshot(), cursor: cursor)
        let event = try await store.persistSession(snapshot, eventType: .transcriptProgress, actor: actor, correlationID: ids.next(), idempotency: nil)
        await eventHub.publish(event)
        return snapshot
    }

    public func updateAgentLabel(sessionID: UUID, label: String?, actor: ExternalActor, expectedRevision: Int64) async throws -> AgentSnapshot {
        try ensureWritable()
        guard let current = agents[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Agent not found") }
        guard current.revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Agent revision is stale", currentRevision: current.revision) }
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = AgentSnapshot(agentID: current.agentID, sessionID: current.sessionID, rootSessionID: current.rootSessionID, parentAgentID: current.parentAgentID, providerNativeIdentity: current.providerNativeIdentity, role: current.role, label: normalized?.isEmpty == true ? nil : normalized, state: current.state, revision: current.revision + 1)
        let session = try await sessionSnapshot(sessionID: sessionID)
        let event = try await store.persistAgent(updated, projectID: session.projectID, actor: actor, correlationID: ids.next(), eventType: .agentUpdated)
        agents[sessionID] = updated
        await eventHub.publish(event)
        return updated
    }

    public func updateSessionPrompt(
        sessionID: UUID,
        prompt: String,
        expectedContextRevision: Int64,
        actor: ExternalActor
    ) async throws -> SessionContextSnapshot {
        try ensureWritable()
        let session = try await sessionSnapshot(sessionID: sessionID)
        let current = try await sessionContext(sessionID: sessionID)
        guard current.contextRevision == expectedContextRevision else {
            throw ServiceAPIError(
                code: .staleRevision,
                message: "Context revision is stale",
                currentRevision: current.contextRevision
            )
        }
        let selection = try await selectionSnapshot(sessionID: sessionID)
        let updated = SessionContextSnapshot(
            sessionID: sessionID,
            prompt: prompt,
            selectionRevision: selection.revision,
            contextRevision: current.contextRevision + 1
        )
        let event = try await store.persistSessionContext(
            updated,
            session: session,
            actor: actor,
            correlationID: ids.next()
        )
        await eventHub.publish(event)
        return updated
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

    public func collaborationMetadata(sessionID: UUID) async throws -> CollaborationMetadataSnapshot {
        let session = try await sessionSnapshot(sessionID: sessionID)
        return try await store.collaboration(sessionID: sessionID)
            ?? CollaborationMetadataSnapshot(sessionID: sessionID, visibility: session.visibility, collaborativeSteeringEnabled: false, controllerUserID: session.creator.goblinUserID, policyRevision: 1, controllerRevision: 1, membershipRevision: 1)
    }

    public func updateCollaborationMetadata(sessionID: UUID, input: CollaborationMetadataInput, actor: ExternalActor, idempotencyKey: String, requestDigest: String, idempotencyResponse: Data? = nil, authorizationDecision: GoblinAuthorizationDecision? = nil) async throws -> CollaborationMetadataSnapshot {
        try ensureWritable()
        let idempotency = IdempotencyInput(actorID: actor.goblinUserID, operation: "setSessionVisibility", key: idempotencyKey, requestDigest: requestDigest)
        if let prior: CollaborationMetadataSnapshot = try await priorResult(idempotency) { return prior }
        guard let session = sessions[sessionID] else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        let authoritySession = await session.snapshot()
        let current = try await collaborationMetadata(sessionID: sessionID)
        guard current.policyRevision == input.expectedPolicyRevision else { throw ServiceAPIError(code: .staleRevision, message: "Collaboration policy revision is stale", currentRevision: current.policyRevision) }
        if let expected = input.expectedControllerRevision, expected != current.controllerRevision { throw ServiceAPIError(code: .staleRevision, message: "Controller revision is stale", currentRevision: current.controllerRevision) }
        if let expected = input.expectedMembershipRevision, expected != current.membershipRevision { throw ServiceAPIError(code: .staleRevision, message: "Membership revision is stale", currentRevision: current.membershipRevision) }
        guard !input.controllerUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Controller user ID is required") }
        let controllerChanged = current.controllerUserID != input.controllerUserID
        let membershipChanged = current.visibility != input.visibility
        let policyChanged = membershipChanged
            || current.collaborativeSteeringEnabled != input.collaborativeSteeringEnabled
            || controllerChanged
        let resultingPolicyRevision = input.policyRevision ?? current.policyRevision + (policyChanged ? 1 : 0)
        let resultingControllerRevision = input.controllerRevision ?? current.controllerRevision + (controllerChanged ? 1 : 0)
        let resultingMembershipRevision = input.membershipRevision ?? current.membershipRevision + (membershipChanged ? 1 : 0)
        guard resultingPolicyRevision == current.policyRevision + (policyChanged ? 1 : 0),
              resultingControllerRevision == current.controllerRevision + (controllerChanged ? 1 : 0),
              resultingMembershipRevision == current.membershipRevision + (membershipChanged ? 1 : 0)
        else { throw ServiceAPIError(code: .staleRevision, message: "Goblin collaboration result revisions are not the exact next authority revisions", currentRevision: current.policyRevision) }
        if let authorizationDecision {
            guard authorizationDecision.sessionID == sessionID,
                  authorizationDecision.actor.goblinUserID == actor.goblinUserID,
                  authorizationDecision.operation == "setSessionVisibility",
                  authorizationDecision.requestDigest == requestDigest,
                  authorizationDecision.policyRevision == resultingPolicyRevision,
                  authorizationDecision.controllerRevision == resultingControllerRevision,
                  authorizationDecision.membershipRevision == resultingMembershipRevision,
                  authorizationDecision.issuedAt <= clock.now(),
                  authorizationDecision.expiresAt > clock.now(),
                  authorizationDecision.attributionLabels?.creatorUserID == nil
                    || authorizationDecision.attributionLabels?.creatorUserID == authoritySession.creator.goblinUserID,
                  authorizationDecision.attributionLabels?.controllerUserID == nil
                    || authorizationDecision.attributionLabels?.controllerUserID == input.controllerUserID,
                  authorizationDecision.attributionLabels?.visibility == nil
                    || authorizationDecision.attributionLabels?.visibility == input.visibility
            else {
                throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Goblin collaboration decision does not acknowledge the exact resulting revisions")
            }
        }
        let acknowledgement = authorizationDecision.map {
            GoblinCollaborationAcknowledgement(
                decisionID: $0.decisionID,
                acknowledgedPolicyRevision: $0.policyRevision,
                acknowledgedControllerRevision: $0.controllerRevision,
                acknowledgedMembershipRevision: $0.membershipRevision,
                resultingPolicyRevision: resultingPolicyRevision,
                resultingControllerRevision: resultingControllerRevision,
                resultingMembershipRevision: resultingMembershipRevision,
                requestID: $0.requestID,
                correlationID: $0.correlationID
            )
        }
        let next = CollaborationMetadataSnapshot(
            sessionID: sessionID,
            visibility: input.visibility,
            collaborativeSteeringEnabled: input.collaborativeSteeringEnabled,
            controllerUserID: input.controllerUserID,
            policyRevision: resultingPolicyRevision,
            controllerRevision: resultingControllerRevision,
            membershipRevision: resultingMembershipRevision,
            goblinAcknowledgement: acknowledgement
        )
        let currentSession = authoritySession
        let cursor = try await store.nextCursor()
        let persistedSession = SessionSnapshot(
            sessionID: currentSession.sessionID,
            projectID: currentSession.projectID,
            parentSessionID: currentSession.parentSessionID,
            rootSessionID: currentSession.rootSessionID,
            creator: currentSession.creator,
            provider: currentSession.provider,
            model: currentSession.model,
            visibility: input.visibility,
            state: currentSession.state,
            runGeneration: currentSession.runGeneration,
            turnEpoch: currentSession.turnEpoch,
            revision: currentSession.revision + 1,
            transcript: currentSession.transcript,
            interactions: currentSession.interactions,
            cursor: cursor
        )
        // Commit durable collaboration/session state first. A persistence failure
        // therefore cannot leave the in-memory provider authority ahead of the
        // events and snapshots observed by macOS or direct MCP.
        let events = try await store.persistCollaboration(next, session: persistedSession, actor: actor, correlationID: authorizationDecision?.correlationID ?? ids.next(), idempotency: idempotency, idempotencyResponse: idempotencyResponse)
        try await session.updateVisibility(input.visibility, expectedRevision: currentSession.revision)
        for event in events { await eventHub.publish(event) }
        return next
    }


    public func updatePermissions(sessionID: UUID, expectedRevision: Int64, mode: String, providerSettings: [String: String], actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> ExecutionPermissionSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "updateExecutionPermissions", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: ExecutionPermissionSnapshot = try await priorResult(idempotency) { return prior }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let current = try await store.permissions(sessionID: sessionID)
        let revision = current?.revision ?? 0
        guard revision == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Permission revision is stale", currentRevision: revision) }
        guard ["readOnly", "workspaceWrite", "fullAccess", "disabled"].contains(mode) else { throw ServiceAPIError(code: .invalidRequest, message: "Unsupported execution permission mode") }
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
        if current.runID == nil,
           let question = try? JSONDecoder.serviceDecoder.decode(ContextBuilderQuestionPayload.self, from: current.payload),
           question.authorityOperation == "context_builder.ask_user"
        {
            let resolved = InteractionSnapshot(
                interactionID: current.interactionID,
                runID: nil,
                agentID: current.agentID,
                kind: current.kind,
                state: .resolved,
                payload: payload,
                revision: current.revision + 1,
                expiresAt: current.expiresAt
            )
            let event = try await store.persistInteraction(resolved, session: session, actor: actor, correlationID: ids.next(), idempotency: idempotency)
            await eventHub.publish(event)
            return resolved
        }
        guard let interactionDelivery else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider interaction delivery is unavailable") }
        // Retain the authority-created provider delivery token in the durable
        // interaction snapshot. The human answer is passed separately and is
        // never allowed to replace routing metadata before acknowledgement.
        let intent = InteractionSnapshot(interactionID: current.interactionID, runID: current.runID, agentID: current.agentID, kind: current.kind, state: .deliveryIntent, payload: current.payload, revision: current.revision + 1, expiresAt: current.expiresAt)
        try await store.persistInteractionDeliveryState(intent, sessionID: sessionID, actor: actor)
        do {
            try await interactionDelivery.deliverAnswer(session: session, interaction: intent, answer: payload)
        } catch {
            let interrupted = InteractionSnapshot(interactionID: current.interactionID, runID: current.runID, agentID: current.agentID, kind: current.kind, state: .interrupted, payload: payload, revision: intent.revision + 1, expiresAt: current.expiresAt)
            try await store.persistInteractionDeliveryState(interrupted, sessionID: sessionID, actor: actor)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider interaction delivery was not acknowledged", retryable: false)
        }
        let resolved = InteractionSnapshot(interactionID: current.interactionID, runID: current.runID, agentID: current.agentID, kind: current.kind, state: .resolved, payload: current.payload, revision: intent.revision + 1, expiresAt: current.expiresAt)
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

    /// Adopts a macOS-created worktree set as an explicit authority mutation.
    /// This is not a property mirror: revision checks, active-run fencing and
    /// all ownership changes are committed atomically before the UI projects
    /// the returned snapshot.
    public func replaceEmbeddedWorktrees(
        sessionID: UUID,
        desired: [WorktreeBindingSnapshot],
        actor: ExternalActor
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionAuthority = sessions[sessionID] else {
            throw ServiceAPIError(code: .notFound, message: "Session not found")
        }
        guard await sessionAuthority.activeBinding() == nil else {
            throw ServiceAPIError(code: .runAlreadyActive, message: "A worktree cannot be changed while a run is active")
        }
        let session = await sessionAuthority.snapshot()
        let project = try await projectSnapshot(projectID: session.projectID)
        let rootIDs = Set(project.roots.map(\.rootID))
        guard desired.allSatisfy({
            $0.projectID == session.projectID
                && $0.sessionID == sessionID
                && rootIDs.contains($0.rootID)
                && !$0.physicalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Embedded worktree replacement contains an unauthorized binding")
        }
        guard Set(desired.map(\.bindingID)).count == desired.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Embedded worktree replacement contains duplicate identities")
        }

        let current = try await store.worktrees(projectID: session.projectID)
            .filter { $0.sessionID == sessionID }
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.bindingID, $0) })
        let desiredIDs = Set(desired.map(\.bindingID))
        var replacement = desired.map { proposed in
            let prior = currentByID[proposed.bindingID]
            return WorktreeBindingSnapshot(
                bindingID: proposed.bindingID,
                projectID: session.projectID,
                rootID: proposed.rootID,
                sessionID: sessionID,
                baseRef: proposed.baseRef,
                branch: proposed.branch,
                physicalPath: proposed.physicalPath,
                ownershipState: .active,
                mergeState: proposed.mergeState,
                revision: (prior?.revision ?? 0) + 1
            )
        }
        replacement.append(contentsOf: current.filter { !desiredIDs.contains($0.bindingID) }.map { prior in
            WorktreeBindingSnapshot(
                bindingID: prior.bindingID,
                projectID: prior.projectID,
                rootID: prior.rootID,
                sessionID: nil,
                baseRef: prior.baseRef,
                branch: prior.branch,
                physicalPath: prior.physicalPath,
                ownershipState: .released,
                mergeState: prior.mergeState,
                revision: prior.revision + 1
            )
        })
        let events = try await store.replaceEmbeddedWorktrees(
            replacement,
            session: session,
            actor: actor,
            correlationID: ids.next()
        )
        for event in events { await eventHub.publish(event) }
        return try await authoritySessionSnapshot(sessionID: sessionID)
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

    public func abortConflictedMerge(sessionID: UUID, bindingID: UUID, leaseID: UUID, expectedRevision: Int64, actor: ExternalActor, idempotencyKey: String? = nil, requestDigest: String? = nil) async throws -> WorktreeBindingSnapshot {
        let idempotency = try mutationIdempotency(actor: actor, operation: "abortConflictedMerge", key: idempotencyKey, digest: requestDigest)
        if let idempotency, let prior: WorktreeBindingSnapshot = try await priorResult(idempotency) { return prior }
        guard let worktreeService else { throw ServiceAPIError(code: .capabilityMissing, message: "Worktree storage is not configured") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        guard let binding = try await store.worktree(bindingID: bindingID), binding.projectID == session.projectID, binding.sessionID == sessionID else {
            throw ServiceAPIError(code: .notFound, message: "Worktree binding not found")
        }
        guard binding.revision == expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Worktree revision is stale", currentRevision: binding.revision)
        }
        let project = try await projectSnapshot(projectID: session.projectID)
        guard let root = project.roots.first(where: { $0.rootID == binding.rootID }) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root")
        }
        let recovered = try await worktreeService.abortConflictedMerge(binding, targetPath: root.canonicalPath, leaseID: leaseID)
        let event = try await store.persistWorktree(recovered, actor: actor, correlationID: ids.next(), idempotency: idempotency)
        await eventHub.publish(event)
        return recovered
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

    public func runContextBuilder(sessionID: UUID, input: ContextBuilderInput, actor: ExternalActor) async throws -> ContextBuilderSnapshot {
        guard let contextBuilderRuntime else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Context Builder runtime is not configured") }
        guard artifactService != nil else { throw ServiceAPIError(code: .capabilityMissing, message: "Context Builder requires durable artifact storage") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let current = try await selectionSnapshot(sessionID: sessionID)
        guard current.revision == input.expectedSelectionRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection revision is stale", currentRevision: current.revision) }
        let project = try await projectSnapshot(projectID: session.projectID)
        let frozenContext = try await sessionContext(sessionID: sessionID)
        let frozenBinding = try await sessionWorktreeBinding(session: session)
        let tool = try await sessionToolAuthority(session: session)
        let workingDirectory = try await workingDirectory(session: session)
        var candidates: [ContextBuilderFileCandidate] = []
        for root in project.roots {
            let entries = try await tool.tree(.init(rootID: root.rootID, maximumDepth: 32, maximumEntries: 20000))
            candidates.append(contentsOf: entries.filter { !$0.isDirectory }.map {
                ContextBuilderFileCandidate(rootID: root.rootID, logicalPath: $0.logicalPath, byteCount: $0.size ?? 0)
            })
        }
        let runID = ids.next()
        let proposal = try await contextBuilderRuntime.propose(.init(
            workspace: .init(
                sessionID: sessionID,
                projectID: session.projectID,
                workingDirectory: workingDirectory,
                prompt: frozenContext.prompt,
                selection: current,
                candidates: candidates,
                tools: ContextBuilderWorkspaceTools { call in
                    switch call {
                    case let .tree(rootID, logicalPath, maximumDepth, maximumEntries):
                        try await .tree(tool.tree(.init(rootID: rootID, logicalPath: logicalPath, maximumDepth: maximumDepth, maximumEntries: maximumEntries)))
                    case let .search(rootID, logicalPath, query, useRegex, maximumResults):
                        try await .search(tool.search(.init(rootID: rootID, query: query, logicalPath: logicalPath, useRegex: useRegex, maximumResults: maximumResults)))
                    case let .read(rootID, logicalPath, startLine, lineCount):
                        try await .file(tool.readFile(.init(rootID: rootID, logicalPath: logicalPath, startLine: startLine, lineCount: lineCount)))
                    case let .codeMap(rootID, logicalPath):
                        try await .codeMap(tool.codeMap(.init(rootID: rootID, logicalPath: logicalPath)))
                    case let .diff(rootID, comparison, logicalPaths):
                        try await .diff(tool.diff(.init(rootID: rootID, comparison: comparison, logicalPaths: logicalPaths)))
                    case let .askUser(prompt, choices):
                        try await .answer(self.askContextBuilderQuestion(sessionID: sessionID, prompt: prompt, choices: choices))
                    }
                }
            ),
            instructions: input.instructions,
            tokenBudget: input.budget,
            responseType: input.responseType,
            allowClarifyingQuestions: input.allowClarifyingQuestions,
            provider: session.provider,
            model: session.model,
            runID: runID
        ))
        let proposalData = try JSONEncoder.serviceEncoder.encode(proposal)
        let proposalArtifact = try await createArtifact(
            projectID: project.projectID,
            sessionID: sessionID,
            kind: "context-builder-proposal",
            logicalName: "context-builder-r\(input.expectedSelectionRevision)-\(runID.uuidString).json",
            content: proposalData,
            actor: actor
        )
        let latestProject = try await projectSnapshot(projectID: session.projectID)
        let latestSelection = try await selectionSnapshot(sessionID: sessionID)
        let latestContext = try await sessionContext(sessionID: sessionID)
        let latestBinding = try await sessionWorktreeBinding(session: session)
        guard latestProject.revision == project.revision,
              latestSelection.revision == current.revision,
              latestSelection.bindingRevision == current.bindingRevision,
              latestContext.contextRevision == frozenContext.contextRevision,
              latestContext.prompt == frozenContext.prompt,
              latestBinding == frozenBinding
        else {
            throw ServiceAPIError(code: .staleRevision, message: "Context Builder frozen workspace changed before commit", currentRevision: latestSelection.revision)
        }
        let selection = try await replaceSelection(sessionID: sessionID, entries: proposal.selection, expectedRevision: input.expectedSelectionRevision, actor: actor)
        if let handoffPrompt = proposal.handoffPrompt {
            _ = try await updateSessionPrompt(
                sessionID: sessionID,
                prompt: handoffPrompt,
                expectedContextRevision: frozenContext.contextRevision,
                actor: actor
            )
        }
        var continuationChatID: UUID?
        if let response = proposal.response, !response.isEmpty, let authority = sessions[sessionID] {
            let chatID = ids.next()
            try await store.persistOracleChat(OracleChatState(
                chatID: chatID,
                sessionID: sessionID,
                providerSessionID: proposal.providerSessionID,
                turns: [.init(prompt: input.instructions, response: response, timestamp: clock.now())],
                revision: 1
            ))
            continuationChatID = chatID
            await authority.appendAuthorityEntry(kind: .assistant, text: response, actor: nil)
            let cursor = try await store.nextCursor()
            let event = try await store.persistSession(replacingCursor(authority.snapshot(), cursor: cursor), eventType: .transcriptMessage, actor: nil, correlationID: runID, idempotency: nil)
            await eventHub.publish(event)
        }
        return ContextBuilderSnapshot(selection: selection, proposalArtifactID: proposalArtifact.artifactID, response: proposal.response, chatID: continuationChatID)
    }

    public func askOracle(sessionID: UUID, input: OracleInput, actor: ExternalActor) async throws -> OracleSnapshot {
        guard let oracleRuntime else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Oracle runtime is not configured") }
        let session = try await sessionSnapshot(sessionID: sessionID)
        let project = try await projectSnapshot(projectID: session.projectID)
        let workingDirectory = try await workingDirectory(session: session)
        let selection = try await selectionSnapshot(sessionID: sessionID)
        let context = try await materializedContext(projectID: project.projectID, selection: selection, include: ["files"])
        let chatID = input.chatID ?? ids.next()
        let priorChat: OracleChatState
        if let inputChatID = input.chatID {
            guard let stored = try await store.oracleChat(chatID: inputChatID), stored.sessionID == sessionID else { throw ServiceAPIError(code: .notFound, message: "Oracle chat not found for this session") }
            priorChat = stored
        } else {
            priorChat = OracleChatState(
                chatID: chatID,
                sessionID: sessionID,
                providerSessionID: nil,
                turns: [],
                revision: 0
            )
        }
        let execution = try await oracleRuntime.ask(.init(
            sessionID: sessionID,
            prompt: input.prompt,
            mode: input.contextMode,
            selectedContext: context,
            priorTurns: priorChat.turns,
            providerSessionID: priorChat.providerSessionID,
            provider: session.provider,
            model: session.model,
            workingDirectory: workingDirectory,
            runID: ids.next()
        ))
        let response = execution.response
        let nextChat = OracleChatState(
            chatID: chatID,
            sessionID: sessionID,
            providerSessionID: execution.providerSessionID,
            turns: priorChat.turns + [
                OracleChatTurn(prompt: input.prompt, response: response, timestamp: clock.now())
            ],
            revision: priorChat.revision + 1
        )
        try await store.persistOracleChat(nextChat)
        if let authority = sessions[sessionID] {
            for entry in execution.transcriptEntries {
                await authority.appendAuthorityEntry(kind: entry.role == .user ? .human : .assistant, text: entry.content, actor: entry.role == .user ? actor : nil)
            }
            let cursor = try await store.nextCursor()
            let event = try await store.persistSession(replacingCursor(authority.snapshot(), cursor: cursor), eventType: .transcriptMessage, actor: actor, correlationID: chatID, idempotency: nil)
            await eventHub.publish(event)
        }
        let artifact = try await createArtifact(projectID: project.projectID, sessionID: sessionID, kind: "oracle", logicalName: "oracle-\(chatID.uuidString)-r\(nextChat.revision).md", content: Data(response.utf8), actor: actor)
        return OracleSnapshot(chatID: chatID, response: response, artifactID: artifact.artifactID, revision: nextChat.revision)
    }

    public func oracleChatState(sessionID: UUID, chatID: UUID) async throws -> OracleChatState {
        guard let state = try await store.oracleChat(chatID: chatID), state.sessionID == sessionID else {
            throw ServiceAPIError(code: .notFound, message: "Oracle chat not found for this session")
        }
        return state
    }

    public func sessionSnapshot(sessionID: UUID) async throws -> SessionSnapshot {
        guard sessions[sessionID] != nil,
              let persisted = try await store.sessionWithInteractions(id: sessionID)
        else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return persisted
    }

    public func projectSnapshots() async -> [ProjectSnapshot] {
        await projects.snapshots()
    }

    public func sessionSnapshots() async throws -> [SessionSnapshot] {
        var values: [SessionSnapshot] = []
        for snapshot in try await store.allSessionsWithInteractions() where sessions[snapshot.sessionID] != nil {
            values.append(snapshot)
        }
        return values.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    public func childSessionSnapshots(parentSessionID: UUID) async throws -> [SessionSnapshot] {
        guard sessions[parentSessionID] != nil else { throw ServiceAPIError(code: .notFound, message: "Session not found") }
        return try await sessionSnapshots().filter { $0.parentSessionID == parentSessionID }
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
        return try await AuthoritativeSnapshot(storeID: meta.storeID, projects: projectSnapshots(), sessions: sessionSnapshots(), cursor: cursor)
    }

    public func quiesce() async throws {
        quiescing = true
        let roots = try await sessionSnapshots().filter { $0.parentSessionID == nil && [.preparing, .running, .waiting].contains($0.state) }
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
        await waitForProviderRunsToSettle()
        try await store.checkpoint()
    }

    /// Deterministic barrier for shutdown/tests: terminal snapshots can become
    /// observable just before the provider task releases its final resources.
    public func waitForProviderRunsToSettle() async {
        while !providerTasks.isEmpty {
            let tasks = Array(providerTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    public func isReady() -> Bool {
        !quiescing
    }

    private func ensureWritable() throws {
        if quiescing { throw ServiceAPIError(code: .quiescing, message: "Service is quiescing", retryable: true) }
    }

    private func ensureProjectHasNoActiveProviderRun(projectID: UUID) async throws {
        for session in sessions.values {
            let snapshot = await session.snapshot()
            if snapshot.projectID == projectID, await session.activeBinding() != nil {
                throw ServiceAPIError(code: .runAlreadyActive, message: "Repositories cannot change while a project provider run is active")
            }
        }
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

    private func askContextBuilderQuestion(sessionID: UUID, prompt: String, choices: [String]) async throws -> String? {
        let expiresAt = clock.now().addingTimeInterval(120)
        let payload = try JSONEncoder.serviceEncoder.encode(ContextBuilderQuestionPayload(prompt: prompt, choices: choices))
        let interaction = try await requestInteraction(sessionID: sessionID, kind: .question, payload: payload, expiresAt: expiresAt)
        do {
            for _ in 0 ..< 1200 {
                try Task.checkCancellation()
                guard let current = try await store.interactions(sessionID: sessionID).first(where: { $0.interactionID == interaction.interactionID }) else {
                    throw ServiceAPIError(code: .notFound, message: "Context Builder interaction disappeared")
                }
                switch current.state {
                case .resolved:
                    return Self.contextBuilderAnswer(from: current.payload)
                case .expired:
                    throw ServiceAPIError(code: .interactionSettled, message: "Context Builder question expired")
                case .interrupted:
                    throw CancellationError()
                case .pending, .deliveryIntent:
                    break
                }
                if clock.now() >= expiresAt { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            try? await settleContextBuilderQuestion(interaction, sessionID: sessionID, state: .interrupted)
            throw error
        }
        try await settleContextBuilderQuestion(interaction, sessionID: sessionID, state: .expired)
        throw ServiceAPIError(code: .interactionSettled, message: "Context Builder question expired")
    }

    private func settleContextBuilderQuestion(_ interaction: InteractionSnapshot, sessionID: UUID, state: InteractionSnapshot.State) async throws {
        let session = try await sessionSnapshot(sessionID: sessionID)
        guard let current = try await store.interactions(sessionID: sessionID).first(where: { $0.interactionID == interaction.interactionID }), current.state == .pending else { return }
        let settled = InteractionSnapshot(
            interactionID: current.interactionID,
            runID: nil,
            agentID: current.agentID,
            kind: current.kind,
            state: state,
            payload: current.payload,
            revision: current.revision + 1,
            expiresAt: current.expiresAt
        )
        let event = try await store.persistInteraction(settled, session: session, actor: nil, correlationID: ids.next(), idempotency: nil)
        await eventHub.publish(event)
    }

    private nonisolated static func contextBuilderAnswer(from payload: Data) -> String? {
        if let value = try? JSONSerialization.jsonObject(with: payload) {
            if let string = value as? String { return string }
            if let object = value as? [String: Any] {
                if let answer = object["answer"] as? String { return answer }
                if let custom = object["custom_response"] as? String { return custom }
                if let answers = object["answers"] as? [String] { return answers.joined(separator: "\n") }
            }
        }
        let text = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func materializedContext(projectID: UUID, selection: SelectionSnapshot, include: [String]) async throws -> String {
        var sections = ["# RepoPrompt Context", "selection-revision: \(selection.revision)"]
        let session = try await sessionSnapshot(sessionID: selection.sessionID)
        guard session.projectID == projectID else { throw ServiceAPIError(code: .rootUnauthorized, message: "Selection does not belong to the project") }
        let tool = try await sessionToolAuthority(session: session)
        for entry in selection.entries {
            if entry.mode == .codeMap {
                let codeMap = try await tool.codeMap(.init(rootID: entry.rootID, logicalPath: entry.logicalPath))
                sections.append("## \(entry.logicalPath) [codemap:\(codeMap.status)]\n```\n\(codeMap.content)\n```")
                continue
            }
            let file = try await tool.readFile(.init(rootID: entry.rootID, logicalPath: entry.logicalPath, maximumBytes: 1_048_576))
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

    private func startProviderRun(
        command: SessionCommand,
        sessionID: UUID,
        session: SessionAuthority,
        actor: ExternalActor,
        idempotency: IdempotencyInput,
        providerPrompt: String? = nil
    ) async throws -> CommandReceipt {
        guard let providerAdapter else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider runtime is not configured") }
        let snapshot = await session.snapshot()
        guard !projectRepositoryMutationBarriers.contains(snapshot.projectID) else {
            throw ServiceAPIError(code: .runAlreadyActive, message: "A repository mutation is active for this project")
        }
        guard let permissions = try await store.permissions(sessionID: sessionID) else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Execution permissions are not configured") }
        guard permissions.mode != "disabled" else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Provider execution is disabled by session policy") }
        guard ["readOnly", "workspaceWrite", "fullAccess"].contains(permissions.mode) else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Execution permission mode is invalid") }
        guard let capability = await providerAdapter.capabilities().first(where: { $0.kind == snapshot.provider && $0.enabled }) else { throw ServiceAPIError(code: .providerUnavailable, message: "Session provider is unavailable") }
        let resumeMode: ProviderResumeMode = switch command {
        case let .resumeSession(_, mode): mode
        default: .fresh
        }
        let previousRun = try await store.latestRun(sessionID: sessionID)
        let resumeIdentity = resumeMode == .fresh ? nil : previousRun?.providerSessionID
        if resumeMode == .resume, !capability.supportsResume || resumeIdentity == nil {
            throw ServiceAPIError(code: .resumeUnsupported, message: "No durable provider identity is available for native resume")
        }
        let workingDirectory = try await workingDirectory(session: snapshot)
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
        await providerAdapter.prepareRun(kind: snapshot.provider, runID: binding.runID)
        let prompt = providerPrompt
            ?? snapshot.transcript.last(where: { $0.kind == .human })?.content
            ?? "Continue the repository task."
        providerTasks[binding.runID] = Task {
            await self.performProviderRun(
                sessionID: sessionID,
                binding: binding,
                run: run,
                prompt: prompt,
                workingDirectory: workingDirectory,
                permissions: permissions
            )
        }
        return receipt
    }

    private func authorizeExternalCommand(_ command: SessionCommand, session: SessionSnapshot, actor: ExternalActor) async throws {
        let metadata = try await collaborationMetadata(sessionID: session.sessionID)
        if actor.goblinUserID == metadata.controllerUserID { return }
        let collaborativelySteerable = switch command {
        case .sendFollowup, .steerSession, .answerInteraction, .buildContext, .runContextBuilder, .askOracle: true
        default: false
        }
        guard session.visibility == .collaborative, metadata.collaborativeSteeringEnabled, collaborativelySteerable else {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Only the current collaboration controller may perform this operation")
        }
    }

    private func steerProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, text: String, targetTurnEpoch: Int64, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        guard let providerAdapter else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider runtime is not configured") }
        let currentProvider = await session.snapshot().provider
        guard await providerAdapter.capabilities().first(where: { $0.kind == currentProvider })?.supportsSteering == true else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Provider does not support native steering")
        }
        guard let activeRunID = await session.activeBinding()?.runID else { throw ServiceAPIError(code: .notFound, message: "Provider run is not active") }
        for _ in 0 ..< 100 {
            if providerControlReadyRuns.contains(activeRunID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard providerControlReadyRuns.contains(activeRunID) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider control channel did not become ready") }
        let binding = try await session.steer(text, actor: actor, targetTurnEpoch: targetTurnEpoch)
        let current = await session.snapshot()
        let cursor = try await store.nextCursor()
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(replacingCursor(current, cursor: cursor), eventType: .sessionUpdated, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        if let run = try await store.latestRun(sessionID: sessionID) {
            try await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: run.providerSessionID, state: run.state, generation: run.generation, turnEpoch: binding.turnEpoch, startReason: run.startReason, endReason: run.endReason, startedAt: run.startedAt, endedAt: run.endedAt))
        }
        // Publish the attributed durable steering command before provider
        // delivery. A provider can emit output synchronously with its ACK; this
        // ordering prevents that output from racing the command transaction.
        do {
            try await providerAdapter.steer(runID: binding.runID, text: text, targetTurnEpoch: targetTurnEpoch)
        } catch {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider-native steering was not acknowledged")
        }
        return receipt
    }

    private func cancelProviderRun(command: SessionCommand, sessionID: UUID, session: SessionAuthority, expectedRunID: UUID?, generation: Int64, actor: ExternalActor, idempotency: IdempotencyInput) async throws -> CommandReceipt {
        guard let binding = await session.activeBinding(), binding.generation == generation, expectedRunID == nil || expectedRunID == binding.runID else { throw await ServiceAPIError(code: .staleRevision, message: "Run identity is stale", currentRevision: (session.snapshot()).runGeneration) }
        let rootSessionID = await (session.snapshot()).rootSessionID
        cancellationBarriers.insert(rootSessionID)
        try await cancelDescendants(rootSessionID: rootSessionID, excluding: sessionID, actor: actor)
        guard await session.settle(binding: binding, terminal: .sessionCanceled, lifecycle: .canceled) == .accepted else { throw ServiceAPIError(code: .staleRevision, message: "Run is already settled") }
        let providerTask = providerTasks[binding.runID]
        providerTask?.cancel()
        try await providerAdapter?.cancel(runID: binding.runID)
        await providerTask?.value
        providerTasks[binding.runID] = nil
        try await finishPersistedRun(sessionID: sessionID, binding: binding, state: "canceled", reason: "user-cancel")
        let cursor = try await store.nextCursor()
        let receipt = CommandReceipt(commandID: ids.next(), sessionID: sessionID, operation: command.operation, acceptedCursor: cursor, status: "accepted")
        let event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionCanceled, actor: actor, correlationID: ids.next(), idempotency: idempotency, idempotencyResponse: JSONEncoder.serviceEncoder.encode(receipt))
        await eventHub.publish(event)
        try await updateAgentLifecycle(sessionID: sessionID, state: .canceled, eventType: .agentFailed, actor: actor)
        return receipt
    }

    private func cancelDescendants(rootSessionID: UUID, excluding rootID: UUID, actor: ExternalActor?) async throws {
        let snapshots = try await sessionSnapshots().filter { $0.rootSessionID == rootSessionID && $0.sessionID != rootID }
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
                _ = await child.settle(binding: binding, terminal: .sessionCanceled, lifecycle: .canceled)
                let providerTask = providerTasks[binding.runID]
                providerTask?.cancel()
                try await providerAdapter?.cancel(runID: binding.runID)
                await providerTask?.value
                providerTasks[binding.runID] = nil
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

    private func performProviderRun(sessionID: UUID, binding: RunBindingIdentity, run: ProviderRunSnapshot, prompt: String, workingDirectory: String, permissions: ExecutionPermissionSnapshot) async {
        guard let providerAdapter, let session = sessions[sessionID] else { return }
        defer { Task { await providerAdapter.forgetRun(runID: binding.runID) } }
        let initial = await session.snapshot()
        do {
            let eventState = ProviderEventPublicationState()
            let executionMode: ProviderExecutionMode = switch permissions.mode {
            case "readOnly": .readOnly
            case "workspaceWrite": .workspaceWrite
            case "fullAccess": .fullAccess
            default: throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Execution permission mode is invalid")
            }
            let result = try await providerAdapter.executeStreaming(
                .init(
                    kind: initial.provider,
                    model: initial.model,
                    prompt: prompt,
                    workingDirectory: workingDirectory,
                    maximumBytes: 8_388_608,
                    runID: binding.runID,
                    resumeProviderSessionID: run.providerSessionID,
                    policy: .init(mode: executionMode, writableRoots: executionMode == .workspaceWrite ? [workingDirectory] : [], providerSettings: permissions.providerSettings)
                )
            ) { event in
                await eventState.observe(event)
                await self.handleProviderEvent(event, sessionID: sessionID, run: run, binding: binding)
            }
            let durableIdentity = result.providerSessionID ?? run.providerSessionID
            if let durableIdentity { try await updateAgentProviderIdentity(sessionID: sessionID, providerSessionID: durableIdentity) }
            if !result.output.isEmpty, await !eventState.hasPublishedAssistant() {
                try await publishProviderTranscript(sessionID: sessionID, binding: binding, kind: .assistant, content: result.output, eventType: .transcriptMessage)
            }
            guard let terminalBinding = await session.activeBinding(), terminalBinding.runID == binding.runID else { return }
            try await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: durableIdentity, state: "completed", generation: run.generation, turnEpoch: terminalBinding.turnEpoch, startReason: run.startReason, endReason: "completed", startedAt: run.startedAt, endedAt: clock.now()))
            try await updateAgentLifecycle(sessionID: sessionID, state: .completed, eventType: .agentCompleted, actor: nil)
            guard await session.settle(binding: terminalBinding, terminal: .sessionCompleted, lifecycle: .completed) == .accepted else { return }
            let cursor = try await store.nextCursor()
            let event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionCompleted, actor: nil, correlationID: ids.next(), idempotency: nil)
            await eventHub.publish(event)
        } catch {
            guard let terminalBinding = await session.activeBinding(), terminalBinding.runID == binding.runID else { return }
            try? await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: run.providerSessionID, state: "failed", generation: run.generation, turnEpoch: terminalBinding.turnEpoch, startReason: run.startReason, endReason: error is CancellationError ? "canceled" : "provider-error", startedAt: run.startedAt, endedAt: clock.now()))
            try? await updateAgentLifecycle(sessionID: sessionID, state: .failed, eventType: .agentFailed, actor: nil)
            guard await session.settle(binding: terminalBinding, terminal: .sessionFailed, lifecycle: .failed) == .accepted else { return }
            if let cursor = try? await store.nextCursor(), let event = try? await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: .sessionFailed, actor: nil, correlationID: ids.next(), idempotency: nil) {
                await eventHub.publish(event)
            }
        }
        providerTasks[binding.runID] = nil
        providerToolInvocations[binding.runID] = nil
        providerControlReadyRuns.remove(binding.runID)
    }

    private func handleProviderEvent(_ event: ProviderRuntimeEvent, sessionID: UUID, run: ProviderRunSnapshot, binding: RunBindingIdentity) async {
        do {
            switch event {
            case let .providerIdentity(identity):
                await recordActiveProviderIdentity(sessionID: sessionID, run: run, binding: binding, providerSessionID: identity)
                providerControlReadyRuns.insert(binding.runID)
            case let .assistantDelta(text):
                if !text.isEmpty { try await publishProviderTranscript(sessionID: sessionID, binding: binding, kind: .assistant, content: text, eventType: .transcriptMessage) }
            case let .assistantFinal(text):
                if !text.isEmpty { try await publishProviderTranscript(sessionID: sessionID, binding: binding, kind: .assistant, content: text, eventType: .transcriptMessage) }
            case let .reasoning(text):
                if !text.isEmpty { try await publishProviderTranscript(sessionID: sessionID, binding: binding, kind: .reasoning, content: text, eventType: .transcriptProgress) }
            case let .progress(text):
                if !text.isEmpty { try await publishProviderTranscript(sessionID: sessionID, binding: binding, kind: .progress, content: text, eventType: .transcriptProgress) }
            case let .toolStarted(providerToolID, name, arguments):
                guard let snapshot = try? await sessionSnapshot(sessionID: sessionID) else { return }
                let invocation = ToolInvocationSnapshot(invocationID: ids.next(), toolName: name, state: "running", argumentDigest: CanonicalSigning.bodyDigest(arguments ?? Data()))
                providerToolInvocations[binding.runID, default: [:]][providerToolID] = invocation
                let envelope = try await store.persistToolInvocation(invocation, session: snapshot, actor: nil, correlationID: invocation.invocationID, eventType: .toolStarted)
                await eventHub.publish(envelope)
            case let .toolUpdated(providerToolID, output):
                guard let invocation = providerToolInvocations[binding.runID]?[providerToolID], let snapshot = try? await sessionSnapshot(sessionID: sessionID) else { return }
                let update = ToolInvocationSnapshot(invocationID: invocation.invocationID, toolName: invocation.toolName, state: "running", argumentDigest: invocation.argumentDigest, resultDigest: CanonicalSigning.bodyDigest(Data(output.utf8)))
                let envelope = try await store.persistToolInvocation(update, session: snapshot, actor: nil, correlationID: invocation.invocationID, eventType: .toolUpdated)
                await eventHub.publish(envelope)
            case let .toolCompleted(providerToolID, name, output, failed):
                guard let snapshot = try? await sessionSnapshot(sessionID: sessionID) else { return }
                let prior = providerToolInvocations[binding.runID]?[providerToolID]
                let invocation = ToolInvocationSnapshot(invocationID: prior?.invocationID ?? ids.next(), toolName: prior?.toolName ?? name, state: failed ? "failed" : "completed", argumentDigest: prior?.argumentDigest ?? CanonicalSigning.bodyDigest(Data()), resultDigest: output.map { CanonicalSigning.bodyDigest(Data($0.utf8)) }, errorCode: failed ? .dependencyUnavailable : nil)
                providerToolInvocations[binding.runID]?[providerToolID] = nil
                let envelope = try await store.persistToolInvocation(invocation, session: snapshot, actor: nil, correlationID: invocation.invocationID, eventType: failed ? .toolFailed : .toolCompleted)
                await eventHub.publish(envelope)
            case let .interactionRequested(providerRequestID, kind, prompt, choices):
                let payload = try JSONEncoder.serviceEncoder.encode(ProviderInteractionPayload(providerRequestID: providerRequestID, prompt: prompt, choices: choices))
                _ = try await requestInteraction(sessionID: sessionID, kind: kind == .question ? .question : .approval, payload: payload)
            case .interactionCancelled:
                break
            case .completed:
                break
            }
        } catch {
            // A malformed/duplicate provider frame must not terminate the native
            // transport. Durable lifecycle settlement remains owned by the run.
        }
    }

    private func publishProviderTranscript(sessionID: UUID, binding: RunBindingIdentity, kind: TranscriptEntry.Kind, content: String, eventType: EventType) async throws {
        guard let session = sessions[sessionID], let activeBinding = await session.activeBinding(), activeBinding.runID == binding.runID,
              await session.acceptProviderOutput(binding: activeBinding, kind: kind, content: content) == .accepted
        else { return }
        let cursor = try await store.nextCursor()
        let event = try await store.persistSession(replacingCursor(session.snapshot(), cursor: cursor), eventType: eventType, actor: nil, correlationID: ids.next(), idempotency: nil)
        await eventHub.publish(event)
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

    private func recordActiveProviderIdentity(
        sessionID: UUID,
        run: ProviderRunSnapshot,
        binding: RunBindingIdentity,
        providerSessionID: String
    ) async {
        guard let session = sessions[sessionID], await session.activeBinding() == binding else { return }
        if let persisted = try? await store.latestRun(sessionID: sessionID),
           persisted.runID == run.runID,
           persisted.providerSessionID != providerSessionID
        {
            try? await store.persistRun(ProviderRunSnapshot(
                runID: run.runID,
                sessionID: run.sessionID,
                provider: run.provider,
                providerSessionID: providerSessionID,
                state: "running",
                generation: run.generation,
                turnEpoch: binding.turnEpoch,
                startReason: run.startReason,
                startedAt: run.startedAt
            ))
        }
        try? await updateAgentProviderIdentity(sessionID: sessionID, providerSessionID: providerSessionID)
    }

    private func finishPersistedRun(sessionID: UUID, binding: RunBindingIdentity, state: String, reason: String) async throws {
        guard let run = try await store.latestRun(sessionID: sessionID), run.runID == binding.runID else { return }
        try await store.persistRun(ProviderRunSnapshot(runID: run.runID, sessionID: run.sessionID, provider: run.provider, providerSessionID: run.providerSessionID, state: state, generation: run.generation, turnEpoch: binding.turnEpoch, startReason: run.startReason, endReason: reason, startedAt: run.startedAt, endedAt: clock.now()))
    }

    private func sessionWorktreeBinding(session: SessionSnapshot) async throws -> WorktreeBindingSnapshot? {
        try await store.worktrees(projectID: session.projectID).first {
            $0.sessionID == session.sessionID || $0.sessionID == session.rootSessionID
        }
    }

    private func workingDirectory(session: SessionSnapshot) async throws -> String {
        if let binding = try await sessionWorktreeBinding(session: session) { return binding.physicalPath }
        let project = try await projectSnapshot(projectID: session.projectID)
        if let projectSourceService {
            let workspace = try await projectSourceService.projectWorkspaceDirectory(projectID: project.projectID)
            if project.roots.isEmpty { return workspace }
            let repositories = URL(fileURLWithPath: workspace).appendingPathComponent("repositories").path
            let prefix = repositories.hasSuffix("/") ? repositories : repositories + "/"
            if project.roots.allSatisfy({ $0.canonicalPath.hasPrefix(prefix) }) { return workspace }
        }
        guard let root = project.roots.first else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Empty projects require managed workspace storage")
        }
        return root.canonicalPath
    }

    private func sessionToolAuthority(session: SessionSnapshot) async throws -> ProjectToolAuthority {
        let snapshot = try await projectSnapshot(projectID: session.projectID)
        let binding = try await sessionWorktreeBinding(session: session)
        let roots = try snapshot.roots.map { root -> CanonicalRoot in
            let path = binding?.rootID == root.rootID ? binding?.physicalPath ?? root.canonicalPath : root.canonicalPath
            let canonical = try filesystem.canonicalizeRoot(path)
            let routed = ProjectRootSnapshot(rootID: root.rootID, logicalName: root.logicalName, canonicalPath: canonical.path, writable: root.writable)
            return CanonicalRoot(snapshot: routed, filesystemIdentity: canonical.identity)
        }
        let routedSnapshot = ProjectSnapshot(projectID: snapshot.projectID, name: snapshot.name, creator: snapshot.creator, state: snapshot.state, roots: roots.map(\.snapshot), revision: snapshot.revision, cursor: snapshot.cursor)
        return ProjectToolAuthority(project: ProjectAuthority(snapshot: routedSnapshot, roots: roots), filesystem: filesystem, commandRunner: commandRunner)
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: value.state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }

    private func replacingLifecycle(_ value: SessionSnapshot, state: SessionLifecycleState, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision + 1, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }

    private static func bindingSnapshot(_ binding: RunBindingIdentity) -> RunBindingSnapshot {
        RunBindingSnapshot(
            runID: binding.runID,
            generation: binding.generation,
            turnEpoch: binding.turnEpoch,
            connectionGeneration: binding.connectionGeneration
        )
    }

}

private struct ContextBuilderQuestionPayload: Codable {
    let authorityOperation: String
    let prompt: String
    let choices: [String]

    init(prompt: String, choices: [String]) {
        authorityOperation = "context_builder.ask_user"
        self.prompt = prompt
        self.choices = choices
    }
}

private actor ProviderEventPublicationState {
    private var didPublishAssistant = false

    func observe(_ event: ProviderRuntimeEvent) {
        switch event {
        case .assistantDelta, .assistantFinal:
            didPublishAssistant = true
        default:
            break
        }
    }

    func hasPublishedAssistant() -> Bool {
        didPublishAssistant
    }
}
