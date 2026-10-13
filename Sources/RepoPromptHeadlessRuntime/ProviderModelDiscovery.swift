import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol

/// Discovery uses the same isolated, authenticated runtime as execution, without
/// sending a prompt or granting filesystem/tool capabilities.
public protocol ProviderModelCatalogDiscovering: Sendable {
    func discoverModelCatalog(policy: ProviderExecutionPolicy) async throws -> [ProviderModelCatalogEntry]
}

enum ProviderModelDiscovery {
    static func claudeBackend(environment: [String: String], providerID: ProviderSettingsID) async throws -> [ProviderModelCatalogEntry]? {
        let baseURL = environment["ANTHROPIC_BASE_URL"]
        let key = environment["ANTHROPIC_API_KEY"]
        let token = environment["ANTHROPIC_AUTH_TOKEN"]
        guard baseURL != nil || key != nil else { return nil }
        let transport = try ValidatedProviderEgressTransport()
        let endpoint = try await transport.validateEndpoint(baseURL ?? "https://api.anthropic.com")
        let headers: [String: String]
        if [.claudeGLM, .claudeKimi].contains(providerID) {
            guard let credential = token ?? key else { throw invalidCatalog() }
            headers = ["Authorization": "Bearer \(credential)"]
        } else if let key {
            headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        } else if let token {
            headers = ["Authorization": "Bearer \(token)", "anthropic-version": "2023-06-01"]
        } else { throw invalidCatalog() }
        let base = endpoint.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let initialPath = providerID == .claudeGLM && endpoint.host == "api.z.ai"
            ? "/api/coding/paas/v4/models"
            : (base.isEmpty ? "/v1/models" : "/" + base + (base.hasSuffix("v1") ? "/models" : "/v1/models"))
        var path: String? = initialPath
        var visited = Set<String>()
        var models: [ProviderModelCatalogEntry] = []
        while let current = path {
            guard visited.insert(current).inserted, visited.count <= 10 else { throw invalidCatalog() }
            let response = try await transport.execute(.init(endpoint: endpoint, method: "GET", pathAndQuery: current, headers: headers, maximumResponseBodyBytes: 2 * 1024 * 1024, totalTimeout: .seconds(15)))
            guard (200 ..< 300).contains(response.statusCode) else { throw invalidCatalog() }
            models.append(contentsOf: try DirectProviderCredentialTester.parseCatalog(response: response, providerID: .anthropicAPI))
            guard models.count <= 500 else { throw invalidCatalog() }
            path = try DirectProviderCredentialTester.nextCatalogPage(response: response, initialPath: initialPath, endpoint: endpoint)
        }
        return try validated(models)
    }

    static func claude(_ response: Data) throws -> [ProviderModelCatalogEntry] {
        let object = try object(response)
        guard let models = object["models"] as? [[String: Any]] else { throw invalidCatalog() }
        return try validated(models.map { item in
            let id = try text(item["value"] ?? item["id"], maximumBytes: 256)
            let efforts = (item["supportedEffortLevels"] as? [String]) ?? []
            return try .init(
                id: id,
                providerRawValue: id,
                displayName: text(item["displayName"] ?? item["display_name"] ?? id, maximumBytes: 256),
                description: optionalText(item["description"], maximumBytes: 1024),
                isProviderDefault: item["isDefault"] as? Bool == true || id == "default",
                reasoningEfforts: efforts,
                supportsNativeImages: true,
                supportsSteering: true
            )
        })
    }

    static func acp(_ response: Data) throws -> [ProviderModelCatalogEntry] {
        let object = try object(response)
        let options = object["configOptions"] as? [[String: Any]] ?? []
        if let model = options.first(where: { ($0["category"] as? String) == "model" || ($0["id"] as? String) == "model" }) {
            let current = model["currentValue"] as? String
            return try validated(flatten(model["options"] as? [[String: Any]] ?? []).map { item in
                let id = try text(item["value"] ?? item["id"], maximumBytes: 256)
                return try .init(
                    id: id,
                    providerRawValue: id,
                    displayName: text(item["name"] ?? item["label"] ?? id, maximumBytes: 256),
                    description: optionalText(item["description"], maximumBytes: 1024),
                    isProviderDefault: id == current,
                    supportsNativeImages: false,
                    supportsSteering: true
                )
            })
        }
        guard let state = object["models"] as? [String: Any],
              let available = state["availableModels"] as? [[String: Any]]
        else { throw invalidCatalog() }
        let current = state["currentModelId"] as? String
        return try validated(available.map { item in
            let id = try text(item["modelId"], maximumBytes: 256)
            return try .init(
                id: id,
                providerRawValue: id,
                displayName: text(item["name"] ?? id, maximumBytes: 256),
                description: optionalText(item["description"], maximumBytes: 1024),
                isProviderDefault: id == current,
                supportsNativeImages: false,
                supportsSteering: true
            )
        })
    }

    static func codexPage(_ response: Data) throws -> (models: [ProviderModelCatalogEntry], cursor: String?) {
        let object = try object(response)
        guard let data = object["data"] as? [[String: Any]] else { throw invalidCatalog() }
        let models = try data.filter { $0["hidden"] as? Bool != true }.map { item in
            let id = try text(item["id"], maximumBytes: 256)
            let efforts = (item["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            return try ProviderModelCatalogEntry(
                id: id,
                providerRawValue: text(item["model"] ?? id, maximumBytes: 256),
                displayName: text(item["displayName"] ?? id, maximumBytes: 256),
                description: optionalText(item["description"], maximumBytes: 1024),
                isProviderDefault: item["isDefault"] as? Bool == true,
                reasoningEfforts: efforts,
                defaultReasoningEffort: item["defaultReasoningEffort"] as? String,
                supportsNativeImages: (item["inputModalities"] as? [String])?.contains("image") ?? true,
                supportsSteering: true
            )
        }
        return (models, object["nextCursor"] as? String)
    }

    static func validated(_ models: [ProviderModelCatalogEntry]) throws -> [ProviderModelCatalogEntry] {
        guard !models.isEmpty, models.count <= 500,
              Set(models.map { $0.id.lowercased() }).count == models.count
        else { throw invalidCatalog() }
        for model in models {
            for effort in model.reasoningEfforts { _ = try text(effort, maximumBytes: 128) }
        }
        return models
    }

    private static func flatten(_ options: [[String: Any]]) -> [[String: Any]] {
        options.flatMap { option in
            if let children = option["options"] as? [[String: Any]] { return flatten(children) }
            return [option]
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 2 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw invalidCatalog() }
        return object
    }

    private static func optionalText(_ value: Any?, maximumBytes: Int) throws -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return try text(value, maximumBytes: maximumBytes)
    }

    private static func text(_ value: Any?, maximumBytes: Int) throws -> String {
        guard let value = value as? String else { throw invalidCatalog() }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(text)
        else { throw invalidCatalog() }
        return text
    }

    private static func invalidCatalog() -> ServiceAPIError {
        .init(code: .dependencyUnavailable, message: "Provider did not advertise a valid model catalog")
    }
}
