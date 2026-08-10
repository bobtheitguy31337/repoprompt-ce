import Foundation
import Hummingbird
import HummingbirdTesting
import RepoPromptHeadlessRuntime
import RepoPromptServiceHTTP
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class AuthenticationAndHTTPTests: XCTestCase {
    func testSignedRequestRejectsNonceReplayAndRoleMismatch() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(keyID: "sync-v1", role: .goblinSync, direction: "goblin-sync-to-repoprompt-v1", secret: Data("secret".utf8))
        let auth = InternalRequestAuthenticator(keys: [key], store: store, now: { instant })
        let timestamp = String(instant.timeIntervalSince1970)
        let nonce = "abcdefghijklmnop"
        let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: "/internal/v1/events", timestamp: timestamp, nonce: nonce, bodyDigest: CanonicalSigning.bodyDigest(Data()), authorizationDecisionDigest: CanonicalSigning.bodyDigest(Data()), keyID: key.keyID)
        let request = SignedInternalRequest(method: "GET", pathAndQuery: "/internal/v1/events", timestamp: timestamp, nonce: nonce, body: Data(), authorizationDecisionData: nil, keyID: key.keyID, signature: CanonicalSigning.hmacSHA256(message: canonical, key: key.secret))
        _ = try await auth.verify(request, allowedRoles: [.goblinSync], operation: "events")
        do { _ = try await auth.verify(request, allowedRoles: [.goblinSync], operation: "events")
            XCTFail("expected replay rejection")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .internalAuthFailed) }
        try await store.close()
    }

    func testLoopbackHealthRoutesAreContentFree() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let auth = InternalRequestAuthenticator(keys: [], store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth)
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/live", method: .get) { response in XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
            try await client.execute(uri: "/health/ready", method: .get) { response in XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
        }
        try await store.close()
    }

    func testUnavailableCapabilityRoutesStillRequireAuthentication() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let auth = InternalRequestAuthenticator(keys: [], store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/internal/v1/catalog/providers", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        try await store.close()
    }
}
