import Foundation
import Hummingbird
import HummingbirdTesting
import RepoPromptHeadlessRuntime
import RepoPromptServiceHTTP
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class AuthenticationAndHTTPTests: XCTestCase {
    func testConfigurationAcceptsOverlappingRoleKeysAndRejectsDuplicateIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func secret(_ name: String) throws -> String {
            let path = directory.appendingPathComponent(name).path
            try Data("secret-\(name)".utf8).write(to: URL(fileURLWithPath: path))
            return path
        }
        var environment = try [
            "REPOPROMPT_TLS_CERT_FILE": "/cert", "REPOPROMPT_TLS_KEY_FILE": "/key", "REPOPROMPT_TLS_CLIENT_CA_FILE": "/ca",
            "REPOPROMPT_GOBLIN_APP_HMAC_FILE": secret("app"), "REPOPROMPT_GOBLIN_SYNC_HMAC_FILE": secret("sync"),
            "REPOPROMPT_OPERATOR_HMAC_FILE": secret("operator"), "REPOPROMPT_EVENT_HMAC_FILE": secret("event"),
            "REPOPROMPT_GOBLIN_APP_PREVIOUS_KEY_ID": "app-v0", "REPOPROMPT_GOBLIN_APP_PREVIOUS_HMAC_FILE": secret("app-v0")
        ]
        let configuration = try RepoPromptServerConfiguration.environment(environment)
        XCTAssertEqual(configuration.signingKeys.count, 4)
        XCTAssertEqual(configuration.signingKeys.first(where: { $0.keyID == "app-v0" })?.active, false)
        XCTAssertEqual(configuration.signingKeys.first(where: { $0.keyID == "app-v0" })?.role, .goblinApp)

        environment["REPOPROMPT_GOBLIN_SYNC_PREVIOUS_KEY_ID"] = "app-v0"
        environment["REPOPROMPT_GOBLIN_SYNC_PREVIOUS_HMAC_FILE"] = try secret("sync-v0")
        XCTAssertThrowsError(try RepoPromptServerConfiguration.environment(environment))
    }

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

    func testReadinessFailsClosedForMissingVolumeAndCapacity() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")])
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let readiness = RepoPromptReadinessService(authority: authority, store: store, volumes: [.init(name: "missing", path: missing)], requiredProviders: [.codex], minimumFreeBytes: 0, minimumFreeNodes: 0, maximumActiveSessions: 0, cacheDuration: 0)
        let auth = InternalRequestAuthenticator(keys: [], store: store)
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth, readiness: readiness)
        let app = Application(router: service.healthRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/health/live", method: .get) { response in XCTAssertEqual(response.status, .ok) }
            try await client.execute(uri: "/health/ready", method: .get) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
        }
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertFalse(snapshot.ready)
        XCTAssertEqual(snapshot.providers.first { $0.kind == .codex }?.ready, true)
        XCTAssertEqual(snapshot.checks.first { $0.name == "volume:missing" }?.detail, "missing")
        XCTAssertEqual(snapshot.checks.first { $0.name == "session-capacity" }?.ready, false)
        try await store.close()
    }

    func testDegradedProjectIsDiagnosticWithoutFailingUnrelatedReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "degraded", roots: [.init(logicalName: "root", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project", requestDigest: "project")
        try FileManager.default.removeItem(at: root)
        let degraded = try await authority.refreshProject(projectID: project.projectID, expectedRevision: project.revision, actor: actor, idempotencyKey: "refresh", requestDigest: "refresh")
        XCTAssertEqual(degraded.state, .degraded)
        let readiness = RepoPromptReadinessService(authority: authority, store: store, minimumFreeBytes: 0, minimumFreeNodes: 0, maximumActiveSessions: 10, cacheDuration: 0)
        let snapshot = await readiness.snapshot(forceRefresh: true)
        XCTAssertTrue(snapshot.ready)
        XCTAssertEqual(snapshot.degradedProjectIDs, [project.projectID])
        try await store.close()
    }

    func testSSELastEventIDBelowReplayFloorReturnsControlFrame() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-sse", requestDigest: "project-sse")
        let metadata = try await store.metadata()
        _ = try await store.archiveEvents(through: 1)

        let instant = Date(timeIntervalSince1970: 1000)
        let key = InternalSigningKey(keyID: "sync-v1", role: .goblinSync, direction: "goblin-sync-to-repoprompt-v1", secret: Data("secret".utf8))
        let auth = InternalRequestAuthenticator(keys: [key], store: store, now: { instant })
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: auth)
        let app = Application(router: service.internalRouter())
        let path = "/internal/v1/events/stream"
        let timestamp = String(instant.timeIntervalSince1970)
        let nonce = "expiredcursor0001"
        let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: CanonicalSigning.bodyDigest(Data()), authorizationDecisionDigest: CanonicalSigning.bodyDigest(Data()), keyID: key.keyID)
        let requestHeaders: HTTPFields = {
            var headers = HTTPFields()
            headers[.init("X-RepoPrompt-Key-Id")!] = key.keyID
            headers[.init("X-RepoPrompt-Timestamp")!] = timestamp
            headers[.init("X-RepoPrompt-Nonce")!] = nonce
            headers[.init("X-RepoPrompt-Signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
            headers[.init("Last-Event-ID")!] = "\(metadata.storeID.uuidString):0"
            return headers
        }()

        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .get, headers: requestHeaders) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(String(decoding: response.body.readableBytesView, as: UTF8.self).contains("event: cursor_expired"))
            }
        }
        try await store.close()
    }
}
