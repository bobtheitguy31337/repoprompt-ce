import Foundation
import RepoPromptServiceProtocol
import SQLiteNIO

public struct StoredComposerProviderCatalog: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let models: [ProviderModelCatalogEntry]
    public let observedAt: Date

    public init(providerID: ProviderSettingsID, models: [ProviderModelCatalogEntry], observedAt: Date) {
        self.providerID = providerID
        self.models = models
        self.observedAt = observedAt
    }
}

public extension SQLiteServiceStore {
    func persistComposerProviderCatalog(_ record: StoredComposerProviderCatalog) async throws {
        let modelsJSON = String(decoding: try encoder.encode(record.models), as: UTF8.self)
        _ = try await connection.query(
            "INSERT INTO composer_provider_catalog_cache(provider_id,schema_version,models_json,observed_at) VALUES(?,1,?,?) ON CONFLICT(provider_id) DO UPDATE SET schema_version=excluded.schema_version,models_json=excluded.models_json,observed_at=excluded.observed_at",
            [.text(record.providerID.rawValue), .text(modelsJSON), .float(record.observedAt.timeIntervalSince1970)]
        )
    }

    func composerProviderCatalog(providerID: ProviderSettingsID) async throws -> StoredComposerProviderCatalog? {
        guard let row = try await connection.query("SELECT models_json,observed_at FROM composer_provider_catalog_cache WHERE provider_id=?", [.text(providerID.rawValue)]).first,
              let modelsJSON = row.column("models_json")?.string,
              let data = modelsJSON.data(using: .utf8)
        else { return nil }
        return .init(
            providerID: providerID,
            models: try decoder.decode([ProviderModelCatalogEntry].self, from: data),
            observedAt: Date(timeIntervalSince1970: row.column("observed_at")?.double ?? 0)
        )
    }
}
