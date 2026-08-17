import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import NIOSSL
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import X509
import XCTest

final class PortalStandaloneMTLSTests: XCTestCase {
    func testOperatorCertificateMapsAndGoblinSyncIsRejected() throws {
        let resolver = CertificateIdentityRoleResolver(identities: [
            "goblin-app": .app,
            "goblin-sync": .sync,
            "repoprompt-operator": .operatorRole
        ])
        XCTAssertEqual(
            try resolver.role(certificate: Self.nioCertificate(identity: "repoprompt-operator")),
            .operatorRole
        )
        XCTAssertEqual(
            try resolver.role(certificate: Self.nioCertificate(identity: "goblin-app")),
            .app
        )
        XCTAssertEqual(
            try resolver.role(certificate: Self.nioCertificate(identity: "goblin-sync")),
            .sync
        )
        XCTAssertFalse(RepoPromptPortalCertificateAuthorization.allows(.sync))
        XCTAssertThrowsError(
            try resolver.role(certificate: Self.nioCertificate(identity: "repoprompt-operator", clientAuth: false))
        ) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .internalAuthFailed)
        }
    }

    func testOperatorMTLSServesPortalSettingsAndAgentSurfacesWithoutChatServerHMAC() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let settings = ServerSettingsService(
            store: store,
            providerCatalog: EmptyServerSettingsCatalog(),
            projectCatalog: store
        )
        let operatorDER = try Self.certificateDER(identity: "repoprompt-operator")
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: "test", secret: Data("secret".utf8)),
            certificateRoleResolver: CertificateIdentityRoleResolver(identities: [
                "goblin-app": .app,
                "goblin-sync": .sync,
                "repoprompt-operator": .operatorRole
            ]),
            serverSettings: settings,
            portalPeerCertificateDER: operatorDER
        )
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal", method: .get) { response in
                XCTAssertEqual(response.status.code, 308)
                XCTAssertEqual(response.headers[.location], "/portal/")
            }
            try await client.execute(uri: "/portal/", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], "private, no-store")
                let html = String(buffer: response.body)
                XCTAssertTrue(html.contains("portal.js") || html.contains("RepoPrompt"))
            }
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let bootstrap = try JSONDecoder.serviceDecoder.decode(
                    PortalBootstrapResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertTrue(bootstrap.sessions.isEmpty)
                XCTAssertFalse(bootstrap.tools.isEmpty)
            }
            var advanced: AdvancedServerSettingsSnapshot?
            try await client.execute(uri: "/portal/api/v1/settings/advanced", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                advanced = try JSONDecoder.serviceDecoder.decode(
                    AdvancedServerSettingsSnapshot.self,
                    from: Data(response.body.readableBytesView)
                )
            }
            let current = try XCTUnwrap(advanced)
            XCTAssertEqual(current.revision, 0)
            let replaced = ReplaceAdvancedServerSettingsRequest(
                expectedRevision: current.revision,
                settings: AdvancedServerSettings(historyIdleThresholdMinutes: 25)
            )
            let body = try JSONEncoder.serviceEncoder.encode(replaced)
            try await client.execute(
                uri: "/portal/api/v1/settings/advanced",
                method: .patch,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let snapshot = try JSONDecoder.serviceDecoder.decode(
                    AdvancedServerSettingsSnapshot.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(snapshot.revision, 1)
                XCTAssertEqual(snapshot.settings.historyIdleThresholdMinutes, 25)
            }
            let create = PortalCreateSessionRequest(
                operationID: UUID(),
                projectID: UUID(),
                providerID: .codex,
                model: "gpt-5.6-sol",
                initialPrompt: "Prove operator mTLS can reach the agent surface"
            )
            try await client.execute(
                uri: "/portal/api/v1/sessions",
                method: .post,
                headers: Self.portalMutationHeaders(),
                body: ByteBuffer(data: try JSONEncoder.serviceEncoder.encode(create))
            ) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                let error = try JSONDecoder.serviceDecoder.decode(
                    ServiceAPIError.self,
                    from: Data(response.body.readableBytesView)
                )
                XCTAssertEqual(error.code, .dependencyUnavailable)
                XCTAssertNotEqual(error.code, .internalAuthFailed)
            }
        }
    }

    func testGoblinSyncCertificateCannotUsePortalAndHMACDoesNotBypassMTLS() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let authority = RepoPromptHeadlessAuthority(store: store)
        let resolver = CertificateIdentityRoleResolver(identities: [
            "goblin-app": .app,
            "goblin-sync": .sync,
            "repoprompt-operator": .operatorRole
        ])
        let syncService = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .sync, direction: "test", secret: Data("secret".utf8)),
            certificateRoleResolver: resolver,
            portalPeerCertificateDER: try Self.certificateDER(identity: "goblin-sync")
        )
        let syncApp = Application(router: syncService.internalRouter())
        try await syncApp.test(.router) { client in
            try await client.execute(uri: "/portal/api/v1/bootstrap", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/portal/api/v1/settings/advanced", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }

        let hmacKey = InternalSigningKey(
            keyID: "app-v1",
            role: .app,
            direction: "goblin-app-to-repoprompt-v1",
            secret: Data("chat-server-hmac-secret-32bytes!!".utf8)
        )
        let hmacService = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [hmacKey], store: store),
            eventSigningKey: hmacKey,
            certificateRoleResolver: resolver
        )
        let hmacApp = Application(router: hmacService.internalRouter())
        try await hmacApp.test(.router) { client in
            try await client.execute(
                uri: "/portal/api/v1/bootstrap",
                method: .get,
                headers: try Self.goblinHMACHeaders(path: "/portal/api/v1/bootstrap", key: hmacKey)
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    private static func portalMutationHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.init("Origin")!] = "https://localhost"
        headers[.init("Sec-Fetch-Site")!] = "same-origin"
        headers[.contentType] = "application/json"
        headers[.init("X-RepoPrompt-Portal-CSRF")!] = "1"
        return headers
    }

    private static func goblinHMACHeaders(path: String, key: InternalSigningKey) throws -> HTTPFields {
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let timestamp = CanonicalSigning.iso8601String(instant)
        let nonce = "portalhmacnonce0001"
        let bodyDigest = CanonicalSigning.bodyDigest(Data())
        let authorizationDigest = CanonicalSigning.bodyDigest(Data())
        let canonical = CanonicalSigning.requestString(
            method: "GET",
            pathAndQuery: path,
            timestamp: timestamp,
            nonce: nonce,
            bodyDigest: bodyDigest,
            authorizationDecisionDigest: authorizationDigest,
            keyID: key.keyID
        )
        var headers = HTTPFields()
        headers[.init("x-internal-key-id")!] = key.keyID
        headers[.init("x-internal-timestamp")!] = timestamp
        headers[.init("x-internal-nonce")!] = nonce
        headers[.init("x-internal-body-digest")!] = bodyDigest
        headers[.init("x-internal-authorization-digest")!] = authorizationDigest
        headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
        return headers
    }

    private static func nioCertificate(identity: String, clientAuth: Bool = true) throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: [UInt8](certificateDER(identity: identity, clientAuth: clientAuth)), format: .der)
    }

    private static func certificateDER(identity: String, clientAuth: Bool = true) throws -> Data {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(identity) }
        var extensionList: [Certificate.Extension] = [
            try Certificate.Extension(SubjectAlternativeNames([.dnsName(identity)]), critical: false)
        ]
        if clientAuth {
            extensionList.insert(try Certificate.Extension(ExtendedKeyUsage([.clientAuth]), critical: false), at: 0)
        }
        let extensions = try Certificate.Extensions(extensionList)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-60),
            notValidAfter: Date().addingTimeInterval(3_600),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: .init(key)
        )
        return Data(try certificate.serializeAsPEM().derBytes)
    }
}

private struct EmptyServerSettingsCatalog: ServerSettingsProviderCatalogProviding {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        .init(providers: [])
    }
}
