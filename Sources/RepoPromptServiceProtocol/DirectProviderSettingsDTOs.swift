import Foundation

public enum DirectProviderContentTypePolicy: String, Codable, CaseIterable, Sendable {
    case applicationJSON
}

/// Revisioned, non-secret configuration for a direct HTTPS provider. Fixed-host
/// providers keep `baseURL == nil`; only the custom OpenAI-compatible provider
/// may persist a deployment-validated public HTTPS base URL.
public struct DirectProviderConfiguration: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let baseURL: String?
    public let preferredModel: String?
    public let maximumOutputTokens: Int
    public let customHeaders: [String: String]
    public let contentTypePolicy: DirectProviderContentTypePolicy
    public let revision: Int64
    public let updatedAt: Date

    public init(
        providerID: ProviderSettingsID,
        baseURL: String? = nil,
        preferredModel: String? = nil,
        maximumOutputTokens: Int = 4096,
        customHeaders: [String: String] = [:],
        contentTypePolicy: DirectProviderContentTypePolicy = .applicationJSON,
        revision: Int64 = 1,
        updatedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.preferredModel = preferredModel
        self.maximumOutputTokens = maximumOutputTokens
        self.customHeaders = customHeaders
        self.contentTypePolicy = contentTypePolicy
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

/// Full replacement avoids omitted-versus-null ambiguity. Credential material
/// is intentionally absent and is accepted only by `ConnectProviderRequest`.
public struct UpdateDirectProviderConfigurationRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let baseURL: String?
    public let preferredModel: String?
    public let maximumOutputTokens: Int
    public let customHeaders: [String: String]
    public let contentTypePolicy: DirectProviderContentTypePolicy

    public init(
        expectedRevision: Int64,
        baseURL: String?,
        preferredModel: String?,
        maximumOutputTokens: Int,
        customHeaders: [String: String],
        contentTypePolicy: DirectProviderContentTypePolicy = .applicationJSON
    ) {
        self.expectedRevision = expectedRevision
        self.baseURL = baseURL
        self.preferredModel = preferredModel
        self.maximumOutputTokens = maximumOutputTokens
        self.customHeaders = customHeaders
        self.contentTypePolicy = contentTypePolicy
    }
}

public struct ProviderModelCatalogSnapshot: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let models: [ProviderModelCatalogEntry]
    public let revision: Int64
    public let refreshedAt: Date

    public init(providerID: ProviderSettingsID, models: [ProviderModelCatalogEntry], revision: Int64, refreshedAt: Date = Date()) {
        self.providerID = providerID
        self.models = models
        self.revision = revision
        self.refreshedAt = refreshedAt
    }
}

public struct DirectProviderEndpoint: Codable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public let basePath: String

    public init(scheme: String, host: String, port: Int, basePath: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.basePath = basePath
    }
}
