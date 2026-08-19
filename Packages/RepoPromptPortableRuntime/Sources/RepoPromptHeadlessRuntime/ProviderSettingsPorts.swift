import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptRuntimeModel

public struct ProviderCLIConfiguration: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let executable: String
    public let expectedVersion: String?
    public let protocolVersion: String?
    public let credentialSourceDirectory: String?

    public init(
        kind: ProviderKind,
        executable: String,
        expectedVersion: String? = nil,
        protocolVersion: String? = nil,
        credentialSourceDirectory: String? = nil
    ) {
        self.kind = kind
        self.executable = executable
        self.expectedVersion = expectedVersion
        self.protocolVersion = protocolVersion
        self.credentialSourceDirectory = credentialSourceDirectory
    }
}

public protocol ProviderRuntimeSettingsAdapting: Sendable {
    func preflight(kind: ProviderKind) async -> ProviderCapability
    func applyRuntimeDefaults(
        kind: ProviderKind,
        defaults: ProviderRuntimeDefaults
    ) async throws
    func applyRuntimeDefaults(
        providerID: ProviderSettingsID,
        defaults: ProviderRuntimeDefaults
    ) async throws
}

public protocol ProviderCredentialVaulting: Sendable {
    func load(providerID: ProviderSettingsID, connectionID: UUID) async throws -> Data
    func store(secret: Data, providerID: ProviderSettingsID, connectionID: UUID) async throws
    func delete(providerID: ProviderSettingsID, connectionID: UUID) async throws
    func rotateToActiveKeyIfNeeded() async throws
    func reconcile(references: [ProviderSettingsID: UUID]) async throws
}

public protocol ProviderCredentialTesting: Sendable {
    func supportedAuthenticationMethods(
        for providerID: ProviderSettingsID
    ) async -> Set<ProviderAuthenticationMethod>
    func test(
        providerID: ProviderSettingsID,
        method: ProviderAuthenticationMethod,
        secret: Data?
    ) async -> ProviderCredentialTestResult
    func logout(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod) async
}

public struct UnavailableProviderCredentialTester: ProviderCredentialTesting {
    public init() {}

    public func supportedAuthenticationMethods(
        for _: ProviderSettingsID
    ) async -> Set<ProviderAuthenticationMethod> {
        []
    }

    public func test(
        providerID _: ProviderSettingsID,
        method _: ProviderAuthenticationMethod,
        secret _: Data?
    ) async -> ProviderCredentialTestResult {
        .init(state: .unavailable, detail: "Credential validation adapter is unavailable")
    }

    public func logout(
        providerID _: ProviderSettingsID,
        method _: ProviderAuthenticationMethod
    ) async {}
}

public struct ProviderManagedAccountSummary: Sendable, Equatable {
    public let account: String
    public let plan: String
    public let authentication: String

    public init(account: String, plan: String, authentication: String) {
        self.account = account
        self.plan = plan
        self.authentication = authentication
    }
}

public enum ProviderManagedAuthenticationState: Sendable, Equatable {
    case authenticated(accountLabel: String?)
    case notAuthenticated
    case unavailable
}

public protocol ProviderManagedAuthenticationDriving: Sendable {
    func authFlowDescriptor(
        providerID: ProviderSettingsID,
        forceRefresh: Bool
    ) async -> ProviderAuthFlowDescriptor?
    func authenticationState(
        providerID: ProviderSettingsID
    ) async -> ProviderManagedAuthenticationState
    func accountSummary(
        providerID: ProviderSettingsID
    ) async -> ProviderManagedAccountSummary?
    func discoverModelCatalog(
        providerID: ProviderSettingsID,
        forceRefresh: Bool
    ) async throws -> [ProviderModelCatalogEntry]?
    func logout(providerID: ProviderSettingsID) async throws
}

public extension ProviderManagedAuthenticationDriving {
    func accountSummary(
        providerID _: ProviderSettingsID
    ) async -> ProviderManagedAccountSummary? {
        nil
    }

    func discoverModelCatalog(
        providerID _: ProviderSettingsID,
        forceRefresh _: Bool
    ) async throws -> [ProviderModelCatalogEntry]? {
        nil
    }
}

public struct UnavailableProviderManagedAuthenticationDriver:
    ProviderManagedAuthenticationDriving
{
    public init() {}

    public func authFlowDescriptor(
        providerID _: ProviderSettingsID,
        forceRefresh _: Bool
    ) async -> ProviderAuthFlowDescriptor? {
        nil
    }

    public func authenticationState(
        providerID _: ProviderSettingsID
    ) async -> ProviderManagedAuthenticationState {
        .unavailable
    }

    public func logout(providerID _: ProviderSettingsID) async throws {
        throw ServiceAPIError(
            code: .capabilityMissing,
            message: "Managed provider authentication is unavailable"
        )
    }
}

public protocol DirectProviderSettingsProviding: Sendable {
    func configuration(
        for providerID: ProviderSettingsID
    ) async throws -> DirectProviderConfiguration
    func update(
        providerID: ProviderSettingsID,
        request: UpdateDirectProviderConfigurationRequest,
        attribution: ProviderMutationAttribution
    ) async throws -> DirectProviderConfiguration
}

/// Probe homes are isolated from operator credentials and update state. This is
/// portable settings health behavior, not private-helper launch resolution.
enum ProviderCLIProbeEnvironment {
    static func prepare(for kind: ProviderKind) throws -> [String: String] {
        let manager = FileManager.default
        let home = manager.temporaryDirectory
            .appendingPathComponent("repoprompt-provider-probes", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
        let config = home.appendingPathComponent(".config", isDirectory: true)
        let cache = home.appendingPathComponent(".cache", isDirectory: true)
        let data = home.appendingPathComponent(".local/share", isDirectory: true)
        for directory in [home, config, cache, data] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return [
            "HOME": home.path,
            "XDG_CONFIG_HOME": config.path,
            "XDG_CACHE_HOME": cache.path,
            "XDG_DATA_HOME": data.path,
            "DISABLE_AUTOUPDATER": "1",
            "CURSOR_AGENT_DISABLE_AUTO_UPDATE": "1"
        ]
    }
}
