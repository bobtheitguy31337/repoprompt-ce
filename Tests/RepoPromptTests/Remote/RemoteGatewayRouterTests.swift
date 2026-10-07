import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptRemoteProtocol
import XCTest

@MainActor
final class RemoteGatewayRouterTests: XCTestCase {
    func testProtectedRequestsRequireAuthorizationBeforeRoutingForEveryTransportContext() async throws {
        var snapshotCalls = 0
        let router = makeRouter(
            authorize: { _ in false },
            snapshot: {
                snapshotCalls += 1
                return nil
            }
        )

        for context in [
            RemoteGatewayRequestContext.legacyHTTPS(authorizationHeader: nil),
            RemoteGatewayRequestContext(
                transport: .authenticatedPeer(endpointID: "peer-1", deviceID: "device-1"),
                authorizationHeader: "Bearer invalid"
            )
        ] {
            let response = await router.route(.snapshot, context: context)
            XCTAssertEqual(response.status, 401)
            XCTAssertEqual(try error(from: response).code, "unauthorized")
        }
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testUnpairReportsDurableRevocationFailure() async throws {
        let router = makeRouter(unpair: { .failed })

        let response = await router.route(
            .unpair,
            context: .legacyHTTPS(authorizationHeader: "Bearer credential")
        )

        XCTAssertEqual(response.status, 500)
        let responseError = try error(from: response)
        XCTAssertEqual(responseError.code, "revocation_failed")
        XCTAssertTrue(responseError.retryable)
    }

    func testUnpairReturnsAcknowledgementOnlyAfterSuccessfulRevocation() async throws {
        var revocationCalls = 0
        let router = makeRouter(unpair: {
            revocationCalls += 1
            return .success
        })

        let response = await router.route(
            .unpair,
            context: .init(
                transport: .authenticatedPeer(endpointID: "peer", deviceID: "device"),
                authorizationHeader: "Bearer credential"
            )
        )
        let acknowledgement = try JSONDecoder().decode(
            RemoteUnpairResponse.self,
            from: json(from: response)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(acknowledgement.unpaired)
        XCTAssertEqual(revocationCalls, 1)
    }

    func testPairingBypassesEstablishedCredentialAuthorization() async throws {
        let pairingRequest = RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: "secret",
            deviceName: "Phone"
        )
        let desktop = RemoteDesktopSummary(
            instanceID: "desktop",
            displayName: "RepoPrompt CE",
            appVersion: "test",
            isAvailable: true,
            lastSeenAt: Date(timeIntervalSince1970: 1)
        )
        let expected = RemotePairingResponse(
            desktop: desktop,
            deviceID: "device",
            credential: "credential"
        )
        let router = makeRouter(
            authorize: { _ in false },
            pair: { request in
                XCTAssertEqual(request, pairingRequest)
                return .success(expected)
            }
        )

        let response = await router.route(
            .pair(pairingRequest),
            context: .legacyHTTPS(authorizationHeader: nil)
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(RemotePairingResponse.self, from: json(from: response)), expected)
    }

    func testCommandResponsePreservesResolvedFieldsAndAddsCurrentEventCursor() async throws {
        let command = RemoteCommandRequest(operation: .startRun)
        let selection = RemoteAgentSelection(
            agentID: "codex",
            modelID: "gpt-test",
            reasoningEffort: "high"
        )
        let catalog = RemoteToolCatalog(
            providerID: "codex",
            revision: 7,
            settings: [
                RemoteToolSettingDescriptor(
                    id: "web",
                    displayName: "Web",
                    category: "network",
                    isEnabled: true
                )
            ],
            isMutable: true
        )
        let contextBuilderResult = RemoteContextBuilderResult(
            tabID: "tab",
            status: "complete",
            prompt: "prompt",
            fileCount: 2,
            totalTokens: 100
        )
        let serviceResponse = RemoteCommandResponse(
            commandID: command.commandID,
            accepted: true,
            message: "accepted",
            eventCursor: 3,
            contextBuilderResult: contextBuilderResult,
            resolvedSelection: selection,
            resolvedToolCatalog: catalog
        )
        let router = makeRouter(
            authorizationState: { RemoteAuthorizationState(defaultLevel: .control) },
            execute: { request in
                XCTAssertEqual(request, command)
                return .success(serviceResponse)
            },
            eventCursor: { 42 }
        )

        let response = await router.route(
            .command(command, endpoint: .commands),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        let decoded = try JSONDecoder().decode(RemoteCommandResponse.self, from: json(from: response))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(decoded.eventCursor, 42)
        XCTAssertEqual(decoded.contextBuilderResult, contextBuilderResult)
        XCTAssertEqual(decoded.resolvedSelection, selection)
        XCTAssertEqual(decoded.resolvedToolCatalog, catalog)
    }

    func testCommandAuthorityMatrixMatchesLegacyPolicy() {
        let expected: [(RemoteCommandOperation, RemoteAuthorityLevel)] = [
            (.respond, .respond),
            (.startRun, .control),
            (.configureSession, .control),
            (.configureTools, .control),
            (.followUp, .control),
            (.steer, .control),
            (.cancel, .control),
            (.resume, .control),
            (.contextBuilder, .control),
            (.registerNotifications, .observe)
        ]

        for (operation, authority) in expected {
            XCTAssertEqual(RemoteGatewayRequestRouter.requiredAuthority(for: operation), authority)
        }
    }

    func testNotificationRegistrationRetainsObserveLevelBehaviorAndCursor() async throws {
        let registration = RemoteNotificationRegistration(platform: .apns, deviceToken: "token")
        let command = RemoteCommandRequest(
            operation: .registerNotifications,
            notificationRegistration: registration
        )
        var registered: RemoteNotificationRegistration?
        var executeCalls = 0
        let router = makeRouter(
            authorizationState: { RemoteAuthorizationState(defaultLevel: .observe) },
            registerNotifications: { value in
                registered = value
                return .success
            },
            execute: { _ in
                executeCalls += 1
                return .failed
            },
            eventCursor: { 55 }
        )

        let response = await router.route(
            .command(command, endpoint: .commands),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        let decoded = try JSONDecoder().decode(RemoteCommandResponse.self, from: json(from: response))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(registered, registration)
        XCTAssertEqual(decoded.eventCursor, 55)
        XCTAssertEqual(decoded.message, "Notification registration saved.")
        XCTAssertEqual(executeCalls, 0)
    }

    func testContextBuilderEndpointRejectsOtherOperationsBeforeExecution() async throws {
        var executeCalls = 0
        let router = makeRouter(execute: { _ in
            executeCalls += 1
            return .failed
        })

        let response = await router.route(
            .command(RemoteCommandRequest(operation: .cancel), endpoint: .contextBuilder),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try error(from: response).code, "invalid_context_builder_command")
        XCTAssertEqual(executeCalls, 0)
    }

    func testIrohTranscriptInitialPageDefaultsToRecentAndExplicitLegacyRemainsAvailable() {
        let sessionID = UUID()
        XCTAssertEqual(
            RemoteIrohGatewayAdapter.transcriptPaging(for: .init(sessionID: sessionID)),
            .recentBackward(before: nil)
        )
        XCTAssertEqual(
            RemoteIrohGatewayAdapter.transcriptPaging(for: .init(
                sessionID: sessionID,
                afterSequenceIndex: nil,
                pagingMode: .legacyForward
            )),
            .legacyForward(afterSequenceIndex: nil)
        )
        XCTAssertEqual(
            RemoteIrohGatewayAdapter.transcriptPaging(for: .init(
                sessionID: sessionID,
                pagingMode: .recentBackward
            )),
            .recentBackward(before: nil)
        )
    }

    func testIrohEndpointBindingIsRejectedOutsidePinnedLegacyHTTPS() async throws {
        var bindingCalls = 0
        let router = makeRouter(bindIrohEndpoint: { _, _ in
            bindingCalls += 1
            return .failure(TestFailure.unexpectedResponse)
        })
        let request = RemoteIrohBindingRequest(
            desktopInstanceID: "desktop",
            deviceID: "device",
            expectedServerEndpointID: String(repeating: "a", count: 64),
            clientEndpointID: String(repeating: "b", count: 64)
        )
        let response = await router.route(
            .bindIrohEndpoint(request),
            context: .init(
                transport: .authenticatedPeer(
                    endpointID: String(repeating: "b", count: 64),
                    deviceID: "device"
                ),
                authorizationHeader: "Bearer valid"
            )
        )

        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(try error(from: response).code, "endpoint_binding_requires_legacy_https")
        XCTAssertEqual(bindingCalls, 0)
    }

    func testEventsRemainTypedUntilTheLegacyAdapterSerializesSSE() async throws {
        let event = RemoteEvent(
            desktopInstanceID: "desktop",
            sequence: 9,
            type: .sessionUpdated
        )
        let replayRouter = makeRouter(replay: { cursor in
            XCTAssertEqual(cursor, 8)
            return .events([event])
        })

        let response = await replayRouter.route(
            .events(after: 8),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(response.status, 200)
        guard case let .events(events) = response.content else {
            return XCTFail("Expected typed events")
        }
        XCTAssertEqual(events, [event])

        let staleRouter = makeRouter(replay: { _ in .snapshotRequired })
        let staleResponse = await staleRouter.route(
            .events(after: 1),
            context: .legacyHTTPS(authorizationHeader: "Bearer valid")
        )
        XCTAssertEqual(staleResponse.status, 409)
        XCTAssertEqual(try error(from: staleResponse).code, "snapshot_required")
    }

    func testLegacyDecoderPreservesRouteAndTranscriptQuerySemantics() {
        let sessionID = UUID()
        let request = RemoteLegacyHTTPRequest(
            method: "GET",
            target: "\(RemoteProtocol.transcriptPath)?session_id=\(sessionID.uuidString)&after=12&limit=33&details=1",
            headers: ["authorization": "Bearer token"],
            body: Data()
        )

        guard case let .request(.transcript(transcript)) = RemoteLegacyHTTPRequestDecoder.decode(request) else {
            return XCTFail("Expected a transcript router request")
        }
        XCTAssertEqual(transcript.sessionID, sessionID)
        XCTAssertEqual(transcript.paging, .legacyForward(afterSequenceIndex: 12))
        XCTAssertEqual(transcript.limit, 33)
        XCTAssertTrue(transcript.includeDetails)
    }

    func testLegacyDecoderPreservesValidationErrorsAndRouteTable() throws {
        let invalidTranscript = RemoteLegacyHTTPRequest(
            method: "GET",
            target: "\(RemoteProtocol.transcriptPath)?session_id=invalid",
            headers: [:],
            body: Data()
        )
        guard case let .response(response) = RemoteLegacyHTTPRequestDecoder.decode(invalidTranscript) else {
            return XCTFail("Expected an immediate validation response")
        }
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try error(from: response).code, "invalid_session")

        let routes: [(String, String, String)] = [
            ("POST", RemoteProtocol.unpairPath, "unpair"),
            ("GET", RemoteProtocol.snapshotPath, "snapshot"),
            ("GET", RemoteProtocol.diagnosticsPath, "diagnostics"),
            ("GET", RemoteProtocol.workspacesPath, "workspaces"),
            ("GET", RemoteProtocol.sessionsPath, "sessions"),
            ("GET", RemoteProtocol.agentsPath, "agents"),
            ("GET", RemoteProtocol.workflowsPath, "workflows"),
            ("GET", RemoteProtocol.historyPath, "history"),
            ("GET", RemoteProtocol.eventsPath, "events")
        ]
        for (method, path, expected) in routes {
            let request = RemoteLegacyHTTPRequest(method: method, target: path, headers: [:], body: Data())
            guard case let .request(route) = RemoteLegacyHTTPRequestDecoder.decode(request) else {
                XCTFail("Expected route for \(method) \(path)")
                continue
            }
            XCTAssertEqual(routeName(route), expected)
        }
    }

    func testLegacyParserRetainsBoundedBodyAndHeaderBehavior() {
        var buffer = Data("POST /remote/v1/commands HTTP/1.1\r\nAuthorization: Bearer token\r\nContent-Length: 4\r\n\r\ntesttrailing".utf8)
        let request = RemoteLegacyHTTPParser.nextRequest(from: &buffer)

        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.target, "/remote/v1/commands")
        XCTAssertEqual(request?.headers["authorization"], "Bearer token")
        XCTAssertEqual(request?.body, Data("test".utf8))
        XCTAssertEqual(buffer, Data("trailing".utf8))

        var oversized = Data("POST / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8)
        XCTAssertNil(RemoteLegacyHTTPParser.nextRequest(from: &oversized))
        XCTAssertTrue(oversized.isEmpty)
    }

    func testLegacyResponseEncoderPreservesHTTPAndShortSSEWireBehavior() {
        let event = RemoteEvent(
            desktopInstanceID: "desktop",
            sequence: 11,
            type: .sessionUpdated
        )
        let encodedEvent = RemoteLegacyHTTPResponseEncoder.encode(
            RemoteGatewayResponse(status: 200, content: .events([event]))
        )
        let eventText = String(decoding: encodedEvent.data, as: UTF8.self)
        XCTAssertTrue(eventText.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(eventText.contains("Content-Type: text/event-stream; charset=utf-8\r\n"))
        XCTAssertTrue(eventText.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(eventText.contains("id: 11\ndata: "))

        let connected = RemoteLegacyHTTPResponseEncoder.encode(
            RemoteGatewayResponse(status: 200, content: .events([]))
        )
        XCTAssertTrue(String(decoding: connected.data, as: UTF8.self).hasSuffix(": connected\n\n"))

        let error = RemoteLegacyHTTPResponseEncoder.encode(.error(
            .init(code: "snapshot_required", message: "Refresh.", retryable: true),
            status: 409
        ))
        let errorText = String(decoding: error.data, as: UTF8.self)
        XCTAssertTrue(errorText.hasPrefix("HTTP/1.1 409 Conflict\r\n"))
        XCTAssertTrue(errorText.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(errorText.contains("\"code\":\"snapshot_required\""))
    }

    func testLegacyAdapterRetainsOneMegabyteInboundBound() {
        XCTAssertEqual(RemoteLegacyHTTPSGatewayAdapter.maximumBufferedRequestBytes, 1_048_576)
    }

    private func makeRouter(
        authorize: @escaping (RemoteGatewayRequestContext) -> Bool = { _ in true },
        pair: @escaping (RemotePairingRequest) -> RemoteGatewayPairingResult = { _ in .failed },
        unpair: @escaping () -> RemoteGatewayRevocationResult = { .success },
        snapshot: @escaping () async -> RemoteSnapshot? = { nil },
        replay: @escaping (UInt64?) async -> RemoteEventReplayResult = { _ in .events([]) },
        authorizationState: @escaping () -> RemoteAuthorizationState = {
            RemoteAuthorizationState(defaultLevel: .control)
        },
        registerNotifications: @escaping (RemoteNotificationRegistration) -> RemoteGatewayRegistrationResult = { _ in .failed },
        execute: @escaping (RemoteCommandRequest) async -> RemoteGatewayCommandResult = { _ in .unavailable },
        eventCursor: @escaping () async -> UInt64 = { 0 },
        bindIrohEndpoint: @escaping (RemoteIrohBindingRequest, String?) -> Result<RemoteIrohBindingResponse, Error> = { _, _ in
            .failure(TestFailure.unexpectedResponse)
        }
    ) -> RemoteGatewayRequestRouter {
        RemoteGatewayRequestRouter(services: RemoteGatewayRoutingServices(
            authorize: authorize,
            pair: pair,
            unpair: unpair,
            snapshot: snapshot,
            diagnostics: { nil },
            history: { _, _ in nil },
            transcript: { _ in .unavailable },
            replay: replay,
            registerNotifications: registerNotifications,
            authorizationState: authorizationState,
            execute: execute,
            eventCursor: eventCursor,
            bindIrohEndpoint: bindIrohEndpoint
        ))
    }

    private func json(from response: RemoteGatewayResponse) throws -> Data {
        guard case let .json(data) = response.content else {
            throw TestFailure.unexpectedResponse
        }
        return data
    }

    private func error(from response: RemoteGatewayResponse) throws -> RemoteErrorResponse {
        guard case let .error(error) = response.content else {
            throw TestFailure.unexpectedResponse
        }
        return error
    }

    private func routeName(_ request: RemoteGatewayRequest) -> String {
        switch request {
        case .pair: "pair"
        case .pairIroh: "pair_iroh"
        case .transportBootstrap: "transport_bootstrap"
        case .bindIrohEndpoint: "bind_iroh_endpoint"
        case .unpair: "unpair"
        case .snapshot: "snapshot"
        case .diagnostics: "diagnostics"
        case .workspaces: "workspaces"
        case .sessions: "sessions"
        case .agents: "agents"
        case .workflows: "workflows"
        case .history: "history"
        case .transcript: "transcript"
        case .events: "events"
        case .command: "command"
        }
    }
}

private enum TestFailure: Error {
    case unexpectedResponse
}

@MainActor
final class RemoteIrohSecurityTests: XCTestCase {
    private final class TestClock {
        var date: Date

        init(_ date: Date) {
            self.date = date
        }
    }

    private enum PersistenceFailure: Error {
        case failed
    }

    func testIssuedLegacyAndIrohAdvertisementsShareExpiringSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let manager = makeManager(clock: clock)
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: "192.0.2.1",
            server: RemoteIrohEndpointAddress(endpointID: endpointID("a"))
        )

        XCTAssertEqual(issued.legacy.oneTimeSecret, issued.iroh.oneTimeSecret)
        XCTAssertEqual(issued.legacy.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(issued.iroh.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(issued.iroh.legacyFallback, issued.legacy)
        XCTAssertEqual(Data(base64URL: issued.legacy.oneTimeSecret)?.count, 32)
    }

    func testPairingSecretExpiresAndIsSingleUse() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2000))
        var persisted: [RemoteStoredDeviceCredential?] = []
        let manager = makeManager(clock: clock) { persisted.append($0) }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        clock.date = try XCTUnwrap(advertisement.expiresAt?.addingTimeInterval(1))

        XCTAssertThrowsError(try manager.pair(
            request: pairingRequest(secret: advertisement.oneTimeSecret),
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.pairingSecretExpired = error else {
                return XCTFail("Expected pairingSecretExpired, got \(error)")
            }
        }
        XCTAssertTrue(persisted.isEmpty)

        XCTAssertThrowsError(try manager.pair(
            request: pairingRequest(secret: advertisement.oneTimeSecret),
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.pairingSecretInvalid = error else {
                return XCTFail("Expected pairingSecretInvalid, got \(error)")
            }
        }
    }

    func testPairingReplayFailsEvenWhenCredentialPersistenceFails() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3000))
        let manager = makeManager(clock: clock) { _ in throw PersistenceFailure.failed }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        let request = pairingRequest(secret: advertisement.oneTimeSecret)

        XCTAssertThrowsError(try manager.pair(request: request, desktop: desktopSummary())) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertThrowsError(try manager.pair(request: request, desktop: desktopSummary())) { error in
            guard case RemoteGatewaySecurityError.pairingSecretInvalid = error else {
                return XCTFail("Expected consumed secret rejection, got \(error)")
            }
        }
    }

    func testFreshValidIrohPairingReplacesStaleOneDeviceRecord() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3500))
        let stale = RemoteStoredDeviceCredential(
            deviceID: "stale-device",
            credential: "stale-credential",
            expiresAt: clock.date.addingTimeInterval(3600),
            deviceName: "Old phone",
            irohPeerEndpointID: endpointID("b")
        )
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock, storedDevice: stale) { persisted = $0 }
        let serverID = endpointID("a")
        let replacementClientID = endpointID("c")
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil,
            server: RemoteIrohEndpointAddress(endpointID: serverID)
        )

        let response = try manager.pairIroh(
            request: RemoteIrohPairingRequest(
                desktopInstanceID: "desktop",
                expectedServerEndpointID: serverID,
                clientEndpointID: replacementClientID,
                oneTimeSecret: issued.iroh.oneTimeSecret,
                deviceName: "Replacement phone"
            ),
            authenticatedPeerEndpointID: replacementClientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )

        XCTAssertNotEqual(response.pairingResponse.deviceID, stale.deviceID)
        XCTAssertEqual(persisted?.deviceID, response.pairingResponse.deviceID)
        XCTAssertEqual(persisted?.irohPeerEndpointID, replacementClientID)
        XCTAssertFalse(manager.isAuthorized("Bearer \(stale.credential)"))
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: replacementClientID
        ))
    }

    func testIrohPairingAuthenticatesBothEndpointBindingsBeforeConsumingSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4000))
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock) { persisted = $0 }
        let serverID = endpointID("a")
        let clientID = endpointID("b")
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil,
            server: RemoteIrohEndpointAddress(endpointID: serverID)
        )
        let request = RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: serverID,
            clientEndpointID: clientID,
            oneTimeSecret: issued.iroh.oneTimeSecret,
            deviceName: "Phone"
        )

        XCTAssertThrowsError(try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: endpointID("c"),
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.endpointBindingInvalid = error else {
                return XCTFail("Expected endpointBindingInvalid, got \(error)")
            }
        }

        let response = try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: clientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )
        XCTAssertEqual(response.serverEndpointID, serverID)
        XCTAssertEqual(response.clientEndpointID, clientID)
        XCTAssertEqual(persisted?.irohPeerEndpointID, clientID)
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: clientID
        ))

        XCTAssertThrowsError(try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: clientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        ))
    }

    func testAuthenticatedHTTPSBindingUpdatesExistingCredentialWithoutReplacement() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5000))
        let original = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone"
        )
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock, storedDevice: original) { persisted = $0 }
        let serverID = endpointID("a")
        let firstClientID = endpointID("b")
        let request = RemoteIrohBindingRequest(
            desktopInstanceID: "desktop",
            deviceID: original.deviceID,
            expectedServerEndpointID: serverID,
            clientEndpointID: firstClientID
        )

        let response = try manager.bindIrohEndpoint(
            request: request,
            authorizationHeader: "Bearer bearer",
            serverEndpointID: serverID
        )
        XCTAssertEqual(response.deviceID, original.deviceID)
        XCTAssertEqual(persisted?.credential, original.credential)
        XCTAssertEqual(persisted?.irohPeerEndpointID, firstClientID)
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: firstClientID
        ))
        XCTAssertFalse(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: endpointID("c")
        ))

        let replacementClientID = endpointID("d")
        _ = try manager.bindIrohEndpoint(
            request: RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: original.deviceID,
                expectedServerEndpointID: serverID,
                clientEndpointID: replacementClientID
            ),
            authorizationHeader: "Bearer bearer",
            serverEndpointID: serverID
        )
        XCTAssertEqual(persisted?.irohPeerEndpointID, replacementClientID)
        XCTAssertFalse(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: firstClientID
        ))
    }

    func testBindingRejectsWrongBearerDeviceAndServer() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6000))
        let original = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone"
        )
        let manager = makeManager(clock: clock, storedDevice: original)
        let serverID = endpointID("a")

        for (request, bearer, actualServer) in [
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "device",
                expectedServerEndpointID: serverID,
                clientEndpointID: endpointID("b")
            ), "Bearer wrong", serverID),
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "other",
                expectedServerEndpointID: serverID,
                clientEndpointID: endpointID("b")
            ), "Bearer bearer", serverID),
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "device",
                expectedServerEndpointID: endpointID("c"),
                clientEndpointID: endpointID("b")
            ), "Bearer bearer", serverID)
        ] {
            XCTAssertThrowsError(try manager.bindIrohEndpoint(
                request: request,
                authorizationHeader: bearer,
                serverEndpointID: actualServer
            ))
        }
    }

    func testPersistedPairingFieldsAreBoundedAndEndpointIDsAreCanonical() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6500))
        var persisted: RemoteStoredDeviceCredential?
        let manager = makeManager(clock: clock) { persisted = $0 }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        let request = RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: advertisement.oneTimeSecret,
            deviceName: String(repeating: "📱", count: 512)
        )
        _ = try manager.pair(request: request, desktop: desktopSummary())
        XCTAssertEqual(persisted?.deviceName.count, RemotePairingManager.maximumDeviceNameCharacters)

        let boundManager = makeManager(clock: clock, storedDevice: persisted)
        XCTAssertThrowsError(try boundManager.bindIrohEndpoint(
            request: RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: persisted?.deviceID ?? "",
                expectedServerEndpointID: endpointID("a"),
                clientEndpointID: "not-an-endpoint"
            ),
            authorizationHeader: "Bearer \(persisted?.credential ?? "")",
            serverEndpointID: endpointID("a")
        )) { error in
            guard case RemoteGatewaySecurityError.endpointBindingInvalid = error else {
                return XCTFail("Expected endpointBindingInvalid, got \(error)")
            }
        }
    }

    func testStoredCredentialDecodesLegacyShapeAndOldDecoderIgnoresBinding() throws {
        let oldJSON = """
        {
          "deviceID": "device",
          "credential": "bearer",
          "expiresAt": 1000
        }
        """
        let decoded = try JSONDecoder().decode(
            RemoteStoredDeviceCredential.self,
            from: Data(oldJSON.utf8)
        )
        XCTAssertEqual(decoded.deviceName, "Remote device")
        XCTAssertNil(decoded.irohPeerEndpointID)

        let updated = RemoteStoredDeviceCredential(
            deviceID: decoded.deviceID,
            credential: decoded.credential,
            expiresAt: decoded.expiresAt,
            deviceName: decoded.deviceName,
            irohPeerEndpointID: endpointID("a")
        )
        struct LegacyCredential: Decodable {
            let deviceID: String
            let credential: String
            let expiresAt: Date
            let deviceName: String
        }
        let legacy = try JSONDecoder().decode(
            LegacyCredential.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertEqual(legacy.deviceID, updated.deviceID)
        XCTAssertEqual(legacy.credential, updated.credential)
        XCTAssertEqual(legacy.expiresAt, updated.expiresAt)
        XCTAssertEqual(legacy.deviceName, updated.deviceName)
    }

    func testFailedDurableRevocationRetainsPairedAuthorizationState() {
        let clock = TestClock(Date(timeIntervalSince1970: 7000))
        let stored = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone",
            irohPeerEndpointID: endpointID("a")
        )
        let manager = makeManager(clock: clock, storedDevice: stored) { _ in
            throw PersistenceFailure.failed
        }

        XCTAssertThrowsError(try manager.revokeDevice()) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertTrue(manager.isPaired)
        XCTAssertTrue(manager.isAuthorized("Bearer bearer"))
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: endpointID("a")
        ))
    }

    func testConstantTimeComparisonHandlesEqualDifferentAndDifferentLengthValues() {
        XCTAssertTrue(RemoteConstantTimeComparison.equals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([9, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([1, 2, 9]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([1, 2]), Data([1, 2, 0])))
    }

    func testDesktopIdentityStoreLoadsCreatesAndReplacesCorruptValues() throws {
        let stable = Data(repeating: 1, count: 32)
        var writes: [Data] = []
        let loaded = try RemoteIrohIdentityStore(
            read: { stable },
            write: { writes.append($0) },
            generate: { XCTFail("Should not generate")
                return Data()
            }
        ).loadOrCreate()
        XCTAssertEqual(loaded, RemoteIrohIdentity(secret: stable, origin: .loaded))
        XCTAssertTrue(writes.isEmpty)

        let createdSecret = Data(repeating: 2, count: 32)
        let created = try RemoteIrohIdentityStore(
            read: { nil },
            write: { writes.append($0) },
            generate: { createdSecret }
        ).loadOrCreate()
        XCTAssertEqual(created, RemoteIrohIdentity(secret: createdSecret, origin: .created))
        XCTAssertEqual(writes.last, createdSecret)

        let replacement = Data(repeating: 3, count: 32)
        let replaced = try RemoteIrohIdentityStore(
            read: { Data(repeating: 9, count: 31) },
            write: { writes.append($0) },
            generate: { replacement }
        ).loadOrCreate()
        XCTAssertEqual(replaced, RemoteIrohIdentity(secret: replacement, origin: .replacedCorruptValue))
        XCTAssertEqual(writes.last, replacement)
    }

    private func makeManager(
        clock: TestClock,
        storedDevice: RemoteStoredDeviceCredential? = nil,
        persist: @escaping (RemoteStoredDeviceCredential?) throws -> Void = { _ in }
    ) -> RemotePairingManager {
        RemotePairingManager(
            desktopInstanceID: "desktop",
            certificateSHA256: String(repeating: "f", count: 64),
            storedDevice: storedDevice,
            now: { clock.date },
            randomBytes: { count in Data(repeating: UInt8(count), count: count) },
            persistStoredDevice: persist
        )
    }

    private func pairingRequest(secret: String) -> RemotePairingRequest {
        RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: secret,
            deviceName: "Phone"
        )
    }

    private func desktopSummary() -> RemoteDesktopSummary {
        RemoteDesktopSummary(
            instanceID: "desktop",
            displayName: "Mac",
            appVersion: "test",
            isAvailable: true
        )
    }

    private func endpointID(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}

private extension Data {
    init?(base64URL: String) {
        var normalized = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

@MainActor
final class RemoteMutationBehaviorTests: XCTestCase {
    func testMCPInvalidParamsBecomeActionableRemoteRejection() {
        let message = WindowRemoteAgentControlService.remoteRejectionMessage(
            for: MCPError.invalidParams("The requested agent session is not currently available.")
        )

        XCTAssertEqual(message, "The requested agent session is not currently available.")
    }

    func testMCPInternalFailuresDoNotExposeInternalDetails() {
        let sensitive = "/private/sensitive/provider-state.json"
        let failures: [MCPError] = [
            .internalError(sensitive),
            .serverError(code: -32000, message: sensitive),
            .parseError(sensitive),
            .methodNotFound(sensitive)
        ]

        for failure in failures {
            let message = WindowRemoteAgentControlService.remoteRejectionMessage(for: failure)
            XCTAssertEqual(message, "The Mac could not deliver this command to the agent session.")
            XCTAssertFalse(message.contains(sensitive))
        }
    }

    func testMCPTransportFailureDoesNotExposeInternalDetails() {
        let message = WindowRemoteAgentControlService.remoteRejectionMessage(
            for: MCPError.transportError(NSError(
                domain: "fixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "/private/sensitive/socket failed"]
            ))
        )

        XCTAssertEqual(
            message,
            "The Mac lost its connection to the agent while delivering this command. Try again."
        )
        XCTAssertFalse(message.contains("/private/sensitive"))
    }

    func testRemoteMutationBoundaryRejectsIncompleteRequestsForEveryMutation() async {
        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)

        for operation in RemoteMutationFailurePolicy.mutationOperations {
            do {
                _ = try await service.execute(RemoteCommandRequest(operation: operation))
                XCTFail("Incomplete \(operation.rawValue) request must be rejected.")
            } catch let error as RemoteAgentControlServiceError {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            } catch {
                XCTFail("Expected a typed remote rejection for \(operation.rawValue), got \(error).")
            }
        }
    }

    func testCancelRejectsTerminalSessionWithoutChangingItsState() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        let sessionID = UUID()
        _ = agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .completed

        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id.uuidString)
        let request = RemoteCommandRequest(
            operation: .cancel,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)

        do {
            _ = try await service.execute(request)
            XCTFail("A terminal session must not accept cancellation.")
        } catch let error as RemoteAgentControlServiceError {
            guard case .commandRejected = error else {
                return XCTFail("Expected command rejection, got \(error).")
            }
        }
        XCTAssertEqual(session.runState, .completed)
    }

    func testConfigureSessionRejectsActiveRunWithoutChangingSelection() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        let sessionID = UUID()
        _ = agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        let originalAgent = session.selectedAgent
        let originalModel = session.selectedModelRaw

        do {
            _ = try await agentMode.mcpConfigureRemoteSession(
                tabID: tabID,
                sessionID: sessionID,
                agentRaw: nil,
                modelRaw: "unavailable-model",
                reasoningEffortRaw: nil
            )
            XCTFail("An active run must reject selection changes.")
        } catch let error as MCPError {
            XCTAssertEqual(
                WindowRemoteAgentControlService.remoteRejectionMessage(for: error),
                "Model and effort controls are locked during an active run."
            )
        }
        XCTAssertEqual(session.selectedAgent, originalAgent)
        XCTAssertEqual(session.selectedModelRaw, originalModel)
    }

    func testProvisionalSessionRollbackReportsCompleteCleanup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let target = try await window.agentModeViewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Remote rollback fixture"
        )

        let cleanupCompleted = await window.agentModeViewModel.mcpDiscardSessionTarget(target)

        XCTAssertEqual(cleanupCompleted, .complete)
        XCTAssertNil(window.agentModeViewModel.session(for: target.tabID, createIfNeeded: false))
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Remote mutation (UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "remoteMutationTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }
}
