import Foundation

/// Stable identifiers for the server-owned provider settings surface. CLI
/// providers map to `ProviderKind`; API-only providers remain catalog entries
/// until a portable runtime is available.
public enum ProviderSettingsID: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCompatible
    case openCodeACP
    case cursorACP
    case xAI

    public var runtimeKind: ProviderKind? {
        switch self {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .xAI: nil
        }
    }
}

public enum ProviderSettingsCategory: String, Codable, Sendable {
    case cliProvider
    case apiProvider
}

public enum ProviderAuthenticationState: String, Codable, Sendable {
    case authenticated
    case attention
    case notConfigured
    case unknown
}

public enum ProviderAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case browserOAuth
    case deviceCodeBeta
    case apiKey
    case enterpriseAccessToken
    case authToken
    case keyHelper
    case workloadIdentityFederation
    case browserLogin
    case providerSpecific
}

public enum ProviderAuthFlowKind: String, Codable, Sendable {
    case browserOAuth
    case deviceCodeBeta
    case externalProvisioning
}

public struct ProviderAuthFlowDescriptor: Codable, Hashable, Sendable {
    public let kind: ProviderAuthFlowKind
    public let displayName: String
    public let startable: Bool
    public let detail: String

    public init(kind: ProviderAuthFlowKind, displayName: String, startable: Bool, detail: String) {
        self.kind = kind
        self.displayName = displayName
        self.startable = startable
        self.detail = detail
    }
}

public struct StartProviderAuthFlowRequest: Codable, Hashable, Sendable {
    public let kind: ProviderAuthFlowKind

    public init(kind: ProviderAuthFlowKind) {
        self.kind = kind
    }
}

/// A deliberately narrow, no-store challenge. Device codes are the only
/// credential-like value permitted and must be shown only to the initiating
/// authenticated administrator for the response lifetime.
public struct ProviderAuthFlowChallenge: Codable, Hashable, Sendable {
    public let flowID: UUID
    public let kind: ProviderAuthFlowKind
    public let userCode: String?
    public let expiresAt: Date

    public init(flowID: UUID, kind: ProviderAuthFlowKind, userCode: String?, expiresAt: Date) {
        self.flowID = flowID
        self.kind = kind
        self.userCode = userCode
        self.expiresAt = expiresAt
    }
}

/// Browser-safe authentication projection. It intentionally has no generic
/// metadata bag, credential path, provider response, or token-shaped field.
public struct ProviderAuthenticationStatus: Codable, Hashable, Sendable {
    public let state: ProviderAuthenticationState
    public let authenticated: Bool
    public let method: ProviderAuthenticationMethod?
    public let accountLabel: String?
    public let planLabel: String?
    public let authenticationLabel: String?
    public let expiresAt: Date?
    public let detail: String?

    public init(state: ProviderAuthenticationState, authenticated: Bool, method: ProviderAuthenticationMethod? = nil, accountLabel: String? = nil, planLabel: String? = nil, authenticationLabel: String? = nil, expiresAt: Date? = nil, detail: String? = nil) {
        self.state = state
        self.authenticated = authenticated
        self.method = method
        self.accountLabel = accountLabel
        self.planLabel = planLabel
        self.authenticationLabel = authenticationLabel
        self.expiresAt = expiresAt
        self.detail = detail
    }
}

public struct ProviderCLIHealth: Codable, Hashable, Sendable {
    public let installed: Bool
    public let healthy: Bool
    public let version: String?
    public let expectedVersion: String?
    public let detail: String?

    public init(installed: Bool, healthy: Bool, version: String? = nil, expectedVersion: String? = nil, detail: String? = nil) {
        self.installed = installed
        self.healthy = healthy
        self.version = version
        self.expectedVersion = expectedVersion
        self.detail = detail
    }
}

public struct ProviderModelCatalogEntry: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let isProviderDefault: Bool
    public let reasoningEfforts: [String]
    public let speedModes: [String]
    public let serviceTiers: [String]

    public init(id: String, displayName: String, description: String? = nil, isProviderDefault: Bool = false, reasoningEfforts: [String] = [], speedModes: [String] = [], serviceTiers: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isProviderDefault = isProviderDefault
        self.reasoningEfforts = reasoningEfforts
        self.speedModes = speedModes
        self.serviceTiers = serviceTiers
    }
}

