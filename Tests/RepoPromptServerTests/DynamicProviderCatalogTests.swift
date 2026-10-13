import Foundation
import RepoPromptAgentRuntimeCore
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class DynamicProviderCatalogTests: XCTestCase {
    func testEveryProviderRefreshesFromDiscoveryAndMenuReadsDoNotPoll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let vault = try ProviderCredentialVault(fileURL: root.appendingPathComponent("fixture.vault"), activeKey: .init(keyID: "fixture", material: Data(repeating: 7, count: 32)))
        let kinds: [ProviderKind] = [.codex, .claudeCompatible, .openCodeACP, .cursorACP, .grokBuildACP]
        let runtimes = kinds.map { CatalogRuntime(kind: $0) }
        let configurations = kinds.map { ProviderCLIConfiguration(kind: $0, executable: "/usr/bin/true", expectedVersion: "test", credentialSourceDirectory: root.path) }
        for providerID in ProviderSettingsID.allCases where providerID != .ollama {
            let reference = providerID == .openCodeACP ? nil : UUID()
            if let reference { try await vault.store(secret: Data("fixture-credential".utf8), providerID: providerID, connectionID: reference) }
            let connection = ProviderConnectionRecord(
                connectionID: UUID(), providerID: providerID, authenticationMethod: providerID == .openCodeACP ? .providerSpecific : .apiKey,
                state: .connected, lastTestedAt: Date(), testState: .valid,
                keyHelperConfigured: false, workloadIdentityConfigured: false,
                createdAt: Date(), updatedAt: Date(), revision: 1
            )
            _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: reference), expectedRevision: 0)
        }
        let direct = Set(ProviderSettingsID.directAPIProviders)
        let registry = DirectProviderRegistry(store: store, transport: CatalogTransport(), deploymentAllowlist: direct, allowLocalURLs: true)
        try await registry.bootstrap()
        let tester = CatalogCredentialTester()
        let exact: [ProviderSettingsID: any AgentProviderRuntime] = Dictionary(uniqueKeysWithValues: direct.map { ($0, CatalogRuntime(kind: .headlessAdapter) as any AgentProviderRuntime) })
        let service = ProviderSettingsService(
            store: store, adapter: ProviderCLIAdapter(runtimes: runtimes, exactRuntimes: exact, enabledExactProviders: direct), configurations: configurations,
            initiallyEnabled: Set(kinds), vault: vault, credentialTester: tester,
            directProviderRegistry: registry, directProviderAllowlist: direct
        )
        try await service.bootstrap()
        let instant = Date()
        await service.refreshModelCatalogs(now: instant)
        let persisted = try await store.providerModelCatalogs()
        XCTAssertEqual(Set(persisted.map(\.providerID)), Set(ProviderSettingsID.allCases))
        let first = try XCTUnwrap(persisted.first { $0.providerID == .codex })
        let calls = await totalCalls(runtimes, tester: tester)
        XCTAssertEqual(calls, ProviderSettingsID.allCases.count)

        for _ in 0 ..< 20 { _ = try await service.composerCatalog() }
        await service.refreshModelCatalogs(now: instant.addingTimeInterval(29 * 60))
        let cachedCalls = await totalCalls(runtimes, tester: tester)
        XCTAssertEqual(cachedCalls, calls)
        await service.refreshModelCatalogs(now: instant.addingTimeInterval(31 * 60))
        let refreshedCalls = await totalCalls(runtimes, tester: tester)
        XCTAssertEqual(refreshedCalls, calls * 2)
        let refreshed = try await store.providerModelCatalog(providerID: .codex)
        XCTAssertEqual(refreshed?.revision, first.revision)
        XCTAssertGreaterThan(try XCTUnwrap(refreshed).refreshedAt, first.refreshedAt)

        let catalog = try await AgentComposerCatalogService(providerSettings: service, store: store).snapshot(
            context: .init(kind: .project, projectID: UUID(), actorID: "test")
        )
        XCTAssertEqual(catalog.providerGroups.count, ProviderSettingsID.allCases.count)
        XCTAssertTrue(catalog.providerGroups.allSatisfy { $0.models.count == 1 })
        XCTAssertEqual(catalog.providerGroups.first { $0.providerID == .codex }?.models.first?.id, "discovered-codex")
    }

    func testNativeCLIsDiscoverWithoutSendingAnInferencePrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("provider")
        try #"""
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            frame = json.loads(line)
            method = frame.get('method')
            if frame.get('type') == 'control_request':
                result = {'type': 'control_response', 'response': {'subtype': 'success', 'request_id': frame['request_id'], 'response': {'models': [{'value': 'live-claude', 'displayName': 'Live Claude'}]}}}
            elif method == 'initialize':
                result = {'id': frame['id'], 'result': {'agentCapabilities': {}}}
            elif method == 'model/list':
                result = {'id': frame['id'], 'result': {'data': [{'id': 'live-codex', 'displayName': 'Live Codex'}]}}
            elif method == 'session/new':
                result = {'id': frame['id'], 'result': {'sessionId': 'probe', 'models': {'currentModelId': 'live-acp', 'availableModels': [{'modelId': 'live-acp', 'name': 'Live ACP'}]}}}
            elif method == 'initialized':
                continue
            else:
                sys.exit(42)
            print(json.dumps(result), flush=True)
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let configurations = [ProviderKind.codex, .claudeCompatible, .openCodeACP, .cursorACP, .grokBuildACP]
            .map { ProviderCLIConfiguration(kind: $0, executable: executable.path, expectedVersion: "test") }
        let adapter = ProviderCLIAdapter(configurations: configurations, processPort: try PortableProcessSupervisionPort(), outputDirectory: root.appendingPathComponent("output").path, ephemeralHomeRoot: root.appendingPathComponent("homes").path)
        for providerID in [ProviderSettingsID.codex, .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom, .openCodeACP, .cursorACP, .grokBuildACP] {
            let models = try await adapter.discoverModelCatalog(providerID: providerID)
            XCTAssertEqual(models.count, 1)
            XCTAssertTrue(models[0].id.hasPrefix("live-"))
        }
    }

    func testACPGroupedChoicesAndLegacyModelStateUseProviderIdentifiers() throws {
        let grouped = Data(#"{"configOptions":[{"id":"model","category":"model","currentValue":"new/model","options":[{"group":"Vendor","options":[{"value":"new/model","name":"New model"}]}]}]}"#.utf8)
        let models = try ProviderModelDiscovery.acp(grouped)
        XCTAssertEqual(models.map(\.id), ["new/model"])
        XCTAssertTrue(models[0].isProviderDefault)
        XCTAssertThrowsError(try ProviderModelDiscovery.acp(Data(#"{"models":{"availableModels":[{"modelId":"bad\nmodel"}]}}"#.utf8)))
    }

    func testDirectCatalogPaginationStaysOnTheValidatedEndpoint() throws {
        let endpoint = DirectProviderEndpoint(scheme: "https", host: "api.anthropic.com", port: 443, basePath: "/v1")
        let response = ValidatedProviderHTTPResponse(statusCode: 200, contentType: "application/json", body: Data(#"{"data":[],"has_more":true,"last_id":"model-next"}"#.utf8))
        XCTAssertEqual(try DirectProviderCredentialTester.nextCatalogPage(response: response, initialPath: "/v1/models", endpoint: endpoint), "/v1/models?after_id=model-next")
        let unsafe = ValidatedProviderHTTPResponse(statusCode: 200, contentType: "application/json", body: Data(#"{"nextLink":"https://evil.example/v1/models"}"#.utf8))
        XCTAssertThrowsError(try DirectProviderCredentialTester.nextCatalogPage(response: unsafe, initialPath: "/v1/models", endpoint: endpoint))
    }

    private func totalCalls(_ runtimes: [CatalogRuntime], tester: CatalogCredentialTester) async -> Int {
        var count = await tester.calls
        for runtime in runtimes { count += await runtime.calls }
        return count
    }
}

private actor CatalogRuntime: AgentProviderRuntime, ProviderModelCatalogDiscovering {
    let kind: ProviderKind
    private(set) var calls = 0
    init(kind: ProviderKind) { self.kind = kind }
    func capability() -> ProviderCapability { .init(kind: kind, enabled: true, executable: "/usr/bin/true", supportsResume: true, supportsSteering: true) }
    func preflight() -> ProviderCapability { capability() }
    func discoverModelCatalog(policy: ProviderExecutionPolicy) -> [ProviderModelCatalogEntry] {
        calls += 1
        let id = policy.providerSettings["claude.backendID"] ?? kind.rawValue
        return [.init(id: "discovered-\(id)", displayName: "Discovered \(id)")]
    }
    func execute(_: ProviderExecutionRequest, onEvent _: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) throws -> ProviderExecutionResult { throw CancellationError() }
    func interrupt(runID _: UUID) {}
}

private actor CatalogCredentialTester: ProviderCredentialTesting {
    private(set) var calls = 0
    func supportedAuthenticationMethods(for _: ProviderSettingsID) -> Set<ProviderAuthenticationMethod> { [.apiKey] }
    func test(providerID: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret _: Data?) -> ProviderCredentialTestResult {
        calls += 1
        return .init(state: .valid, detail: "Discovered", models: [.init(id: "discovered-\(providerID.rawValue)", displayName: "Discovered")])
    }
    func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) {}
}

private struct CatalogTransport: ValidatedProviderEgressTransporting {
    func validateEndpoint(_ value: String) async throws -> DirectProviderEndpoint { try ProviderEndpointPolicy.parseCustomBaseURL(value) }
    func execute(_: ValidatedProviderHTTPRequest) async throws -> ValidatedProviderHTTPResponse { throw CancellationError() }
}
