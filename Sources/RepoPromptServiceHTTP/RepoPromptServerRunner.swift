import Foundation
import Hummingbird
import HummingbirdTLS
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public struct RepoPromptServerConfiguration: Sendable {
    public let stateDatabasePath: String
    public let worktreeDirectory: String
    public let artifactDirectory: String
    public let projectDirectory: String
    public let cacheDirectory: String
    public let providerHomeDirectory: String
    public let bindHost: String
    public let bindPort: Int
    public let healthHost: String
    public let healthPort: Int
    public let certificatePath: String
    public let privateKeyPath: String
    public let clientCAPath: String
    public let signingKeys: [InternalSigningKey]
    public let eventSigningKey: InternalSigningKey
    public let providerExecutables: [ProviderKind: String]
    public let providerVersions: [ProviderKind: String]
    public let providerProtocols: [ProviderKind: String]
    public let providerCredentialSources: [ProviderKind: String]
    public let minimumFreeBytes: Int64
    public let minimumFreeNodes: Int64
    public let maximumActiveSessions: Int
    public let restoreActivationTokenPath: String?

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw ConfigurationError.missing(name) }
            return value
        }
        func secret(_ variable: String) throws -> Data {
            let path = try required(variable)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        func previousKey(prefix: String, role: InternalRouteRole, direction: String) throws -> InternalSigningKey? {
            let id = environment["\(prefix)_PREVIOUS_KEY_ID"]
            let file = environment["\(prefix)_PREVIOUS_HMAC_FILE"]
            guard id != nil || file != nil else { return nil }
            guard let id, !id.isEmpty, file != nil else { throw ConfigurationError.invalid("\(prefix) previous key ID and HMAC file must be configured together") }
            return try InternalSigningKey(keyID: id, role: role, direction: direction, secret: secret("\(prefix)_PREVIOUS_HMAC_FILE"), active: false)
        }
        let app = try InternalSigningKey(keyID: environment["REPOPROMPT_GOBLIN_APP_KEY_ID"] ?? "goblin-app-v1", role: .goblinApp, direction: "goblin-app-to-repoprompt-v1", secret: secret("REPOPROMPT_GOBLIN_APP_HMAC_FILE"))
        let sync = try InternalSigningKey(keyID: environment["REPOPROMPT_GOBLIN_SYNC_KEY_ID"] ?? "goblin-sync-v1", role: .goblinSync, direction: "goblin-sync-to-repoprompt-v1", secret: secret("REPOPROMPT_GOBLIN_SYNC_HMAC_FILE"))
        let operatorKey = try InternalSigningKey(keyID: environment["REPOPROMPT_OPERATOR_KEY_ID"] ?? "repoprompt-operator-v1", role: .operatorRole, direction: "repoprompt-operator-to-repoprompt-v1", secret: secret("REPOPROMPT_OPERATOR_HMAC_FILE"))
        let event = try InternalSigningKey(keyID: environment["REPOPROMPT_EVENT_KEY_ID"] ?? "repoprompt-event-v1", role: .goblinSync, direction: "repoprompt-to-goblin-v1", secret: secret("REPOPROMPT_EVENT_HMAC_FILE"))
        let signingKeys = try [
            app, sync, operatorKey,
            previousKey(prefix: "REPOPROMPT_GOBLIN_APP", role: .goblinApp, direction: app.direction),
            previousKey(prefix: "REPOPROMPT_GOBLIN_SYNC", role: .goblinSync, direction: sync.direction),
            previousKey(prefix: "REPOPROMPT_OPERATOR", role: .operatorRole, direction: operatorKey.direction)
        ].compactMap(\.self)
        let allSigningKeys = signingKeys + [event]
        guard allSigningKeys.allSatisfy({
            $0.keyID.range(of: "^[A-Za-z0-9_.:-]{1,128}$", options: .regularExpression) != nil && $0.secret.count >= 32
        }) else { throw ConfigurationError.invalid("Internal signing keys require a valid key ID and at least 256 bits") }
        guard Set(signingKeys.map(\.keyID)).count == signingKeys.count else { throw ConfigurationError.invalid("Internal signing key IDs must be unique across roles and rotations") }
        var providers: [ProviderKind: String] = [
            .codex: environment["REPOPROMPT_CODEX_EXECUTABLE"] ?? "/opt/repoprompt/providers/codex",
            .claudeCompatible: environment["REPOPROMPT_CLAUDE_EXECUTABLE"] ?? "/opt/repoprompt/providers/claude",
            .openCodeACP: environment["REPOPROMPT_OPENCODE_EXECUTABLE"] ?? "/opt/repoprompt/providers/opencode",
            .cursorACP: environment["REPOPROMPT_CURSOR_EXECUTABLE"] ?? "/opt/repoprompt/providers/cursor-agent"
        ]
        let disabled = Set((environment["REPOPROMPT_DISABLED_PROVIDERS"] ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        providers = providers.filter { !disabled.contains($0.key.rawValue) }
        let versions: [ProviderKind: String] = [.codex: "0.147.0", .claudeCompatible: "2.1.226", .openCodeACP: "1.15.11", .cursorACP: "2026.08.04-aaa8809"]
        let protocols: [ProviderKind: String] = [.codex: "app-server-v2", .claudeCompatible: "stream-json-v1", .openCodeACP: "acp-v1", .cursorACP: "acp-v1-beta"]
        let credentialSources = [
            (ProviderKind.codex, environment["REPOPROMPT_CODEX_CREDENTIAL_HOME"]),
            (.claudeCompatible, environment["REPOPROMPT_CLAUDE_CREDENTIAL_HOME"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_CREDENTIAL_HOME"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_CREDENTIAL_HOME"])
        ].reduce(into: [ProviderKind: String]()) { result, value in if let path = value.1, !path.isEmpty { result[value.0] = path } }
        let stateDatabase = environment["REPOPROMPT_STATE_DB"] ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        return try Self(
            stateDatabasePath: stateDatabase,
            worktreeDirectory: environment["REPOPROMPT_WORKTREE_DIR"] ?? "/srv/repoprompt/worktrees",
            artifactDirectory: environment["REPOPROMPT_ARTIFACT_DIR"] ?? "/var/lib/repoprompt/artifacts",
            projectDirectory: environment["REPOPROMPT_PROJECT_DIR"] ?? "/srv/repoprompt/projects",
            cacheDirectory: environment["REPOPROMPT_CACHE_DIR"] ?? "/var/cache/repoprompt",
            providerHomeDirectory: environment["REPOPROMPT_PROVIDER_HOME_DIR"] ?? URL(fileURLWithPath: stateDatabase).deletingLastPathComponent().appendingPathComponent("provider-homes").path,
            bindHost: environment["REPOPROMPT_BIND_HOST"] ?? "0.0.0.0", bindPort: Int(environment["REPOPROMPT_BIND_PORT"] ?? "9443") ?? 9443,
            healthHost: "127.0.0.1", healthPort: Int(environment["REPOPROMPT_HEALTH_PORT"] ?? "9080") ?? 9080,
            certificatePath: required("REPOPROMPT_TLS_CERT_FILE"), privateKeyPath: required("REPOPROMPT_TLS_KEY_FILE"), clientCAPath: required("REPOPROMPT_TLS_CLIENT_CA_FILE"),
            signingKeys: signingKeys, eventSigningKey: event,
            providerExecutables: providers,
            providerVersions: versions,
            providerProtocols: protocols,
            providerCredentialSources: credentialSources,
            minimumFreeBytes: Int64(environment["REPOPROMPT_MINIMUM_FREE_BYTES"] ?? "268435456") ?? 268_435_456,
            minimumFreeNodes: Int64(environment["REPOPROMPT_MINIMUM_FREE_NODES"] ?? "1024") ?? 1024,
            maximumActiveSessions: Int(environment["REPOPROMPT_MAX_ACTIVE_SESSIONS"] ?? "64") ?? 64,
            restoreActivationTokenPath: environment["REPOPROMPT_RESTORE_ACTIVATION_TOKEN_FILE"]
        )
    }
}

public enum ConfigurationError: Error, CustomStringConvertible { case missing(String)
    case invalid(String)
    public var description: String {
        switch self {
        case let .missing(name): "Required configuration \(name) is missing"
        case let .invalid(message): message
        }
    }
}

public enum RepoPromptServerRunner {
    public static func run(configuration: RepoPromptServerConfiguration) async throws {
        let stateDirectory = URL(fileURLWithPath: configuration.stateDatabasePath).deletingLastPathComponent().path
        for directory in [
            stateDirectory,
            configuration.worktreeDirectory,
            configuration.artifactDirectory,
            configuration.projectDirectory,
            configuration.cacheDirectory,
            configuration.providerHomeDirectory
        ] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        // Parse all trust material before any listener can report ready.
        let certificateRoles = try CertificateIdentityRoleResolver.environment()
        let tls = try RepoPromptTLSConfiguration.mutualTLS13(
            certificatePath: configuration.certificatePath,
            privateKeyPath: configuration.privateKeyPath,
            trustRootsPath: configuration.clientCAPath
        )
        let instanceID = UUID()
        let store = try await SQLiteServiceStore.open(
            storage: .file(configuration.stateDatabasePath),
            eventSigningKey: ServiceEventSigningKey(
                keyID: configuration.eventSigningKey.keyID,
                secret: configuration.eventSigningKey.secret
            )
        )
        if let tokenPath = configuration.restoreActivationTokenPath {
            let token = try Data(contentsOf: URL(fileURLWithPath: tokenPath))
            _ = try await store.activateRestoredStore(activationToken: token, instanceID: instanceID)
        }
        guard try await store.metadata().activationState == "active" else {
            try await store.close(clean: false)
            throw ServiceAPIError(code: .quiescing, message: "Restored store requires activation fencing")
        }

        let worktrees = try WorktreeRuntimeService(
            baseDirectory: configuration.worktreeDirectory,
            resources: store,
            ownerInstanceID: instanceID
        )
        let artifacts = try ArtifactRuntimeService(
            baseDirectory: configuration.artifactDirectory,
            resources: store
        )
        let processOutput = URL(fileURLWithPath: stateDirectory).appendingPathComponent("provider-output").path
        try FileManager.default.createDirectory(atPath: processOutput, withIntermediateDirectories: true)
        let reconciler = OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: configuration.artifactDirectory,
            worktreeRoot: configuration.worktreeDirectory,
            providerHomeRoot: configuration.providerHomeDirectory,
            providerOutputRoot: processOutput
        )
        _ = await reconciler.reconcileStartup()
        let durabilityOperations = DurabilityOperationsService(store: store, reconciler: reconciler)
        _ = await durabilityOperations.runOnce()

        let processPort = try PortableProcessSupervisionPort()
        let providerConfigurations = configuration.providerExecutables.map { kind, executable in
            ProviderCLIConfiguration(
                kind: kind,
                executable: executable,
                expectedVersion: configuration.providerVersions[kind],
                protocolVersion: configuration.providerProtocols[kind],
                credentialSourceDirectory: configuration.providerCredentialSources[kind]
            )
        }
        let providers = ProviderCLIAdapter(
            configurations: providerConfigurations,
            processPort: processPort,
            processStore: store,
            outputDirectory: processOutput,
            ephemeralHomeRoot: configuration.providerHomeDirectory
        )
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktrees,
            artifactService: artifacts,
            providerAdapter: providers
        )
        try await authority.recover()

        let drainController = MutationDrainController()
        let authenticator = InternalRequestAuthenticator(keys: configuration.signingKeys, store: store)
        let readiness = RepoPromptReadinessService(
            authority: authority,
            store: store,
            volumes: [
                .init(name: "state", path: stateDirectory),
                .init(name: "artifacts", path: configuration.artifactDirectory),
                .init(name: "projects", path: configuration.projectDirectory),
                .init(name: "worktrees", path: configuration.worktreeDirectory),
                .init(name: "cache", path: configuration.cacheDirectory)
            ],
            requiredProviders: Set(configuration.providerExecutables.keys),
            expectedProviderProtocols: configuration.providerProtocols,
            minimumFreeBytes: configuration.minimumFreeBytes,
            minimumFreeNodes: configuration.minimumFreeNodes,
            maximumActiveSessions: configuration.maximumActiveSessions,
            drainController: drainController,
            trustConfigurationValid: true
        )
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: authenticator,
            eventSigningKey: configuration.eventSigningKey,
            certificateRoleResolver: certificateRoles,
            readiness: readiness,
            drainController: drainController,
            durabilityOperations: durabilityOperations
        )
        let internalApplication = try Application(
            router: service.internalRouter(),
            server: .tls(tlsConfiguration: tls),
            configuration: .init(
                address: .hostname(configuration.bindHost, port: configuration.bindPort),
                serverName: "RepoPromptServer"
            )
        )
        let healthApplication = Application(
            router: service.healthRouter(),
            configuration: .init(
                address: .hostname(configuration.healthHost, port: configuration.healthPort),
                serverName: nil
            )
        )
        await durabilityOperations.start()

        var serviceError: Error?
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await internalApplication.runService() }
                group.addTask { try await healthApplication.runService() }
                _ = try await group.next()
                let drain = await drainController.drain(timeout: 15)
                try await authority.quiesce()
                await durabilityOperations.stop()
                _ = await durabilityOperations.runOnce()
                if !drain.drainTimedOut {
                    try await store.checkpoint()
                }
                group.cancelAll()
            }
        } catch {
            serviceError = error
            _ = await drainController.drain(timeout: 15)
            try? await authority.quiesce()
            await durabilityOperations.stop()
            _ = await durabilityOperations.runOnce()
        }

        let drain = await drainController.snapshot()
        let clean = !drain.drainTimedOut && serviceError == nil
        if clean { try await store.checkpoint() }
        try await store.close(clean: clean)
        if let serviceError { throw serviceError }
    }
}
