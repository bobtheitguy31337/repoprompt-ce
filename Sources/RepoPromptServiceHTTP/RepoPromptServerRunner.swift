import Foundation
import Hummingbird
import HummingbirdTLS
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
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
    public let enabledProviders: Set<ProviderKind>
    public let enabledDirectProviders: Set<ProviderSettingsID>
    public let providerVersions: [ProviderKind: String]
    public let providerProtocols: [ProviderKind: String]
    public let providerCredentialSources: [ProviderKind: String]
    public let providerAuthenticationStatusFiles: [ProviderSettingsID: String]
    public let providerModelCatalogFiles: [ProviderSettingsID: String]
    public let providerVaultKey: ProviderVaultKey?
    public let providerVaultDecryptionKeys: [ProviderVaultKey]
    public let providerVaultFilePath: String
    public let minimumFreeBytes: Int64
    public let minimumFreeNodes: Int64
    public let maximumActiveSessions: Int
    public let restoreActivationTokenPath: String?
    public let projectSourcePolicy: ProjectSourcePolicy
    public let projectSourceGitCredentials: ProjectSourceGitCredentials

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
        let providers: [ProviderKind: String] = [
            .codex: environment["REPOPROMPT_CODEX_EXECUTABLE"] ?? "/opt/repoprompt/providers/codex",
            .claudeCompatible: environment["REPOPROMPT_CLAUDE_EXECUTABLE"] ?? "/opt/repoprompt/providers/claude",
            .openCodeACP: environment["REPOPROMPT_OPENCODE_EXECUTABLE"] ?? "/opt/repoprompt/providers/opencode",
            .cursorACP: environment["REPOPROMPT_CURSOR_EXECUTABLE"] ?? "/opt/repoprompt/providers/cursor-agent"
        ]
        let enabledProviderNames = if let configured = environment["REPOPROMPT_ENABLED_PROVIDERS"] {
            configured
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            [ProviderKind.codex.rawValue, ProviderKind.claudeCompatible.rawValue]
        }
        var enabledProviders = Set<ProviderKind>()
        for name in enabledProviderNames {
            guard let kind = ProviderKind(rawValue: name), providers[kind] != nil else {
                throw ConfigurationError.invalid("REPOPROMPT_ENABLED_PROVIDERS contains an unknown or non-catalogued provider: \(name)")
            }
            enabledProviders.insert(kind)
        }
        let allowedDirectProviders = Set([
            ProviderSettingsID.openAIAPI,
            .anthropicAPI,
            .openRouter,
            .customOpenAICompatible
        ])
        let enabledDirectProviderNames = environment["REPOPROMPT_ENABLED_DIRECT_PROVIDERS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        var enabledDirectProviders = Set<ProviderSettingsID>()
        for name in enabledDirectProviderNames where !name.isEmpty {
            guard let providerID = ProviderSettingsID(rawValue: name), allowedDirectProviders.contains(providerID) else {
                throw ConfigurationError.invalid("REPOPROMPT_ENABLED_DIRECT_PROVIDERS contains an unknown or prohibited provider: \(name)")
            }
            enabledDirectProviders.insert(providerID)
        }
        let versions: [ProviderKind: String] = [.codex: CodexCLIContract.pinnedVersion, .claudeCompatible: "2.1.226", .openCodeACP: "1.15.11", .cursorACP: "2026.08.04-aaa8809"]
        let protocols: [ProviderKind: String] = [.codex: "app-server-v2", .claudeCompatible: "stream-json-v1", .openCodeACP: "acp-v1", .cursorACP: "acp-v1-beta"]
        if environment["REPOPROMPT_CODEX_CREDENTIAL_HOME"].map({ !$0.isEmpty }) == true
            || environment["REPOPROMPT_CODEX_AUTH_STATUS_FILE"].map({ !$0.isEmpty }) == true
        {
            throw ConfigurationError.invalid("Codex authentication must use the server-managed provider state")
        }
        let credentialSources = [
            (ProviderKind.claudeCompatible, environment["REPOPROMPT_CLAUDE_CREDENTIAL_HOME"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_CREDENTIAL_HOME"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_CREDENTIAL_HOME"])
        ].reduce(into: [ProviderKind: String]()) { result, value in if let path = value.1, !path.isEmpty { result[value.0] = path } }
        func optionalAbsoluteFiles(_ values: [(ProviderSettingsID, String?)], label: String) throws -> [ProviderSettingsID: String] {
            try values.reduce(into: [:]) { result, value in
                guard let path = value.1, !path.isEmpty else { return }
                guard path.hasPrefix("/") else { throw ConfigurationError.invalid("\(label) paths must be absolute") }
                result[value.0] = path
            }
        }
        let authenticationStatusFiles = try optionalAbsoluteFiles([
            (.claudeCompatible, environment["REPOPROMPT_CLAUDE_AUTH_STATUS_FILE"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_AUTH_STATUS_FILE"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_AUTH_STATUS_FILE"]),
            (.xAI, environment["REPOPROMPT_XAI_AUTH_STATUS_FILE"])
        ], label: "Provider authentication status")
        let modelCatalogFiles = try optionalAbsoluteFiles([
            (.codex, environment["REPOPROMPT_CODEX_MODEL_CATALOG_FILE"]),
            (.claudeCompatible, environment["REPOPROMPT_CLAUDE_MODEL_CATALOG_FILE"]),
            (.openCodeACP, environment["REPOPROMPT_OPENCODE_MODEL_CATALOG_FILE"]),
            (.cursorACP, environment["REPOPROMPT_CURSOR_MODEL_CATALOG_FILE"]),
            (.xAI, environment["REPOPROMPT_XAI_MODEL_CATALOG_FILE"])
        ], label: "Provider model catalog")
        let stateDatabase = environment["REPOPROMPT_STATE_DB"] ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        let vaultKey: ProviderVaultKey?
        if let keyFile = environment["REPOPROMPT_PROVIDER_VAULT_MASTER_KEY_FILE"], !keyFile.isEmpty {
            guard keyFile.hasPrefix("/") else { throw ConfigurationError.invalid("Provider vault master key path must be absolute") }
            vaultKey = try ProviderVaultKey.load(keyID: environment["REPOPROMPT_PROVIDER_VAULT_KEY_ID"] ?? "provider-vault-v1", filePath: keyFile)
        } else {
            vaultKey = nil
        }
        let previousVaultKeyID = environment["REPOPROMPT_PROVIDER_VAULT_PREVIOUS_KEY_ID"]
        let previousVaultKeyFile = environment["REPOPROMPT_PROVIDER_VAULT_PREVIOUS_MASTER_KEY_FILE"]
        guard (previousVaultKeyID == nil) == (previousVaultKeyFile == nil) else {
            throw ConfigurationError.invalid("Provider vault previous key ID and master key file must be configured together")
        }
        let previousVaultKeys: [ProviderVaultKey]
        if let previousVaultKeyID, let previousVaultKeyFile {
            guard !previousVaultKeyID.isEmpty,
                  previousVaultKeyFile.hasPrefix("/"),
                  let vaultKey,
                  previousVaultKeyID != vaultKey.keyID
            else {
                throw ConfigurationError.invalid("Provider vault previous key requires a distinct active key and an absolute key path")
            }
            previousVaultKeys = try [ProviderVaultKey.load(keyID: previousVaultKeyID, filePath: previousVaultKeyFile)]
        } else {
            previousVaultKeys = []
        }
        if !enabledDirectProviders.isEmpty, vaultKey == nil {
            throw ConfigurationError.invalid("Deployment-admitted direct providers require a provider vault master key")
        }
        let vaultFilePath = environment["REPOPROMPT_PROVIDER_VAULT_FILE"] ?? URL(fileURLWithPath: stateDatabase).deletingLastPathComponent().appendingPathComponent("provider-credentials.vault").path
        guard vaultFilePath.hasPrefix("/") else {
            throw ConfigurationError.invalid("Provider vault path must be absolute")
        }
        let projectSourcePolicy: ProjectSourcePolicy
        if let path = environment["REPOPROMPT_PROJECT_SOURCE_POLICY_FILE"], !path.isEmpty {
            guard path.hasPrefix("/") else { throw ConfigurationError.invalid("Project source policy path must be absolute") }
            projectSourcePolicy = try ProjectSourcePolicy.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            projectSourcePolicy = .disabled
        }
        let projectSourceGitCredentials = try ProjectSourceGitCredentials(
            sshPrivateKeyPath: environment["REPOPROMPT_GIT_SSH_KEY_FILE"],
            sshKnownHostsPath: environment["REPOPROMPT_GIT_KNOWN_HOSTS_FILE"]
        )
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
            enabledProviders: enabledProviders,
            enabledDirectProviders: enabledDirectProviders,
            providerVersions: versions,
            providerProtocols: protocols,
            providerCredentialSources: credentialSources,
            providerAuthenticationStatusFiles: authenticationStatusFiles,
            providerModelCatalogFiles: modelCatalogFiles,
            providerVaultKey: vaultKey,
            providerVaultDecryptionKeys: previousVaultKeys,
            providerVaultFilePath: vaultFilePath,
            minimumFreeBytes: Int64(environment["REPOPROMPT_MINIMUM_FREE_BYTES"] ?? "268435456") ?? 268_435_456,
            minimumFreeNodes: Int64(environment["REPOPROMPT_MINIMUM_FREE_NODES"] ?? "1024") ?? 1024,
            maximumActiveSessions: Int(environment["REPOPROMPT_MAX_ACTIVE_SESSIONS"] ?? "64") ?? 64,
            restoreActivationTokenPath: environment["REPOPROMPT_RESTORE_ACTIVATION_TOKEN_FILE"],
            projectSourcePolicy: projectSourcePolicy,
            projectSourceGitCredentials: projectSourceGitCredentials
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

private struct RestoreActivationRequest: Decodable {
    let schemaVersion: Int
    let acknowledged: Bool
    let restoredFromStoreID: UUID
    let backupSequence: Int64
    let backupCreatedAt: String
    let backupManifestSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, acknowledged, backupSequence, backupCreatedAt
        case restoredFromStoreID = "restoredFromStoreId"
        case backupManifestSHA256 = "backupManifestSha256"
    }
}

