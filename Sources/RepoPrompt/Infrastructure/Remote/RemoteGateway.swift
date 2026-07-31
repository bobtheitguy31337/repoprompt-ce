import AppKit
import Foundation
import Network
import RepoPromptRemoteProtocol
import Security

private struct RemoteHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

/// Opt-in LAN gateway for the Remote control surface. The gateway is
/// intentionally independent from the Unix-socket MCP server and talks to
/// typed application services through the snapshot and command boundaries.
@MainActor
final class RemoteGatewayController: NSObject, ObservableObject {
    static let shared = RemoteGatewayController()

    @Published private(set) var isRunning = false
    @Published private(set) var pairingAdvertisement: RemotePairingAdvertisement?
    @Published private(set) var pairingCode: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastRequestAt: Date?
    @Published private(set) var lastSuccessfulRequestAt: Date?
    @Published private(set) var lastSnapshotAt: Date?
    @Published private(set) var isPaired = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "RepoPrompt.remote.gatewayEnabled"
    private static let defaultAuthorityKey = "RepoPrompt.remote.defaultAuthority"
    private static let maximumBufferedRequestBytes = 1_048_576

    private weak var windowStatesManager: WindowStatesManager?
    private var controlService: (any RemoteAgentControlService)?
    private let pairingManager = RemotePairingManager.shared
    private lazy var notificationRelay = RemoteNotificationRelay(pairingManager: pairingManager)
    private let tlsIdentityStore = RemoteTLSIdentityStore()
    private let availabilityController = RemoteAvailabilityController.shared
    private let replayBuffer = RemoteEventReplayBuffer(capacity: 512)
    private let transcriptRevisionTracker = RemoteTranscriptRevisionTracker()
    /// Changes only when the CE process restarts. Gateway stop/start preserves it.
    private let transcriptRevisionEpoch = UUID()

