import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RepoPromptHeadlessRuntime
import RepoPromptPortalProtocol
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class PortalOperatorOnboardingTests: XCTestCase {
    func testFirstRunSetupThenLoginIssuesSessionCookie() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal/", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let html = String(buffer: response.body)
                XCTAssertTrue(html.contains("auth-gate"))
            }
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/portal/api/v1/auth/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let status = try JSONDecoder.serviceDecoder.decode(AuthStatus.self, from: Data(response.body.readableBytesView))
                XCTAssertTrue(status.needsSetup)
                XCTAssertFalse(status.authenticated)
                XCTAssertTrue(status.passwordLoginEnabled)
            }
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password"
                )))
            ) { response in
                XCTAssertEqual(response.status, .created)
                XCTAssertTrue((response.headers[.setCookie] ?? "").contains("rpce_operator_session="))
            }
            var cookie = ""
            try await client.execute(
                uri: "/portal/api/v1/login",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(LoginBody(password: "operator-password")))
            ) { response in
                XCTAssertEqual(response.status, .ok)
                cookie = try XCTUnwrap(response.headers[.setCookie])
            }
            var headers = HTTPFields()
            headers[.cookie] = cookie.split(separator: ";").first.map(String.init)
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testSetupRejectsMismatchedPassword() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "different-password"
                )))
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testConfigurationBootsWithoutTLSFilesAndEnablesPasswordLogin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try RepoPromptServerConfiguration.environment([
            "REPOPROMPT_STATE_DB": directory.appendingPathComponent("repoprompt.sqlite").path,
            "REPOPROMPT_ENABLED_PROVIDERS": ""
        ])
        XCTAssertFalse(configuration.usesMutualTLS)
        XCTAssertTrue(configuration.certificatePath.hasSuffix("/trust/server.crt"))
        XCTAssertNil(configuration.clientCAPath)
        XCTAssertNil(configuration.portalPort)
    }

    func testMutualTLSKeepsPasswordLoginAndBindsHttpPortal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try RepoPromptServerConfiguration.environment([
            "REPOPROMPT_STATE_DB": directory.appendingPathComponent("repoprompt.sqlite").path,
            "REPOPROMPT_ENABLED_PROVIDERS": "",
            "REPOPROMPT_TLS_CERT_FILE": directory.appendingPathComponent("server.crt").path,
            "REPOPROMPT_TLS_KEY_FILE": directory.appendingPathComponent("server.key").path,
            "REPOPROMPT_TLS_CLIENT_CA_FILE": directory.appendingPathComponent("ca.crt").path,
            "REPOPROMPT_OPERATOR_CERT_IDENTITY": "operator.internal"
        ])
        XCTAssertTrue(configuration.usesMutualTLS)
        XCTAssertEqual(configuration.portalPort, 9081)
    }

    func testOperatorCertificateDoesNotSkipPasswordSetup() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = RepoPromptHTTPService(
            authority: RepoPromptHeadlessAuthority(store: store),
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: InternalHMACDirection.repoPromptToClient, secret: Data("response-secret-32-bytes-long!!".utf8)),
            certificateRoleResolver: CertificateIdentityRoleResolver(identities: ["repoprompt-operator": .operatorRole]),
            portalPeerCertificateDER: Data("not-used".utf8),
            portalPasswordLoginEnabled: true
        )
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal/api/v1/auth/status", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let status = try JSONDecoder.serviceDecoder.decode(AuthStatus.self, from: Data(response.body.readableBytesView))
                XCTAssertTrue(status.needsSetup)
                XCTAssertFalse(status.authenticated)
                XCTAssertTrue(status.passwordLoginEnabled)
            }
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password"
                )))
            ) { response in
                XCTAssertEqual(response.status, .created)
            }
        }
    }

    func testOperatorProjectLifecycleAndSessionArchiveUseSharedAuthority() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(
                keyID: "response",
                role: .sync,
                direction: InternalHMACDirection.repoPromptToClient,
                secret: Data("response-secret-32-bytes-long!!".utf8)
            ),
            portalPasswordLoginEnabled: true
        )
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            var cookie = ""
            try await client.execute(
                uri: "/portal/api/v1/setup",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                    password: "operator-password",
                    passwordConfirmation: "operator-password"
                )))
            ) { response in
                XCTAssertEqual(response.status, .created)
                cookie = try XCTUnwrap(response.headers[.setCookie])
            }
            var headers = Self.portalMutationHeaders()
            headers[.cookie] = cookie.split(separator: ";").first.map(String.init)

            let unavailableCreate = PortalCreateProjectRequest(
                operationID: UUID(),
                name: "Unavailable Clone",
                logicalName: "repo",
                source: .gitClone(
                    remote: "https://github.com/repoprompt/repoprompt-ce.git",
                    ref: "main"
                )
            )
            try await client.execute(
                uri: "/portal/api/v1/projects",
                method: .post,
                headers: headers,
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(unavailableCreate))
            ) { response in
                XCTAssertEqual(response.status, .unprocessableContent)
                let error = try JSONDecoder.serviceDecoder.decode(
                    ServiceAPIError.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(error.code, .capabilityMissing)
            }

            let actor = ExternalActor(
                userID: "operator:\(SQLiteServiceStore.defaultOperatorUsername)",
                username: SQLiteServiceStore.defaultOperatorUsername,
                displayName: "\(SQLiteServiceStore.defaultOperatorUsername) portal"
            )
            let project = try await authority.createProject(
                input: .init(name: "Original", roots: []),
                externalActor: actor,
                idempotencyKey: UUID().uuidString,
                requestDigest: CanonicalSigning.bodyDigest(Data("project".utf8))
            )
            let session = try await authority.createSession(
                input: .init(
                    projectID: project.projectID,
                    provider: .codex,
                    providerSettingsID: .codex,
                    model: "gpt-5.6-sol",
                    visibility: .privateSession,
                    startImmediately: false
                ),
                externalActor: actor,
                idempotencyKey: UUID().uuidString,
                requestDigest: CanonicalSigning.bodyDigest(Data("session".utf8))
            )

            let rename = PortalRenameProjectRequest(
                operationID: UUID(),
                expectedRevision: project.revision,
                name: "Renamed"
            )
            var renamed: PortalProjectSummary?
            try await client.execute(
                uri: "/portal/api/v1/projects/\(project.projectID.uuidString)",
                method: .patch,
                headers: headers,
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(rename))
            ) { response in
                XCTAssertEqual(response.status, .ok)
                renamed = try JSONDecoder.serviceDecoder.decode(
                    PortalProjectSummary.self,
                    from: Data(response.body.readableBytesView)
                )
            }
            XCTAssertEqual(renamed?.name, "Renamed")

            let archive = PortalSessionActionRequest(
                operationID: UUID(),
                expectedRevision: session.revision
            )
            try await client.execute(
                uri: "/portal/api/v1/sessions/\(session.sessionID.uuidString)/actions/archive",
                method: .post,
                headers: headers,
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(archive))
            ) { response in
                XCTAssertEqual(response.status, .accepted)
            }
            let archived = try await authority.sessionSnapshot(sessionID: session.sessionID)
            XCTAssertEqual(archived.state, .archived)

            let remove = PortalRemoveProjectRequest(
                operationID: UUID(),
                expectedRevision: try XCTUnwrap(renamed).revision
            )
            try await client.execute(
                uri: "/portal/api/v1/projects/\(project.projectID.uuidString)",
                method: .delete,
                headers: headers,
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(remove))
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
    }

    private static func service(store: SQLiteServiceStore) async throws -> RepoPromptHTTPService {
        let authority = RepoPromptHeadlessAuthority(store: store)
        return RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: InternalHMACDirection.repoPromptToClient, secret: Data("response-secret-32-bytes-long!!".utf8)),
            portalPasswordLoginEnabled: true
        )
    }

    private static func portalMutationHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.init("Origin")!] = "https://localhost"
        headers[.init("Sec-Fetch-Site")!] = "same-origin"
        headers[.contentType] = "application/json"
        headers[.init("X-RepoPrompt-Portal-CSRF")!] = "1"
        return headers
    }

    private struct AuthStatus: Decodable {
        let needsSetup: Bool
        let authenticated: Bool
        let passwordLoginEnabled: Bool
    }

    private struct SetupBody: Encodable {
        let password: String
        let passwordConfirmation: String
    }

    private struct LoginBody: Encodable {
        let password: String
    }
}
