import Foundation
import Hummingbird
import HummingbirdTesting
@testable import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class ProviderSettingsPortalTests: XCTestCase {
    func testProviderSettingsPersistenceIsRevisionedAndNonSecret() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let initial = ProviderSettingsPreference(
            providerID: .codex,
            enabled: true,
            defaultModel: "gpt-5.6-sol",
            reasoningEffort: "high",
            serviceTier: "fast",
            revision: 1
        )
        try await store.upsertProviderSettings(initial, expectedRevision: 0)
        let persisted = try await store.providerSettings()
        let metadata = try await store.metadata()
        XCTAssertEqual(persisted, [initial])
        XCTAssertEqual(metadata.schemaVersion, 3)

        do {
            _ = try await store.upsertProviderSettings(initial, expectedRevision: 0)
            XCTFail("expected stale revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
    }

    func testBrowserAuthenticationStatusContractHasNoSecretOrPathFields() throws {
        let status = ProviderAuthenticationStatus(
            state: .authenticated,
            authenticated: true,
            method: .browserOAuth,
            accountLabel: "team account",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            detail: "Connected"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(status)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["state", "authenticated", "method", "accountLabel", "expiresAt", "detail"])
        let keys = object.keys.joined(separator: " ").lowercased()
        for forbidden in ["secret", "token", "credential", "path", "helper", "raw"] {
            XCTAssertFalse(keys.contains(forbidden), "browser contract exposed forbidden key: \(forbidden)")
        }
    }

    func testRuntimeDefaultsPreserveExplicitSessionOverrides() {
        let request = ProviderExecutionRequest(
            kind: .codex,
            model: nil,
            prompt: "work",
            workingDirectory: "/tmp",
            runID: UUID(),
            policy: .init(providerSettings: ["provider.reasoningEffort": "ultra"])
        )
        let resolved = request.applying(defaults: .init(
            enabled: true,
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            speedMode: "fast",
            serviceTier: "fast"
        ))
        XCTAssertEqual(resolved.model, "gpt-5.6-sol")
        XCTAssertEqual(resolved.policy.providerSettings["provider.reasoningEffort"], "ultra")
        XCTAssertEqual(resolved.policy.providerSettings["provider.speedMode"], "fast")
        XCTAssertEqual(resolved.policy.providerSettings["provider.serviceTier"], "fast")
    }

    func testProviderSettingsServicePublishesSanitizedHealthCatalogAndCapabilities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusURL = directory.appendingPathComponent("status.json")
        try Data(#"{"authenticated":true,"method":"apiKey","accountLabel":"server account","detail":"Connected"}"#.utf8).write(to: statusURL)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift", protocolVersion: "app-server-v2")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [])
        let service = ProviderSettingsService(
            store: store,
            adapter: adapter,
            configurations: [configuration],
            initiallyEnabled: [],
            authenticationStatusFiles: [.codex: statusURL.path]
        )
        try await service.bootstrap()
        let catalog = try await service.catalog()
        let codex = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        XCTAssertTrue(codex.cli?.installed == true)
        XCTAssertTrue(codex.cli?.healthy == true)
        XCTAssertTrue(codex.authentication.authenticated)
        XCTAssertEqual(codex.authentication.accountLabel, "server account")
        XCTAssertEqual(codex.models.first?.id, "gpt-5.6-sol")
        XCTAssertTrue(codex.capabilities.supportsReasoningEffort)
        XCTAssertTrue(codex.capabilities.supportsServiceTier)
        XCTAssertFalse(codex.capabilities.supportsSpeedMode)
        XCTAssertFalse(codex.deploymentAllowed)
        XCTAssertFalse(codex.runtimePreflightVerified)
        XCTAssertFalse(codex.effectiveEnabled)
        do {
            _ = try await service.update(providerID: .codex, request: .init(
                expectedRevision: codex.preference.revision,
                enabled: true,
                defaultModel: codex.preference.defaultModel,
                reasoningEffort: nil,
                speedMode: nil,
                serviceTier: nil
            ))
            XCTFail("deployment ceiling must reject enablement")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
        try await store.close()
    }

    func testPortalMutationProtectionRequiresSameOriginJSONAndCustomHeader() throws {
        XCTAssertNoThrow(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "https://server.example:9443",
            host: "server.example:9443",
            fetchSite: "same-origin",
            contentType: "application/json; charset=utf-8",
            csrfHeader: "1"
        ))
        XCTAssertThrowsError(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "https://attacker.example",
            host: "server.example:9443",
            fetchSite: "cross-site",
            contentType: "application/json",
            csrfHeader: "1"
        ))
        XCTAssertThrowsError(try RepoPromptPortalRequestProtection.validateMutation(
            origin: "https://server.example:9443",
            host: "server.example:9443",
            fetchSite: nil,
            contentType: "application/x-www-form-urlencoded",
            csrfHeader: nil
        ))
    }

    func testPortalAssetsPreserveDesktopHierarchyAndNeverPersistBrowserState() throws {
        let html = String(decoding: try RepoPromptPortalAssets.data(for: .index), as: UTF8.self)
        let css = String(decoding: try RepoPromptPortalAssets.data(for: .stylesheet), as: UTF8.self)
        let script = String(decoding: try RepoPromptPortalAssets.data(for: .script), as: UTF8.self)

        for term in ["What are we building?", "Models &amp; Providers", "Copy &amp; Chat", "Runtime"] {
            XCTAssertTrue(html.contains(term), "missing desktop term: \(term)")
        }
        for token in ["--space-4: 4px", "--space-16: 16px", "--space-32: 32px", "ui-rounded", "ui-monospace"] {
            XCTAssertTrue(css.contains(token), "missing visual token: \(token)")
        }
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
        XCTAssertFalse(script.contains("console."))
        XCTAssertFalse(script.contains("style."), "strict CSP forbids inline style mutation")
        XCTAssertTrue(script.contains("challenge.userCode"), "device challenge should be transiently renderable")
        XCTAssertEqual(try RepoPromptPortalAssets.response(for: .index).headers[.cacheControl], "private, no-store")
        XCTAssertEqual(try RepoPromptPortalAssets.response(for: .stylesheet).headers[.cacheControl], "private, max-age=3600")
    }

    func testPortalRejectsRequestsWithoutOperatorCertificate() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: InternalRequestAuthenticator(keys: [], store: store),
            eventSigningKey: InternalSigningKey(keyID: "response", role: .goblinSync, direction: "test", secret: Data("secret".utf8))
        )
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            try await client.execute(uri: "/portal", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertNil(response.headers[.init("x-internal-signature")!])
                XCTAssertEqual(response.headers[.cacheControl], "private, no-store")
            }
        }
        try await store.close()
    }
}
