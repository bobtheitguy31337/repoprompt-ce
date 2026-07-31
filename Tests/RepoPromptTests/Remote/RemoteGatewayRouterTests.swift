import Foundation
@testable import RepoPromptApp
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
