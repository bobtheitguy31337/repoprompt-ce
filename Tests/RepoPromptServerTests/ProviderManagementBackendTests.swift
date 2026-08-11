import Crypto
import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class ProviderManagementBackendTests: XCTestCase {
    func testProviderRedactionRemovesKnownAndTokenShapedSecrets() {
        let known = "opaque-credential-value"
        let redacted = ProviderSecretRedaction.redact("Authorization bearer xai-1234567890 and \(known)", knownSecrets: [known])
        XCTAssertFalse(redacted.contains("xai-1234567890"))
        XCTAssertFalse(redacted.contains(known))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    func testVaultEncryptsAtomicallyMigratesAndRotatesWithoutPlaintext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.vault")
        let first = try ProviderVaultKey(keyID: "key-v1", material: Data(repeating: 7, count: 32))
        let second = try ProviderVaultKey(keyID: "key-v2", material: Data(repeating: 9, count: 32))
        let connectionID = UUID()
        let secret = Data("xai-write-only-secret-value".utf8)

        let vault = try ProviderCredentialVault(fileURL: file, activeKey: first)
        try await vault.store(secret: secret, providerID: .xAI, connectionID: connectionID)
        let initiallyLoaded = try await vault.load(providerID: .xAI, connectionID: connectionID)
        XCTAssertEqual(initiallyLoaded, secret)
        XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try String(decoding: Data(contentsOf: file), as: UTF8.self).contains("xai-write-only-secret-value"))

        try await vault.rotate(to: second)
        let rotated = try await vault.load(providerID: .xAI, connectionID: connectionID)
        XCTAssertEqual(rotated, secret)
        let reopened = try ProviderCredentialVault(fileURL: file, activeKey: second)
        let reopenedSecret = try await reopened.load(providerID: .xAI, connectionID: connectionID)
        XCTAssertEqual(reopenedSecret, secret)
        XCTAssertThrowsError(try ProviderCredentialVault(fileURL: file, activeKey: first))
    }

    func testVaultMigratesEncryptedSchemaV1Document() async throws {
        struct LegacyPayload: Codable { let providerID: ProviderSettingsID
            let secret: Data
        }
        struct LegacyDocument: Codable { let schemaVersion: Int
            let generation: Int64
            let entries: [String: String]
            let keyID: String
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("legacy.vault")
        let key = try ProviderVaultKey(keyID: "legacy", material: Data(repeating: 4, count: 32))
        let connectionID = UUID()
        let secret = Data("legacy-secret-never-plaintext".utf8)
        let clear = try JSONEncoder.serviceEncoder.encode(LegacyPayload(providerID: .codex, secret: secret))
        let sealed = try XCTUnwrap(AES.GCM.seal(clear, using: SymmetricKey(data: key.material)).combined)
        let data = try JSONEncoder.serviceEncoder.encode(LegacyDocument(schemaVersion: 1, generation: 2, entries: [connectionID.uuidString: sealed.base64EncodedString()], keyID: key.keyID))
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]))

        let vault = try ProviderCredentialVault(fileURL: file, activeKey: key)
        let migratedSecret = try await vault.load(providerID: .codex, connectionID: connectionID)
        XCTAssertEqual(migratedSecret, secret)
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(migrated["schemaVersion"] as? Int, 2)
        XCTAssertFalse(try String(decoding: Data(contentsOf: file), as: UTF8.self).contains("legacy-secret-never-plaintext"))
    }

    func testMasterKeyFileRequiresStrict0600() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 32), attributes: [.posixPermissions: 0o644]))
        XCTAssertThrowsError(try ProviderVaultKey.load(keyID: "test", filePath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertNoThrow(try ProviderVaultKey.load(keyID: "test", filePath: file.path))
    }

    func testAPIKeyConnectionIsEncryptedAuditedValidatedAndInjectedOnlyThroughEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(fileURL: directory.appendingPathComponent("vault"), activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 3, count: 32)))
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let tester = RecordingCredentialTester(result: .init(state: .valid, detail: "Credential accepted"))
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.codex], vault: vault, credentialTester: tester, runner: StaticVersionRunner())
        try await service.bootstrap()
        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")
        let secret = "sk-test-write-only-value"

        var snapshot = try await service.connect(providerID: .codex, request: .init(authenticationMethod: .apiKey, credential: secret, accountLabel: "team"), attribution: attribution)
        XCTAssertEqual(snapshot.connection?.testState, .notTested)
        XCTAssertFalse(snapshot.effectiveEnabled)
        snapshot = try await service.testConnection(providerID: .codex, attribution: attribution)
        XCTAssertEqual(snapshot.connection?.testState, .valid)
        XCTAssertTrue(snapshot.effectiveEnabled)

        let environment = try await VaultProviderProcessEnvironment(store: store, vault: vault).environment(for: .codex)
        XCTAssertEqual(environment, ["OPENAI_API_KEY": secret])
        let encoded = try String(decoding: JSONEncoder.serviceEncoder.encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        let audits = try await store.providerConnectionAudit()
        XCTAssertEqual(audits.map(\.operation), ["connect", "test"])
        XCTAssertFalse(try String(decoding: JSONEncoder.serviceEncoder.encode(audits), as: UTF8.self).contains(secret))

        snapshot = try await service.disconnect(providerID: .codex, attribution: attribution)
        XCTAssertNil(snapshot.connection)
        let remainingConnections = try await store.providerConnections()
        XCTAssertTrue(remainingConnections.isEmpty)
    }

    func testCredentialCannotBePersistedAsAccountLabel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(fileURL: directory.appendingPathComponent("vault"), activeKey: ProviderVaultKey(keyID: "test", material: Data(repeating: 3, count: 32)))
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let tester = EchoingCredentialTester()
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.codex], vault: vault, credentialTester: tester, runner: StaticVersionRunner())
        try await service.bootstrap()
        let attribution = ProviderMutationAttribution(actorID: "admin-1", actorLabel: "alice", channel: "test")

        do {
            _ = try await service.connect(providerID: .codex, request: .init(authenticationMethod: .apiKey, credential: "  opaquecredential  ", accountLabel: "opaquecredential"), attribution: attribution)
            XCTFail("normalized credential was accepted as an account label")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .invalidRequest) }

        _ = try await service.connect(providerID: .codex, request: .init(authenticationMethod: .apiKey, credential: "opaquecredential"), attribution: attribution)
        do {
            _ = try await service.testConnection(providerID: .codex, attribution: attribution)
            XCTFail("validator-returned credential was accepted as an account label")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .dependencyUnavailable) }
        let persisted = try await store.providerConnection(providerID: .codex)
        let stored = try XCTUnwrap(persisted)
        XCTAssertNil(stored.record.accountLabel)
        XCTAssertEqual(stored.record.testState, .notTested)
    }

    func testConnectionRejectsUnsupportedControlsAndOpenCodeRawCredentialProxying() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let configuration = ProviderCLIConfiguration(kind: .codex, executable: "/usr/bin/swift")
        let adapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.codex], runner: StaticVersionRunner())
        let service = ProviderSettingsService(store: store, adapter: adapter, configurations: [configuration], initiallyEnabled: [.codex], runner: StaticVersionRunner())
        try await service.bootstrap()
        let catalog = try await service.catalog()
        let codex = try XCTUnwrap(catalog.providers.first { $0.providerID == .codex })
        do {
            _ = try await service.update(providerID: .codex, request: .init(expectedRevision: codex.preference.revision, enabled: true, defaultModel: "gpt-5.6-sol", reasoningEffort: "impossible", speedMode: nil, serviceTier: nil))
            XCTFail("unsupported control was accepted")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .invalidRequest) }
        do {
            _ = try await service.connect(providerID: .openCodeACP, request: .init(authenticationMethod: .providerSpecific, credential: "must-not-proxy"), attribution: .init(actorID: "a", actorLabel: "a", channel: "test"))
            XCTFail("OpenCode raw credential proxy was accepted")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .invalidRequest) }
    }

    func testTransientAuthFlowIsOwnerFencedAndCancelRemovesState() async throws {
        let driver = FakeAuthFlowDriver()
        let coordinator = TransientProviderAuthFlowCoordinator(driver: driver)
        let status = try await coordinator.start(providerID: .codex, kind: .deviceCodeBeta, ownerID: "admin-a")
        XCTAssertEqual(status.userCode, "ABCD-EFGH")
        do {
            _ = try await coordinator.poll(flowID: status.flowID, ownerID: "admin-b")
            XCTFail("another administrator accessed the device code")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .notFound) }
        try await coordinator.cancel(flowID: status.flowID, ownerID: "admin-a")
        let wasCancelled = await driver.wasCancelled(status.flowID)
        XCTAssertTrue(wasCancelled)
        do {
            _ = try await coordinator.poll(flowID: status.flowID, ownerID: "admin-a")
            XCTFail("cancelled transaction remained visible")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .notFound) }
    }
}

