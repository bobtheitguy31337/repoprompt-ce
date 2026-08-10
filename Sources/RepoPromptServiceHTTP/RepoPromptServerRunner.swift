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
        let app = try InternalSigningKey(keyID: environment["REPOPROMPT_GOBLIN_APP_KEY_ID"] ?? "goblin-app-v1", role: .goblinApp, direction: "goblin-app-to-repoprompt-v1", secret: secret("REPOPROMPT_GOBLIN_APP_HMAC_FILE"))
        let sync = try InternalSigningKey(keyID: environment["REPOPROMPT_GOBLIN_SYNC_KEY_ID"] ?? "goblin-sync-v1", role: .goblinSync, direction: "goblin-sync-to-repoprompt-v1", secret: secret("REPOPROMPT_GOBLIN_SYNC_HMAC_FILE"))
        let operatorKey = try InternalSigningKey(keyID: environment["REPOPROMPT_OPERATOR_KEY_ID"] ?? "repoprompt-operator-v1", role: .operatorRole, direction: "repoprompt-operator-to-repoprompt-v1", secret: secret("REPOPROMPT_OPERATOR_HMAC_FILE"))
        let event = try InternalSigningKey(keyID: environment["REPOPROMPT_EVENT_KEY_ID"] ?? "repoprompt-event-v1", role: .goblinSync, direction: "repoprompt-to-goblin-v1", secret: secret("REPOPROMPT_EVENT_HMAC_FILE"))
        let providers: [ProviderKind: String] = [
            .codex: environment["REPOPROMPT_CODEX_EXECUTABLE"] ?? "/opt/repoprompt/providers/codex",
            .claudeCompatible: environment["REPOPROMPT_CLAUDE_EXECUTABLE"] ?? "/opt/repoprompt/providers/claude",
            .openCodeACP: environment["REPOPROMPT_OPENCODE_EXECUTABLE"] ?? "/opt/repoprompt/providers/opencode",
            .cursorACP: environment["REPOPROMPT_CURSOR_EXECUTABLE"] ?? "/opt/repoprompt/providers/cursor-agent"
        ]
        return try Self(
            stateDatabasePath: environment["REPOPROMPT_STATE_DB"] ?? "/var/lib/repoprompt/state/repoprompt.sqlite",
            worktreeDirectory: environment["REPOPROMPT_WORKTREE_DIR"] ?? "/var/lib/repoprompt/worktrees",
            artifactDirectory: environment["REPOPROMPT_ARTIFACT_DIR"] ?? "/var/lib/repoprompt/artifacts",
            bindHost: environment["REPOPROMPT_BIND_HOST"] ?? "0.0.0.0", bindPort: Int(environment["REPOPROMPT_BIND_PORT"] ?? "9443") ?? 9443,
            healthHost: "127.0.0.1", healthPort: Int(environment["REPOPROMPT_HEALTH_PORT"] ?? "9080") ?? 9080,
            certificatePath: required("REPOPROMPT_TLS_CERT_FILE"), privateKeyPath: required("REPOPROMPT_TLS_KEY_FILE"), clientCAPath: required("REPOPROMPT_TLS_CLIENT_CA_FILE"),
            signingKeys: [app, sync, operatorKey], eventSigningKey: event,
            providerExecutables: providers
        )
    }
}

public enum ConfigurationError: Error, CustomStringConvertible { case missing(String)
    public var description: String {
        switch self { case let .missing(name): "Required configuration \(name) is missing" }
    }
}

public enum RepoPromptServerRunner {
    public static func run(configuration: RepoPromptServerConfiguration) async throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: configuration.stateDatabasePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .file(configuration.stateDatabasePath), eventSigningKey: ServiceEventSigningKey(keyID: configuration.eventSigningKey.keyID, secret: configuration.eventSigningKey.secret))
        let worktrees = try WorktreeRuntimeService(baseDirectory: configuration.worktreeDirectory)
        let artifacts = try ArtifactRuntimeService(baseDirectory: configuration.artifactDirectory)
        let processPort = try PortableProcessSupervisionPort()
        let processOutput = URL(fileURLWithPath: configuration.stateDatabasePath).deletingLastPathComponent().appendingPathComponent("provider-output").path
        let providers = ProviderCLIAdapter(configurations: configuration.providerExecutables.map { ProviderCLIConfiguration(kind: $0.key, executable: $0.value) }, processPort: processPort, outputDirectory: processOutput)
        let authority = RepoPromptHeadlessAuthority(store: store, worktreeService: worktrees, artifactService: artifacts, providerAdapter: providers)
        try await authority.recover()
        let authenticator = InternalRequestAuthenticator(keys: configuration.signingKeys, store: store)
        let certificateRoles = try CertificateIdentityRoleResolver.environment()
        let service = RepoPromptHTTPService(authority: authority, store: store, authenticator: authenticator, eventSigningKey: configuration.eventSigningKey, certificateRoleResolver: certificateRoles)
        let tls = try RepoPromptTLSConfiguration.mutualTLS13(certificatePath: configuration.certificatePath, privateKeyPath: configuration.privateKeyPath, trustRootsPath: configuration.clientCAPath)
        let internalApplication = try Application(router: service.internalRouter(), server: .tls(tlsConfiguration: tls), configuration: .init(address: .hostname(configuration.bindHost, port: configuration.bindPort), serverName: "RepoPromptServer"))
        let healthApplication = Application(router: service.healthRouter(), configuration: .init(address: .hostname(configuration.healthHost, port: configuration.healthPort), serverName: nil))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await internalApplication.runService() }
                group.addTask { try await healthApplication.runService() }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            try? await authority.quiesce()
            try? await store.close(clean: false)
            throw error
        }
        try await authority.quiesce()
        try await store.close(clean: true)
    }
}
