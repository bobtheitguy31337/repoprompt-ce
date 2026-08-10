import Foundation
import Hummingbird
import NIOSSL
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct RepoPromptHTTPService: Sendable {
    private enum SSEFrame {
        case event(EventEnvelope)
        case heartbeat
    }

    private let authority: RepoPromptHeadlessAuthority
    private let store: SQLiteServiceStore
    private let authenticator: InternalRequestAuthenticator
    private let responseSigner: InternalResponseSigner
    private let certificateRoleResolver: CertificateIdentityRoleResolver?
    private let readiness: RepoPromptReadinessService
    private let drainController: MutationDrainController
    private let durabilityOperations: DurabilityOperationsService?

    public init(
        authority: RepoPromptHeadlessAuthority,
        store: SQLiteServiceStore,
        authenticator: InternalRequestAuthenticator,
        eventSigningKey: InternalSigningKey,
        certificateRoleResolver: CertificateIdentityRoleResolver? = nil,
        readiness: RepoPromptReadinessService? = nil,
        drainController: MutationDrainController = MutationDrainController(),
        durabilityOperations: DurabilityOperationsService? = nil
    ) {
        self.authority = authority
        self.store = store
        self.authenticator = authenticator
        responseSigner = InternalResponseSigner(key: eventSigningKey)
        self.certificateRoleResolver = certificateRoleResolver
        self.drainController = drainController
        self.durabilityOperations = durabilityOperations
        self.readiness = readiness ?? RepoPromptReadinessService(
            authority: authority,
            store: store,
            drainController: drainController
        )
    }

    public func healthRouter() -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        router.get("/health/live") { _, _ in Response(status: .ok) }
        router.get("/health/ready") { _, _ in await readiness.snapshot().ready ? Response(status: .ok) : Response(status: .serviceUnavailable) }
        return router
    }

    public func internalRouter() -> Router<RepoPromptRequestContext> {
        let router = Router<RepoPromptRequestContext>(context: RepoPromptRequestContext.self)
        router.get("/internal/v1/capabilities") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp, .goblinSync], operation: "capabilities")
            let meta = try await store.metadata()
            return try HTTPResponses.json(ServiceCapabilitiesResponse(
                protocolRange: .init(minimum: 1, maximum: 1),
                schemaVersion: meta.schemaVersion,
                storeID: meta.storeID,
                replayFloor: meta.replayFloor,
                providers: await providerCatalog(),
                models: [],
                workflows: try await authority.workflowSnapshots(),
                executionModes: executionModeCatalog(),
                eventTypes: EventType.allCases,
                projectSources: await authority.projectSourceCapabilities()
            ))
        } }
        router.get("/internal/v1/diagnostics") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "diagnostics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot(forceRefresh: true)
            return try HTTPResponses.json(RepoPromptDiagnostics(
                storeID: meta.storeID,
                schemaVersion: meta.schemaVersion,
                nextGlobalSequence: meta.nextGlobalSequence,
                replayFloor: meta.replayFloor,
                readiness: currentReadiness,
                operational: currentReadiness.operational,
                drain: currentReadiness.drain,
                maintenance: await durabilityOperations?.snapshot()
            ))
        } }
        router.get("/metrics") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "metrics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot()
            let operational = currentReadiness.operational
            var lines = [
                "repoprompt_ready \(currentReadiness.ready ? 1 : 0)",
                "repoprompt_event_latest_sequence \(max(0, meta.nextGlobalSequence - 1))",
                "repoprompt_event_replay_floor \(meta.replayFloor)",
                "repoprompt_event_live_count \(operational?.liveEventCount ?? 0)",
                "repoprompt_event_archive_segments \(operational?.archiveSegmentCount ?? 0)",
                "repoprompt_event_archive_events \(operational?.archivedEventCount ?? 0)",
                "repoprompt_event_archive_compressed_bytes \(operational?.compressedArchiveBytes ?? 0)",
                "repoprompt_active_sessions \(currentReadiness.activeSessionCount)",
                "repoprompt_degraded_projects \(currentReadiness.degradedProjectIDs.count)",
                "repoprompt_mutations_in_flight \(currentReadiness.drain.inFlightMutations)",
                "repoprompt_mutations_accepting \(currentReadiness.drain.acceptingMutations ? 1 : 0)",
                "repoprompt_process_families_active \(operational?.activeProcessFamilyCount ?? 0)",
                "repoprompt_sqlite_bytes \(operational?.databaseBytes ?? 0)",
                "repoprompt_sqlite_wal_bytes \(operational?.walBytes ?? 0)"
            ]
            for aggregate in operational?.ownedResources.aggregates ?? [] {
                lines.append("repoprompt_owned_resources{kind=\"\(aggregate.kind.rawValue)\",state=\"\(aggregate.state.rawValue)\"} \(aggregate.count)")
                lines.append("repoprompt_owned_resource_bytes{kind=\"\(aggregate.kind.rawValue)\",state=\"\(aggregate.state.rawValue)\"} \(aggregate.bytes)")
            }
            for checkpoint in operational?.checkpointCounts ?? [] {
                lines.append("repoprompt_checkpoints{retention=\"\(checkpoint.retentionClass)\"} \(checkpoint.count)")
            }
            let text = lines.joined(separator: "\n") + "\n"
            var headers = HTTPFields()
            headers[.contentType] = "text/plain; version=0.0.4"
            headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(Data(text.utf8))
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
        } }

        router.get("/internal/v1/projects") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listProjects")
            let projects = await authority.projectSnapshots().map(ProjectWireSnapshot.init)
            return try await HTTPResponses.json(page(projects, request: request, defaultLimit: 100, maximumLimit: 500) { $0.projectID.uuidString })
        } }
        router.post("/internal/v1/projects") { request, context in await respond(request) { let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "createProject")
            let input = try JSONDecoder.serviceDecoder.decode(CreateProjectInput.self, from: data)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let snapshot = try await authority.createProject(input: input, externalActor: actor, idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot), status: .created)
        } }
        router.post("/internal/v1/project-source-operations") { request, context in await respond(request) { let data = try await bodyData(request)
            let auth = try await authenticate(
                request,
                context: context,
                body: data,
                roles: [.goblinApp],
                operation: "createProjectFromSource"
            )
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSourceOperationInput.self, from: data)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let result = try await authority.createProjectFromSource(
                input: input,
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try HTTPResponses.json(result, status: .created)
        } }
        router.patch("/internal/v1/projects/:id") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(UpdateProjectInput.self, from: data)
            let snapshot = try await authority.updateProject(projectID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot))
        } }
        router.delete("/internal/v1/projects/:id") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "removeProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(RemoveProjectInput.self, from: data)
            try await authority.removeProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return HTTPResponses.empty()
        } }
        router.get("/internal/v1/projects/:id/snapshot") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(ProjectWireSnapshot(authority.projectSnapshot(projectID: id)))
        } }
        router.get("/internal/v1/projects/:id/tree") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getProjectTree", projectID: id)
            let rootID = try requireQueryUUID(request, name: "rootId")
            let path = String(request.uri.queryParameters["path"] ?? "")
            let depth = request.uri.queryParameters.get("depth", as: Int.self) ?? 4
            let maximumEntries = request.uri.queryParameters.get("limit", as: Int.self) ?? 5000
            guard (0 ... 16).contains(depth), (1 ... 5000).contains(maximumEntries) else { throw ServiceAPIError(code: .invalidRequest, message: "Tree bounds exceed the v1 limit") }
            return try await HTTPResponses.json(authority.projectTree(projectID: id, request: ProjectTreeRequest(rootID: rootID, logicalPath: path, maximumDepth: depth, maximumEntries: maximumEntries)))
        } }
        router.post("/internal/v1/projects/:id/search") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "searchProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSearchRequest.self, from: data)
            guard (1 ... 500).contains(input.maximumResults), (1 ... 2_097_152).contains(input.maximumFileBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "Search bounds exceed the v1 limit") }
            return try await HTTPResponses.json(authority.projectSearch(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/file") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "getFile", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectFileRequest.self, from: data)
            guard (1 ... 2_097_152).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "File bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectFile(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/codemap") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "getCodeMap", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectCodeMapRequest.self, from: data)
            guard (1 ... 5_242_880).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "CodeMap bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectCodeMap(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/diff") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "getDiff", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectDiffRequest.self, from: data)
            guard (1 ... 2_097_152).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "Diff bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectDiff(projectID: id, request: input))
        } }
        router.get("/internal/v1/projects/:id/worktrees") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listWorktrees", projectID: id)
            let worktrees = try await authority.worktreeSnapshots(projectID: id).map(WorktreeWireSnapshot.init)
            return try await HTTPResponses.json(page(worktrees, request: request, defaultLimit: 100, maximumLimit: 500) { $0.bindingID.uuidString })
        } }
        router.get("/internal/v1/projects/:id/worktrees/:worktreeId") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getWorktree", projectID: id)
            return try await HTTPResponses.json(WorktreeWireSnapshot(authority.worktreeSnapshot(projectID: id, bindingID: bindingID)))
        } }
        router.post("/internal/v1/projects/:id/refresh") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "refreshProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectRefreshInput.self, from: data)
            let snapshot = try await authority.refreshProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot))
        } }
        router.get("/internal/v1/projects/:id/context/selection-template") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSelectionTemplate(projectID: id))
        } }
        router.put("/internal/v1/projects/:id/context/selection-template") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSelectionTemplateMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.replaceProjectSelectionTemplate(projectID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }

        router.get("/internal/v1/sessions") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listSessions")
            let sessions = try await authority.sessionSnapshots()
            return try await HTTPResponses.json(page(sessions, request: request, defaultLimit: 100, maximumLimit: 500) { $0.sessionID.uuidString })
        } }
        router.post("/internal/v1/sessions") { request, context in await respond(request) { let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CreateSessionInput.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "startSession", projectID: input.projectID)
            guard input.parentSessionID == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Public session creation cannot specify parentSessionID; child agents are created by agent_manage") }
            let snapshot = try await authority.createSession(input: input, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(snapshot, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/snapshot") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getSession", sessionID: id)
            return try await HTTPResponses.json(authority.sessionSnapshot(sessionID: id))
        } }
        router.get("/internal/v1/sessions/:id/transcript") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getTranscript", sessionID: id)
            let transcript = try await authority.sessionSnapshot(sessionID: id).transcript
            return try await HTTPResponses.json(page(transcript, request: request, defaultLimit: 200, maximumLimit: 1000) { String(format: "%020lld", $0.sessionSequence) })
        } }
        router.post("/internal/v1/sessions/:id/commands") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let command = try JSONDecoder.serviceDecoder.decode(SessionCommand.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: command.operation, sessionID: id)
            let receipt = try await authority.execute(command: command, sessionID: id, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try HTTPResponses.json(receipt, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/context/selection") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getSelection", sessionID: id)
            return try await HTTPResponses.json(authority.selectionSnapshot(sessionID: id))
        } }
        router.put("/internal/v1/sessions/:id/context/selection") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "replaceSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.replaceSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/add") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "addToSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.addSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/remove") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "removeFromSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionRemovalInput.self, from: data)
            return try await HTTPResponses.json(authority.removeSelection(sessionID: id, rootID: input.rootID, logicalPaths: input.logicalPaths, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.get("/internal/v1/sessions/:id/permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getExecutionPermissions", sessionID: id)
            guard let snapshot = try await authority.permissionSnapshot(sessionID: id) else { return Response(status: .noContent) }
            return try HTTPResponses.json(snapshot)
        } }
        router.patch("/internal/v1/sessions/:id/permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateExecutionPermissions", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.patch("/internal/v1/sessions/:id/execution-permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateExecutionPermissions", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.patch("/internal/v1/sessions/:id/collaboration-metadata") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CollaborationMetadataInput.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "setSessionVisibility", sessionID: id)
            return try await HTTPResponses.json(authority.updateCollaborationMetadata(sessionID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }
        router.get("/internal/v1/sessions/:id/interactions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getInteractions", sessionID: id)
            let interactions = try await authority.interactionSnapshots(sessionID: id)
            return try await HTTPResponses.json(page(interactions, request: request, defaultLimit: 100, maximumLimit: 500) { $0.interactionID.uuidString })
        } }
        router.post("/internal/v1/sessions/:id/interactions/answer") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "answerInteraction", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: input.interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/interactions/:interactionId/answer") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let interactionID = try context.parameters.require("interactionId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "answerInteraction", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            guard input.interactionID == interactionID else { throw ServiceAPIError(code: .invalidRequest, message: "Interaction path and body IDs do not match") }
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/worktrees") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "createWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeCreateInput.self, from: data)
            let snapshot = try await authority.createWorktree(sessionID: id, rootID: input.rootID, baseRef: input.baseRef, branch: input.branch, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/worktrees/merge") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "mergeWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            let snapshot = try await authority.mergeWorktree(sessionID: id, bindingID: input.bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.patch("/internal/v1/sessions/:id/worktree-binding") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "bindWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeBindInput.self, from: data)
            let snapshot = try await authority.bindWorktree(sessionID: id, bindingID: input.bindingID, expectedRevision: input.expectedRevision, expectedSelectionBindingRevision: input.expectedSelectionBindingRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.post("/internal/v1/sessions/:id/worktrees/:worktreeId/merge") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "mergeWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            guard input.bindingID == bindingID else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree path and body IDs do not match") }
            let snapshot = try await authority.mergeWorktree(sessionID: id, bindingID: bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.get("/internal/v1/sessions/:id/artifacts") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getArtifacts", sessionID: id)
            let artifacts = try await authority.artifactSnapshots(sessionID: id)
            return try await HTTPResponses.json(page(artifacts, request: request, defaultLimit: 100, maximumLimit: 500) { $0.artifactID.uuidString })
        } }
        router.get("/internal/v1/sessions/:id/artifacts/:artifactId/content") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let artifactID = try context.parameters.require("artifactId", as: UUID.self)
            let requestedRange = try parseByteRange(request.headers[.range])
            let signedTarget = requestedRange.map {
                "\(request.uri.string)#range=bytes=\($0.lowerBound)-\($0.upperBound - 1)"
            } ?? request.uri.string
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "downloadArtifact", sessionID: id, pathAndQuery: signedTarget)
            let result = try await authority.artifactContent(sessionID: id, artifactID: artifactID, range: requestedRange)
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            headers[.cacheControl] = "no-store"
            headers[.contentLength] = String(result.1.count)
            headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(result.1)
            let partial = result.2.lowerBound != 0 || result.2.upperBound != Int(result.0.size)
            if partial { headers[.contentRange] = "bytes \(result.2.lowerBound)-\(max(result.2.lowerBound, result.2.upperBound - 1))/\(result.0.size)" }
            return Response(status: partial ? .partialContent : .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: result.1)))
        } }
        router.get("/internal/v1/catalog/workflows") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listWorkflows")
            let workflows = try await authority.workflowSnapshots()
            return try await HTTPResponses.json(page(workflows, request: request, defaultLimit: 100, maximumLimit: 500) { $0.workflowID })
        } }
        router.get("/internal/v1/catalog/workflows/:id") { request, context in await respond(request) {
            let id = try context.parameters.require("id")
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getWorkflow")
            return try await HTTPResponses.json(authority.workflowSnapshot(workflowID: id))
        } }
        router.get("/internal/v1/catalog/providers") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listProviders")
            let providers = await providerCatalog()
            return try await HTTPResponses.json(page(providers, request: request, defaultLimit: 100, maximumLimit: 500) { $0.kind.rawValue })
        } }
        router.get("/internal/v1/catalog/models") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listModels")
            return try await HTTPResponses.json(page([ModelCatalogItem](), request: request, defaultLimit: 100, maximumLimit: 500) { $0.id })
        } }
        router.get("/internal/v1/catalog/execution-modes") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listExecutionModes")
            return try await HTTPResponses.json(page(executionModeCatalog(), request: request, defaultLimit: 100, maximumLimit: 500) { $0.id })
        } }
        router.get("/internal/v1/sessions/:id/children") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listSessionChildren", sessionID: id)
            let children = try await authority.childSessionSnapshots(parentSessionID: id)
            return try await HTTPResponses.json(page(children, request: request, defaultLimit: 100, maximumLimit: 500) { $0.sessionID.uuidString })
        } }
        router.post("/internal/v1/sessions/:id/context/build") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "buildContext", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuildInput.self, from: data)
            return try await HTTPResponses.json(authority.buildContext(sessionID: id, expectedSelectionRevision: input.expectedSelectionRevision, include: input.include, actor: requireActor(auth)), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/context/context-builder") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "runContextBuilder", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuilderInput.self, from: data)
            guard (1 ... 1_000_000).contains(input.budget) else { throw ServiceAPIError(code: .invalidRequest, message: "Context Builder budget exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.runContextBuilder(sessionID: id, input: input, actor: requireActor(auth)))
        } }
        router.post("/internal/v1/sessions/:id/context/oracle") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "askOracle", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(OracleInput.self, from: data)
            return try await HTTPResponses.json(authority.askOracle(sessionID: id, input: input, actor: requireActor(auth)))
        } }

        router.get("/internal/v1/events") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinSync], operation: "events")
            let cursor = try parseCursor(request)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 500
            guard (1 ... 1000).contains(limit) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Event replay limit is outside the v1 bound")
            }
            return try await HTTPResponses.json(authority.events(after: cursor, limit: limit))
        } }
        router.get("/internal/v1/events/stream") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinSync], operation: "eventStream")
            let stream: AsyncThrowingStream<EventEnvelope, Error>
            do {
                stream = try await authority.subscribe(after: parseCursor(request))
            } catch let error as ServiceAPIError where error.code == .cursorExpired {
                return try cursorExpiredStream(error)
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-store"
            headers[.internalBodyDigest] = CanonicalSigning.bodyDigest(Data())
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in try await writer.write(ByteBuffer(string: ": repoprompt-stream-v1\n\n"))
                for try await frame in heartbeatFrames(stream) {
                    switch frame {
                    case let .event(event):
                        let json = String(decoding: try JSONEncoder.serviceEncoder.encode(event), as: UTF8.self)
                        try await writer.write(ByteBuffer(string: "id: \(event.storeID.uuidString):\(event.globalSequence)\nevent: \(event.eventType.rawValue)\ndata: \(json)\n\n"))
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        } }
        router.get("/internal/v1/snapshot") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinSync], operation: "snapshot")
            return try await HTTPResponses.json(AuthoritativeWireSnapshot(authority.authoritativeSnapshot()))
        } }
        router.post("/internal/v1/admin/checkpoint") { request, context in await respond(request) { let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "checkpoint")
            try await store.checkpoint()
            return HTTPResponses.empty()
        } }
        router.post("/internal/v1/admin/quiesce") { request, context in await respond(request) { let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "quiesce")
            await drainController.startDrain()
            try await authority.quiesce()
            return Response(status: .accepted)
        } }

        return router
    }

    private func respond(_ request: Request, _ operation: () async throws -> Response) async -> Response {
        let method = String(describing: request.method).uppercased()
        let path = request.uri.string
        let isMutation = method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE"
        guard isMutation else {
            let response: Response
            do { response = try await operation() } catch { response = HTTPResponses.error(error) }
            return responseSigner.sign(response, requestPathAndQuery: path)
        }
        guard await drainController.beginMutation() else {
            return responseSigner.sign(HTTPResponses.error(ServiceAPIError(code: .quiescing, message: "Service is draining mutations", retryable: true)), requestPathAndQuery: path)
        }
        let response: Response
        do {
            response = try await operation()
        } catch {
            response = HTTPResponses.error(error)
        }
        await drainController.finishMutation()
        return responseSigner.sign(response, requestPathAndQuery: path)
    }

    private struct PageToken: Codable {
        let storeID: UUID
        let globalSequence: Int64
        let offset: Int

        private enum CodingKeys: String, CodingKey {
            case storeID = "storeId"
            case globalSequence, offset
        }
    }

    private func page<Item: Codable & Sendable>(
        _ items: [Item],
        request: Request,
        defaultLimit: Int,
        maximumLimit: Int,
        sortKey: (Item) -> String
    ) async throws -> Page<Item> {
        let requestedLimit = request.uri.queryParameters.get("limit", as: Int.self) ?? defaultLimit
        guard requestedLimit > 0, requestedLimit <= maximumLimit else {
            throw ServiceAPIError(code: .invalidRequest, message: "Pagination limit is outside the v1 bound")
        }
        let metadata = try await store.metadata()
        let cursor = ServiceCursor(storeID: metadata.storeID, globalSequence: max(0, metadata.nextGlobalSequence - 1))
        let offset: Int
        if let encoded = request.uri.queryParameters["pageToken"] {
            guard let data = CanonicalSigning.base64URLDecode(String(encoded)),
                  let token = try? JSONDecoder.serviceDecoder.decode(PageToken.self, from: data),
                  token.storeID == cursor.storeID,
                  token.globalSequence == cursor.globalSequence,
                  token.offset >= 0
            else {
                throw ServiceAPIError(code: .staleRevision, message: "Pagination token is stale or invalid", cursor: cursor)
            }
            offset = token.offset
        } else {
            offset = 0
        }
        let ordered = items.sorted { sortKey($0) < sortKey($1) }
        guard offset <= ordered.count else { throw ServiceAPIError(code: .invalidRequest, message: "Pagination offset is invalid") }
        let end = min(ordered.count, offset + requestedLimit)
        let nextToken: String?
        if end < ordered.count {
            nextToken = CanonicalSigning.base64URLEncode(try JSONEncoder.serviceEncoder.encode(PageToken(storeID: cursor.storeID, globalSequence: cursor.globalSequence, offset: end)))
        } else {
            nextToken = nil
        }
        return Page(items: Array(ordered[offset ..< end]), nextPageToken: nextToken, cursor: cursor)
    }

    private func providerCatalog() async -> [ProviderCatalogItem] {
        await authority.providerCapabilities().map { capability in
            ProviderCatalogItem(
                kind: capability.kind,
                enabled: capability.enabled,
                version: capability.version,
                protocolVersion: capability.protocolVersion,
                supportsResume: capability.supportsResume,
                supportsSteering: capability.supportsSteering,
                reasonUnavailable: capability.reasonUnavailable == nil ? nil : "provider_unavailable"
            )
        }
    }

    private func executionModeCatalog() -> [ExecutionModeCatalogItem] {
        let providers = ProviderKind.allCases
        return [
            .init(id: "readOnly", displayName: "Read only", allowsWorkspaceWrites: false, allowsUnrestrictedHostAccess: false, providers: providers),
            .init(id: "workspaceWrite", displayName: "Workspace write", allowsWorkspaceWrites: true, allowsUnrestrictedHostAccess: false, providers: providers),
            .init(id: "fullAccess", displayName: "Full access", allowsWorkspaceWrites: true, allowsUnrestrictedHostAccess: true, providers: providers)
        ]
    }

    private func bodyData(_ request: Request) async throws -> Data {
        let buffer = try await request.body.collect(upTo: 1_048_576)
        return Data(buffer.readableBytesView)
    }

    private func authenticate(_ request: Request, context: RepoPromptRequestContext, body: Data, roles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil, pathAndQuery: String? = nil) async throws -> AuthenticatedInternalRequest {
        guard let keyID = request.headers[.internalKeyID], let timestamp = request.headers[.internalTimestamp], let nonce = request.headers[.internalNonce], let bodyDigest = request.headers[.internalBodyDigest], let signature = request.headers[.internalSignature] else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signed internal headers are required") }
        let decisionData = request.headers[.goblinAuthorizationDecision].flatMap(CanonicalSigning.base64URLDecode)
        let authenticated = try await authenticator.verify(SignedInternalRequest(method: String(describing: request.method), pathAndQuery: pathAndQuery ?? request.uri.string, timestamp: timestamp, nonce: nonce, body: body, bodyDigest: bodyDigest, authorizationDecisionData: decisionData, authorizationDecisionDigest: request.headers[.internalAuthorizationDigest], keyID: keyID, signature: signature), allowedRoles: roles, operation: operation, projectID: projectID, sessionID: sessionID)
        if let certificateRoleResolver {
            guard let certificate = try await context.channel.nioSSL_peerCertificate().get() else { throw ServiceAPIError(code: .internalAuthFailed, message: "A client certificate is required") }
            guard try certificateRoleResolver.role(certificate: certificate) == authenticated.role else { throw ServiceAPIError(code: .internalAuthFailed, message: "Client certificate and HMAC roles do not match") }
        }
        return authenticated
    }

    private func requireActor(_ auth: AuthenticatedInternalRequest) throws -> ExternalActor {
        guard let actor = auth.decision?.actor else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Human actor attribution is required") }
        return actor
    }

    private func requireIdempotency(_ request: Request) throws -> String {
        guard let value = request.headers[.idempotencyKey], !value.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Idempotency-Key is required") }
        return value
    }

    private func requireQueryUUID(_ request: Request, name: String) throws -> UUID {
        guard let value = request.uri.queryParameters[Substring(name)], let id = UUID(uuidString: String(value)) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Query parameter \(name) must be a UUID")
        }
        return id
    }

    private func parseCursor(_ request: Request) throws -> ServiceCursor? {
        let query = request.uri.queryParameters["after"].map(String.init)
        let header = request.headers[.init("Last-Event-ID")!]
        if let query, let header, query != header {
            throw ServiceAPIError(code: .invalidRequest, message: "after and Last-Event-ID cursors disagree")
        }
        guard let after = query ?? header else { return nil }
        let parts = after.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let storeID = UUID(uuidString: String(parts[0])), let sequence = Int64(parts[1]), sequence >= 0 else { throw ServiceAPIError(code: .invalidRequest, message: "Cursor must be storeId:sequence") }
        return ServiceCursor(storeID: storeID, globalSequence: sequence)
    }

    private func parseByteRange(_ value: String?) throws -> Range<Int>? {
        guard let value else { return nil }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw ServiceAPIError(code: .invalidRequest, message: "Only one bounded byte range is supported") }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int(bounds[0]), let inclusiveUpper = Int(bounds[1]), lower >= 0, inclusiveUpper >= lower, inclusiveUpper < Int.max, inclusiveUpper - lower < 8 * 1024 * 1024 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Byte range must be bytes=start-end")
        }
        return lower ..< inclusiveUpper + 1
    }

    private func heartbeatFrames(_ source: AsyncThrowingStream<EventEnvelope, Error>) -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await event in source {
                                continuation.yield(.event(event))
                            }
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(15))
                                continuation.yield(.heartbeat)
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func cursorExpiredStream(_ error: ServiceAPIError) throws -> Response {
        guard let cursor = error.cursor else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Cursor transition metadata is unavailable", retryable: true)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-store"
        let transition = CursorExpiredResponse(storeID: cursor.storeID, replayFloor: cursor.globalSequence)
        let payload = String(decoding: try JSONEncoder.serviceEncoder.encode(transition), as: UTF8.self)
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            try await writer.write(ByteBuffer(string: "event: cursor_expired\ndata: \(payload)\n\n"))
            try await writer.finish(nil)
        })
    }
}