public enum RepoPromptServerRunner {
    /// Shared by the executable composition root and authenticated HTTP contract tests.
    /// Keeping this seam here prevents tests from silently assembling a different catalog authority.
    public static func composeAgentCatalog(
        providerSettings: ProviderSettingsService,
        store: SQLiteServiceStore,
        workflows: [AgentComposerWorkflowDescriptor],
        suggestions: [ComposerSuggestionDescriptor],
        emptyState: AgentEmptyStateDescriptor,
        providerProfileLoader: (@Sendable (ProviderSettingsID) async throws -> AgentCatalogProviderProfile)? = nil,
        composeModelLoader: (@Sendable () async throws -> String?)? = nil
    ) -> any AgentComposerCatalogProviding {
        AgentComposerCatalogService(
            providerSettings: providerSettings,
            store: store,
            workflows: workflows,
            suggestions: suggestions,
            emptyState: emptyState,
            providerProfileLoader: providerProfileLoader,
            composeModelLoader: composeModelLoader
        )
    }

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
            guard token.count >= 32 else { throw ServiceAPIError(code: .invalidRequest, message: "Restore activation token must contain at least 256 bits") }
            let requestURL = URL(fileURLWithPath: stateDirectory).appendingPathComponent("restore-request.json")
            var metadata = try await store.metadata()
            if metadata.activationState == "active", FileManager.default.fileExists(atPath: requestURL.path) {
                let request = try JSONDecoder.serviceDecoder.decode(RestoreActivationRequest.self, from: Data(contentsOf: requestURL))
                guard request.schemaVersion == 1, request.acknowledged,
                      request.restoredFromStoreID == metadata.storeID,
                      request.backupSequence >= 0,
                      request.backupCreatedAt.utf8.count <= 128,
                      request.backupManifestSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                else { throw ServiceAPIError(code: .invalidRequest, message: "Restore activation request is invalid or does not match this store") }
                _ = try await store.prepareRestoredStore(
                    from: request.restoredFromStoreID,
                    backupSequence: request.backupSequence,
                    digest: request.backupManifestSHA256,
                    activationToken: token
                )
                metadata = try await store.metadata()
            }
            if metadata.activationState == "restore_prepared" {
                _ = try await store.activateRestoredStore(activationToken: token, instanceID: instanceID)
                if FileManager.default.fileExists(atPath: requestURL.path) {
                    try FileManager.default.removeItem(at: requestURL)
                }
            } else if metadata.activationState != "active" {
                throw ServiceAPIError(code: .quiescing, message: "Restored store requires activation fencing")
            }
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
        let projectSources = try ProjectSourceProvisioningService(
            cloneRoot: configuration.projectDirectory,
            policy: configuration.projectSourcePolicy,
            credentials: configuration.projectSourceGitCredentials,
            resources: store
        )
        let reconciler = try OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: configuration.artifactDirectory,
            worktreeRoot: configuration.worktreeDirectory,
            providerHomeRoot: configuration.providerHomeDirectory,
            providerOutputRoot: processOutput,
            projectRoot: configuration.projectDirectory
        )
        _ = try await reconciler.reconcileStartup()
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
        if FileManager.default.fileExists(atPath: configuration.providerVaultFilePath), configuration.providerVaultKey == nil {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider credential vault exists but no master key is configured", retryable: false)
        }
        let providerVault = try configuration.providerVaultKey.map {
            try ProviderCredentialVault(
                fileURL: URL(fileURLWithPath: configuration.providerVaultFilePath),
                activeKey: $0,
                decryptionKeys: configuration.providerVaultDecryptionKeys
            )
        }
        let managedCodexHome = try CodexManagedAuthHome(
            rootPath: URL(fileURLWithPath: stateDirectory, isDirectory: true)
                .appendingPathComponent("provider-auth/codex", isDirectory: true).path
        )
        let codexAuthentication = CodexDeviceAuthDriver(
            executable: configuration.providerExecutables[.codex] ?? "",
            expectedVersion: configuration.providerVersions[.codex] ?? CodexCLIContract.pinnedVersion,
            managedHome: managedCodexHome,
            processPort: processPort,
            processStore: store,
            outputDirectory: processOutput
        )
        let portalDesktopSettings = PortalDesktopSettingsService(store: store)
        let directTransport = try ValidatedProviderEgressTransport()
        let directProviderRegistry = DirectProviderRegistry(
            store: store,
            transport: directTransport,
            deploymentAllowlist: configuration.enabledDirectProviders
        )
        try await directProviderRegistry.bootstrap()
        let directCredentialAccessor = VaultDirectProviderCredentialAccessor(store: store, vault: providerVault)
        let directRuntimes: [ProviderSettingsID: any AgentProviderRuntime] = Dictionary(uniqueKeysWithValues:
            configuration.enabledDirectProviders.map { providerID in
                (
                    providerID,
                    DirectAPIProviderRuntime(
                        providerID: providerID,
                        registry: directProviderRegistry,
                        credentials: directCredentialAccessor,
                        transport: directTransport
                    ) as any AgentProviderRuntime
                )
            }
        )
        let credentialEnvironment = VaultProviderProcessEnvironment(
            store: store,
            vault: providerVault,
            externallyProvisionedKinds: Set(configuration.providerCredentialSources.keys),
            credentialSourceDirectories: configuration.providerCredentialSources,
            managedCodexCredentialSource: managedCodexHome.credentialSourceDirectory,
            managedCodexRuntimeHome: managedCodexHome,
            backendSettings: portalDesktopSettings
        )
        let providers = ProviderCLIAdapter(
            configurations: providerConfigurations,
            enabledProviders: configuration.enabledProviders,
            exactRuntimes: directRuntimes,
            enabledExactProviders: configuration.enabledDirectProviders,
            processPort: processPort,
            processStore: store,
            outputDirectory: processOutput,
            ephemeralHomeRoot: configuration.providerHomeDirectory,
            credentialEnvironment: credentialEnvironment,
            credentialSource: credentialEnvironment
        )
        let credentialTester = CompositeProviderCredentialTester(
            cli: ProviderAuthenticationAdapter(configurations: providerConfigurations, backendSettings: portalDesktopSettings),
            direct: DirectProviderCredentialTester(registry: directProviderRegistry, transport: directTransport)
        )
        let providerSettings = ProviderSettingsService(
            store: store,
            adapter: providers,
            configurations: providerConfigurations,
            initiallyEnabled: configuration.enabledProviders,
            authenticationStatusFiles: configuration.providerAuthenticationStatusFiles,
            modelCatalogFiles: configuration.providerModelCatalogFiles,
            authFlows: TransientProviderAuthFlowCoordinator(driver: codexAuthentication),
            managedAuthentication: codexAuthentication,
            vault: providerVault,
            credentialTester: credentialTester,
            directProviderRegistry: directProviderRegistry,
            directProviderAllowlist: configuration.enabledDirectProviders
        )
        try await providers.recoverProcessFamilies()
        let activeProviderRunIDs = Set(try await store.activeProcessFamilies().map(\.runID))
        _ = await reconciler.reconcileProviderResourcesAfterProcessRecovery(
            activeRunIDs: activeProviderRunIDs
        )
        try await providerSettings.bootstrap()
        let serverSettings = ServerSettingsService(
            store: store,
            providerCatalog: providerSettings,
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: worktrees,
            artifactService: artifacts,
            providerAdapter: providers,
            projectSourceService: projectSources,
            serverSettings: serverSettings,
            directProviderDefaults: portalDesktopSettings
        )
        try await authority.recover()
        let composerWorkflows: [AgentComposerWorkflowDescriptor] = []
        let composerSuggestions: [ComposerSuggestionDescriptor] = [
            .init(kind: .nativeCommand, id: "compact", insertionText: "/compact", displayName: "Compact context", detailText: "Ask Codex to compact the current context.", providerIDs: [.codex], expansion: "/compact")
        ]
        let composerCatalog = composeAgentCatalog(
            providerSettings: providerSettings,
            store: store,
            workflows: composerWorkflows,
            suggestions: composerSuggestions,
            emptyState: .init(featuredWorkflowIDs: [], tips: ["Tag a file to add its current contents to only this turn.", "Choose a concrete model before sending.", "Use Shift+Return to add a new line."]),
            providerProfileLoader: { providerID in
                try await portalDesktopSettings.composerCatalogProfile(for: providerID)
            },
            composeModelLoader: {
                try await serverSettings.agentModels().effectiveProfile.resolvedComposeModelRaw()
            }
        )
        let composerAttachments = try AgentComposerAttachmentStore(
            store: store,
            configuration: .init(acceptedRoot: URL(fileURLWithPath: stateDirectory, isDirectory: true).appendingPathComponent("agent-attachments/accepted", isDirectory: true).path)
        )
        try await composerAttachments.recover()
        let turnCompiler = AgentTurnIntentCompiler(taggedFiles: AuthorityAgentTurnTaggedFileResolver(authority: authority), suggestions: StaticAgentTurnSuggestionResolver(descriptors: composerSuggestions))
        let submissionCoordinator = AgentSubmissionCoordinator(store: store, catalog: composerCatalog, compiler: turnCompiler, attachments: composerAttachments)
        let transcriptPresentation = AgentTranscriptPresentationService(store: store)
        for pending in try await submissionCoordinator.recover() {
            do {
                let accepted = try await submissionCoordinator.acceptedForRecovery(pending)
                let actor = ExternalActor(goblinUserID: pending.actorID, username: "recovered-submission", displayName: "Recovered submission")
                try await authority.dispatchAcceptedFollowup(accepted, actor: actor, requestDigest: pending.requestDigest)
                try await submissionCoordinator.markDispatched(submissionID: pending.submissionID)
            } catch {
                try? await submissionCoordinator.markLaunchFailed(submissionID: pending.submissionID, message: "Accepted provider dispatch recovery failed")
            }
        }

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
            requiredProviders: configuration.enabledProviders,
            expectedProviderProtocols: configuration.providerProtocols,
            minimumFreeBytes: configuration.minimumFreeBytes,
            minimumFreeNodes: configuration.minimumFreeNodes,
            maximumActiveSessions: configuration.maximumActiveSessions,
            drainController: drainController,
            trustConfigurationValid: true,
            providerSettings: providerSettings
        )
        let service = RepoPromptHTTPService(
            authority: authority,
            store: store,
            authenticator: authenticator,
            eventSigningKey: configuration.eventSigningKey,
            certificateRoleResolver: certificateRoles,
            readiness: readiness,
            drainController: drainController,
            durabilityOperations: durabilityOperations,
            providerSettings: providerSettings,
            serverSettings: serverSettings,
            composerCatalog: composerCatalog,
            composerAttachments: composerAttachments,
            submissionCoordinator: submissionCoordinator,
            transcriptPresentation: transcriptPresentation,
            portalDesktopSettings: portalDesktopSettings
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
        let mcpAdapter = RepoPromptMCPAdapter(authority: authority)
        let mcpSocketURL = URL(
            fileURLWithPath: CodexRepoPromptMCPConfig.socketPath(),
            isDirectory: false
        )
        let mcpSocketServer = HeadlessMCPSocketServer(socketURL: mcpSocketURL, adapter: mcpAdapter)
        if FileManager.default.fileExists(atPath: mcpSocketURL.deletingLastPathComponent().path) {
            do {
                try await mcpSocketServer.start()
            } catch {
                await durabilityOperations.stop()
                throw error
            }
        }

        var serviceError: Error?
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await internalApplication.runService() }
                group.addTask { try await healthApplication.runService() }
                _ = try await group.next()
                let drain = await drainController.drain(timeout: 15)
                await mcpSocketServer.stop()
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
            await mcpSocketServer.stop()
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