private actor RecordingCredentialTester: ProviderCredentialTesting {
    let result: ProviderCredentialTestResult
    init(result: ProviderCredentialTestResult) {
        self.result = result
    }

    func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret _: Data?) async -> ProviderCredentialTestResult {
        result
    }

    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

private actor EchoingCredentialTester: ProviderCredentialTesting {
    func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        .init(state: .valid, detail: "Credential accepted", accountLabel: secret.flatMap { String(data: $0, encoding: .utf8) })
    }

    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

private actor StaticVersionRunner: WorkspaceCommandRunning {
    func run(executable _: String, arguments _: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        "Swift version 6.2"
    }
}

private actor FakeAuthFlowDriver: ProviderAuthFlowDriving {
    private var statuses: [UUID: ProviderAuthTransactionStatus] = [:]
    private var cancelled: Set<UUID> = []
    func start(providerID: ProviderSettingsID, kind: ProviderAuthFlowKind) async throws -> ProviderAuthTransactionStatus {
        let status = ProviderAuthTransactionStatus(flowID: UUID(), providerID: providerID, kind: kind, state: .pending, userCode: "ABCD-EFGH", verificationURL: URL(string: "https://example.test/device"), expiresAt: Date().addingTimeInterval(300), detail: "Awaiting authorization")
        statuses[status.flowID] = status
        return status
    }

    func poll(flowID: UUID) async throws -> ProviderAuthTransactionStatus {
        guard let status = statuses[flowID] else { throw ServiceAPIError(code: .notFound, message: "missing") }
        return status
    }

    func cancel(flowID: UUID) async {
        statuses[flowID] = nil
        cancelled.insert(flowID)
    }

    func wasCancelled(_ flowID: UUID) -> Bool {
        cancelled.contains(flowID)
    }
}
