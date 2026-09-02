import Crypto
import Foundation
import Hummingbird
import NIOCore
import NIOSSL
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptPortalProtocol
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
    private let providerSettings: ProviderSettingsService?
    private let serverSettings: ServerSettingsService?
    private let composerCatalog: (any AgentComposerCatalogProviding)?
    private let composerAttachments: AgentComposerAttachmentStore?
    private let submissionCoordinator: AgentSubmissionCoordinator?
    private let submissionDispatchQueue: AgentSubmissionDispatchQueue?
    private let transcriptPresentation: AgentTranscriptPresentationService?
    private let portalDesktopSettings: PortalDesktopSettingsService
    private let portalPeerCertificateDER: Data?
    private let portalPasswordLoginEnabled: Bool

    public init(
        authority: RepoPromptHeadlessAuthority,
        store: SQLiteServiceStore,
        authenticator: InternalRequestAuthenticator,
        eventSigningKey: InternalSigningKey,
        certificateRoleResolver: CertificateIdentityRoleResolver? = nil,
        readiness: RepoPromptReadinessService? = nil,
        drainController: MutationDrainController = MutationDrainController(),
        durabilityOperations: DurabilityOperationsService? = nil,
        providerSettings: ProviderSettingsService? = nil,
        serverSettings: ServerSettingsService? = nil,
        composerCatalog: (any AgentComposerCatalogProviding)? = nil,
        composerAttachments: AgentComposerAttachmentStore? = nil,
        submissionCoordinator: AgentSubmissionCoordinator? = nil,
        submissionDispatchQueue: AgentSubmissionDispatchQueue? = nil,
        transcriptPresentation: AgentTranscriptPresentationService? = nil,
        portalDesktopSettings: PortalDesktopSettingsService? = nil,
        portalPeerCertificateDER: Data? = nil,
        portalPasswordLoginEnabled: Bool = true
    ) {
        self.authority = authority
        self.store = store
        self.authenticator = authenticator
        responseSigner = InternalResponseSigner(key: eventSigningKey)
        self.certificateRoleResolver = certificateRoleResolver
        self.drainController = drainController
        self.durabilityOperations = durabilityOperations
        self.providerSettings = providerSettings
        self.serverSettings = serverSettings
        self.composerCatalog = composerCatalog
        self.composerAttachments = composerAttachments
        self.submissionCoordinator = submissionCoordinator
        self.submissionDispatchQueue = submissionDispatchQueue ?? submissionCoordinator.map {
            AgentSubmissionDispatchQueue(authority: authority, coordinator: $0)
        }
        self.transcriptPresentation = transcriptPresentation
        self.portalDesktopSettings = portalDesktopSettings ?? PortalDesktopSettingsService(store: store)
        self.portalPeerCertificateDER = portalPeerCertificateDER
        self.portalPasswordLoginEnabled = portalPasswordLoginEnabled
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
        router.get("/portal") { request, context in await portalRespond(request) {
            if request.uri.string.split(separator: "?", maxSplits: 1).first == "/portal" {
                return RepoPromptPortalAssets.canonicalRedirect()
            }
            return try RepoPromptPortalAssets.response(for: .index)
        } }
        router.get("/portal/assets/:name") { request, context in await portalRespond(request) {
            let name = try context.parameters.require("name")
            guard let asset = RepoPromptPortalAssets.Asset(routeName: name) else {
                throw ServiceAPIError(code: .notFound, message: "Portal asset not found")
            }
            return try RepoPromptPortalAssets.response(for: asset)
        } }
        router.get("/portal/api/v1/auth/status") { request, context in await portalRespond(request) {
            try portalJSON(await portalAuthStatus(request: request, context: context))
        } }
        router.get("/portal/api/v1/events/stream") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let cursor: ServiceCursor
            if let requested = try parseCursor(request) {
                cursor = requested
            } else {
                let next = try await store.nextCursor()
                cursor = ServiceCursor(storeID: next.storeID, globalSequence: max(0, next.globalSequence - 1))
            }
            let stream = try await authority.subscribe(after: cursor)
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "no-store"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                try await writer.write(ByteBuffer(string: ": repoprompt-portal-stream-v1\n\n"))
                for try await frame in heartbeatFrames(stream) {
                    switch frame {
                    case let .event(event):
                        let refresh = PortalRefreshEvent(projectID: event.projectID, sessionID: event.sessionID)
                        let json = try String(decoding: JSONEncoder.serviceEncoder.encode(refresh), as: UTF8.self)
                        try await writer.write(ByteBuffer(string: "id: \(event.storeID.uuidString):\(event.globalSequence)\nevent: refresh\ndata: \(json)\n\n"))
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        } }
        router.post("/portal/api/v1/setup") { request, context in await portalRespond(request) {
            try validatePortalMutation(request)
            return try await completePortalSetup(request: request)
        } }
        router.post("/portal/api/v1/login") { request, context in await portalRespond(request) {
            try validatePortalMutation(request)
            return try await completePortalLogin(request: request)
        } }
        router.post("/portal/api/v1/logout") { request, context in await portalRespond(request) {
            try validatePortalMutation(request)
            return try await completePortalLogout(request: request)
        } }
        router.get("/portal/api/v1/bootstrap") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let bootstrap = try await portalBootstrap(principal: principal)
            return try portalJSON(bootstrap)
        } }
        router.get("/external/v1/bootstrap") { request, _ in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            return try portalJSON(try await bootstrap(actor: actor))
        } }
        router.post("/external/v1/projects") { request, _ in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(GabblinCreateProjectRequest.self, from: data)
            let key = try requireIdempotency(request)
            guard let operationID = UUID(uuidString: key) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Gabblin project creation requires a UUID idempotency key")
            }
            let result = try await authority.createProjectFromSource(
                input: .init(
                    operationID: operationID,
                    expectedRevision: 0,
                    name: input.name,
                    logicalName: input.name,
                    source: .managedDirectory(name: input.name)
                ),
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            let project = try await authority.projectSnapshot(projectID: result.projectID)
            return try portalJSON(
                GabblinProjectResponse(project: RepoPromptPortalSessionProjection.project(project)),
                status: .created
            )
        } }
        router.get("/external/v1/projects/:id/composer-catalog") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            return try await portalJSON(requireComposerCatalog().snapshot(
                context: .init(kind: .project, projectID: projectID, actorID: actor.userID)
            ))
        } }
        router.get("/external/v1/projects/:id/composer-suggestions") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            return try await portalJSON(requireComposerCatalog().suggestions(
                context: .init(kind: .project, projectID: projectID, actorID: actor.userID),
                query: try gabblinSuggestionQuery(request),
                kinds: [.nativeCommand, .skill, .file],
                limit: 50
            ))
        } }
        router.post("/external/v1/projects/:id/composer-attachments") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            _ = try requireIdempotency(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            let data = try await bodyData(request, maximumBytes: 10 * 1_024 * 1_024 + 64 * 1_024)
            let upload = try composerAttachmentUpload(
                data: data,
                contentType: request.headers[.contentType],
                fallbackDisplayName: String(request.uri.queryParameters["displayName"] ?? "image")
            )
            guard upload.displayName.utf8.count <= 256 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Attachment display name exceeds its bound")
            }
            let attachment = try await requireComposerAttachments().stage(
                data: upload.data,
                displayName: upload.displayName,
                declaredMediaType: upload.mediaType,
                actorID: actor.userID,
                projectID: projectID
            )
            return try portalJSON(attachment, status: .created)
        } }
        router.post("/external/v1/projects/:id/composer-attachments/resolve") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            _ = try requireIdempotency(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            let input = try await JSONDecoder.serviceDecoder.decode(
                ComposerAttachmentResolveRequest.self,
                from: bodyData(request)
            )
            return try await portalJSON(requireComposerAttachments().resolve(
                attachmentIDs: input.attachmentIDs,
                actorID: actor.userID,
                projectID: projectID
            ))
        } }
        router.get("/external/v1/projects/:id/composer-attachments/:attachmentId/preview") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            let sessionID = try optionalGabblinSessionID(request)
            if let sessionID {
                let session = try await authority.sessionSnapshot(sessionID: sessionID)
                guard session.projectID == projectID else {
                    throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable")
                }
            } else {
                _ = try await authority.projectSnapshot(projectID: projectID)
            }
            let preview = try await requireComposerAttachments().preview(
                attachmentID: attachmentID,
                actorID: actor.userID,
                projectID: projectID,
                visibleSessionID: sessionID
            )
            return portalBytes(preview.1, contentType: preview.0.mediaType)
        } }
        router.delete("/external/v1/projects/:id/composer-attachments/:attachmentId") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            _ = try requireIdempotency(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            try await requireComposerAttachments().delete(
                attachmentID: attachmentID,
                actorID: actor.userID,
                projectID: projectID
            )
            return portalEmpty()
        } }
        router.get("/external/v1/sessions/:id") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            let collaboration = try await authority.collaborationMetadata(sessionID: sessionID)
            let control = try await authority.agentSessionActionSnapshot(
                sessionID: sessionID,
                actor: actor,
                composerAvailable: composerCatalog != nil
            )
            return try portalJSON(GabblinSessionDetailResponse(
                session: RepoPromptPortalSessionProjection.project(session, agentControl: control),
                collaboration: collaboration
            ))
        } }
        router.get("/external/v1/sessions/:id/events/stream") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            _ = try await authority.agentSessionActionSnapshot(
                sessionID: sessionID,
                actor: actor,
                composerAvailable: composerCatalog != nil
            )
            let next = try await store.nextCursor()
            let cursor = ServiceCursor(storeID: next.storeID, globalSequence: max(0, next.globalSequence - 1))
            let stream = try await authority.subscribe(after: cursor)
            let initialRefresh = PortalRefreshEvent(projectID: session.projectID, sessionID: sessionID)
            let initialJSON = try String(decoding: JSONEncoder.serviceEncoder.encode(initialRefresh), as: UTF8.self)
            var headers = HTTPFields()
            headers[.contentType] = "text/event-stream"
            headers[.cacheControl] = "private, no-store"
            return Response(status: .ok, headers: headers, body: ResponseBody { writer in
                try await writer.write(ByteBuffer(string: ": repoprompt-gabblin-session-stream-v1\n\nevent: refresh\ndata: \(initialJSON)\n\n"))
                for try await frame in heartbeatFrames(stream) {
                    switch frame {
                    case let .event(event) where event.sessionID == sessionID:
                        let refresh = PortalRefreshEvent(projectID: event.projectID, sessionID: sessionID)
                        let json = try String(decoding: JSONEncoder.serviceEncoder.encode(refresh), as: UTF8.self)
                        try await writer.write(ByteBuffer(string: "id: \(event.storeID.uuidString):\(event.globalSequence)\nevent: refresh\ndata: \(json)\n\n"))
                    case .event:
                        continue
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        } }
        router.get("/external/v1/sessions/:id/composer-catalog") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            return try await portalJSON(requireComposerCatalog().snapshot(context: .init(
                kind: .session,
                projectID: snapshot.session.projectID,
                sessionID: sessionID,
                actorID: actor.userID,
                activeRun: snapshot.activeBinding != nil
            )))
        } }
        router.get("/external/v1/sessions/:id/composer-suggestions") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            return try await portalJSON(requireComposerCatalog().suggestions(
                context: .init(
                    kind: .session,
                    projectID: snapshot.session.projectID,
                    sessionID: sessionID,
                    actorID: actor.userID,
                    activeRun: snapshot.activeBinding != nil
                ),
                query: try gabblinSuggestionQuery(request),
                kinds: [.nativeCommand, .skill, .file],
                limit: 50
            ))
        } }
        router.get("/external/v1/sessions/:id/presentation") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 25
            guard (1 ... 100).contains(limit) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Presentation limit is outside the external API bound")
            }
            let pageToken = request.uri.queryParameters["pageToken"].map(String.init)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            let metadata = try await authority.collaborationMetadata(sessionID: sessionID)
            let page = try await requireTranscriptPresentation().page(
                sessionID: sessionID,
                actorID: actor.userID,
                legacyTranscript: session.transcript,
                interactions: session.interactions,
                pageToken: pageToken,
                limit: limit,
                mutableInteractions: metadata.controllerUserID == actor.userID
            )
            return try portalJSON(page)
        } }
        router.get("/external/v1/sessions/:id/children") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.sessionSnapshot(sessionID: sessionID)
            let children = try await authority.childSessionSnapshots(parentSessionID: sessionID)
            let controls = try await authority.agentSessionActionSnapshots(
                sessionIDs: children.map(\.sessionID),
                actor: actor,
                composerAvailable: composerCatalog != nil
            )
            let summaries = children.map {
                RepoPromptPortalSessionProjection.project($0, agentControl: controls[$0.sessionID])
            }
            return try await portalJSON(page(
                summaries,
                request: request,
                defaultLimit: 100,
                maximumLimit: 500,
                sortKey: { $0.sessionID.uuidString }
            ))
        } }
        router.get("/external/v1/sessions/:id/artifacts") { request, context in await portalRespond(request) {
            _ = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let artifacts = try await authority.artifactSnapshots(sessionID: sessionID)
            return try await portalJSON(page(
                artifacts,
                request: request,
                defaultLimit: 100,
                maximumLimit: 200,
                sortKey: { $0.artifactID.uuidString }
            ))
        } }
        router.get("/external/v1/sessions/:id/artifacts/:artifactId/content") { request, context in await portalRespond(request) {
            _ = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let artifactID = try context.parameters.require("artifactId", as: UUID.self)
            let requestedRange = try parseByteRange(request.headers[.range])
            let result = try await authority.artifactContent(
                sessionID: sessionID,
                artifactID: artifactID,
                range: requestedRange
            )
            var headers = HTTPFields()
            headers[.contentType] = "application/octet-stream"
            headers[.cacheControl] = "private, no-store"
            headers[.contentLength] = String(result.1.count)
            let partial = result.2.lowerBound != 0 || result.2.upperBound != Int(result.0.size)
            if partial {
                headers[.contentRange] = "bytes \(result.2.lowerBound)-\(max(result.2.lowerBound, result.2.upperBound - 1))/\(result.0.size)"
            }
            return Response(
                status: partial ? .partialContent : .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: result.1))
            )
        } }
        router.get("/external/v1/sessions/:id/selection") { request, context in await portalRespond(request) {
            _ = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(authority.selectionSnapshot(sessionID: sessionID))
        } }
        router.post("/external/v1/agent-sessions") { request, _ in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalStartAgentSessionRequest.self, from: data)
            let key = try requireGabblinOperationKey(request, operationID: input.operationID)
            guard input.start.visibility == .privateSession, input.start.selectedMessageContext == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "Gabblin Agent sessions must be private root sessions")
            }
            guard let provider = input.start.turn.configuration.providerID.runtimeKind else {
                throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider has no execution adapter")
            }
            _ = try await authority.projectSnapshot(projectID: input.start.projectID)
            let shell = CreateSessionInput(
                projectID: input.start.projectID,
                provider: provider,
                providerSettingsID: input.start.turn.configuration.providerID,
                model: input.start.turn.configuration.modelID,
                visibility: .privateSession,
                startImmediately: false
            )
            let digest = CanonicalSigning.bodyDigest(data)
            let accepted = try await authority.acceptStructuredSession(
                input: shell,
                coordinator: requireSubmissionCoordinator(),
                actor: actor,
                publicSubmissionKey: key,
                requestDigest: digest,
                submission: input.start.turn
            )
            try await requireSubmissionDispatchQueue().enqueue(
                accepted,
                actor: actor,
                requestDigest: digest
            )
            let session = try await authority.sessionSnapshot(sessionID: accepted.receipt.sessionID)
            let control = try? await authority.agentSessionActionSnapshot(
                sessionID: session.sessionID,
                actor: actor,
                composerAvailable: composerCatalog != nil
            )
            return try portalJSON(
                PortalAgentSubmissionReceipt(
                    accepted.receipt,
                    session: RepoPromptPortalSessionProjection.project(session, agentControl: control)
                ),
                status: .accepted
            )
        } }
        router.post("/external/v1/sessions/:id/turns") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalSubmitAgentTurnRequest.self, from: data)
            let key = try requireGabblinOperationKey(request, operationID: input.operationID)
            let digest = CanonicalSigning.bodyDigest(data)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: actor,
                operation: "submitTurn",
                requestDigest: digest
            )
            if snapshot.activeBinding != nil {
                let control = try await authority.agentSessionActionSnapshot(
                    sessionID: sessionID,
                    actor: actor,
                    composerAvailable: composerCatalog != nil
                )
                guard control.steer.allowed, let epoch = control.steer.targetTurnEpoch else {
                    throw ServiceAPIError(
                        code: .runAlreadyActive,
                        message: control.steer.reasonText ?? "The current run is not ready for another message yet.",
                        retryable: control.steer.reasonCode == "steering_not_ready"
                    )
                }
                guard input.turn.content.attachmentIDs.isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Attachments cannot be added while steering a running agent.")
                }
                let text = input.turn.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Enter a message before sending")
                }
                let receipt = try await authority.execute(
                    command: .steerSession(text: text, targetTurnEpoch: epoch),
                    sessionID: sessionID,
                    externalActor: actor,
                    idempotencyKey: key,
                    requestDigest: digest
                )
                return try portalJSON(receipt, status: .accepted)
            }
            let accepted = try await requireSubmissionCoordinator().acceptFollowup(
                session: snapshot.session,
                activeRun: snapshot.activeRun,
                actor: actor,
                publicSubmissionKey: key,
                requestDigest: digest,
                submission: input.turn
            )
            try await requireSubmissionDispatchQueue().enqueue(
                accepted,
                actor: actor,
                requestDigest: digest
            )
            return try portalJSON(PortalAgentSubmissionReceipt(accepted.receipt), status: .accepted)
        } }
        router.post("/external/v1/sessions/:id/agent-commands") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(GabblinAgentCommandRequest.self, from: data)
            let key = try requireGabblinOperationKey(request, operationID: input.operationID)
            let receipt = try await authority.execute(
                command: try input.sessionCommand(),
                sessionID: sessionID,
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(receipt, status: .accepted)
        } }
        router.post("/external/v1/sessions/:id/interactions/:interactionId/answer") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let interactionID = try context.parameters.require("interactionId", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalInteractionAnswerRequest.self, from: data)
            let key = try requireGabblinOperationKey(request, operationID: input.operationID)
            guard let interaction = try await authority.interactionSnapshots(sessionID: sessionID)
                .first(where: { $0.interactionID == interactionID })
            else {
                throw ServiceAPIError(code: .notFound, message: "Interaction not found")
            }
            guard interaction.revision == input.expectedRevision else {
                throw ServiceAPIError(
                    code: .staleRevision,
                    message: "Interaction revision changed",
                    currentRevision: interaction.revision
                )
            }
            let payload = try AgentInteractionPresentationAdapter.compile(
                response: input.response,
                for: interaction
            )
            let result = try await authority.answerInteraction(
                sessionID: sessionID,
                interactionID: interactionID,
                expectedRevision: input.expectedRevision,
                payload: payload,
                actor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(result)
        } }
        router.put("/external/v1/sessions/:id/selection") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            let digest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: actor,
                operation: "replaceSelection",
                requestDigest: digest
            )
            return try await portalJSON(authority.replaceSelection(
                sessionID: sessionID,
                entries: input.entries,
                expectedRevision: input.expectedRevision,
                actor: actor,
                idempotencyKey: requireIdempotency(request),
                requestDigest: digest
            ))
        } }
        router.post("/external/v1/sessions/:id/selection/add") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            let digest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: actor,
                operation: "addToSelection",
                requestDigest: digest
            )
            return try await portalJSON(authority.addSelection(
                sessionID: sessionID,
                entries: input.entries,
                expectedRevision: input.expectedRevision,
                actor: actor,
                idempotencyKey: requireIdempotency(request),
                requestDigest: digest
            ))
        } }
        router.post("/external/v1/sessions/:id/selection/remove") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionRemovalInput.self, from: data)
            let digest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: actor,
                operation: "removeFromSelection",
                requestDigest: digest
            )
            return try await portalJSON(authority.removeSelection(
                sessionID: sessionID,
                rootID: input.rootID,
                logicalPaths: input.logicalPaths,
                expectedRevision: input.expectedRevision,
                actor: actor,
                idempotencyKey: requireIdempotency(request),
                requestDigest: digest
            ))
        } }
        router.post("/external/v1/sessions/:id/context-builder") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            _ = try requireIdempotency(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuilderInput.self, from: data)
            if let budget = input.budget, !(1 ... 1_000_000).contains(budget) {
                throw ServiceAPIError(code: .invalidRequest, message: "Context Builder budget exceeds the v1 bound")
            }
            let digest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: actor,
                operation: "runContextBuilder",
                requestDigest: digest
            )
            return try await portalJSON(authority.runContextBuilder(
                sessionID: sessionID,
                input: input,
                actor: actor,
                origin: .internal,
                requestDigest: digest
            ))
        } }
        router.post("/external/v1/sessions/:id/oracle") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            _ = try requireIdempotency(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(OracleInput.self, from: data)
            let digest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: actor,
                operation: "askOracle",
                requestDigest: digest
            )
            return try await portalJSON(authority.askOracle(
                sessionID: sessionID,
                input: input,
                actor: actor,
                requestDigest: digest
            ))
        } }
        router.patch("/external/v1/sessions/:id/visibility") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(GabblinVisibilityRequest.self, from: data)
            let current = try await authority.collaborationMetadata(sessionID: sessionID)
            let collaboration = try await authority.updateCollaborationMetadata(
                sessionID: sessionID,
                input: .init(
                    expectedPolicyRevision: input.expectedPolicyRevision,
                    visibility: input.visibility,
                    collaborativeSteeringEnabled: current.collaborativeSteeringEnabled,
                    controllerUserID: current.controllerUserID
                ),
                actor: actor,
                idempotencyKey: requireIdempotency(request),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(GabblinCollaborationResponse(collaboration: collaboration))
        } }
        router.patch("/external/v1/sessions/:id/collaborative-steering") { request, context in await portalRespond(request) {
            let actor = try await authenticateGabblin(request: request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(GabblinSteeringRequest.self, from: data)
            let current = try await authority.collaborationMetadata(sessionID: sessionID)
            let collaboration = try await authority.updateCollaborationMetadata(
                sessionID: sessionID,
                input: .init(
                    expectedPolicyRevision: input.expectedPolicyRevision,
                    visibility: current.visibility,
                    collaborativeSteeringEnabled: input.enabled,
                    controllerUserID: current.controllerUserID
                ),
                actor: actor,
                idempotencyKey: requireIdempotency(request),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(GabblinCollaborationResponse(collaboration: collaboration))
        } }
        router.get("/portal/api/v1/client-integrations") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let integration = try await store.gabblinIntegration()
            let members = try await store.gabblinMembers()
            return try portalJSON(PortalClientIntegrationInventory(
                gabblin: PortalGabblinInventory(
                    integration: integration.map {
                        PortalGabblinIntegrationView(
                            status: $0.status.rawValue,
                            createdAt: $0.createdAt,
                            updatedAt: $0.updatedAt,
                            revokedAt: $0.revokedAt
                        )
                    },
                    members: members.map {
                        PortalGabblinMemberView(
                            memberID: $0.memberID,
                            username: $0.username,
                            displayName: $0.displayName,
                            firstSeenAt: $0.firstSeenAt,
                            lastSeenAt: $0.lastSeenAt,
                            profileObservedAt: $0.profileObservedAt
                        )
                    }
                )
            ))
        } }
        router.post("/portal/api/v1/client-integrations/gabblin") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            let issue = try await store.createGabblinIntegration()
            return try portalJSON(PortalGabblinCredentialDisclosureResponse(token: issue.token), status: .created)
        } }
        router.post("/portal/api/v1/client-integrations/gabblin/rotate") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            let issue = try await store.rotateGabblinCredential()
            return try portalJSON(PortalGabblinCredentialDisclosureResponse(token: issue.token))
        } }
        router.delete("/portal/api/v1/client-integrations/gabblin") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            _ = try await store.revokeGabblinIntegration()
            return portalEmpty()
        } }
        router.post("/portal/api/v1/projects") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalCreateProjectRequest.self, from: data)
            let source: ProjectSourceOperationInput.Source = switch input.source {
            case let .managedDirectory(name):
                .managedDirectory(name: name)
            case let .gitClone(remote, ref):
                .gitClone(remote: remote, ref: ref)
            }
            let result = try await authority.createProjectFromSource(
                input: .init(
                    operationID: input.operationID,
                    expectedRevision: 0,
                    name: input.name,
                    logicalName: input.logicalName,
                    source: source
                ),
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(result, status: .created)
        } }
        router.post("/portal/api/v1/projects/:id/repositories") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalAddProjectRepositoryRequest.self, from: data)
            let result = try await authority.addProjectRepository(
                projectID: projectID,
                input: .init(
                    expectedRevision: input.expectedRevision,
                    logicalName: input.logicalName,
                    source: .init(remote: input.remote, ref: input.ref)
                ),
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(result, status: .created)
        } }
        router.patch("/portal/api/v1/projects/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalRenameProjectRequest.self, from: data)
            let snapshot = try await authority.renameProject(
                projectID: projectID,
                input: .init(expectedRevision: input.expectedRevision, name: input.name),
                actor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(RepoPromptPortalSessionProjection.project(snapshot))
        } }
        router.delete("/portal/api/v1/projects/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalRemoveProjectRequest.self, from: data)
            try await authority.removeProject(
                projectID: projectID,
                expectedRevision: input.expectedRevision,
                actor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return portalEmpty()
        } }
        router.get("/portal/api/v1/projects/:id/composer-catalog") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            let catalog = try await requireComposerCatalog().snapshot(
                context: .init(kind: .project, projectID: projectID, actorID: principal.actorID)
            )
            return try portalJSON(catalog)
        } }
        router.get("/portal/api/v1/sessions/:id/composer-catalog") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            let activeRun = snapshot.activeBinding != nil
            let catalog = try await requireComposerCatalog().snapshot(
                context: .init(
                    kind: .session,
                    projectID: snapshot.session.projectID,
                    sessionID: sessionID,
                    actorID: principal.actorID,
                    activeRun: activeRun
                )
            )
            return try portalJSON(catalog)
        } }
        router.post("/portal/api/v1/projects/:id/composer-attachments") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            let projectID = try context.parameters.require("id", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            let data = try await bodyData(request, maximumBytes: 10 * 1_024 * 1_024 + 64 * 1_024)
            let upload = try composerAttachmentUpload(
                data: data,
                contentType: request.headers[.contentType],
                fallbackDisplayName: String(request.uri.queryParameters["displayName"] ?? "image")
            )
            guard upload.displayName.utf8.count <= 256 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Attachment display name exceeds its bound")
            }
            let attachment = try await requireComposerAttachments().stage(
                data: upload.data,
                displayName: upload.displayName,
                declaredMediaType: upload.mediaType,
                actorID: principal.actorID,
                projectID: projectID
            )
            return try portalJSON(attachment, status: .created)
        } }
        router.get("/portal/api/v1/projects/:id/composer-attachments/:attachmentId/preview") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            let sessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            if let sessionID {
                let session = try await authority.sessionSnapshot(sessionID: sessionID)
                guard session.projectID == projectID else {
                    throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable")
                }
            } else {
                _ = try await authority.projectSnapshot(projectID: projectID)
            }
            let preview = try await requireComposerAttachments().preview(
                attachmentID: attachmentID,
                actorID: principal.actorID,
                projectID: projectID,
                visibleSessionID: sessionID
            )
            return portalBytes(preview.1, contentType: preview.0.mediaType)
        } }
        router.delete("/portal/api/v1/projects/:id/composer-attachments/:attachmentId") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            _ = try await authority.projectSnapshot(projectID: projectID)
            try await requireComposerAttachments().delete(
                attachmentID: attachmentID,
                actorID: principal.actorID,
                projectID: projectID
            )
            return portalEmpty()
        } }
        router.get("/portal/api/v1/sessions/:id/presentation") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 25
            guard (1 ... 25).contains(limit) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Presentation limit is outside the portal bound")
            }
            let pageToken = request.uri.queryParameters["pageToken"].map(String.init)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            let metadata = try await authority.collaborationMetadata(sessionID: sessionID)
            let page = try await requireTranscriptPresentation().page(
                sessionID: sessionID,
                actorID: principal.actorID,
                legacyTranscript: session.transcript,
                interactions: session.interactions,
                pageToken: pageToken,
                limit: limit,
                mutableInteractions: metadata.controllerUserID == principal.actorID
            )
            let control = try await authority.agentSessionActionSnapshot(
                sessionID: sessionID,
                actor: principal.externalActor,
                composerAvailable: composerCatalog != nil
            )
            let sidebarSessions = try await portalSidebarSessions(
                principal: principal,
                projectID: session.projectID
            )
            return try portalJSON(RepoPromptPortalSessionProjection.presentationPage(
                session: session,
                control: control,
                page: page,
                sidebarSessions: sidebarSessions
            ))
        } }
        router.post("/portal/api/v1/sessions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalCreateSessionRequest.self, from: data)
            let catalog = try await requireProviderSettings().catalog(refreshCLI: false)
            let providerID: ProviderSettingsID
            let resolvedModel: String?
            let reasoningEffort: String?
            if let explicitProviderID = input.providerID {
                providerID = explicitProviderID
                resolvedModel = input.model
                reasoningEffort = nil
            } else {
                let target = input.routingTarget ?? .engineer
                guard let resolved = try await requireServerSettings().resolveAgentTarget(projectID: input.projectID, target: target) else {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "No Agent Model route is available for the new session", retryable: true)
                }
                providerID = resolved.providerID
                resolvedModel = resolved.modelID
                reasoningEffort = resolved.reasoningEffort
            }
            guard let provider = catalog.providers.first(where: { $0.providerID == providerID }) else {
                throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
            }
            let runtimeDefaults = try await requirePortalDesktopSettings().runtimeDefaults(for: providerID)
            let createInput = try RepoPromptPortalSessionProjection.validatedCreateInput(
                input,
                provider: provider,
                resolvedModel: resolvedModel,
                reasoningEffort: reasoningEffort,
                runtimeDefaults: runtimeDefaults
            )
            let snapshot = try await authority.createSession(
                input: createInput,
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            let control = try? await authority.agentSessionActionSnapshot(
                sessionID: snapshot.sessionID,
                actor: principal.externalActor,
                composerAvailable: composerCatalog != nil
            )
            return try portalJSON(
                RepoPromptPortalSessionProjection.project(snapshot, agentControl: control),
                status: .accepted
            )
        } }
        router.post("/portal/api/v1/agent-sessions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalStartAgentSessionRequest.self, from: data)
            guard input.start.visibility == .privateSession, input.start.selectedMessageContext == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "Portal Agent sessions must be private root sessions")
            }
            guard let provider = input.start.turn.configuration.providerID.runtimeKind else {
                throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider has no execution adapter")
            }
            _ = try await authority.projectSnapshot(projectID: input.start.projectID)
            let shell = CreateSessionInput(
                projectID: input.start.projectID,
                provider: provider,
                providerSettingsID: input.start.turn.configuration.providerID,
                model: input.start.turn.configuration.modelID,
                visibility: .privateSession,
                startImmediately: false
            )
            let digest = CanonicalSigning.bodyDigest(data)
            let accepted = try await authority.acceptStructuredSession(
                input: shell,
                coordinator: requireSubmissionCoordinator(),
                actor: principal.externalActor,
                publicSubmissionKey: input.operationID.uuidString.lowercased(),
                requestDigest: digest,
                submission: input.start.turn
            )
            try await requireSubmissionDispatchQueue().enqueue(
                accepted,
                actor: principal.externalActor,
                requestDigest: digest
            )
            let session = try await authority.sessionSnapshot(sessionID: accepted.receipt.sessionID)
            let control = try? await authority.agentSessionActionSnapshot(
                sessionID: session.sessionID,
                actor: principal.externalActor,
                composerAvailable: composerCatalog != nil
            )
            return try portalJSON(
                PortalAgentSubmissionReceipt(
                    accepted.receipt,
                    session: RepoPromptPortalSessionProjection.project(session, agentControl: control)
                ),
                status: .accepted
            )
        } }
        router.post("/portal/api/v1/sessions/:id/turns") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalSubmitAgentTurnRequest.self, from: data)
            let digest = CanonicalSigning.bodyDigest(data)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            try await authority.authorizeSessionCollaboration(
                sessionID: sessionID,
                actor: principal.externalActor,
                operation: "submitTurn",
                requestDigest: digest
            )
            // The server, not a browser snapshot, decides whether this message
            // starts a turn or steers the currently bound run. This closes the
            // race where a run begins between rendering and form submission.
            if snapshot.activeBinding != nil {
                let control = try await authority.agentSessionActionSnapshot(
                    sessionID: sessionID,
                    actor: principal.externalActor,
                    composerAvailable: composerCatalog != nil
                )
                guard control.steer.allowed, let epoch = control.steer.targetTurnEpoch else {
                    throw ServiceAPIError(
                        code: .runAlreadyActive,
                        message: control.steer.reasonText ?? "The current run is not ready for another message yet.",
                        retryable: control.steer.reasonCode == "steering_not_ready"
                    )
                }
                guard input.turn.content.attachmentIDs.isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Attachments cannot be added while steering a running agent.")
                }
                let text = input.turn.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Enter a message before sending")
                }
                let receipt = try await authority.execute(
                    command: .steerSession(text: text, targetTurnEpoch: epoch),
                    sessionID: sessionID,
                    externalActor: principal.externalActor,
                    idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                    requestDigest: digest
                )
                return try portalJSON(receipt, status: .accepted)
            }
            let accepted = try await requireSubmissionCoordinator().acceptFollowup(
                session: snapshot.session,
                activeRun: snapshot.activeRun,
                actor: principal.externalActor,
                publicSubmissionKey: input.operationID.uuidString.lowercased(),
                requestDigest: digest,
                submission: input.turn
            )
            try await requireSubmissionDispatchQueue().enqueue(
                accepted,
                actor: principal.externalActor,
                requestDigest: digest
            )
            return try portalJSON(PortalAgentSubmissionReceipt(accepted.receipt), status: .accepted)
        } }
        router.post("/portal/api/v1/sessions/:id/messages") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(PortalSendMessageRequest.self, from: data)
            let followup = try RepoPromptPortalSessionProjection.validatedSendCommand(input)
            guard case let .sendFollowup(text, _) = followup else {
                throw ServiceAPIError(code: .internalFailure, message: "Portal message validation produced an invalid command")
            }
            let control = try await authority.agentSessionActionSnapshot(
                sessionID: sessionID,
                actor: principal.externalActor,
                composerAvailable: composerCatalog != nil
            )
            let command: SessionCommand
            if control.steer.allowed, let epoch = control.steer.targetTurnEpoch {
                command = .steerSession(text: text, targetTurnEpoch: epoch)
            } else if control.submitTurn.allowed {
                command = followup
            } else {
                let denial = control.steer.reasonCode == "steering_not_ready"
                    ? control.steer
                    : control.submitTurn
                throw ServiceAPIError(
                    code: denial.reasonCode == "run_active" ? .runAlreadyActive : .invalidRequest,
                    message: denial.reasonText ?? "This session cannot accept a message right now",
                    retryable: denial.reasonCode == "steering_not_ready"
                )
            }
            let receipt = try await authority.execute(
                command: command,
                sessionID: sessionID,
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(principal: principal, operationID: input.operationID),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(receipt, status: .accepted)
        } }
        router.post("/portal/api/v1/sessions/:id/interactions/:interactionId/answer") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let interactionID = try context.parameters.require("interactionId", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(
                PortalInteractionAnswerRequest.self,
                from: data
            )
            guard let interaction = try await authority.interactionSnapshots(sessionID: sessionID)
                .first(where: { $0.interactionID == interactionID })
            else {
                throw ServiceAPIError(code: .notFound, message: "Interaction not found")
            }
            guard interaction.revision == input.expectedRevision else {
                throw ServiceAPIError(
                    code: .staleRevision,
                    message: "Interaction revision changed",
                    currentRevision: interaction.revision
                )
            }
            let payload = try AgentInteractionPresentationAdapter.compile(
                response: input.response,
                for: interaction
            )
            let resolved = try await authority.answerInteraction(
                sessionID: sessionID,
                interactionID: interactionID,
                expectedRevision: input.expectedRevision,
                payload: payload,
                actor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(
                    principal: principal,
                    operationID: input.operationID
                ),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(resolved)
        } }
        router.post("/portal/api/v1/sessions/:id/actions/:action") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let action = try context.parameters.require("action")
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(
                PortalSessionActionRequest.self,
                from: data
            )
            let control = try await authority.agentSessionActionSnapshot(
                sessionID: sessionID,
                actor: principal.externalActor,
                composerAvailable: composerCatalog != nil
            )
            let command: SessionCommand
            switch action {
            case "resume":
                guard control.resume.allowed else {
                    throw ServiceAPIError(
                        code: .resumeUnsupported,
                        message: control.resume.reasonText ?? "This session cannot be resumed"
                    )
                }
                command = .resumeSession(
                    expectedRunID: control.resume.expectedRunID,
                    providerResumeMode: .auto
                )
            case "cancel":
                guard control.cancel.allowed,
                      let generation = control.cancel.expectedGeneration
                else {
                    throw ServiceAPIError(
                        code: .invalidRequest,
                        message: control.cancel.reasonText ?? "This session cannot be cancelled"
                    )
                }
                command = .cancelSession(
                    expectedRunID: control.cancel.expectedRunID,
                    expectedGeneration: generation
                )
            case "retry":
                guard control.retry.allowed,
                      let sourceRunID = control.retry.sourceRunID
                else {
                    throw ServiceAPIError(
                        code: .invalidRequest,
                        message: control.retry.reasonText ?? "This session cannot be retried"
                    )
                }
                command = .retrySession(sourceRunID: sourceRunID, fromTranscriptEntryID: nil)
            case "archive":
                guard control.archive.allowed,
                      let expectedRevision = control.archive.expectedSessionRevision
                else {
                    throw ServiceAPIError(
                        code: .invalidRequest,
                        message: control.archive.reasonText ?? "This session cannot be archived"
                    )
                }
                command = .archiveSession(expectedRevision: expectedRevision)
            default:
                throw ServiceAPIError(code: .notFound, message: "Session action not found")
            }
            let receipt = try await authority.execute(
                command: command,
                sessionID: sessionID,
                externalActor: principal.externalActor,
                idempotencyKey: portalIdempotencyKey(
                    principal: principal,
                    operationID: input.operationID
                ),
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try portalJSON(receipt, status: .accepted)
        } }
        router.get("/portal/api/v1/desktop-settings") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requirePortalDesktopSettings().snapshot())
        } }
        router.patch("/portal/api/v1/desktop-settings") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(UpdatePortalDesktopSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requirePortalDesktopSettings().update(input))
        } }
        router.get("/portal/api/v1/settings/agent-models") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().agentModels())
        } }
        router.patch("/portal/api/v1/settings/agent-models") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceGlobalAgentModelsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceGlobalAgentModels(input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/settings/agent-models/apply-recommendations") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ApplyAgentModelRecommendationsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().applyGlobalAgentModelRecommendations(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/projects/:id/settings/agent-models") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(requireServerSettings().agentModels(projectID: projectID))
        } }
        router.patch("/portal/api/v1/projects/:id/settings/agent-models") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceProjectAgentModelsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceProjectAgentModels(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/agent-models/copy-global") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CopyGlobalAgentModelsToProjectRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().copyGlobalAgentModelsToProject(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/agent-models/copy-project") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CopyProjectAgentModelsToGlobalRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().copyProjectAgentModelsToGlobal(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/agent-models/apply-recommendations") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ApplyAgentModelRecommendationsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().applyProjectAgentModelRecommendations(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/subagent-permissions") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().subagentPermissions())
        } }
        router.patch("/portal/api/v1/settings/subagent-permissions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceSubagentPermissionSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceSubagentPermissions(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/direct-agent-permissions") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().directAgentPermissions())
        } }
        router.patch("/portal/api/v1/settings/direct-agent-permissions") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceDirectAgentPermissionsSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceDirectAgentPermissions(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/context-builder") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().contextBuilder())
        } }
        router.patch("/portal/api/v1/settings/context-builder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceGlobalContextBuilderSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceGlobalContextBuilder(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/projects/:id/settings/context-builder") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(requireServerSettings().contextBuilder(projectID: projectID))
        } }
        router.patch("/portal/api/v1/projects/:id/settings/context-builder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceProjectContextBuilderSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceProjectContextBuilder(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/settings/context-builder/copy-global") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CopyGlobalContextBuilderToProjectRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().copyGlobalContextBuilderToProject(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/model-presets") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().modelPresets())
        } }
        router.patch("/portal/api/v1/settings/model-presets") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceMCPModelPresetsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceModelPresets(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/advanced") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().advanced())
        } }
        router.patch("/portal/api/v1/settings/advanced") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceAdvancedServerSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceAdvanced(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/workspace-approvals") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().workspaceApprovals())
        } }
        router.patch("/portal/api/v1/settings/workspace-approvals") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceWorkspaceApprovalSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceWorkspaceApprovals(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/mcp-disabled-tools") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().mcpDisabledTools())
        } }
        router.patch("/portal/api/v1/settings/mcp-disabled-tools") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceMCPDisabledToolsSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceMCPDisabledTools(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/settings/show-model-presets") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireServerSettings().showModelPresets())
        } }
        router.patch("/portal/api/v1/settings/show-model-presets") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(ReplaceMCPShowModelPresetsSettingsRequest.self, from: bodyData(request))
            return try await portalJSON(requireServerSettings().replaceShowModelPresets(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/sessions/:id/selection") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let sessionID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(authority.selectionSnapshot(sessionID: sessionID))
        } }
        router.get("/portal/api/v1/projects/:id/selection-presets") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let projectID = try context.parameters.require("id", as: UUID.self)
            return try await portalJSON(authority.projectSelectionPresets(projectID: projectID))
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CreateProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.createProjectSelectionPreset(projectID: projectID, request: input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.patch("/portal/api/v1/projects/:id/selection-presets/:presetID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let presetID = try context.parameters.require("presetID", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(UpdateProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.updateProjectSelectionPreset(projectID: projectID, presetID: presetID, request: input, attribution: principal.settingsAttribution))
        } }
        router.delete("/portal/api/v1/projects/:id/selection-presets/:presetID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let presetID = try context.parameters.require("presetID", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(DeleteProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.deleteProjectSelectionPreset(projectID: projectID, presetID: presetID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets/reorder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ReorderProjectSelectionPresetsRequest.self, from: bodyData(request))
            return try await portalJSON(authority.reorderProjectSelectionPresets(projectID: projectID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets/capture") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(CaptureProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.captureProjectSelectionPreset(projectID: projectID, request: input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.post("/portal/api/v1/projects/:id/selection-presets/apply") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let projectID = try context.parameters.require("id", as: UUID.self)
            let input = try await JSONDecoder.serviceDecoder.decode(ApplyProjectSelectionPresetRequest.self, from: bodyData(request))
            return try await portalJSON(authority.applyProjectSelectionPreset(projectID: projectID, request: input, actor: principal.externalActor))
        } }
        router.get("/portal/api/v1/workflows") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(authority.workflowRepositorySnapshot())
        } }
        router.post("/portal/api/v1/workflows") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(CreateServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "name", "definition", "enabled", "visible", "featured"])
            return try await portalJSON(authority.createWorkflow(input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.patch("/portal/api/v1/workflows/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(UpdateServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedRowRevision", "name", "definition", "enabled", "visible", "featured"])
            return try await portalJSON(authority.updateWorkflow(workflowID: workflowID, request: input, attribution: principal.settingsAttribution))
        } }
        router.delete("/portal/api/v1/workflows/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(DeleteServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedRowRevision"])
            return try await portalJSON(authority.deleteWorkflow(workflowID: workflowID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/workflows/:id/clone") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(CloneServerWorkflowRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedSourceRowRevision", "name"])
            return try await portalJSON(authority.cloneWorkflow(workflowID: workflowID, request: input, attribution: principal.settingsAttribution), status: .created)
        } }
        router.patch("/portal/api/v1/workflows/:id/visibility") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let workflowID = try context.parameters.require("id")
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(SetServerWorkflowVisibilityRequest.self, data: data, allowedKeys: ["expectedRevision", "expectedRowRevision", "visible"])
            return try await portalJSON(authority.setWorkflowVisibility(workflowID: workflowID, request: input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/workflows/reorder") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(ReorderServerWorkflowsRequest.self, data: data, allowedKeys: ["expectedRevision", "featuredWorkflowIDs"])
            return try await portalJSON(authority.reorderWorkflows(input, attribution: principal.settingsAttribution))
        } }
        router.patch("/portal/api/v1/workflows/preferences") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(UpdateServerWorkflowPreferencesRequest.self, data: data, allowedKeys: ["expectedRevision", "includeSessionCleanupGuidance"])
            return try await portalJSON(authority.updateWorkflowPreferences(input, attribution: principal.settingsAttribution))
        } }
        router.post("/portal/api/v1/workflows/reload") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let data = try await bodyData(request)
            let input = try Self.decodeStrictWorkflowPayload(ReloadServerWorkflowsRequest.self, data: data, allowedKeys: ["expectedRevision"])
            return try await portalJSON(authority.reloadWorkflows(input, attribution: principal.settingsAttribution))
        } }
        router.get("/portal/api/v1/provider-settings") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            let catalog = try await requireProviderSettings().catalog()
            return try portalJSON(catalog)
        } }
        router.get("/portal/api/v1/provider-settings/:id/direct-configuration") { request, context in await portalRespond(request) {
            _ = try await authenticatePortal(request: request, context: context)
            return try await portalJSON(requireProviderSettings().directConfiguration(providerID: providerSettingsID(context)))
        } }
        router.patch("/portal/api/v1/provider-settings/:id/direct-configuration") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(UpdateDirectProviderConfigurationRequest.self, from: bodyData(request))
            let configuration = try await requireProviderSettings().updateDirectConfiguration(
                providerID: providerSettingsID(context),
                request: input,
                attribution: principal.providerAttribution
            )
            return try portalJSON(configuration)
        } }
        router.patch("/portal/api/v1/provider-settings/:id") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let id = try context.parameters.require("id")
            guard let providerID = ProviderSettingsID(rawValue: id) else {
                throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
            }
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(UpdateProviderSettingsRequest.self, from: data)
            let snapshot = try await requireProviderSettings().update(providerID: providerID, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/enable") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: bodyData(request))
            let snapshot = try await requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: true, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/disable") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let input = try await JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: bodyData(request))
            let snapshot = try await requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: false, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/install") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            return try await portalJSON(requireProviderSettings().installCLI(providerID: providerSettingsID(context), attribution: principal.providerAttribution), status: .created)
        } }
        router.post("/portal/api/v1/provider-settings/:id/update-cli") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            return try await portalJSON(requireProviderSettings().updateCLI(providerID: providerSettingsID(context), attribution: principal.providerAttribution))
        } }
        router.post("/portal/api/v1/provider-settings/:id/uninstall") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request, requireJSON: false)
            return try await portalJSON(requireProviderSettings().uninstallCLI(providerID: providerSettingsID(context), attribution: principal.providerAttribution))
        } }
        router.post("/portal/api/v1/provider-settings/:id/auth-flows") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let id = try context.parameters.require("id")
            guard let providerID = ProviderSettingsID(rawValue: id) else {
                throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
            }
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(StartProviderAuthFlowRequest.self, from: data)
            let challenge = try await requireProviderSettings().startAuthFlow(
                providerID: providerID,
                request: input,
                attribution: principal.providerAttribution
            )
            return try portalJSON(challenge, status: .accepted)
        } }
        router.post("/portal/api/v1/provider-settings/:id/connect") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let providerID = try providerSettingsID(context)
            let input = try await JSONDecoder.serviceDecoder.decode(ConnectProviderRequest.self, from: bodyData(request))
            let snapshot = try await requireProviderSettings().connect(providerID: providerID, request: input, attribution: principal.providerAttribution)
            return try portalJSON(snapshot, status: .created)
        } }
        router.post("/portal/api/v1/provider-settings/:id/test") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let snapshot = try await requireProviderSettings().testConnection(providerID: providerSettingsID(context), attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/disconnect") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let snapshot = try await requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: principal.providerAttribution)
            return try portalJSON(snapshot)
        } }
        router.post("/portal/api/v1/provider-settings/:id/revoke") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let snapshot = try await requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: principal.providerAttribution, revoke: true)
            return try portalJSON(snapshot)
        } }
        router.get("/portal/api/v1/provider-auth-flows/:flowID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            let flowID = try context.parameters.require("flowID", as: UUID.self)
            let status = try await requireProviderSettings().pollAuthFlow(flowID: flowID, ownerID: principal.actorID)
            return try portalJSON(status)
        } }
        router.delete("/portal/api/v1/provider-auth-flows/:flowID") { request, context in await portalRespond(request) {
            let principal = try await authenticatePortal(request: request, context: context)
            try validatePortalMutation(request)
            let flowID = try context.parameters.require("flowID", as: UUID.self)
            try await requireProviderSettings().cancelAuthFlow(flowID: flowID, ownerID: principal.actorID)
            return HTTPResponses.empty()
        } }
        router.get("/internal/v1/provider-settings") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app, .operatorRole], operation: "providerCatalog")
            return try await HTTPResponses.json(requireProviderSettings().catalog())
        } }
        router.get("/internal/v1/provider-settings/:id/direct-configuration") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app, .operatorRole], operation: "providerDirectConfigurationRead")
            return try await HTTPResponses.json(requireProviderSettings().directConfiguration(providerID: providerSettingsID(context)))
        } }
        router.patch("/internal/v1/provider-settings/:id/direct-configuration") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerDirectConfigurationUpdate")
            let input = try JSONDecoder.serviceDecoder.decode(UpdateDirectProviderConfigurationRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().updateDirectConfiguration(
                providerID: providerSettingsID(context),
                request: input,
                attribution: providerAttribution(auth)
            ))
        } }
        router.patch("/internal/v1/provider-settings/:id") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerUpdate")
            let input = try JSONDecoder.serviceDecoder.decode(UpdateProviderSettingsRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().update(providerID: providerSettingsID(context), request: input, attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/enable") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerEnable")
            let input = try JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: true, request: input, attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/disable") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerDisable")
            let input = try JSONDecoder.serviceDecoder.decode(SetProviderEnabledRequest.self, from: data)
            return try await HTTPResponses.json(requireProviderSettings().setEnabled(providerID: providerSettingsID(context), enabled: false, request: input, attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/install") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "providerCLIInstall")
            return try await HTTPResponses.json(requireProviderSettings().installCLI(providerID: providerSettingsID(context), attribution: providerAttribution(auth)), status: .created)
        } }
        router.post("/internal/v1/provider-settings/:id/update-cli") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "providerCLIUpdate")
            return try await HTTPResponses.json(requireProviderSettings().updateCLI(providerID: providerSettingsID(context), attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/uninstall") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.operatorRole], operation: "providerCLIUninstall")
            return try await HTTPResponses.json(requireProviderSettings().uninstallCLI(providerID: providerSettingsID(context), attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/connect") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerConnect")
            let input = try JSONDecoder.serviceDecoder.decode(ConnectProviderRequest.self, from: data)
            let snapshot = try await requireProviderSettings().connect(providerID: providerSettingsID(context), request: input, attribution: providerAttribution(auth))
            return try HTTPResponses.json(snapshot, status: .created)
        } }
        router.post("/internal/v1/provider-settings/:id/test") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerTest")
            return try await HTTPResponses.json(requireProviderSettings().testConnection(providerID: providerSettingsID(context), attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/disconnect") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerDisconnect")
            return try await HTTPResponses.json(requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: providerAttribution(auth)))
        } }
        router.post("/internal/v1/provider-settings/:id/revoke") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerRevoke")
            return try await HTTPResponses.json(requireProviderSettings().disconnect(providerID: providerSettingsID(context), attribution: providerAttribution(auth), revoke: true))
        } }
        router.post("/internal/v1/provider-settings/:id/auth-flows") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerAuthStart")
            let input = try JSONDecoder.serviceDecoder.decode(StartProviderAuthFlowRequest.self, from: data)
            let status = try await requireProviderSettings().startAuthFlow(providerID: providerSettingsID(context), request: input, attribution: providerAttribution(auth))
            return try HTTPResponses.json(status, status: .accepted)
        } }
        router.get("/internal/v1/provider-auth-flows/:flowID") { request, context in await respond(request) {
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app, .operatorRole], operation: "providerAuthPoll")
            let status = try await requireProviderSettings().pollAuthFlow(flowID: context.parameters.require("flowID", as: UUID.self), ownerID: providerAttribution(auth).actorID)
            return try HTTPResponses.json(status)
        } }
        router.delete("/internal/v1/provider-auth-flows/:flowID") { request, context in await respond(request) {
            let data = try await bodyData(request)
            _ = try requireIdempotency(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app, .operatorRole], operation: "providerAuthCancel")
            try await requireProviderSettings().cancelAuthFlow(flowID: context.parameters.require("flowID", as: UUID.self), ownerID: providerAttribution(auth).actorID)
            return HTTPResponses.empty()
        } }
        router.get("/internal/v1/capabilities") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.app, .sync], operation: "capabilities")
            let meta = try await store.metadata()
            let models = try await composerCatalog?.compatibilityModels() ?? []
            return try await HTTPResponses.json(ServiceCapabilitiesResponse(
                protocolRange: .init(minimum: 1, maximum: 1),
                schemaVersion: meta.schemaVersion,
                storeID: meta.storeID,
                replayFloor: meta.replayFloor,
                providers: providerCatalog(),
                models: models,
                workflows: authority.workflowSnapshots(),
                executionModes: executionModeCatalog(),
                eventTypes: EventType.allCases,
                projectSources: authority.projectSourceCapabilities()
            ))
        } }
        router.get("/internal/v1/catalog/composer") { request, context in await respond(request) {
            let projectID = request.uri.queryParameters["projectId"].flatMap { UUID(uuidString: String($0)) }
            let sessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            guard (projectID != nil) != (sessionID != nil) else { throw ServiceAPIError(code: .invalidRequest, message: "Exactly one projectId or sessionId is required") }
            if let projectID {
                let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerCatalog", projectID: projectID)
                _ = try await authority.projectSnapshot(projectID: projectID)
                let actor = try requireActor(auth)
                return try await HTTPResponses.privateJSON(requireComposerCatalog().snapshot(context: .init(kind: .project, projectID: projectID, actorID: actor.userID)))
            }
            let resolvedSessionID = sessionID!
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerCatalog", sessionID: resolvedSessionID)
            let actor = try requireActor(auth)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: resolvedSessionID)
            let active = snapshot.activeBinding != nil
            return try await HTTPResponses.privateJSON(requireComposerCatalog().snapshot(context: .init(kind: .session, projectID: snapshot.session.projectID, sessionID: resolvedSessionID, actorID: actor.userID, activeRun: active)))
        } }
        router.get("/internal/v1/catalog/composer-suggestions") { request, context in await respond(request) {
            let projectID = request.uri.queryParameters["projectId"].flatMap { UUID(uuidString: String($0)) }
            let sessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            guard (projectID != nil) != (sessionID != nil) else { throw ServiceAPIError(code: .invalidRequest, message: "Exactly one projectId or sessionId is required") }
            let query = String(request.uri.queryParameters["query"] ?? "")
            let kinds = Set(String(request.uri.queryParameters["kinds"] ?? "nativeCommand,skill,file").split(separator: ",").compactMap { ComposerSuggestionWire.Kind(rawValue: String($0)) })
            guard !kinds.isEmpty, kinds.count <= 3 else { throw ServiceAPIError(code: .invalidRequest, message: "Suggestion kinds are invalid") }
            if let projectID {
                let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerSuggestions", projectID: projectID)
                _ = try await authority.projectSnapshot(projectID: projectID)
                let actor = try requireActor(auth)
                return try await HTTPResponses.privateJSON(requireComposerCatalog().suggestions(context: .init(kind: .project, projectID: projectID, actorID: actor.userID), query: query, kinds: kinds, limit: 50))
            }
            let resolvedSessionID = sessionID!
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getComposerSuggestions", sessionID: resolvedSessionID)
            let actor = try requireActor(auth)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: resolvedSessionID)
            let active = snapshot.activeBinding != nil
            return try await HTTPResponses.privateJSON(requireComposerCatalog().suggestions(context: .init(kind: .session, projectID: snapshot.session.projectID, sessionID: resolvedSessionID, actorID: actor.userID, activeRun: active), query: query, kinds: kinds, limit: 50))
        } }
        router.get("/internal/v1/diagnostics") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.operatorRole], operation: "diagnostics")
            let meta = try await store.metadata()
            let currentReadiness = await readiness.snapshot(forceRefresh: true)
            return try await HTTPResponses.json(RepoPromptDiagnostics(
                storeID: meta.storeID,
                schemaVersion: meta.schemaVersion,
                nextGlobalSequence: meta.nextGlobalSequence,
                replayFloor: meta.replayFloor,
                readiness: currentReadiness,
                operational: currentReadiness.operational,
                drain: currentReadiness.drain,
                maintenance: durabilityOperations?.snapshot()
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

        router.get("/internal/v1/projects") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listProjects")
            let projects = await authority.projectSnapshots().map(ProjectWireSnapshot.init)
            return try await HTTPResponses.json(page(projects, request: request, defaultLimit: 100, maximumLimit: 500) { $0.projectID.uuidString })
        } }
        router.post("/internal/v1/projects") { request, context in await respond(request) { let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "createProject")
            let input = try JSONDecoder.serviceDecoder.decode(CreateProjectWireInput.self, from: data)
            guard input.schemaVersion == 1, input.expectedRevision == 0 else {
                throw ServiceAPIError(code: .invalidRequest, message: "Project creation contract is invalid")
            }
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let snapshot = try await authority.createProject(
                input: .init(name: input.name, roots: []),
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data),
                correlationID: input.operationID
            )
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot), status: .created)
        } }
        router.post("/internal/v1/projects/:id/source-operations") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(
                request,
                context: context,
                body: data,
                roles: [.app],
                operation: "addProjectRepository",
                projectID: id
            )
            let input = try JSONDecoder.serviceDecoder.decode(AddProjectRepositoryInput.self, from: data)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let result = try await authority.addProjectRepository(
                projectID: id,
                input: input,
                externalActor: actor,
                idempotencyKey: key,
                requestDigest: CanonicalSigning.bodyDigest(data)
            )
            return try HTTPResponses.json(result, status: .created)
        } }
        router.patch("/internal/v1/projects/:id") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "renameProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(RenameProjectInput.self, from: data)
            let snapshot = try await authority.renameProject(projectID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot))
        } }
        router.delete("/internal/v1/projects/:id") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "removeProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(RemoveProjectInput.self, from: data)
            try await authority.removeProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return HTTPResponses.empty()
        } }
        router.post("/internal/v1/projects/:id/composer-attachments") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request, maximumBytes: 10 * 1_024 * 1_024 + 64 * 1_024)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "createComposerAttachment", projectID: projectID)
            let actor = try requireActor(auth)
            let upload = try composerAttachmentUpload(data: data, contentType: request.headers[.contentType], fallbackDisplayName: String(request.uri.queryParameters["displayName"] ?? "image"))
            guard upload.displayName.utf8.count <= 256 else { throw ServiceAPIError(code: .invalidRequest, message: "Attachment display name exceeds its bound") }
            let attachment = try await requireComposerAttachments().stage(data: upload.data, displayName: upload.displayName, declaredMediaType: upload.mediaType, actorID: actor.userID, projectID: projectID)
            return try HTTPResponses.privateJSON(attachment, status: .created)
        } }
        router.post("/internal/v1/projects/:id/composer-attachments/resolve") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "resolveComposerAttachments", projectID: projectID)
            let input = try JSONDecoder.serviceDecoder.decode(ComposerAttachmentResolveRequest.self, from: data)
            let actor = try requireActor(auth)
            return try await HTTPResponses.privateJSON(requireComposerAttachments().resolve(attachmentIDs: input.attachmentIDs, actorID: actor.userID, projectID: projectID))
        } }
        router.get("/internal/v1/projects/:id/composer-attachments/:attachmentId/preview") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            let visibleSessionID = request.uri.queryParameters["sessionId"].flatMap { UUID(uuidString: String($0)) }
            let auth: AuthenticatedInternalRequest
            if let visibleSessionID {
                let session = try await authority.sessionSnapshot(sessionID: visibleSessionID)
                guard session.projectID == projectID else { throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable") }
                auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "previewComposerAttachment", sessionID: visibleSessionID)
            } else {
                auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "previewComposerAttachment", projectID: projectID)
            }
            let actor = try requireActor(auth)
            let preview = try await requireComposerAttachments().preview(attachmentID: attachmentID, actorID: actor.userID, projectID: projectID, visibleSessionID: visibleSessionID)
            return HTTPResponses.privateBytes(preview.1, contentType: preview.0.mediaType)
        } }
        router.delete("/internal/v1/projects/:id/composer-attachments/:attachmentId") { request, context in await respond(request) {
            let projectID = try context.parameters.require("id", as: UUID.self)
            let attachmentID = try context.parameters.require("attachmentId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "deleteComposerAttachment", projectID: projectID)
            let actor = try requireActor(auth)
                try await requireComposerAttachments().delete(attachmentID: attachmentID, actorID: actor.userID, projectID: projectID)
                return HTTPResponses.privateEmpty()
        } }
        router.get("/internal/v1/projects/:id/snapshot") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(ProjectWireSnapshot(authority.projectSnapshot(projectID: id)))
        } }
        router.get("/internal/v1/projects/:id/tree") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getProjectTree", projectID: id)
            let rootID = try requireQueryUUID(request, name: "rootId")
            let path = String(request.uri.queryParameters["path"] ?? "")
            let depth = request.uri.queryParameters.get("depth", as: Int.self) ?? 4
            let maximumEntries = request.uri.queryParameters.get("limit", as: Int.self) ?? 5000
            guard (0 ... 16).contains(depth), (1 ... 5000).contains(maximumEntries) else { throw ServiceAPIError(code: .invalidRequest, message: "Tree bounds exceed the v1 limit") }
            return try await HTTPResponses.json(authority.projectTree(projectID: id, request: ProjectTreeRequest(rootID: rootID, logicalPath: path, maximumDepth: depth, maximumEntries: maximumEntries)))
        } }
        router.post("/internal/v1/projects/:id/search") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "searchProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSearchRequest.self, from: data)
            guard (1 ... 500).contains(input.maximumResults), (1 ... 2_097_152).contains(input.maximumFileBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "Search bounds exceed the v1 limit") }
            return try await HTTPResponses.json(authority.projectSearch(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/file") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "getFile", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectFileRequest.self, from: data)
            guard (1 ... 2_097_152).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "File bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectFile(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/codemap") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "getCodeMap", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectCodeMapRequest.self, from: data)
            guard (1 ... 5_242_880).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "CodeMap bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectCodeMap(projectID: id, request: input))
        } }
        router.post("/internal/v1/projects/:id/diff") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            _ = try await authenticate(request, context: context, body: data, roles: [.app], operation: "getDiff", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectDiffRequest.self, from: data)
            guard (1 ... 2_097_152).contains(input.maximumBytes) else { throw ServiceAPIError(code: .invalidRequest, message: "Diff bound exceeds the v1 limit") }
            return try await HTTPResponses.json(authority.projectDiff(projectID: id, request: input))
        } }
        router.get("/internal/v1/projects/:id/worktrees") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listWorktrees", projectID: id)
            let worktrees = try await authority.worktreeSnapshots(projectID: id).map(WorktreeWireSnapshot.init)
            return try await HTTPResponses.json(page(worktrees, request: request, defaultLimit: 100, maximumLimit: 500) { $0.bindingID.uuidString })
        } }
        router.get("/internal/v1/projects/:id/worktrees/:worktreeId") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getWorktree", projectID: id)
            return try await HTTPResponses.json(WorktreeWireSnapshot(authority.worktreeSnapshot(projectID: id, bindingID: bindingID)))
        } }
        router.post("/internal/v1/projects/:id/refresh") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "refreshProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectRefreshInput.self, from: data)
            let snapshot = try await authority.refreshProject(projectID: id, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data))
            return try HTTPResponses.json(ProjectWireSnapshot(snapshot))
        } }
        router.get("/internal/v1/projects/:id/context/selection-template") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getProject", projectID: id)
            return try await HTTPResponses.json(authority.projectSelectionTemplate(projectID: id))
        } }
        router.put("/internal/v1/projects/:id/context/selection-template") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "updateProject", projectID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSelectionTemplateMutationInput.self, from: data)
            return try await HTTPResponses.json(authority.replaceProjectSelectionTemplate(projectID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data)))
        } }

        router.get("/internal/v1/sessions") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listSessions")
            let sessions = try await authority.sessionSnapshots()
            return try await HTTPResponses.json(page(sessions, request: request, defaultLimit: 100, maximumLimit: 500) { $0.sessionID.uuidString })
        } }
        router.post("/internal/v1/sessions") { request, context in await respond(request) { let data = try await bodyData(request)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            let key = try requireIdempotency(request)
            if let structured = try? JSONDecoder.serviceDecoder.decode(AgentStartSessionWire.self, from: data) {
                guard let provider = structured.turn.configuration.providerID.runtimeKind else {
                    throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider has no execution adapter")
                }
                let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "startSession", projectID: structured.projectID)
                let actor = try requireActor(auth)
                let selectedMessageContext = try structured.selectedMessageContext?.validated()
                let shell = CreateSessionInput(projectID: structured.projectID, provider: provider, model: structured.turn.configuration.modelID, visibility: structured.visibility, startImmediately: false)
                let accepted = try await authority.acceptStructuredSession(input: shell, coordinator: requireSubmissionCoordinator(), actor: actor, publicSubmissionKey: key, requestDigest: requestDigest, submission: structured.turn, selectedMessageContext: selectedMessageContext)
                try await requireSubmissionDispatchQueue().enqueue(accepted, actor: actor, requestDigest: requestDigest)
                return try HTTPResponses.privateJSON(accepted.receipt, status: .accepted)
            }
            let requestBody = try JSONDecoder.serviceDecoder.decode(CreateSessionRequest.self, from: data)
            let input: CreateSessionInput
            if requestBody.hasExplicitProviderRoute {
                input = try requestBody.explicitCreateSessionInput()
            } else {
                input = try await requireServerSettings().createSessionInput(from: requestBody)
            }
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "startSession", projectID: input.projectID)
            guard input.parentSessionID == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Public session creation cannot specify parentSessionID; child agents are created by agent_manage") }
            let snapshot = try await authority.createSession(input: input, externalActor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest)
            return try HTTPResponses.privateJSON(snapshot, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/snapshot") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getSession", sessionID: id)
            return try await HTTPResponses.privateJSON(authority.sessionDetailSnapshot(sessionID: id))
        } }
        router.get("/internal/v1/sessions/:id/transcript") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getTranscript", sessionID: id)
            let transcript = try await authority.sessionSnapshot(sessionID: id).transcript
            return try await HTTPResponses.json(page(transcript, request: request, defaultLimit: 200, maximumLimit: 1000) { String(format: "%020lld", $0.sessionSequence) })
        } }
        router.get("/internal/v1/sessions/:id/transcript/presentation") { request, context in await respond(request) {
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let auth = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getTranscriptPresentation", sessionID: sessionID)
            let actor = try requireActor(auth)
            let session = try await authority.sessionSnapshot(sessionID: sessionID)
            let metadata = try await authority.collaborationMetadata(sessionID: sessionID)
            let token = request.uri.queryParameters["pageToken"].map(String.init)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 25
            let page = try await requireTranscriptPresentation().page(sessionID: sessionID, actorID: actor.userID, legacyTranscript: session.transcript, interactions: session.interactions, pageToken: token, limit: limit, mutableInteractions: metadata.controllerUserID == actor.userID)
            return try HTTPResponses.privateJSON(page)
        } }
        router.post("/internal/v1/sessions/:id/turns") { request, context in await respond(request) {
            let sessionID = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "submitTurn", sessionID: sessionID)
            let actor = try requireActor(auth)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(AgentTurnSubmissionWire.self, from: data)
            let snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: sessionID, actor: actor, operation: "submitTurn", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let accepted = try await requireSubmissionCoordinator().acceptFollowup(session: snapshot.session, activeRun: snapshot.activeRun, actor: actor, publicSubmissionKey: key, requestDigest: requestDigest, submission: input)
            try await requireSubmissionDispatchQueue().enqueue(accepted, actor: actor, requestDigest: requestDigest)
            return try HTTPResponses.privateJSON(accepted.receipt, status: .accepted)
        } }
        router.post("/internal/v1/sessions/:id/commands") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let command = try JSONDecoder.serviceDecoder.decode(SessionCommand.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: command.operation, sessionID: id)
            let receipt = try await authority.execute(command: command, sessionID: id, externalActor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try HTTPResponses.json(receipt, status: .accepted)
        } }
        router.get("/internal/v1/sessions/:id/context/selection") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getSelection", sessionID: id)
            return try await HTTPResponses.json(authority.selectionSnapshot(sessionID: id))
        } }
        router.put("/internal/v1/sessions/:id/context/selection") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "replaceSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "replaceSelection", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.replaceSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/add") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "addToSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionMutationInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "addToSelection", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.addSelection(sessionID: id, entries: input.entries, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/context/selection/remove") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "removeFromSelection", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(SelectionRemovalInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "removeFromSelection", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.removeSelection(sessionID: id, rootID: input.rootID, logicalPaths: input.logicalPaths, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.get("/internal/v1/sessions/:id/permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getExecutionPermissions", sessionID: id)
            guard let snapshot = try await authority.permissionSnapshot(sessionID: id) else { return Response(status: .noContent) }
            return try HTTPResponses.json(snapshot)
        } }
        router.patch("/internal/v1/sessions/:id/permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "updateExecutionPermissions", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "updateExecutionPermissions", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.patch("/internal/v1/sessions/:id/execution-permissions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "updateExecutionPermissions", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(ExecutionPermissionUpdateInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "updateExecutionPermissions", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.updatePermissions(sessionID: id, expectedRevision: input.expectedRevision, mode: input.mode, providerSettings: input.providerSettings, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.patch("/internal/v1/sessions/:id/collaboration-metadata") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let input = try JSONDecoder.serviceDecoder.decode(CollaborationMetadataInput.self, from: data)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "setSessionVisibility", sessionID: id)
            return try await HTTPResponses.json(authority.updateCollaborationMetadata(sessionID: id, input: input, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }
        router.get("/internal/v1/sessions/:id/interactions") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getInteractions", sessionID: id)
            let interactions = try await authority.interactionSnapshots(sessionID: id)
            return try await HTTPResponses.json(page(interactions, request: request, defaultLimit: 100, maximumLimit: 500) { $0.interactionID.uuidString })
        } }
        router.post("/internal/v1/sessions/:id/interactions/answer") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "answerInteraction", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "answerInteraction", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: input.interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/interactions/:interactionId/answer") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let interactionID = try context.parameters.require("interactionId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "answerInteraction", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(InteractionAnswerInput.self, from: data)
            guard input.interactionID == interactionID else { throw ServiceAPIError(code: .invalidRequest, message: "Interaction path and body IDs do not match") }
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "answerInteraction", requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.answerInteraction(sessionID: id, interactionID: interactionID, expectedRevision: input.expectedRevision, payload: input.payload, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/worktrees") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "createWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeCreateInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "createWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.createWorktree(sessionID: id, rootID: input.rootID, baseRef: input.baseRef, branch: input.branch, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/worktrees/merge") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "mergeWorktree", sessionID: id)
            let key = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "mergeWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.mergeWorktree(sessionID: id, bindingID: input.bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: key, requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.patch("/internal/v1/sessions/:id/worktree-binding") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "bindWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeBindInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "bindWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.bindWorktree(sessionID: id, bindingID: input.bindingID, expectedRevision: input.expectedRevision, expectedSelectionBindingRevision: input.expectedSelectionBindingRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.post("/internal/v1/sessions/:id/worktrees/:worktreeId/merge") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let bindingID = try context.parameters.require("worktreeId", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "mergeWorktree", sessionID: id)
            let input = try JSONDecoder.serviceDecoder.decode(WorktreeMergeInput.self, from: data)
            guard input.bindingID == bindingID else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree path and body IDs do not match") }
            let requestDigest = CanonicalSigning.bodyDigest(data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "mergeWorktree", requestDigest: requestDigest, authorizationDecision: auth.decision)
            let snapshot = try await authority.mergeWorktree(sessionID: id, bindingID: bindingID, strategy: input.strategy, expectedRevision: input.expectedRevision, actor: requireActor(auth), idempotencyKey: requireIdempotency(request), requestDigest: requestDigest, authorizationDecision: auth.decision)
            return try HTTPResponses.json(WorktreeWireSnapshot(snapshot))
        } }
        router.get("/internal/v1/sessions/:id/artifacts") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getArtifacts", sessionID: id)
            let artifacts = try await authority.artifactSnapshots(sessionID: id)
            return try await HTTPResponses.json(page(artifacts, request: request, defaultLimit: 100, maximumLimit: 500) { $0.artifactID.uuidString })
        } }
        router.get("/internal/v1/sessions/:id/artifacts/:artifactId/content") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let artifactID = try context.parameters.require("artifactId", as: UUID.self)
            let requestedRange = try parseByteRange(request.headers[.range])
            let signedTarget = requestedRange.map {
                "\(request.uri.string)#range=bytes=\($0.lowerBound)-\($0.upperBound - 1)"
            } ?? request.uri.string
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "downloadArtifact", sessionID: id, pathAndQuery: signedTarget)
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
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listWorkflows")
            let workflows = try await authority.workflowSnapshots()
            return try await HTTPResponses.json(page(workflows, request: request, defaultLimit: 100, maximumLimit: 500) { $0.workflowID })
        } }
        router.get("/internal/v1/catalog/workflows/:id") { request, context in await respond(request) {
            let id = try context.parameters.require("id")
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "getWorkflow")
            return try await HTTPResponses.json(authority.workflowSnapshot(workflowID: id))
        } }
        router.get("/internal/v1/catalog/providers") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listProviders")
            let providers = await providerCatalog()
            return try await HTTPResponses.json(page(providers, request: request, defaultLimit: 100, maximumLimit: 500) { $0.kind.rawValue })
        } }
        router.get("/internal/v1/catalog/models") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listModels")
            let models = try await requireComposerCatalog().compatibilityModels()
            return try await HTTPResponses.json(page(models, request: request, defaultLimit: 100, maximumLimit: 500) { "\($0.providerID?.rawValue ?? $0.provider.rawValue):\($0.id)" })
        } }
        router.get("/internal/v1/catalog/execution-modes") { request, context in await respond(request) {
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listExecutionModes")
            return try await HTTPResponses.json(page(executionModeCatalog(), request: request, defaultLimit: 100, maximumLimit: 500) { $0.id })
        } }
        router.get("/internal/v1/sessions/:id/children") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            _ = try await authenticate(request, context: context, body: Data(), roles: [.app], operation: "listSessionChildren", sessionID: id)
            let children = try await authority.childSessionSnapshots(parentSessionID: id)
            return try await HTTPResponses.json(page(children, request: request, defaultLimit: 100, maximumLimit: 500) { $0.sessionID.uuidString })
        } }
        router.post("/internal/v1/sessions/:id/context/build") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "buildContext", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuildInput.self, from: data)
            let requestDigest = CanonicalSigning.bodyDigest(data)
            return try await HTTPResponses.json(authority.buildContext(sessionID: id, expectedSelectionRevision: input.expectedSelectionRevision, include: input.include, actor: requireActor(auth), requestDigest: requestDigest, authorizationDecision: auth.decision), status: .created)
        } }
        router.post("/internal/v1/sessions/:id/context/context-builder") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "runContextBuilder", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(ContextBuilderInput.self, from: data)
            if let budget = input.budget, !(1 ... 1_000_000).contains(budget) {
                throw ServiceAPIError(code: .invalidRequest, message: "Context Builder budget exceeds the v1 bound")
            }
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "runContextBuilder", requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.runContextBuilder(sessionID: id, input: input, actor: requireActor(auth), origin: .internal, requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }
        router.post("/internal/v1/sessions/:id/context/oracle") { request, context in await respond(request) { let id = try context.parameters.require("id", as: UUID.self)
            let data = try await bodyData(request)
            let auth = try await authenticate(request, context: context, body: data, roles: [.app], operation: "askOracle", sessionID: id)
            _ = try requireIdempotency(request)
            let input = try JSONDecoder.serviceDecoder.decode(OracleInput.self, from: data)
            try await authority.authorizeSessionCollaboration(sessionID: id, actor: requireActor(auth), operation: "askOracle", requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision)
            return try await HTTPResponses.json(authority.askOracle(sessionID: id, input: input, actor: requireActor(auth), requestDigest: CanonicalSigning.bodyDigest(data), authorizationDecision: auth.decision))
        } }

        router.get("/internal/v1/events") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.sync], operation: "events")
            let cursor = try parseCursor(request)
            let limit = request.uri.queryParameters.get("limit", as: Int.self) ?? 500
            guard (1 ... 1000).contains(limit) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Event replay limit is outside the v1 bound")
            }
            return try await HTTPResponses.json(authority.events(after: cursor, limit: limit))
        } }
        router.get("/internal/v1/events/stream") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.sync], operation: "eventStream")
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
                        let json = try String(decoding: JSONEncoder.serviceEncoder.encode(event), as: UTF8.self)
                        try await writer.write(ByteBuffer(string: "id: \(event.storeID.uuidString):\(event.globalSequence)\nevent: \(event.eventType.rawValue)\ndata: \(json)\n\n"))
                    case .heartbeat:
                        try await writer.write(ByteBuffer(string: ": heartbeat\n\n"))
                    }
                }
                try await writer.finish(nil)
            })
        } }
        router.get("/internal/v1/snapshot") { request, context in await respond(request) { _ = try await authenticate(request, context: context, body: Data(), roles: [.sync], operation: "snapshot")
            let snapshot = try await authority.authoritativeSnapshot()
            let agents = try await authority.agentSnapshots()
            let titles = RepoPromptPortalSessionProjection.snapshotTitles(sessions: snapshot.sessions, agents: agents)
            return try HTTPResponses.json(AuthoritativeWireSnapshot(snapshot, sessionTitles: titles))
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
            return HTTPResponses.empty(status: .accepted)
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

    private func portalRespond(_ request: Request, _ operation: () async throws -> Response) async -> Response {
        let method = String(describing: request.method).uppercased()
        let isMutation = method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE"
        if isMutation, await !(drainController.beginMutation()) {
            return portalError(ServiceAPIError(code: .quiescing, message: "Service is draining mutations", retryable: true))
        }
        let response: Response
        do { response = try await operation() } catch { response = portalError(error) }
        if isMutation { await drainController.finishMutation() }
        return response
    }

    private struct PortalAuthenticatedPrincipal {
        let actorID: String
        let providerAttribution: ProviderMutationAttribution
        let settingsAttribution: SettingsMutationAttribution
        let externalActor: ExternalActor
    }

    private struct GabblinActorEnvelope: Decodable {
        let schemaVersion: Int
        let subject: String
        let username: String
        let displayName: String
    }

    private struct GabblinCreateProjectRequest: Decodable {
        let name: String
    }

    private struct GabblinProjectResponse: Encodable {
        let project: PortalProjectSummary
    }

    private struct GabblinSessionDetailResponse: Encodable {
        let session: PortalSessionSummary
        let collaboration: CollaborationMetadataSnapshot
    }

    private struct GabblinCollaborationResponse: Encodable {
        let collaboration: CollaborationMetadataSnapshot
    }

    private struct GabblinVisibilityRequest: Decodable {
        let expectedPolicyRevision: Int64
        let visibility: Visibility
    }

    private struct GabblinSteeringRequest: Decodable {
        let expectedPolicyRevision: Int64
        let enabled: Bool
    }

    private struct GabblinAgentCommandRequest: Decodable {
        let operation: String
        let operationID: UUID
        let text: String?
        let targetTurnEpoch: Int64?
        let expectedRunID: UUID?
        let expectedGeneration: Int64?
        let providerResumeMode: ProviderResumeMode?
        let sourceRunID: UUID?
        let fromTranscriptEntryID: UUID?

        private enum CodingKeys: String, CodingKey {
            case operation
            case operationID = "operationId"
            case text, targetTurnEpoch
            case expectedRunID = "expectedRunId"
            case expectedGeneration, providerResumeMode
            case sourceRunID = "sourceRunId"
            case fromTranscriptEntryID = "fromTranscriptEntryId"
        }

        func sessionCommand() throws -> SessionCommand {
            switch operation {
            case "steer":
                guard let text, let targetTurnEpoch else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Steer command is incomplete")
                }
                return .steerSession(text: text, targetTurnEpoch: targetTurnEpoch)
            case "cancel":
                guard let expectedGeneration else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Cancel command is incomplete")
                }
                return .cancelSession(
                    expectedRunID: expectedRunID,
                    expectedGeneration: expectedGeneration
                )
            case "resume":
                return .resumeSession(
                    expectedRunID: expectedRunID,
                    providerResumeMode: providerResumeMode ?? .auto
                )
            case "retry":
                guard let sourceRunID else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Retry command is incomplete")
                }
                return .retrySession(
                    sourceRunID: sourceRunID,
                    fromTranscriptEntryID: fromTranscriptEntryID
                )
            default:
                throw ServiceAPIError(code: .invalidRequest, message: "Unsupported Gabblin session command")
            }
        }
    }

    private struct PortalAuthStatusResponse: Encodable {
        let needsSetup: Bool
        let authenticated: Bool
        let username: String?
        let passwordLoginEnabled: Bool
    }

    private struct PortalRefreshEvent: Encodable {
        let projectID: UUID
        let sessionID: UUID?

        private enum CodingKeys: String, CodingKey {
            case projectID = "projectId"
            case sessionID = "sessionId"
        }
    }

    private struct PortalClientIntegrationInventory: Encodable {
        let gabblin: PortalGabblinInventory
    }

    private struct PortalGabblinInventory: Encodable {
        let integration: PortalGabblinIntegrationView?
        let members: [PortalGabblinMemberView]
    }

    private struct PortalGabblinIntegrationView: Encodable {
        let status: String
        let createdAt: Date
        let updatedAt: Date
        let revokedAt: Date?
    }

    private struct PortalGabblinMemberView: Encodable {
        let memberID: UUID
        let username: String
        let displayName: String
        let firstSeenAt: Date
        let lastSeenAt: Date
        let profileObservedAt: Date
    }

    private struct PortalGabblinCredentialDisclosureResponse: Encodable {
        let token: String
    }

    private struct PortalSetupRequest: Decodable {
        let password: String
        let passwordConfirmation: String
    }

    private struct PortalLoginRequest: Decodable {
        let username: String?
        let password: String
    }

    private func portalAuthStatus(request: Request, context: RepoPromptRequestContext) async throws -> PortalAuthStatusResponse {
        let hasAccount = try await store.hasOperatorAccount()
        let needsSetup = portalPasswordLoginEnabled && !hasAccount
        let principal = try? await authenticatePortal(request: request, context: context)
        return PortalAuthStatusResponse(
            needsSetup: needsSetup,
            authenticated: principal != nil,
            username: principal.map { $0.externalActor.username },
            passwordLoginEnabled: portalPasswordLoginEnabled
        )
    }

    private func completePortalSetup(request: Request) async throws -> Response {
        guard portalPasswordLoginEnabled else {
            throw ServiceAPIError(code: .invalidRequest, message: "Password setup is not enabled for this server")
        }
        let input = try JSONDecoder.serviceDecoder.decode(PortalSetupRequest.self, from: try await bodyData(request))
        guard input.password == input.passwordConfirmation else {
            throw ServiceAPIError(code: .invalidRequest, message: "Password confirmation does not match")
        }
        try await store.createOperatorAccount(password: input.password)
        let token = try await store.createOperatorSession()
        return portalSessionResponse(token: token, status: .created)
    }

    private func completePortalLogin(request: Request) async throws -> Response {
        guard portalPasswordLoginEnabled else {
            throw ServiceAPIError(code: .invalidRequest, message: "Password login is not enabled for this server")
        }
        let input = try JSONDecoder.serviceDecoder.decode(PortalLoginRequest.self, from: try await bodyData(request))
        let username = (input.username?.isEmpty == false ? input.username : nil) ?? SQLiteServiceStore.defaultOperatorUsername
        guard try await store.verifyOperatorPassword(username: username, password: input.password) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Operator username or password is incorrect")
        }
        let token = try await store.createOperatorSession(username: username)
        return portalSessionResponse(token: token)
    }

    private func completePortalLogout(request: Request) async throws -> Response {
        if let token = operatorSessionToken(from: request) {
            try await store.deleteOperatorSession(token: token)
        }
        var response = try portalJSON(["ok": true])
        response.headers[.setCookie] = "rpce_operator_session=; Path=/portal; HttpOnly; SameSite=Strict; Secure; Max-Age=0"
        return response
    }

    private func portalSessionResponse(token: String, status: HTTPResponse.Status = .ok) -> Response {
        var response = (try? portalJSON(["ok": true], status: status)) ?? Response(status: status)
        response.headers[.setCookie] = "rpce_operator_session=\(token); Path=/portal; HttpOnly; SameSite=Strict; Secure; Max-Age=43200"
        return response
    }

    private func operatorSessionToken(from request: Request) -> String? {
        guard let header = request.headers[.cookie] else { return nil }
        return header.split(separator: ";").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("rpce_operator_session=") }
            .map { String($0.dropFirst("rpce_operator_session=".count)) }
    }

    private func authenticatePortal(request: Request, context: RepoPromptRequestContext) async throws -> PortalAuthenticatedPrincipal {
        if let token = operatorSessionToken(from: request),
           let username = try await store.operatorSessionUsername(token: token)
        {
            let actorID = "operator:\(username)"
            let actorLabel = "\(username) portal"
            return PortalAuthenticatedPrincipal(
                actorID: actorID,
                providerAttribution: ProviderMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-password"),
                settingsAttribution: SettingsMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-password"),
                externalActor: ExternalActor(userID: actorID, username: username, displayName: actorLabel)
            )
        }
        if portalPasswordLoginEnabled {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Sign in to the operator portal")
        }
        guard let certificateRoleResolver else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Sign in to the operator portal")
        }
        let certificate: NIOSSLCertificate
        if let portalPeerCertificateDER {
            certificate = try NIOSSLCertificate(bytes: [UInt8](portalPeerCertificateDER), format: .der)
        } else {
            let peer: NIOSSLCertificate?
            do {
                peer = try await context.channel.nioSSL_peerCertificate().get()
            } catch {
                peer = nil
            }
            guard let peer else {
                throw ServiceAPIError(code: .internalAuthFailed, message: "An authorized portal client certificate is required")
            }
            certificate = peer
        }
        let role = try certificateRoleResolver.role(certificate: certificate)
        guard RepoPromptPortalCertificateAuthorization.allows(role) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "An authorized portal client certificate is required")
        }
        let digest = try SHA256.hash(data: Data(certificate.toDERBytes())).map { String(format: "%02x", $0) }.joined()
        let actorID = "certificate:\(digest)"
        let actorLabel = "\(role.rawValue) portal"
        return PortalAuthenticatedPrincipal(
            actorID: actorID,
            providerAttribution: ProviderMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-mtls"),
            settingsAttribution: SettingsMutationAttribution(actorID: actorID, actorLabel: actorLabel, channel: "portal-mtls"),
            externalActor: ExternalActor(userID: actorID, username: actorLabel, displayName: actorLabel)
        )
    }

    private func authenticateGabblin(request: Request) async throws -> ExternalActor {
        let authorization = request.headers[.init("Authorization")!] ?? ""
        guard authorization.hasPrefix("Bearer ") else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Gabblin API token is required")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard let encodedActor = request.headers[.init("X-RepoPrompt-Gabblin-Actor")!],
              encodedActor.utf8.count <= 1_024,
              let actorData = CanonicalSigning.base64URLDecode(encodedActor),
              let envelope = try? JSONDecoder.serviceDecoder.decode(GabblinActorEnvelope.self, from: actorData),
              envelope.schemaVersion == 1,
              envelope.subject.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              !envelope.username.isEmpty,
              envelope.username.utf8.count <= 128,
              !envelope.displayName.isEmpty,
              envelope.displayName.utf8.count <= 256
        else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Gabblin actor header is invalid")
        }
        try await store.authenticateGabblinCredential(
            token: token,
            subject: envelope.subject,
            username: envelope.username,
            displayName: envelope.displayName
        )
        return ExternalActor(userID: envelope.subject, username: envelope.username, displayName: envelope.displayName)
    }

    private func requireGabblinOperationKey(_ request: Request, operationID: UUID) throws -> String {
        let key = try requireIdempotency(request)
        guard key.caseInsensitiveCompare(operationID.uuidString) == .orderedSame else {
            throw ServiceAPIError(code: .invalidRequest, message: "Gabblin operation and idempotency IDs do not match")
        }
        return key
    }

    private func gabblinSuggestionQuery(_ request: Request) throws -> String {
        let query = String(request.uri.queryParameters["query"] ?? "")
        guard query.utf8.count <= 512,
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Composer suggestion query is invalid")
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalGabblinSessionID(_ request: Request) throws -> UUID? {
        guard let raw = request.uri.queryParameters["sessionId"] else { return nil }
        guard let sessionID = UUID(uuidString: String(raw)) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Composer attachment session ID is invalid")
        }
        return sessionID
    }

    private func portalIdempotencyKey(principal: PortalAuthenticatedPrincipal, operationID: UUID) -> String {
        "portal:\(principal.actorID):\(operationID.uuidString.lowercased())"
    }

    private func providerSettingsID(_ context: RepoPromptRequestContext) throws -> ProviderSettingsID {
        let id = try context.parameters.require("id")
        guard let providerID = ProviderSettingsID(rawValue: id) else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings not found")
        }
        return providerID
    }

    private func requirePortalDesktopSettings() -> PortalDesktopSettingsService {
        portalDesktopSettings
    }

    private func requireProviderSettings() throws -> ProviderSettingsService {
        guard let providerSettings else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider settings are unavailable", retryable: true)
        }
        return providerSettings
    }

    private func requireServerSettings() throws -> ServerSettingsService {
        guard let serverSettings else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Server settings are unavailable", retryable: true)
        }
        return serverSettings
    }

    private func requireComposerCatalog() throws -> any AgentComposerCatalogProviding {
        guard let composerCatalog else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent composer catalog is unavailable", retryable: true) }
        return composerCatalog
    }

    private func requireComposerAttachments() throws -> AgentComposerAttachmentStore {
        guard let composerAttachments else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent composer attachments are unavailable", retryable: true) }
        return composerAttachments
    }

    private func requireSubmissionCoordinator() throws -> AgentSubmissionCoordinator {
        guard let submissionCoordinator else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent submission coordinator is unavailable", retryable: true) }
        return submissionCoordinator
    }

    private func requireSubmissionDispatchQueue() throws -> AgentSubmissionDispatchQueue {
        guard let submissionDispatchQueue else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent submission dispatch queue is unavailable", retryable: true) }
        return submissionDispatchQueue
    }

    private func requireTranscriptPresentation() throws -> AgentTranscriptPresentationService {
        guard let transcriptPresentation else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Agent transcript presentation is unavailable", retryable: true) }
        return transcriptPresentation
    }

    private func providerAttribution(_ auth: AuthenticatedInternalRequest) -> ProviderMutationAttribution {
        if let actor = auth.decision?.actor {
            return .init(actorID: actor.userID, actorLabel: actor.username, channel: "app")
        }
        return .init(actorID: "signing-key:\(auth.keyID)", actorLabel: auth.role.rawValue, channel: "internal-hmac")
    }

    static func decodeStrictWorkflowPayload<Value: Decodable>(
        _ type: Value.Type,
        data: Data,
        allowedKeys: Set<String>
    ) throws -> Value {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowedKeys) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Workflow request contains unsupported fields")
        }
        return try JSONDecoder.serviceDecoder.decode(type, from: data)
    }

    private func portalJSON(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder.serviceEncoder.encode(value)
        var headers = RepoPromptPortalAssets.securityHeaders(contentType: "application/json; charset=utf-8")
        headers[.cacheControl] = "private, no-store"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func portalBytes(_ data: Data, contentType: String) -> Response {
        var headers = RepoPromptPortalAssets.securityHeaders(contentType: contentType)
        headers[.cacheControl] = "private, no-store"
        headers[.contentLength] = String(data.count)
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func portalEmpty() -> Response {
        var headers = RepoPromptPortalAssets.securityHeaders(contentType: "application/json; charset=utf-8")
        headers[.cacheControl] = "private, no-store"
        return Response(status: .noContent, headers: headers)
    }

    private func portalError(_ error: Error) -> Response {
        let apiError = error as? ServiceAPIError ?? ServiceAPIError(code: .dependencyUnavailable, message: "Portal dependency failed", retryable: true)
        let status: HTTPResponse.Status = switch apiError.code {
        case .invalidRequest: .badRequest
        case .internalAuthFailed: .unauthorized
        case .authorizationDecisionRejected: .forbidden
        case .notFound: .notFound
        case .staleRevision, .controllerChanged: .conflict
        case .rateLimited: .tooManyRequests
        case .dependencyUnavailable, .quiescing, .persistenceUnavailable: .serviceUnavailable
        default: .unprocessableContent
        }
        return (try? portalJSON(apiError, status: status)) ?? Response(status: .internalServerError)
    }

    private func validatePortalMutation(_ request: Request, requireJSON: Bool = true) throws {
        try RepoPromptPortalRequestProtection.validateMutation(
            origin: request.headers[.init("Origin")!],
            host: request.head.authority,
            fetchSite: request.headers[.init("Sec-Fetch-Site")!],
            contentType: request.headers[.contentType],
            csrfHeader: request.headers[.init("X-RepoPrompt-Portal-CSRF")!],
            requireJSON: requireJSON
        )
    }

    private func portalSidebarSessions(
        principal: PortalAuthenticatedPrincipal,
        projectID: UUID? = nil
    ) async throws -> [PortalSessionSummary] {
        let snapshots = try await authority.sessionSnapshots().filter {
            projectID == nil || $0.projectID == projectID
        }
        let controls = try await authority.agentSessionActionSnapshots(
            sessionIDs: snapshots.map(\.sessionID),
            actor: principal.externalActor,
            composerAvailable: composerCatalog != nil
        )
        return RepoPromptPortalSessionProjection.sidebarSessions(
            snapshots,
            controls: controls
        )
    }

    private func portalBootstrap(principal: PortalAuthenticatedPrincipal) async throws -> PortalBootstrapResponse {
        try await bootstrap(actor: principal.externalActor)
    }

    private func bootstrap(actor: ExternalActor) async throws -> PortalBootstrapResponse {
        let projects = await authority.projectSnapshots().map(RepoPromptPortalSessionProjection.project)
        let snapshots = try await authority.sessionSnapshots()
        let controls = try await authority.agentSessionActionSnapshots(
            sessionIDs: snapshots.map(\.sessionID),
            actor: actor,
            composerAvailable: composerCatalog != nil
        )
        let sessions = RepoPromptPortalSessionProjection.sidebarSessions(snapshots, controls: controls)
        let workflowRepository = try await authority.workflowRepositorySnapshot()
        let workflows = try await authority.workflowSnapshots().map {
            PortalWorkflowSummary(
                workflowID: $0.workflowID,
                name: $0.name,
                source: ServerWorkflowSource(rawValue: $0.source) ?? .builtin,
                enabled: $0.enabled,
                visible: $0.visible,
                featuredOrder: $0.featuredOrder,
                rowRevision: $0.rowRevision
            )
        }
        return PortalBootstrapResponse(
            projects: projects,
            sessions: sessions,
            workflows: workflows,
            tools: RepoPromptPortalSessionProjection.tools(),
            workflowRepositoryRevision: workflowRepository.revision,
            includeSessionCleanupGuidance: workflowRepository.includeSessionCleanupGuidance,
            projectSources: await authority.projectSourceCapabilities()
        )
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
        let nextToken: String? = if end < ordered.count {
            try CanonicalSigning.base64URLEncode(JSONEncoder.serviceEncoder.encode(PageToken(storeID: cursor.storeID, globalSequence: cursor.globalSequence, offset: end)))
        } else {
            nil
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

    private func bodyData(_ request: Request, maximumBytes: Int = 1_048_576) async throws -> Data {
        let buffer = try await request.body.collect(upTo: maximumBytes)
        return Data(buffer.readableBytesView)
    }

    private func composerAttachmentUpload(data: Data, contentType: String?, fallbackDisplayName: String) throws -> (data: Data, mediaType: String?, displayName: String) {
        guard let contentType, contentType.lowercased().hasPrefix("multipart/form-data") else {
            return (data, contentType?.split(separator: ";", maxSplits: 1).first.map(String.init), fallbackDisplayName)
        }
        let parameters = contentType.split(separator: ";").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard let boundaryParameter = parameters.first(where: { $0.lowercased().hasPrefix("boundary=") }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment boundary is missing")
        }
        var boundary = String(boundaryParameter.dropFirst("boundary=".count))
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") { boundary = String(boundary.dropFirst().dropLast()) }
        guard !boundary.isEmpty, boundary.utf8.count <= 200 else { throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment boundary is invalid") }
        let headerTerminator = Data("\r\n\r\n".utf8)
        let nextBoundary = Data("\r\n--\(boundary)".utf8)
        guard let headerEnd = data.range(of: headerTerminator), headerEnd.lowerBound <= 16 * 1_024,
              let bodyEnd = data.range(of: nextBoundary, in: headerEnd.upperBound ..< data.endIndex),
              let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment body is malformed") }
        let lines = headerText.components(separatedBy: "\r\n")
        let disposition = lines.first { $0.lowercased().hasPrefix("content-disposition:") } ?? ""
        guard disposition.lowercased().contains("form-data"), disposition.lowercased().contains("name=\"file\"") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Multipart attachment requires one file field")
        }
        let filename = disposition.range(of: "filename=\"").flatMap { start -> String? in
            let suffix = disposition[start.upperBound...]
            guard let end = suffix.firstIndex(of: "\"") else { return nil }
            return String(suffix[..<end])
        }
        let mediaType = lines.first { $0.lowercased().hasPrefix("content-type:") }.map { String($0.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces) }
        let payload = Data(data[headerEnd.upperBound ..< bodyEnd.lowerBound])
        guard payload.count <= 10 * 1_024 * 1_024 else { throw ServiceAPIError(code: .invalidRequest, message: "Image exceeds the 10 MiB item limit") }
        return (payload, mediaType, filename ?? fallbackDisplayName)
    }

    private func authenticate(_ request: Request, context: RepoPromptRequestContext, body: Data, roles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil, pathAndQuery: String? = nil) async throws -> AuthenticatedInternalRequest {
        guard let keyID = request.headers[.internalKeyID], let timestamp = request.headers[.internalTimestamp], let nonce = request.headers[.internalNonce], let bodyDigest = request.headers[.internalBodyDigest], let signature = request.headers[.internalSignature] else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signed internal headers are required") }
        let decisionHeader = request.headers[.authorizationDecision]
        let decisionData = decisionHeader.flatMap(CanonicalSigning.base64URLDecode)
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
        let payload = try String(decoding: JSONEncoder.serviceEncoder.encode(transition), as: UTF8.self)
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            try await writer.write(ByteBuffer(string: "event: cursor_expired\ndata: \(payload)\n\n"))
            try await writer.finish(nil)
        })
    }
}
