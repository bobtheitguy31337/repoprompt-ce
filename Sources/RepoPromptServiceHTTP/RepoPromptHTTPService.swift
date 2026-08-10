import Foundation
import Hummingbird
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct RepoPromptHTTPService: Sendable {
    private let authority: RepoPromptHeadlessAuthority
    private let store: SQLiteServiceStore
    private let authenticator: InternalRequestAuthenticator
    private let eventSigningKey: InternalSigningKey?

    public init(authority: RepoPromptHeadlessAuthority, store: SQLiteServiceStore, authenticator: InternalRequestAuthenticator, eventSigningKey: InternalSigningKey? = nil) {
        self.authority = authority
        self.store = store
        self.authenticator = authenticator
        self.eventSigningKey = eventSigningKey
    }

    public func healthRouter() -> Router<BasicRequestContext> {
        let router = Router()
        router.get("/health/live") { _, _ in Response(status: .ok) }
        router.get("/health/ready") { _, _ in await authority.isReady() ? Response(status: .ok) : Response(status: .serviceUnavailable) }
        return router
    }

    public func internalRouter() -> Router<BasicRequestContext> {
        let router = Router()
        router.get("/internal/v1/capabilities") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.goblinApp, .goblinSync], operation: "capabilities")
            return try await HTTPResponses.json(authority.capabilities())
        } }
        router.get("/internal/v1/diagnostics") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.operatorRole], operation: "diagnostics")
            let meta = try await store.metadata()
            return try await HTTPResponses.json(["storeId": meta.storeID.uuidString, "schemaVersion": String(meta.schemaVersion), "nextGlobalSequence": String(meta.nextGlobalSequence), "ready": String(authority.isReady())])
        } }
        router.get("/metrics") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.operatorRole], operation: "metrics")
            let meta = try await store.metadata()
            let text = await "repoprompt_ready \(authority.isReady() ? 1 : 0)\nrepoprompt_event_latest_sequence \(max(0, meta.nextGlobalSequence - 1))\n"
            var headers = HTTPFields()
            headers[.contentType] = "text/plain; version=0.0.4"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
        } }

        router.get("/internal/v1/projects") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.goblinApp], operation: "listProjects")
            return try await HTTPResponses.json(authority.projectSnapshots())
        } }
        router.post("/internal/v1/projects") { request, _ in await respond { let data = try await bodyData(request)
            let auth = try await authenticate(request, body: data, roles: [.goblinApp], operation: "createProject")
            let input = try JSONDecoder.serviceDecoder.decode(CreateProjectInput.self, from: data)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let snapshot = try await authority.createProject(input: input, externalActor: actor, idempotencyKey: key, requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(snapshot, status: .created)
        } }
        router.get("/internal/v1/projects/:id/snapshot") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, body: Data(), roles: [.goblinApp], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSnapshot(projectID: id))
        } }

        router.get("/internal/v1/sessions") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.goblinApp], operation: "listSessions")
            return try await HTTPResponses.json(authority.sessionSnapshots())
        } }
        router.post("/internal/v1/sessions") { request, _ in await respond { let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CreateSessionInput.self, from: data)
            let auth = try await authenticate(request, body: data, roles: [.goblinApp], operation: "startSession", projectID: input.projectID)
            let snapshot = try await authority.createSession(input: input, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(snapshot, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/snapshot") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, body: Data(), roles: [.goblinApp], operation: "getSession", sessionID: id)
            return try await HTTPResponses.json(authority.sessionSnapshot(sessionID: id))
        } }
        router.get("/internal/v1/sessions/:id/transcript") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, body: Data(), roles: [.goblinApp], operation: "getTranscript", sessionID: id)
            return try await HTTPResponses.json(authority.sessionSnapshot(sessionID: id).transcript)
        } }
        router.post("/internal/v1/sessions/:id/commands") { request, context in await respond { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let command = try JSONDecoder.serviceDecoder.decode(SessionCommand.self, from: data)
            let auth = try await authenticate(request, body: data, roles: [.goblinApp], operation: command.operation, sessionID: id)
            let receipt = try await authority.execute(command: command, sessionID: id, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(receipt, status: .accepted)
        } }

        router.get("/internal/v1/events") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.goblinSync], operation: "events")
            let cursor = try parseCursor(request)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 500
            return try await HTTPResponses.json(authority.events(after: cursor, limit: limit))
        } }
        router.get("/internal/v1/events/stream") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.goblinSync], operation: "eventStream")
            let stream = try await authority.subscribe(after: parseCursor(request))
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-store"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in try await writer.write(ByteBuffer(string: ": repoprompt-stream-v1\n\n"))
                for try await event in stream {
                    let signed = signEvent(event)
                    let json = try JSONEncoder.serviceEncoder.encode(signed).base64EncodedString()
                    let frame = "id: \(signed.storeID.uuidString):\(signed.globalSequence)\nevent: \(signed.eventType.rawValue)\ndata: \(json)\n\n"
                    try await writer.write(ByteBuffer(string: frame))
                }
                try await writer.finish(nil)
            })
        } }
        router.get("/internal/v1/snapshot") { request, _ in await respond { _ = try await authenticate(request, body: Data(), roles: [.goblinSync], operation: "snapshot")
            return try await HTTPResponses.json(authority.authoritativeSnapshot())
        } }
        router.post("/internal/v1/admin/checkpoint") { request, _ in await respond { let data = try await bodyData(request)
            _ = try await authenticate(request, body: data, roles: [.operatorRole], operation: "checkpoint")
            try await store.checkpoint()
            return Response(status: .noContent)
        } }
        router.post("/internal/v1/admin/quiesce") { request, _ in await respond { let data = try await bodyData(request)
            _ = try await authenticate(request, body: data, roles: [.operatorRole], operation: "quiesce")
            try await authority.quiesce()
            return Response(status: .accepted)
        } }

        registerCapabilityPlaceholders(router)
        return router
    }

    private func registerCapabilityPlaceholders(_ router: Router<BasicRequestContext>) {
        let gets: [(path: String, operation: String, projectTarget: Bool, sessionTarget: Bool)] = [
            ("/internal/v1/catalog/providers", "listProviders", false, false),
            ("/internal/v1/catalog/models", "listModels", false, false),
            ("/internal/v1/catalog/workflows", "listWorkflows", false, false),
            ("/internal/v1/catalog/execution-modes", "listExecutionModes", false, false),
            ("/internal/v1/projects/:id/tree", "getProjectTree", true, false),
            ("/internal/v1/projects/:id/worktrees", "listWorktrees", true, false),
            ("/internal/v1/sessions/:id/children", "listSessionChildren", false, true),
            ("/internal/v1/sessions/:id/artifacts", "getArtifacts", false, true),
            ("/internal/v1/sessions/:id/context/selection", "getSelection", false, true)
        ]
        for route in gets {
            router.get(RouterPath(route.path)) { request, context in
                await respond {
                    let targetID = (route.projectTarget || route.sessionTarget) ? try context.parameters.require("id", as: UUID.self) : nil
                    _ = try await authenticate(
                        request,
                        body: Data(),
                        roles: [.goblinApp],
                        operation: route.operation,
                        projectID: route.projectTarget ? targetID : nil,
                        sessionID: route.sessionTarget ? targetID : nil
                    )
                    throw ServiceAPIError(code: .capabilityMissing, message: "Route is versioned but its backing runtime capability is unavailable")
                }
            }
        }

        let posts: [(path: String, operation: String, projectTarget: Bool, sessionTarget: Bool)] = [
            ("/internal/v1/projects/:id/refresh", "refreshProject", true, false),
            ("/internal/v1/projects/:id/search", "searchProject", true, false),
            ("/internal/v1/projects/:id/file", "getFile", true, false),
            ("/internal/v1/projects/:id/diff", "getDiff", true, false),
            ("/internal/v1/sessions/:id/worktrees", "createWorktree", false, true),
            ("/internal/v1/sessions/:id/context/selection/add", "addToSelection", false, true),
            ("/internal/v1/sessions/:id/context/selection/remove", "removeFromSelection", false, true),
            ("/internal/v1/sessions/:id/context/build", "buildContext", false, true),
            ("/internal/v1/sessions/:id/context/context-builder", "runContextBuilder", false, true),
            ("/internal/v1/sessions/:id/context/oracle", "askOracle", false, true)
        ]
        for route in posts {
            router.post(RouterPath(route.path)) { request, context in
                await respond {
                    let data = try await bodyData(request)
                    let targetID = try context.parameters.require("id", as: UUID.self)
                    _ = try await authenticate(
                        request,
                        body: data,
                        roles: [.goblinApp],
                        operation: route.operation,
                        projectID: route.projectTarget ? targetID : nil,
                        sessionID: route.sessionTarget ? targetID : nil
                    )
                    throw ServiceAPIError(code: .capabilityMissing, message: "Route is versioned but its backing runtime capability is unavailable")
                }
            }
        }
    }

    private func respond(_ operation: () async throws -> Response) async -> Response {
        do { return try await operation() } catch { return HTTPResponses.error(error) }
    }

    private func bodyData(_ request: Request) async throws -> Data {
        let buffer = try await request.body.collect(upTo: 1_048_576)
        return Data(buffer.readableBytesView)
    }

    private func authenticate(_ request: Request, body: Data, roles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil) async throws -> AuthenticatedInternalRequest {
        guard let keyID = request.headers[.repoKeyID], let timestamp = request.headers[.repoTimestamp], let nonce = request.headers[.repoNonce], let signature = request.headers[.repoSignature] else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signed internal headers are required") }
        let decisionData = request.headers[.repoDecision].flatMap { Data(base64Encoded: $0) }
        return try await authenticator.verify(SignedInternalRequest(method: String(describing: request.method), pathAndQuery: request.uri.string, timestamp: timestamp, nonce: nonce, body: body, authorizationDecisionData: decisionData, keyID: keyID, signature: signature), allowedRoles: roles, operation: operation, projectID: projectID, sessionID: sessionID)
    }

    private func requireActor(_ auth: AuthenticatedInternalRequest) throws -> ExternalActor {
        guard let actor = auth.decision?.actor else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Human actor attribution is required") }
        return actor
    }

    private func requireIdempotency(_ request: Request) throws -> String {
        guard let value = request.headers[.idempotencyKey], !value.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Idempotency-Key is required") }
        return value
    }

    private func parseCursor(_ request: Request) throws -> ServiceCursor? {
        guard let after = request.uri.queryParameters["after"] else { return nil }
        let parts = after.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let storeID = UUID(uuidString: String(parts[0])), let sequence = Int64(parts[1]) else { throw ServiceAPIError(code: .invalidRequest, message: "Cursor must be storeId:sequence") }
        return ServiceCursor(storeID: storeID, globalSequence: sequence)
    }

    private func signEvent(_ event: EventEnvelope) -> EventEnvelope {
        guard let key = eventSigningKey else { return event }
        let signature = CanonicalSigning.hmacSHA256(message: "\(event.storeID.uuidString)\n\(event.globalSequence)\n\(event.digest)", key: key.secret)
        return EventEnvelope(eventID: event.eventID, storeID: event.storeID, globalSequence: event.globalSequence, timestamp: event.timestamp, projectID: event.projectID, sessionID: event.sessionID, agentID: event.agentID, parentAgentID: event.parentAgentID, rootSessionID: event.rootSessionID, runID: event.runID, sessionSequence: event.sessionSequence, eventType: event.eventType, generation: event.generation, turnEpoch: event.turnEpoch, actor: event.actor, correlationID: event.correlationID, causationID: event.causationID, payload: event.payload, digest: event.digest, keyID: key.keyID, signature: signature)
    }
}
