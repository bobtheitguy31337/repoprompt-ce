import Foundation
import Hummingbird
import NIOSSL
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
    private let eventSigningKey: InternalSigningKey?
    private let certificateRoleResolver: CertificateIdentityRoleResolver?
    private let readiness: RepoPromptReadinessService

    public init(authority: RepoPromptHeadlessAuthority, store: SQLiteServiceStore, authenticator: InternalRequestAuthenticator, eventSigningKey: InternalSigningKey? = nil, certificateRoleResolver: CertificateIdentityRoleResolver? = nil, readiness: RepoPromptReadinessService? = nil) {
        self.authority = authority
        self.store = store
        self.authenticator = authenticator
        self.eventSigningKey = eventSigningKey
        self.certificateRoleResolver = certificateRoleResolver
        self.readiness = readiness ?? RepoPromptReadinessService(authority: authority, store: store)
    }

    public func healthRouter() -> Router<BasicRequestContext> {
        let router = Router<BasicRequestContext>()
        router.get("/health/live") { _, _ in Response(status: .ok) }
        router.get("/health/ready") { _, _ in await readiness.snapshot().ready ? Response(status: .ok) : Response(status: .serviceUnavailable) }
        return router
    }

    public func internalRouter() -> Router<RepoPromptRequestContext> {
        let router = Router<RepoPromptRequestContext>(context: RepoPromptRequestContext.self)
        router.get("/internal/v1/capabilities") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp, .goblinSync], operation: "capabilities")
            return try await HTTPResponses.json(authority.capabilities())
        } }
        router.get("/internal/v1/diagnostics") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "diagnostics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot()
            return try HTTPResponses.json(RepoPromptDiagnostics(storeID: meta.storeID, schemaVersion: meta.schemaVersion, nextGlobalSequence: meta.nextGlobalSequence, replayFloor: meta.replayFloor, readiness: currentReadiness))
        } }
        router.get("/metrics") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "metrics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot()
            let degradedCount = currentReadiness.degradedProjectIDs.count
            let text = "repoprompt_ready \(currentReadiness.ready ? 1 : 0)\nrepoprompt_event_latest_sequence \(max(0, meta.nextGlobalSequence - 1))\nrepoprompt_active_sessions \(currentReadiness.activeSessionCount)\nrepoprompt_degraded_projects \(degradedCount)\n"
            var headers = HTTPFields()
            headers[.contentType] = "text/plain; version=0.0.4"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
        } }

        router.get("/internal/v1/projects") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listProjects")
            return try await HTTPResponses.json(authority.projectSnapshots())
        } }
        router.post("/internal/v1/projects") { request, context in await respond { let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "createProject")
            let input = try JSONDecoder.serviceDecoder.decode(CreateProjectInput.self, from: data)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let snapshot = try await authority.createProject(input: input, externalActor: actor, idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(snapshot, status: .created)
        } }
        router.patch("/internal/v1/projects/:id") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(UpdateProjectInput.self, from: data)
            return try await HTTPResponses.json(authority.updateProject(projectID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.delete("/internal/v1/projects/:id") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "removeProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(RemoveProjectInput.self, from: data)
            try await authority.removeProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return Response(status: .noContent)
        } }
        router.get("/internal/v1/projects/:id/snapshot") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSnapshot(projectID: id))
        } }
        router.get("/internal/v1/projects/:id/tree") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getProjectTree", projectID: id)
            let rootID = try requireQueryUUID(request, name: "rootId")
            let path = String(request.uri.queryParameters["path"] ?? "")
            let depth = request.uri.queryParameters.get("depth", as: Int.self) ?? 4
            return try await HTTPResponses.json(authority.projectTree(projectID: id, request: ProjectTreeRequest(rootID: rootID, logicalPath: path, maximumDepth: depth)))
        } }
        router.post("/internal/v1/projects/:id/search") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "searchProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSearch(projectID: id, request: JSONDecoder.serviceDecoder.decode(ProjectSearchRequest.self, from: data)))
        } }
        router.post("/internal/v1/projects/:id/file") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "getFile", projectID: id)
            return try await HTTPResponses.json(authority.projectFile(projectID: id, request: JSONDecoder.serviceDecoder.decode(ProjectFileRequest.self, from: data)))
        } }
        router.post("/internal/v1/projects/:id/codemap") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "getCodeMap", projectID: id)
            return try await HTTPResponses.json(authority.projectCodeMap(projectID: id, request: JSONDecoder.serviceDecoder.decode(ProjectCodeMapRequest.self, from: data)))
        } }
        router.post("/internal/v1/projects/:id/diff") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "getDiff", projectID: id)
            return try await HTTPResponses.json(authority.projectDiff(projectID: id, request: JSONDecoder.serviceDecoder.decode(ProjectDiffRequest.self, from: data)))
        } }
        router.get("/internal/v1/projects/:id/worktrees") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listWorktrees", projectID: id)
            return try await HTTPResponses.json(authority.worktreeSnapshots(projectID: id))
        } }
        router.get("/internal/v1/projects/:id/worktrees/:worktreeId") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getWorktree", projectID: id)
            return try await HTTPResponses.json(authority.worktreeSnapshot(projectID: id, bindingID: bindingID))
        } }
        router.post("/internal/v1/projects/:id/refresh") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "refreshProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectRefreshInput.self, from: data)
            return try await HTTPResponses.json(authority.refreshProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.get("/internal/v1/projects/:id/context/selection-template") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSelectionTemplate(projectID: id))
        } }
        router.put("/internal/v1/projects/:id/context/selection-template") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSelectionTemplateMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.replaceProjectSelectionTemplate(projectID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }

        router.get("/internal/v1/sessions") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listSessions")
            return try await HTTPResponses.json(authority.sessionSnapshots())
        } }
        router.post("/internal/v1/sessions") { request, context in await respond { let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CreateSessionInput.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "startSession", projectID: input.projectID)
            guard input.parentSessionID == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Public session creation cannot specify parentSessionID; child agents are created by agent_manage") }
            let snapshot = try await authority.createSession(input: input, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(snapshot, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/snapshot") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getSession", sessionID: id)
            return try await HTTPResponses.json(authority.sessionSnapshot(sessionID: id))
        } }
        router.get("/internal/v1/sessions/:id/transcript") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getTranscript", sessionID: id)
            return try await HTTPResponses.json(authority.sessionSnapshot(sessionID: id).transcript)
        } }
        router.post("/internal/v1/sessions/:id/commands") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let command = try JSONDecoder.serviceDecoder.decode(SessionCommand.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: command.operation, sessionID: id)
            let receipt = try await authority.execute(command: command, sessionID: id, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(receipt, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/context/selection") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getSelection", sessionID: id)
            return try await HTTPResponses.json(authority.selectionSnapshot(sessionID: id))
        } }
        router.put("/internal/v1/sessions/:id/context/selection") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "replaceSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.replaceSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/add") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "addToSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.addSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/remove") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "removeFromSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionRemovalInput.self, from: data)
            return try await HTTPResponses.json(authority.removeSelection(sessionID: id, rootID: input.rootID, logicalPaths: input.logicalPaths, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.get("/internal/v1/sessions/:id/permissions") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getExecutionPermissions", sessionID: id)
            guard let snapshot = try await authority.permissionSnapshot(sessionID: id) else { return Response(status: .noContent) }
            return try HTTPResponses.json(snapshot)
        } }
        router.patch("/internal/v1/sessions/:id/permissions") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateExecutionPermissions", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.patch("/internal/v1/sessions/:id/execution-permissions") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "updateExecutionPermissions", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.patch("/internal/v1/sessions/:id/collaboration-metadata") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CollaborationMetadataInput.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "setSessionVisibility", sessionID: id)
            return try await HTTPResponses.json(authority.updateCollaborationMetadata(sessionID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.get("/internal/v1/sessions/:id/interactions") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getInteractions", sessionID: id)
            return try await HTTPResponses.json(authority.interactionSnapshots(sessionID: id))
        } }
        router.post("/internal/v1/sessions/:id/interactions/answer") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "answerInteraction", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: input.interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/interactions/:interactionId/answer") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let interactionID = try context.parameters.require("interactionId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "answerInteraction", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            guard input.interactionID == interactionID else { throw ServiceAPIError(code: .invalidRequest, message: "Interaction path and body IDs do not match") }
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/worktrees") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "createWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeCreateInput.self, from: data)
            return try await HTTPResponses.json(authority.createWorktree(sessionID: id, rootID: input.rootID, baseRef: input.baseRef, branch: input.branch, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/worktrees/merge") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "mergeWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            return try await HTTPResponses.json(authority.mergeWorktree(sessionID: id, bindingID: input.bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.patch("/internal/v1/sessions/:id/worktree-binding") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "bindWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeBindInput.self, from: data)
            return try await HTTPResponses.json(authority.bindWorktree(sessionID: id, bindingID: input.bindingID, expectedRevision: input.expectedRevision, expectedSelectionBindingRevision: input.expectedSelectionBindingRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.post("/internal/v1/sessions/:id/worktrees/:worktreeId/merge") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "mergeWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            guard input.bindingID == bindingID else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree path and body IDs do not match") }
            return try await HTTPResponses.json(authority.mergeWorktree(sessionID: id, bindingID: bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }
        router.get("/internal/v1/sessions/:id/artifacts") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getArtifacts", sessionID: id)
            return try await HTTPResponses.json(authority.artifactSnapshots(sessionID: id))
        } }
        router.get("/internal/v1/sessions/:id/artifacts/:artifactId/content") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let artifactID = try context.parameters.require("artifactId", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "downloadArtifact", sessionID: id)
            let requestedRange = try parseByteRange(request.headers[.range])
            let result = try await authority.artifactContent(sessionID: id, artifactID: artifactID, range: requestedRange)
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            headers[.cacheControl] = "no-store"
            headers[.contentLength] = String(result.1.count)
            let partial = result.2.lowerBound != 0 || result.2.upperBound != Int(result.0.size)
            if partial { headers[.contentRange] = "bytes \(result.2.lowerBound)-\(max(result.2.lowerBound, result.2.upperBound - 1))/\(result.0.size)" }
            return Response(status: partial ? .partialContent : .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: result.1)))
        } }
        router.get("/internal/v1/catalog/workflows") { request, context in await respond {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listWorkflows")
            return try await HTTPResponses.json(authority.workflowSnapshots())
        } }
        router.get("/internal/v1/catalog/workflows/:id") { request, context in await respond {
            let id = try context.parameters.require("id")
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "getWorkflow")
            return try await HTTPResponses.json(authority.workflowSnapshot(workflowID: id))
        } }
        router.get("/internal/v1/catalog/providers") { request, context in await respond {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listProviders")
            return try await HTTPResponses.json(authority.providerCapabilities())
        } }
        router.get("/internal/v1/catalog/models") { request, context in await respond {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listModels")
            return try HTTPResponses.json([String]())
        } }
        router.get("/internal/v1/catalog/execution-modes") { request, context in await respond {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listExecutionModes")
            return try HTTPResponses.json(["read-only", "workspace-write", "full-access"])
        } }
        router.get("/internal/v1/sessions/:id/children") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinApp], operation: "listSessionChildren", sessionID: id)
            return try await HTTPResponses.json(authority.childSessionSnapshots(parentSessionID: id))
        } }
        router.post("/internal/v1/sessions/:id/context/build") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "buildContext", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuildInput.self, from: data)
            return try await HTTPResponses.json(authority.buildContext(sessionID: id, expectedSelectionRevision: input.expectedSelectionRevision, include: input.include, actor: requireActor(auth)), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/context/context-builder") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "runContextBuilder", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuilderInput.self, from: data)
            return try await HTTPResponses.json(authority.runContextBuilder(sessionID: id, input: input, actor: requireActor(auth)))
        } }
        router.post("/internal/v1/sessions/:id/context/oracle") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.goblinApp], operation: "askOracle", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(OracleInput.self, from: data)
            return try await HTTPResponses.json(authority.askOracle(sessionID: id, input: input, actor: requireActor(auth)))
        } }

        router.get("/internal/v1/events") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinSync], operation: "events")
            let cursor = try parseCursor(request)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 500
            return try await HTTPResponses.json(authority.events(after: cursor, limit: limit))
        } }
        router.get("/internal/v1/events/stream") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinSync], operation: "eventStream")
            let stream: AsyncThrowingStream<EventEnvelope, Error>
            do {
                stream = try await authority.subscribe(after: parseCursor(request))
            } catch let error as ServiceAPIError where error.code == .cursorExpired {
                return try cursorExpiredStream(error)
            }
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-store"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in try await writer.write(ByteBuffer(string: ": repoprompt-stream-v1\n\n"))
                for try await frame in heartbeatFrames(stream) {
                    switch frame {
                    case let .event(event):
                        let signed = signEvent(event)
                        let json = try JSONEncoder.serviceEncoder.encode(signed).base64EncodedString()
                        try await writer.write(ByteBuffer(string: "id: \(signed.storeID.uuidString):\(signed.globalSequence)\nevent: \(signed.eventType.rawValue)\ndata: \(json)\n\n"))
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        } }
        router.get("/internal/v1/snapshot") { request, context in await respond { _ = try await authenticate(request, context: context, body: Data(), roles: [.goblinSync], operation: "snapshot")
            return try await HTTPResponses.json(authority.authoritativeSnapshot())
        } }
        router.post("/internal/v1/admin/checkpoint") { request, context in await respond { let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "checkpoint")
            try await store.checkpoint()
            return Response(status: .noContent)
        } }
        router.post("/internal/v1/admin/quiesce") { request, context in await respond { let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "quiesce")
            try await authority.quiesce()
            return Response(status: .accepted)
        } }

        return router
    }

    private func respond(_ operation: () async throws -> Response) async -> Response {
        do { return try await operation() } catch { return HTTPResponses.error(error) }
    }

    private func bodyData(_ request: Request) async throws -> Data {
        let buffer = try await request.body.collect(upTo: 1_048_576)
        return Data(buffer.readableBytesView)
    }

    private func authenticate(_ request: Request, context: RepoPromptRequestContext, body: Data, roles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil) async throws -> AuthenticatedInternalRequest {
        guard let keyID = request.headers[.repoKeyID], let timestamp = request.headers[.repoTimestamp], let nonce = request.headers[.repoNonce], let signature = request.headers[.repoSignature] else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signed internal headers are required") }
        let decisionData = request.headers[.repoDecision].flatMap { Data(base64Encoded: $0) }
        let authenticated = try await authenticator.verify(SignedInternalRequest(method: String(describing: request.method), pathAndQuery: request.uri.string, timestamp: timestamp, nonce: nonce, body: body, authorizationDecisionData: decisionData, keyID: keyID, signature: signature), allowedRoles: roles, operation: operation, projectID: projectID, sessionID: sessionID)
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
        let lastEventID = request.headers[.init("Last-Event-ID")!].map { Substring($0) }
        guard let after = request.uri.queryParameters["after"] ?? lastEventID else { return nil }
        let parts = after.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let storeID = UUID(uuidString: String(parts[0])), let sequence = Int64(parts[1]) else { throw ServiceAPIError(code: .invalidRequest, message: "Cursor must be storeId:sequence") }
        return ServiceCursor(storeID: storeID, globalSequence: sequence)
    }

    private func parseByteRange(_ value: String?) throws -> Range<Int>? {
        guard let value else { return nil }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw ServiceAPIError(code: .invalidRequest, message: "Only one bounded byte range is supported") }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int(bounds[0]), let inclusiveUpper = Int(bounds[1]), lower >= 0, inclusiveUpper >= lower else {
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
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-store"
        let payload = try JSONEncoder.serviceEncoder.encode(error).base64EncodedString()
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            try await writer.write(ByteBuffer(string: "event: cursor_expired\ndata: \(payload)\n\n"))
            try await writer.finish(nil)
        })
    }

    private func signEvent(_ event: EventEnvelope) -> EventEnvelope {
        guard let key = eventSigningKey else { return event }
        let signature = CanonicalSigning.hmacSHA256(message: "\(event.storeID.uuidString)\n\(event.globalSequence)\n\(event.digest)", key: key.secret)
        return EventEnvelope(protocolVersion: event.protocolVersion, eventID: event.eventID, storeID: event.storeID, globalSequence: event.globalSequence, timestamp: event.timestamp, projectID: event.projectID, sessionID: event.sessionID, agentID: event.agentID, parentAgentID: event.parentAgentID, rootSessionID: event.rootSessionID, runID: event.runID, sessionSequence: event.sessionSequence, eventType: event.eventType, payloadVersion: event.payloadVersion, generation: event.generation, turnEpoch: event.turnEpoch, actor: event.actor, correlationID: event.correlationID, causationID: event.causationID, payload: event.payload, digest: event.digest, keyID: key.keyID, signature: signature)
    }
}
