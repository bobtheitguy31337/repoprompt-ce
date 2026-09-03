import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class ClientIntegrationHTTPTests: XCTestCase {
    func testPortalAssetsDoNotMentionOtherProducts() throws {
        let script = String(decoding: try RepoPromptPortalAssets.data(for: .script), as: UTF8.self)
        let html = String(decoding: try RepoPromptPortalAssets.data(for: .index), as: UTF8.self)
        XCTAssertTrue(script.contains("Connect an app to RepoPrompt."))
        XCTAssertTrue(script.contains("eventType.startsWith(\"session.\")"))
        XCTAssertTrue(script.contains("eventRefreshNeedsBootstrap"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("gabblin"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("gabblin"))
    }

    func testGenericAdminPathsIssueUnbrandedTokenAndAuthenticate() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            let cookie = try await Self.completeSetup(client: client)
            var mutation = Self.portalMutationHeaders()
            mutation[.cookie] = cookie

            var token = ""
            try await client.execute(
                uri: "/portal/api/v1/client-integrations",
                method: .post,
                headers: mutation
            ) { response in
                XCTAssertEqual(response.status, .created)
                token = try JSONDecoder.serviceDecoder.decode(
                    TokenDisclosure.self,
                    from: Data(response.body.readableBytesView)
                ).token
                XCTAssertTrue(token.hasPrefix("rp_client_v1."))
                XCTAssertFalse(token.contains("gabblin"))
            }

            try await client.execute(
                uri: "/portal/api/v1/client-integrations",
                method: .get,
                headers: mutation
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let body = String(decoding: Data(response.body.readableBytesView), as: UTF8.self)
                XCTAssertFalse(body.contains("gabblin"))
                let inventory = try JSONDecoder.serviceDecoder.decode(
                    Inventory.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(inventory.client.integration?.status, "active")
            }

            try await client.execute(
                uri: "/external/v1/bootstrap",
                method: .get,
                headers: try Self.externalHeaders(token: token, actorHeader: "X-RepoPrompt-Actor")
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }

            try await client.execute(
                uri: "/portal/api/v1/client-integrations/rotate",
                method: .post,
                headers: mutation
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }

            try await client.execute(
                uri: "/external/v1/bootstrap",
                method: .get,
                headers: try Self.externalHeaders(token: token, actorHeader: "X-RepoPrompt-Actor")
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testLegacyActorHeaderStillAuthenticates() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let issue = try await store.createClientIntegration()
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/external/v1/bootstrap",
                method: .get,
                headers: try Self.externalHeaders(token: issue.token, actorHeader: "X-RepoPrompt-Gabblin-Actor")
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testExternalBootstrapRejectsMissingActorHeader() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let issue = try await store.createClientIntegration()
        let service = try await Self.service(store: store)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(issue.token)"
            try await client.execute(
                uri: "/external/v1/bootstrap",
                method: .get,
                headers: headers
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
                let error = try JSONDecoder.serviceDecoder.decode(
                    ServiceAPIError.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(error.code, .internalAuthFailed)
                XCTAssertEqual(error.message, "Actor header is invalid")
                XCTAssertFalse(error.message.localizedCaseInsensitiveContains("gabblin"))
            }
        }
    }

    private static func service(store: SQLiteServiceStore) async throws -> RepoPromptHTTPService {
        RepoPromptHTTPService(
            authority: RepoPromptHeadlessAuthority(store: store),
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
    }

    private static func completeSetup(client: some TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/portal/api/v1/setup",
            method: .post,
            headers: portalMutationHeaders(),
            body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(SetupBody(
                password: "operator-password",
                passwordConfirmation: "operator-password"
            )))
        ) { response in
            XCTAssertEqual(response.status, .created)
        }
        var cookie = ""
        try await client.execute(
            uri: "/portal/api/v1/login",
            method: .post,
            headers: portalMutationHeaders(),
            body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(LoginBody(password: "operator-password")))
        ) { response in
            XCTAssertEqual(response.status, .ok)
            cookie = try XCTUnwrap(response.headers[.setCookie])
        }
        return String(cookie.split(separator: ";").first ?? Substring(cookie))
    }

    private static func portalMutationHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.init("Origin")!] = "https://localhost"
        headers[.init("Sec-Fetch-Site")!] = "same-origin"
        headers[.contentType] = "application/json"
        headers[.init("X-RepoPrompt-Portal-CSRF")!] = "1"
        return headers
    }

    private static func externalHeaders(token: String, actorHeader: String) throws -> HTTPFields {
        let envelope = ActorEnvelope(schemaVersion: 1, subject: "member_1", username: "ada", displayName: "Ada")
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[.init(actorHeader)!] = CanonicalSigning.base64URLEncode(try JSONEncoder.serviceEncoder.encode(envelope))
        return headers
    }

    private struct TokenDisclosure: Decodable {
        let token: String
    }

    private struct Inventory: Decodable {
        let client: ClientState
    }

    private struct ClientState: Decodable {
        let integration: IntegrationState?
    }

    private struct IntegrationState: Decodable {
        let status: String
    }

    private struct ActorEnvelope: Encodable {
        let schemaVersion: Int
        let subject: String
        let username: String
        let displayName: String
    }

    private struct SetupBody: Encodable {
        let password: String
        let passwordConfirmation: String
    }

    private struct LoginBody: Encodable {
        let password: String
    }
}