public struct ProviderSettingsCapabilities: Codable, Hashable, Sendable {
    public let supportsModelSelection: Bool
    public let supportsReasoningEffort: Bool
    public let supportsSpeedMode: Bool
    public let supportsServiceTier: Bool
    public let authenticationMethods: [ProviderAuthenticationMethod]
    public let authFlows: [ProviderAuthFlowDescriptor]

    public init(supportsModelSelection: Bool, supportsReasoningEffort: Bool, supportsSpeedMode: Bool, supportsServiceTier: Bool, authenticationMethods: [ProviderAuthenticationMethod], authFlows: [ProviderAuthFlowDescriptor]) {
        self.supportsModelSelection = supportsModelSelection
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsSpeedMode = supportsSpeedMode
        self.supportsServiceTier = supportsServiceTier
        self.authenticationMethods = authenticationMethods
        self.authFlows = authFlows
    }
}

/// Non-secret, revisioned defaults applied by the Swift provider dispatcher.
public struct ProviderSettingsPreference: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let enabled: Bool
    public let defaultModel: String?
    public let reasoningEffort: String?
    public let speedMode: String?
    public let serviceTier: String?
    public let revision: Int64

    public init(providerID: ProviderSettingsID, enabled: Bool, defaultModel: String? = nil, reasoningEffort: String? = nil, speedMode: String? = nil, serviceTier: String? = nil, revision: Int64 = 1) {
        self.providerID = providerID
        self.enabled = enabled
        self.defaultModel = defaultModel
        self.reasoningEffort = reasoningEffort
        self.speedMode = speedMode
        self.serviceTier = serviceTier
        self.revision = revision
    }
}

public struct ProviderSettingsSnapshot: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let displayName: String
    public let category: ProviderSettingsCategory
    public let summary: String
    public let deploymentAllowed: Bool
    public let runtimePreflightVerified: Bool
    public let effectiveEnabled: Bool
    public let preference: ProviderSettingsPreference
    public let cli: ProviderCLIHealth?
    public let authentication: ProviderAuthenticationStatus
    public let connection: ProviderConnectionRecord?
    public let preflight: ProviderPreflightStatus
    public let capabilities: ProviderSettingsCapabilities
    public let models: [ProviderModelCatalogEntry]

    public init(providerID: ProviderSettingsID, displayName: String, category: ProviderSettingsCategory, summary: String, deploymentAllowed: Bool, runtimePreflightVerified: Bool, effectiveEnabled: Bool, preference: ProviderSettingsPreference, cli: ProviderCLIHealth?, authentication: ProviderAuthenticationStatus, connection: ProviderConnectionRecord? = nil, preflight: ProviderPreflightStatus = .init(ready: false, reason: .runtimeUnavailable, detail: "Provider preflight has not run"), capabilities: ProviderSettingsCapabilities, models: [ProviderModelCatalogEntry]) {
        self.providerID = providerID
        self.displayName = displayName
        self.category = category
        self.summary = summary
        self.deploymentAllowed = deploymentAllowed
        self.runtimePreflightVerified = runtimePreflightVerified
        self.effectiveEnabled = effectiveEnabled
        self.preference = preference
        self.cli = cli
        self.authentication = authentication
        self.connection = connection
        self.preflight = preflight
        self.capabilities = capabilities
        self.models = models
    }
}

public struct ProviderSettingsCatalogResponse: Codable, Sendable {
    public let providers: [ProviderSettingsSnapshot]
    public let generatedAt: Date

    public init(providers: [ProviderSettingsSnapshot], generatedAt: Date = Date()) {
        self.providers = providers
        self.generatedAt = generatedAt
    }
}

/// Full replacement avoids ambiguous omitted-vs-null PATCH semantics.
public struct UpdateProviderSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let enabled: Bool
    public let defaultModel: String?
    public let reasoningEffort: String?
    public let speedMode: String?
    public let serviceTier: String?

    public init(expectedRevision: Int64, enabled: Bool, defaultModel: String?, reasoningEffort: String?, speedMode: String?, serviceTier: String?) {
        self.expectedRevision = expectedRevision
        self.enabled = enabled
        self.defaultModel = defaultModel
        self.reasoningEffort = reasoningEffort
        self.speedMode = speedMode
        self.serviceTier = serviceTier
    }
}