    private var tlsIdentity: RemoteTLSIdentity?
    private var listener: NWListener?
    private var bonjourService: NetService?
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]
    private var eventPollTask: Task<Void, Never>?
    private var lastPublishedSnapshot: RemoteSnapshot?
    private(set) var activePort: UInt16?

    var notificationRelayConfigured: Bool {
        notificationRelay.isConfigured
    }

    var notificationRegistrationAvailable: Bool {
        pairingManager.registeredNotification != nil
    }

    override private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isPaired = pairingManager.isPaired
        super.init()
    }

    func configure(windowStatesManager: WindowStatesManager) {
        self.windowStatesManager = windowStatesManager
        controlService = WindowRemoteAgentControlService(windowStatesManager: windowStatesManager)
        if isEnabled, !isRunning {
            Task { [weak self] in
                try? await self?.start()
            }
        }
    }

    private static func makePairingCode(for advertisement: RemotePairingAdvertisement) -> String? {
        guard let data = try? JSONEncoder().encode(advertisement) else { return nil }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "rpremote://pair?payload=\(payload)"
    }

    var pairedDeviceName: String? {
        pairingManager.pairedDeviceName
    }

    func refreshPairingAdvertisement() {
        guard let activePort else { return }
        setPairingAdvertisement(pairingManager.issueAdvertisement(
            port: activePort,
            serviceName: bonjourName,
            host: RemoteLocalAddress.preferredIPv4Address()
        ))
    }

    var defaultAuthority: RemoteAuthorityLevel {
        get {
            RemoteAuthorityLevel(
                rawValue: UserDefaults.standard.integer(forKey: Self.defaultAuthorityKey)
            ) ?? .observe
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultAuthorityKey) }
    }

    var authorizationState: RemoteAuthorizationState {
        RemoteAuthorizationState(defaultLevel: defaultAuthority)
    }

    func start() async throws {
        guard !isRunning else { return }
        guard windowStatesManager != nil else {
            throw RemoteGatewayError.configurationUnavailable
        }

        do {
            let identity = try tlsIdentityStore.loadOrCreate()
            tlsIdentity = identity
            if identity.wasCreated {
                // A new TLS identity invalidates the certificate pin held by
                // existing phones, so do not leave an unusable device paired.
                pairingManager.revokeDevice()
                isPaired = false
            }
            pairingManager.setCertificateSHA256(identity.certificateSHA256)

            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv12
            )
            guard let secIdentity = sec_identity_create(identity.identity)
            else { throw RemoteGatewaySecurityError.certificateUnavailable }
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions,
                secIdentity
            )

            let parameters = NWParameters(tls: tlsOptions)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                listener.stateUpdateHandler = { [weak controller = self, weak listener] state in
                    Task { @MainActor in
                        guard let controller, let listener else { return }
                        switch state {
                        case .ready:
                            guard !resumed else { return }
                            resumed = true
                            guard let port = listener.port?.rawValue else {
                                continuation.resume(throwing: RemoteGatewayError.listenerUnavailable)
                                return
                            }
                            controller.activePort = port
                            controller.setPairingAdvertisement(controller.pairingManager.issueAdvertisement(
                                port: port,
                                serviceName: controller.bonjourName,
                                host: RemoteLocalAddress.preferredIPv4Address()
                            ))
                            controller.publishBonjour(port: port)
                            controller.isRunning = true
                            controller.lastError = nil
                            controller.startEventPolling()
                            continuation.resume()
                        case let .failed(error):
                            guard !resumed else { return }
                            resumed = true
                            controller.lastError = error.localizedDescription
                            continuation.resume(throwing: error)
                        case .cancelled:
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(throwing: RemoteGatewayError.listenerUnavailable)
                        default:
                            break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        self?.accept(connection)
                    }
                }
                listener.start(queue: .main)
            }
        } catch {
            stop()
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        eventPollTask?.cancel()
        eventPollTask = nil
        lastPublishedSnapshot = nil
        listener?.cancel()
        listener = nil
        bonjourService?.stop()
        bonjourService = nil
        connectionBuffers.removeAll()
        setPairingAdvertisement(nil)
        activePort = nil
        isRunning = false
        availabilityController.releaseSleepAssertion()
    }

    func diagnostics() async -> RemoteDiagnostics {
        await RemoteDiagnostics(
            gatewayState: isRunning ? "running" : "stopped",
            lastRequestAt: lastRequestAt,
            lastSuccessfulRequestAt: lastSuccessfulRequestAt,
            lastSnapshotAt: lastSnapshotAt,
            lastEventCursor: replayBuffer.latestCursor(),
            pairedDevice: pairingManager.isPaired,
            notificationRegistration: notificationRegistrationAvailable,
            notificationRelayConfigured: notificationRelayConfigured,
            notificationLastAttemptAt: notificationRelay.lastAttemptAt,
            notificationLastError: notificationRelay.lastError
        )
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if enabled {
            do { try await start() } catch { lastError = error.localizedDescription }
        } else {
            stop()
        }
    }

    private func setPairingAdvertisement(_ advertisement: RemotePairingAdvertisement?) {
        pairingAdvertisement = advertisement
        pairingCode = advertisement.flatMap(Self.makePairingCode(for:))
    }

    func revokePairedDevice() {
        pairingManager.revokeDevice()
        isPaired = false
        refreshPairingAdvertisement()
    }

    func publish(_ event: RemoteEvent) async -> RemoteEvent {
        await replayBuffer.append(event)
    }

    private func startEventPolling() {
        eventPollTask?.cancel()
        eventPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await publishLiveStateChanges()
            }
        }
    }

    /// The gateway publishes bounded, sanitized coarse events from the same
    /// authoritative snapshot used by GET /snapshot. This keeps the gateway
    /// independent of individual Agent Mode runners while still making live
    /// state changes observable to a reconnecting phone.
    private func publishLiveStateChanges() async {
        guard isRunning else { return }
        let current = await snapshot()
        availabilityController.update(snapshot: current)
        guard let previous = lastPublishedSnapshot else {
            lastPublishedSnapshot = current
            return
        }

        var pendingEvents: [RemoteEvent] = []

        if previous.authorization != current.authorization {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .authorizationChanged,
                payload: .authorization(current.authorization)
            ))
        }

        if previous.workflowCatalog != current.workflowCatalog
            || previous.agentCatalog != current.agentCatalog
            || previous.agentCatalogMetadata != current.agentCatalogMetadata
        {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .catalogChanged,
                payload: .catalog(
                    RemoteCatalogPayload(
                        workflows: current.workflowCatalog,
                        agents: current.agentCatalog,
                        metadata: current.agentCatalogMetadata
                    )
                )
            ))
        }

        let oldWorkspaces = Dictionary(uniqueKeysWithValues: previous.workspaces.map { ($0.workspaceID, $0) })
        for workspace in current.workspaces where oldWorkspaces[workspace.workspaceID] != workspace {
            let type: RemoteEventType = workspace.isOpen ? .workspaceReady : .workspaceOpening
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: type,
                workspaceID: workspace.workspaceID,
                payload: .workspace(workspace)
            ))
        }

        let oldSessions = Dictionary(uniqueKeysWithValues: previous.sessions.map { ($0.sessionID, $0) })
        for session in current.sessions {
            guard let old = oldSessions[session.sessionID] else {
                pendingEvents.append(RemoteEvent(
                    desktopInstanceID: pairingManager.desktopInstanceID,
                    type: .sessionCreated,
                    workspaceID: session.workspaceID,
                    sessionID: session.sessionID,
                    payload: .session(session)
                ))
                continue
            }
            guard old != session else { continue }
            if let event = Self.transcriptRevisionEvent(
                old: old,
                current: session,
                desktopInstanceID: pairingManager.desktopInstanceID
            ) {
                pendingEvents.append(event)
            }
            guard Self.hasSessionChangeExcludingTranscriptRevision(old: old, current: session) else {
                continue
            }
            let type: RemoteEventType = if old.runState != session.runState {
                switch session.runState {
                case .working: .runStarted
                case .waitingForInput: .runWaitingForInput
                case .completed: .runCompleted
                case .failed: .runFailed
                case .cancelled: .runCancelled
                default: .sessionUpdated
                }
            } else if old.latestMeaningfulActivity != session.latestMeaningfulActivity {
                .runProgressed
            } else if old.pendingInteraction == nil, session.pendingInteraction != nil {
                .interactionCreated
            } else if old.pendingInteraction != nil, session.pendingInteraction == nil {
                .interactionResolved
            } else {
                .sessionUpdated
            }
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: type,
                workspaceID: session.workspaceID,
                sessionID: session.sessionID,
                payload: .session(session)
            ))
            if let category = Self.notificationCategory(old: old, current: session) {
                _ = await notificationRelay.deliver(category: category, sessionID: session.sessionID)
            }
        }

        let oldAttention = Dictionary(uniqueKeysWithValues: previous.attentionItems.map { ($0.id, $0) })
        let currentAttention = Dictionary(uniqueKeysWithValues: current.attentionItems.map { ($0.id, $0) })
        for item in current.attentionItems where oldAttention[item.id] != item {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .interactionCreated,
                sessionID: item.sessionID,
                payload: .attention(item)
            ))
        }
        for id in oldAttention.keys where currentAttention[id] == nil {
            pendingEvents.append(RemoteEvent(
                desktopInstanceID: pairingManager.desktopInstanceID,
                type: .interactionResolved,
                payload: .attentionRemoved(id)
            ))
        }

        for event in RemoteEventCoalescer.coalesce(pendingEvents) {
            _ = await publish(event)
        }

        lastPublishedSnapshot = current
    }

    static func transcriptRevisionEvent(
        old: RemoteSessionSummary,
        current: RemoteSessionSummary,
        desktopInstanceID: String
    ) -> RemoteEvent? {
        guard old.transcriptRevision != current.transcriptRevision,
              let revision = current.transcriptRevision
        else { return nil }
        return RemoteEvent(
            desktopInstanceID: desktopInstanceID,
            type: .transcriptItemsAppended,
            workspaceID: current.workspaceID,
            sessionID: current.sessionID,
            payload: .text(String(revision))
        )
    }

    static func hasSessionChangeExcludingTranscriptRevision(
        old: RemoteSessionSummary,
        current: RemoteSessionSummary
    ) -> Bool {
        old.sessionID != current.sessionID
            || old.workspaceID != current.workspaceID
            || old.composeTabID != current.composeTabID
            || old.parentSessionID != current.parentSessionID
            || old.sessionName != current.sessionName
            || old.workflow != current.workflow
            || old.workflowID != current.workflowID
            || old.runStartedAt != current.runStartedAt
            || old.agent != current.agent
            || old.model != current.model
            || old.reasoningEffort != current.reasoningEffort
            || old.configurationControls != current.configurationControls
            || old.runState != current.runState
            || old.lifecycleStage != current.lifecycleStage
            || old.latestMeaningfulActivity != current.latestMeaningfulActivity
            || old.pendingInteraction != current.pendingInteraction
            || old.childSessionIDs != current.childSessionIDs
            || old.worktreeSummary != current.worktreeSummary
            || old.mergeAttention != current.mergeAttention
            || old.failureSummary != current.failureSummary
            || old.lastUpdatedAt != current.lastUpdatedAt
            || old.isLive != current.isLive
    }

    private static func notificationCategory(
        old: RemoteSessionSummary,
        current: RemoteSessionSummary
    ) -> RemoteNotificationCategory? {
        if old.pendingInteraction == nil, let interaction = current.pendingInteraction {
            return interaction.kind == .approval ? .approvalRequired : .agentNeedsInput
        }
        guard old.runState != current.runState else { return nil }
        switch current.runState {
        case .completed: return .completed
        case .failed: return .failed
        default: return nil
        }
    }

    private var bonjourName: String {
        "RepoPrompt-\(pairingManager.desktopInstanceID.prefix(8))"
    }

    private func publishBonjour(port: UInt16) {
        bonjourService?.stop()
        let service = NetService(
            domain: "local.",
            type: "_repoprompt-remote._tcp.",
            name: bonjourName,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "desktopInstanceID": pairingManager.desktopInstanceID.data(using: .utf8) ?? Data(),
            "protocol": "v1".data(using: .utf8) ?? Data()
        ]))
        service.schedule(in: .main, forMode: .common)
        service.publish(options: [.listenForConnections])
        bonjourService = service
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connectionBuffers[identifier] = Data()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.receive(on: connection)
                case .failed, .cancelled:
                    self.connectionBuffers.removeValue(forKey: ObjectIdentifier(connection))
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, let connection else { return }
                let identifier = ObjectIdentifier(connection)
                if let data, !data.isEmpty {
                    self.connectionBuffers[identifier, default: Data()].append(data)
                    guard self.connectionBuffers[identifier, default: Data()].count <= Self.maximumBufferedRequestBytes else {
                        self.connectionBuffers.removeValue(forKey: identifier)
                        connection.cancel()
                        return
                    }
                    await self.processBufferedRequests(on: connection)
                }
                guard !isComplete, error == nil else {
                    self.connectionBuffers.removeValue(forKey: identifier)
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func processBufferedRequests(on connection: NWConnection) async {
        let identifier = ObjectIdentifier(connection)
        while var buffer = connectionBuffers[identifier],
              let request = nextRequest(from: &buffer)
        {
            connectionBuffers[identifier] = buffer
            await handle(request, on: connection)
            if connectionBuffers[identifier] == nil { return }
        }
    }

    private func nextRequest(from buffer: inout Data) -> RemoteHTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeAll()
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].lowercased()
            let value = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= Self.maximumBufferedRequestBytes else {
            buffer.removeAll(keepingCapacity: true)
            return nil
        }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let bodyEnd = bodyStart + contentLength
        let body = buffer.subdata(in: bodyStart ..< bodyEnd)
        buffer.removeSubrange(buffer.startIndex ..< bodyEnd)
        return RemoteHTTPRequest(method: requestParts[0], target: requestParts[1], headers: headers, body: body)
    }

    private func handle(_ request: RemoteHTTPRequest, on connection: NWConnection) async {
        lastRequestAt = Date()
        guard let components = URLComponents(string: request.target) else {
            sendError(.init(code: "invalid_request", message: "Invalid request target."), status: 400, on: connection)
            return
        }
        switch (request.method, components.path) {
        case ("POST", RemoteProtocol.pairingPath):
            guard let pairingRequest = try? JSONDecoder().decode(RemotePairingRequest.self, from: request.body) else {
                sendError(.init(code: "invalid_pairing_request", message: "Invalid pairing request."), status: 400, on: connection)
                return
            }
            do {
                let response = try pairingManager.pair(request: pairingRequest, desktop: desktopSummary)
                isPaired = true
                sendJSON(response, status: 200, on: connection)
            } catch let error as RemoteGatewaySecurityError {
                sendError(.init(code: "pairing_failed", message: error.localizedDescription), status: 403, on: connection)
            } catch {
                sendError(.init(code: "pairing_failed", message: "Pairing could not be completed."), status: 500, on: connection)
            }

        case ("POST", RemoteProtocol.unpairPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            pairingManager.revokeDevice()
            isPaired = false
            refreshPairingAdvertisement()
            sendJSON(RemoteUnpairResponse(), status: 200, on: connection)

        case ("GET", RemoteProtocol.snapshotPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            await sendJSON(snapshot(), status: 200, on: connection)

        case ("GET", RemoteProtocol.diagnosticsPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            await sendJSON(diagnostics(), status: 200, on: connection)

        case ("GET", RemoteProtocol.workspacesPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            await sendJSON(snapshot().workspaces, status: 200, on: connection)

        case ("GET", RemoteProtocol.sessionsPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            await sendJSON(snapshot().sessions, status: 200, on: connection)

        case ("GET", RemoteProtocol.agentsPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            await sendJSON(snapshot().agentCatalog, status: 200, on: connection)

        case ("GET", RemoteProtocol.workflowsPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            await sendJSON(snapshot().workflowCatalog, status: 200, on: connection)

        case ("GET", RemoteProtocol.historyPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            let query = components.queryItems?.first(where: { $0.name == "q" })?.value
            let limit = components.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 50
            guard let readService = makeReadService() else {
                sendError(.init(code: "unavailable", message: "Remote read services are not ready.", retryable: true), status: 503, on: connection)
                return
            }
            let page = await readService.history(query: query, limit: limit)
            sendJSON(
                RemoteHistoryPage(protocolVersion: RemoteProtocol.currentVersion, entries: page.entries, hasMore: page.hasMore),
                status: 200,
                on: connection
            )

        case ("GET", RemoteProtocol.transcriptPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            guard let sessionID = components.queryItems?.first(where: { $0.name == "session_id" })?.value.flatMap(UUID.init) else {
                sendError(.init(code: "invalid_session", message: "A valid session_id is required."), status: 400, on: connection)
                return
            }
            let after = components.queryItems?.first(where: { $0.name == "after" })?.value.flatMap(Int.init)
            let limit = components.queryItems?.first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 100
            let includeDetails = components.queryItems?.first(where: { $0.name == "details" })?.value == "1"
            let itemIDValue = components.queryItems?.first(where: { $0.name == "item_id" })?.value
            if itemIDValue != nil, itemIDValue.flatMap(UUID.init) == nil {
                sendError(.init(code: "invalid_transcript_item", message: "A valid item_id is required."), status: 400, on: connection)
                return
            }
            let paging: RemoteTranscriptPageRequest
            if let itemID = itemIDValue.flatMap(UUID.init) {
                paging = .exactItem(itemID)
            } else if components.queryItems?.first(where: { $0.name == "order" })?.value == "recent" {
                let beforeValue = components.queryItems?.first(where: { $0.name == "before" })?.value
                do {
                    paging = try .recentBackward(before: beforeValue.map(RemoteTranscriptCursorCodec.decode))
                } catch {
                    sendError(
                        .init(code: "invalid_transcript_cursor", message: "The transcript cursor is invalid."),
                        status: 400,
                        on: connection
                    )
                    return
                }
            } else {
                paging = .legacyForward(afterSequenceIndex: after)
            }
            guard let readService = makeReadService() else {
                sendError(.init(code: "unavailable", message: "Remote read services are not ready.", retryable: true), status: 503, on: connection)
                return
            }
            do {
                let page = try await readService.transcript(
                    sessionID: sessionID,
                    paging: paging,
                    limit: limit,
                    includeDetails: includeDetails
                )
                await sendJSON(
                    RemoteTranscriptPage(
                        sessionID: page.sessionID,
                        items: page.items,
                        nextSequenceIndex: page.nextSequenceIndex,
                        hasMore: page.hasMore,
                        eventCursor: replayBuffer.latestCursor(),
                        pagingMode: page.pagingMode,
                        olderCursor: page.olderCursor,
                        hasOlder: page.hasOlder,
                        transcriptRevision: page.transcriptRevision,
                        transcriptRevisionEpoch: transcriptRevisionEpoch
                    ),
                    status: 200,
                    on: connection
                )
            } catch let error as RemoteReadServiceError {
                switch error {
                case .sessionNotFound:
                    sendError(.init(code: "session_not_found", message: error.localizedDescription), status: 404, on: connection)
                case .transcriptItemNotFound:
                    sendError(
                        .init(code: "transcript_item_not_found", message: error.localizedDescription, retryable: true),
                        status: 404,
                        on: connection
                    )
                case .invalidCursor:
                    sendError(.init(code: "invalid_transcript_cursor", message: error.localizedDescription), status: 400, on: connection)
                }
            } catch {
                sendError(.init(code: "transcript_failed", message: "The transcript could not be loaded.", retryable: true), status: 500, on: connection)
            }

        case ("GET", RemoteProtocol.eventsPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            let cursor = components.queryItems?.first(where: { $0.name == "after" }).flatMap(\.value).flatMap(UInt64.init)
            switch await replayBuffer.replay(after: cursor, desktopInstanceID: pairingManager.desktopInstanceID) {
            case let .events(events):
                let body = events.map { event in
                    let data = (try? JSONEncoder().encode(event)) ?? Data()
                    return "id: \(event.sequence)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
                }.joined()
                sendSSE(body.isEmpty ? ": connected\n\n" : body, on: connection)
            case .snapshotRequired:
                sendError(
                    .init(code: "snapshot_required", message: "The event cursor is no longer retained.", retryable: true),
                    status: 409,
                    on: connection
                )
            }

        case ("POST", RemoteProtocol.commandsPath), ("POST", RemoteProtocol.contextBuilderPath):
            guard pairingManager.isAuthorized(request.headers["authorization"]) else {
                sendError(.init(code: "unauthorized", message: "A valid paired-device credential is required."), status: 401, on: connection)
                return
            }
            guard let command = try? JSONDecoder().decode(RemoteCommandRequest.self, from: request.body) else {
                sendError(.init(code: "invalid_command", message: "Invalid remote command request."), status: 400, on: connection)
                return
            }
            if components.path == RemoteProtocol.contextBuilderPath,
               command.operation != .contextBuilder
            {
                sendError(.init(code: "invalid_context_builder_command", message: "The context-builder endpoint accepts only context_builder commands."), status: 400, on: connection)
                return
            }
            if command.operation == .registerNotifications {
                guard let registration = command.notificationRegistration else {
                    sendError(.init(code: "invalid_notification_registration", message: "A notification registration is required."), status: 400, on: connection)
                    return
                }
                do {
                    try pairingManager.registerNotifications(registration)
                    await sendJSON(
                        RemoteCommandResponse(
                            commandID: command.commandID,
                            accepted: true,
                            message: "Notification registration saved.",
                            eventCursor: replayBuffer.latestCursor()
                        ),
                        status: 200,
                        on: connection
                    )
                } catch {
                    sendError(.init(code: "notification_registration_failed", message: "Notification registration could not be saved."), status: 409, on: connection)
                }
                return
            }
            let requiredAuthority = Self.requiredAuthority(for: command.operation)
            guard authorizationState.allows(requiredAuthority) else {
                sendError(
                    .init(code: "forbidden", message: "The paired device does not have sufficient authority for this command."),
                    status: 403,
                    on: connection
                )
                return
            }
            guard let controlService else {
                sendError(.init(code: "unavailable", message: "Remote control services are not ready.", retryable: true), status: 503, on: connection)
                return
            }
            do {
                let response = try await controlService.execute(command)
                let responseWithCursor = await Self.attachingEventCursor(
                    to: response,
                    eventCursor: replayBuffer.latestCursor()
                )
                sendJSON(responseWithCursor, status: 200, on: connection)
            } catch let error as RemoteAgentControlServiceError {
                sendError(.init(code: "command_rejected", message: error.localizedDescription), status: 409, on: connection)
            } catch {
                sendError(.init(code: "command_failed", message: "The remote command could not be completed."), status: 500, on: connection)
            }

        default:
            sendError(.init(code: "not_found", message: "Remote endpoint not found."), status: 404, on: connection)
        }
    }

    static func attachingEventCursor(
        to response: RemoteCommandResponse,
        eventCursor: UInt64
    ) -> RemoteCommandResponse {
        RemoteCommandResponse(
            protocolVersion: response.protocolVersion,
            commandID: response.commandID,
            accepted: response.accepted,
            workspaceID: response.workspaceID,
            sessionID: response.sessionID,
            runState: response.runState,
            message: response.message,
            eventCursor: eventCursor,
            contextBuilderResult: response.contextBuilderResult,
            resolvedSelection: response.resolvedSelection,
            resolvedToolCatalog: response.resolvedToolCatalog
        )
    }

    private static func requiredAuthority(for operation: RemoteCommandOperation) -> RemoteAuthorityLevel {
        switch operation {
        case .respond:
            .respond
        case .startRun, .configureSession, .configureTools, .followUp, .steer, .cancel, .resume, .contextBuilder:
            .control
        case .registerNotifications:
            .observe
        }
    }

    private func makeReadService() -> WindowRemoteReadService? {
        guard let windowStatesManager else { return nil }
        let contexts = windowStatesManager.allWindows
            .filter { !$0.isClosing }
            .map { (agentMode: $0.agentModeViewModel, workspaceManager: $0.workspaceManager) }
        return WindowRemoteReadService(
            contexts: contexts,
            revisionTracker: transcriptRevisionTracker
        )
    }

    private var desktopSummary: RemoteDesktopSummary {
        RemoteDesktopSummary(
            instanceID: pairingManager.desktopInstanceID,
            displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "RepoPrompt CE",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            isAvailable: true,
            lastSeenAt: Date()
        )
    }

    private func snapshot() async -> RemoteSnapshot {
        lastSnapshotAt = Date()
        let authorization = authorizationState
        guard let window = windowStatesManager?.allWindows.first else {
            let snapshot = await RemoteSnapshot(
                desktop: desktopSummary,
                connection: .init(state: .connected, transport: "lan_https"),
                authorization: authorization,
                eventCursor: replayBuffer.latestCursor(),
                transcriptRevisionEpoch: transcriptRevisionEpoch
            )
            availabilityController.update(snapshot: snapshot)
            return snapshot
        }
        let windows = windowStatesManager?.allWindows ?? [window]
        let contexts = windows.map {
            (agentMode: $0.agentModeViewModel, workspaceManager: $0.workspaceManager)
        }
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: WorkspaceManagerRemoteCatalogService(
                managers: windows.map(\.workspaceManager)
            ),
            sessionQuery: AgentModeRemoteSessionQueryService(
                contexts: contexts,
                revisionTracker: transcriptRevisionTracker
            ),
            workflowCatalog: DesktopRemoteCatalogService(agentModes: contexts.map(\.agentMode))
        )
        let snapshot = await builder.build(
            desktop: desktopSummary,
            connection: .init(state: .connected, transport: "lan_https", lastConnectedAt: Date()),
            authorization: authorization,
            eventCursor: replayBuffer.latestCursor(),
            transcriptRevisionEpoch: transcriptRevisionEpoch
        )
        availabilityController.update(snapshot: snapshot)
        return snapshot
    }

    private func sendJSON(_ value: some Encodable, status: Int, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(value) else {
            sendError(.init(code: "encoding_failed", message: "The response could not be encoded."), status: 500, on: connection)
            return
        }
        send(
            status: status,
            contentType: "application/json; charset=utf-8",
            body: data,
            on: connection
        )
    }

    private func sendSSE(_ body: String, on connection: NWConnection) {
        send(
            status: 200,
            contentType: "text/event-stream; charset=utf-8",
            body: Data(body.utf8),
            on: connection
        )
    }

    private func sendError(_ error: RemoteErrorResponse, status: Int, on connection: NWConnection) {
        sendJSON(error, status: status, on: connection)
    }

    private func send(status: Int, contentType: String, body: Data, on connection: NWConnection) {
        if (200 ..< 300).contains(status) {
            lastSuccessfulRequestAt = Date()
        }
        let reason = Self.reasonPhrase(for: status)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Internal Server Error"
        }
    }

    private static func certificate(from identity: SecIdentity) throws -> SecCertificate? {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess else { throw RemoteGatewaySecurityError.certificateUnavailable }
        return certificate
    }

    private static func privateKey(from identity: SecIdentity) throws -> SecKey? {
        var key: SecKey?
        let status = SecIdentityCopyPrivateKey(identity, &key)
        guard status == errSecSuccess else { throw RemoteGatewaySecurityError.certificateUnavailable }
        return key
    }
}

enum RemoteGatewayError: LocalizedError {
    case configurationUnavailable
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: "Remote gateway configuration is unavailable."
        case .listenerUnavailable: "The Remote gateway listener could not start."
        }
    }
}
