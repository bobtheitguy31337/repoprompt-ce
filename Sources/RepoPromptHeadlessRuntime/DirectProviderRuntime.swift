import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public protocol DirectProviderConfigurationProviding: Sendable {
    func configuration(for providerID: ProviderSettingsID) async throws -> DirectProviderConfiguration
    func endpoint(for providerID: ProviderSettingsID) async throws -> DirectProviderEndpoint
    func isDeploymentAllowed(_ providerID: ProviderSettingsID) async -> Bool
}

public protocol DirectProviderCredentialAccessing: Sendable {
    func credential(for providerID: ProviderSettingsID) async throws -> Data
}

public actor VaultDirectProviderCredentialAccessor: DirectProviderCredentialAccessing {
    private let store: SQLiteServiceStore
    private let vault: ProviderCredentialVault?

    public init(store: SQLiteServiceStore, vault: ProviderCredentialVault?) {
        self.store = store
        self.vault = vault
    }

    public func credential(for providerID: ProviderSettingsID) async throws -> Data {
        guard providerID.isDirectAPI,
              let connection = try await store.providerConnection(providerID: providerID),
              connection.record.state == .connected,
              connection.record.testState == .valid,
              connection.record.expiresAt.map({ $0 > Date() }) ?? true,
              let reference = connection.credentialReference,
              let vault
        else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
        }
        let credential = try await vault.load(providerID: providerID, connectionID: reference)
        guard !credential.isEmpty, credential.count <= 65_536 else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
        }
        return credential
    }
}

public actor DirectProviderRegistry: DirectProviderConfigurationProviding {
    private let store: SQLiteServiceStore
    private let transport: any ValidatedProviderEgressTransporting
    private let deploymentAllowlist: Set<ProviderSettingsID>
    private var configurations: [ProviderSettingsID: DirectProviderConfiguration] = [:]

    public init(
        store: SQLiteServiceStore,
        transport: any ValidatedProviderEgressTransporting,
        deploymentAllowlist: Set<ProviderSettingsID>
    ) {
        self.store = store
        self.transport = transport
        self.deploymentAllowlist = Set(deploymentAllowlist.filter(\.isDirectAPI))
    }

    public func bootstrap() async throws {
        configurations = try await Dictionary(uniqueKeysWithValues: store.directProviderConfigurations().map { ($0.providerID, $0) })
        for providerID in [ProviderSettingsID.openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible] {
            if configurations[providerID] == nil {
                let initial = try Self.validateConfiguration(
                    providerID: providerID,
                    baseURL: nil,
                    preferredModel: nil,
                    maximumOutputTokens: 4096,
                    customHeaders: [:],
                    contentTypePolicy: .applicationJSON,
                    revision: 1,
                    updatedAt: Date()
                )
                configurations[providerID] = try await store.upsertDirectProviderConfiguration(initial, expectedRevision: 0)
            }
        }
    }

    public func isDeploymentAllowed(_ providerID: ProviderSettingsID) -> Bool {
        deploymentAllowlist.contains(providerID)
    }

    public func configuration(for providerID: ProviderSettingsID) throws -> DirectProviderConfiguration {
        guard deploymentAllowlist.contains(providerID), let configuration = configurations[providerID] else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider is not admitted by this deployment")
        }
        return configuration
    }

    public func endpoint(for providerID: ProviderSettingsID) async throws -> DirectProviderEndpoint {
        let configuration = try configuration(for: providerID)
        if providerID == .customOpenAICompatible {
            guard let baseURL = configuration.baseURL else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Custom provider endpoint is not configured")
            }
            return try await transport.validateEndpoint(baseURL)
        }
        return try ProviderEndpointPolicy.fixed(providerID: providerID)
    }

    public func update(
        providerID: ProviderSettingsID,
        request: UpdateDirectProviderConfigurationRequest,
        attribution: ProviderMutationAttribution
    ) async throws -> DirectProviderConfiguration {
        guard deploymentAllowlist.contains(providerID), let current = configurations[providerID] else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider is not admitted by this deployment")
        }
        guard current.revision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Direct provider configuration revision is stale", currentRevision: current.revision)
        }
        let next = try Self.validateConfiguration(
            providerID: providerID,
            baseURL: request.baseURL,
            preferredModel: request.preferredModel,
            maximumOutputTokens: request.maximumOutputTokens,
            customHeaders: request.customHeaders,
            contentTypePolicy: request.contentTypePolicy,
            revision: current.revision + 1,
            updatedAt: Date()
        )
        if providerID == .customOpenAICompatible, let baseURL = next.baseURL {
            _ = try await transport.validateEndpoint(baseURL)
        }
        configurations[providerID] = try await store.upsertDirectProviderConfiguration(
            next,
            expectedRevision: current.revision,
            audit: .init(operation: "updateDirectConfiguration", attribution: attribution, authenticationMethod: nil, result: "updated")
        )
        return configurations[providerID]!
    }

    static func validateConfiguration(
        providerID: ProviderSettingsID,
        baseURL: String?,
        preferredModel: String?,
        maximumOutputTokens: Int,
        customHeaders: [String: String],
        contentTypePolicy: DirectProviderContentTypePolicy,
        revision: Int64,
        updatedAt: Date
    ) throws -> DirectProviderConfiguration {
        guard providerID.isDirectAPI,
              revision > 0,
              (1 ... 65_536).contains(maximumOutputTokens),
              customHeaders.count <= 16
        else { throw ServiceAPIError(code: .invalidRequest, message: "Direct provider configuration is invalid") }
        let normalizedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerID == .customOpenAICompatible {
            if let normalizedBaseURL, !normalizedBaseURL.isEmpty {
                _ = try ProviderEndpointPolicy.parseCustomBaseURL(normalizedBaseURL)
            }
        } else if normalizedBaseURL?.isEmpty == false {
            throw ServiceAPIError(code: .invalidRequest, message: "Fixed-host providers do not accept a base URL")
        }
        if !customHeaders.isEmpty, ![ProviderSettingsID.openRouter, .customOpenAICompatible].contains(providerID) {
            throw ServiceAPIError(code: .invalidRequest, message: "This provider does not accept custom headers")
        }
        let normalizedModel = try safeText(preferredModel, maximumBytes: 256)
        var normalizedHeaders: [String: String] = [:]
        var totalBytes = 0
        for (rawName, rawValue) in customHeaders {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            let forbidden = Set([
                "authorization", "proxy-authorization", "cookie", "set-cookie", "host",
                "connection", "content-length", "transfer-encoding", "te", "trailer", "upgrade",
                "forwarded", "via", "x-real-ip"
            ])
            guard name.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
                  !forbidden.contains(lower),
                  !lower.hasPrefix("x-forwarded-"),
                  !lower.hasPrefix("proxy-"),
                  !lower.contains("api-key"),
                  !lower.contains("apikey"),
                  !lower.contains("token"),
                  !lower.contains("secret"),
                  !lower.contains("credential"),
                  !value.isEmpty,
                  value.utf8.count <= 1024,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !ProviderSecretRedaction.containsLikelySecret(value)
            else { throw ServiceAPIError(code: .invalidRequest, message: "Direct provider header is forbidden or unsafe") }
            totalBytes += name.utf8.count + value.utf8.count
            normalizedHeaders[name] = value
        }
        guard totalBytes <= 8192 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Direct provider headers exceed their bound")
        }
        return DirectProviderConfiguration(
            providerID: providerID,
            baseURL: providerID == .customOpenAICompatible ? normalizedBaseURL : nil,
            preferredModel: normalizedModel,
            maximumOutputTokens: maximumOutputTokens,
            customHeaders: normalizedHeaders,
            contentTypePolicy: contentTypePolicy,
            revision: revision,
            updatedAt: updatedAt
        )
    }

    private static func safeText(_ value: String?, maximumBytes: Int) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Direct provider setting is invalid") }
        return value
    }
}

public actor DirectProviderCredentialTester: ProviderCredentialTesting {
    private let registry: DirectProviderRegistry
    private let transport: any ValidatedProviderEgressTransporting

    public init(registry: DirectProviderRegistry, transport: any ValidatedProviderEgressTransporting) {
        self.registry = registry
        self.transport = transport
    }

    public func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        guard providerID.isDirectAPI, await registry.isDeploymentAllowed(providerID) else { return [] }
        return [.apiKey]
    }

    public func test(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        guard method == .apiKey,
              await supportedAuthenticationMethods(for: providerID).contains(method),
              let secret,
              let credential = String(data: secret, encoding: .utf8),
              !credential.isEmpty,
              credential.utf8.count <= 65_536,
              !credential.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return .init(state: .invalid, detail: "Provider credential is invalid") }
        do {
            let endpoint = try await registry.endpoint(for: providerID)
            let response = try await transport.execute(.init(
                endpoint: endpoint,
                method: "GET",
                pathAndQuery: Self.catalogPath(providerID: providerID, endpoint: endpoint),
                headers: Self.authenticationHeaders(providerID: providerID, credential: credential),
                maximumResponseBodyBytes: 2 * 1024 * 1024,
                totalTimeout: .seconds(15)
            ))
            switch response.statusCode {
            case 200 ..< 300:
                let models = try Self.parseCatalog(response: response, providerID: providerID)
                return .init(state: .valid, detail: "Provider credential and model catalog validated", models: models)
            case 401, 403:
                return .init(state: .invalid, detail: "Provider rejected the configured credential")
            default:
                return .init(state: .unavailable, detail: "Provider validation is temporarily unavailable")
            }
        } catch is CancellationError {
            return .init(state: .unavailable, detail: "Provider validation was cancelled")
        } catch {
            return .init(state: .unavailable, detail: "Provider validation is temporarily unavailable")
        }
    }

    public func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}

    static func authenticationHeaders(providerID: ProviderSettingsID, credential: String) -> [String: String] {
        switch providerID {
        case .anthropicAPI:
            ["x-api-key": credential, "anthropic-version": "2023-06-01"]
        default:
            ["Authorization": "Bearer \(credential)"]
        }
    }

    static func catalogPath(providerID: ProviderSettingsID, endpoint: DirectProviderEndpoint) -> String {
        let base = endpoint.basePath
        if providerID == .customOpenAICompatible {
            return base.hasSuffix("/v1") ? "\(base)/models" : "\(base)/v1/models"
        }
        return "\(base)/models"
    }

    static func parseCatalog(response: ValidatedProviderHTTPResponse, providerID: ProviderSettingsID) throws -> [ProviderModelCatalogEntry] {
        guard response.body.count <= 2 * 1024 * 1024,
              response.contentType?.lowercased().contains("json") == true,
              let catalogText = String(data: response.body, encoding: .utf8),
              !ProviderSecretRedaction.containsLikelySecret(catalogText),
              let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let data = payload["data"] as? [[String: Any]],
              data.count <= 500
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid") }
        var seen = Set<String>()
        var models: [ProviderModelCatalogEntry] = []
        for item in data {
            guard let rawID = item["id"] as? String,
                  let id = try? safeCatalogText(rawID, maximumBytes: 256),
                  seen.insert(id).inserted
            else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid") }
            let rawName = (item["display_name"] as? String) ?? (item["name"] as? String) ?? id
            guard let displayName = try? safeCatalogText(rawName, maximumBytes: 256) else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid")
            }
            let description: String?
            if let raw = item["description"] as? String {
                description = try safeCatalogText(raw, maximumBytes: 1024)
            } else {
                description = nil
            }
            let reasoningEfforts: [String] = providerID == .anthropicAPI
                ? []
                : ["low", "medium", "high", "xhigh", "max"]
            let serviceTiers: [String] = providerID == .openAIAPI
                ? ["auto", "default", "flex", "priority", "scale"]
                : []
            models.append(.init(
                id: id,
                displayName: displayName,
                description: description,
                isProviderDefault: false,
                reasoningEfforts: reasoningEfforts,
                serviceTiers: serviceTiers
            ))
        }
        guard !models.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is empty")
        }
        return models.sorted { $0.id < $1.id }
    }

    private static func safeCatalogText(_ value: String, maximumBytes: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumBytes,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(normalized)
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider model catalog is invalid") }
        return normalized
    }
}

public actor CompositeProviderCredentialTester: ProviderCredentialTesting {
    private let cli: any ProviderCredentialTesting
    private let direct: any ProviderCredentialTesting

    public init(cli: any ProviderCredentialTesting, direct: any ProviderCredentialTesting) {
        self.cli = cli
        self.direct = direct
    }

    public func supportedAuthenticationMethods(for providerID: ProviderSettingsID) async -> Set<ProviderAuthenticationMethod> {
        if providerID.isDirectAPI { return await direct.supportedAuthenticationMethods(for: providerID) }
        return await cli.supportedAuthenticationMethods(for: providerID)
    }

    public func test(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        if providerID.isDirectAPI { return await direct.test(providerID: providerID, method: method, secret: secret) }
        return await cli.test(providerID: providerID, method: method, secret: secret)
    }

    public func logout(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod) async {
        if providerID.isDirectAPI { await direct.logout(providerID: providerID, method: method) }
        else { await cli.logout(providerID: providerID, method: method) }
    }
}

public actor DirectAPIProviderRuntime: AgentProviderRuntime {
    public let kind = ProviderKind.headlessAdapter
    public let providerID: ProviderSettingsID
    private let registry: any DirectProviderConfigurationProviding
    private let credentials: any DirectProviderCredentialAccessing
    private let transport: any ValidatedProviderEgressTransporting
    private var activeRuns: Set<UUID> = []

    public init(
        providerID: ProviderSettingsID,
        registry: any DirectProviderConfigurationProviding,
        credentials: any DirectProviderCredentialAccessing,
        transport: any ValidatedProviderEgressTransporting
    ) {
        precondition(providerID.isDirectAPI)
        self.providerID = providerID
        self.registry = registry
        self.credentials = credentials
        self.transport = transport
    }

    public func capability() async -> ProviderCapability {
        let admitted = await registry.isDeploymentAllowed(providerID)
        return .init(
            kind: .headlessAdapter,
            enabled: admitted,
            executable: nil,
            supportsResume: false,
            supportsSteering: false,
            protocolVersion: providerID == .anthropicAPI ? "anthropic-messages-v1" : "openai-chat-completions-v1",
            reasonUnavailable: admitted ? nil : "direct provider is not deployment-admitted"
        )
    }

    public func preflight() async -> ProviderCapability { await capability() }

    public func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        guard request.policy.providerSettings["provider.settingsID"] == providerID.rawValue else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Exact direct provider identity is missing")
        }
        let configuration = try await registry.configuration(for: providerID)
        let endpoint = try await registry.endpoint(for: providerID)
        let credentialData = try await credentials.credential(for: providerID)
        guard let credential = String(data: credentialData, encoding: .utf8) else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Direct provider credential is unavailable")
        }
        let model = request.model ?? configuration.preferredModel
        guard let model, !model.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "A direct provider model is required")
        }
        activeRuns.insert(request.runID)
        defer { activeRuns.remove(request.runID) }
        try Task.checkCancellation()

        let mapped = try Self.mappedRequest(
            providerID: providerID,
            endpoint: endpoint,
            configuration: configuration,
            credential: credential,
            model: model,
            prompt: request.prompt,
            settings: request.policy.providerSettings
        )
        let response: ValidatedProviderHTTPResponse
        do {
            response = try await transport.execute(mapped)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider request failed", retryable: true)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ServiceAPIError(
                code: response.statusCode == 401 || response.statusCode == 403 ? .providerUnavailable : .dependencyUnavailable,
                message: response.statusCode == 401 || response.statusCode == 403
                    ? "Direct provider rejected the configured credential"
                    : "Direct provider request failed",
                retryable: response.statusCode != 401 && response.statusCode != 403
            )
        }
        let output = try await Self.parseOutput(response: response, providerID: providerID, maximumBytes: request.maximumBytes) { event in
            await onEvent(event)
        }
        await onEvent(.completed(providerSessionID: nil))
        return .init(output: output, providerSessionID: nil)
    }

    public func interrupt(runID: UUID) async throws {
        guard activeRuns.contains(runID) else { return }
        // Dispatcher cancellation owns the task. This method is an exact-run
        // admission fence; the authority cancels its in-flight task immediately.
    }

    public func hasActiveRun(_ runID: UUID) -> Bool { activeRuns.contains(runID) }

    static func mappedRequest(
        providerID: ProviderSettingsID,
        endpoint: DirectProviderEndpoint,
        configuration: DirectProviderConfiguration,
        credential: String,
        model: String,
        prompt: String,
        settings: [String: String]
    ) throws -> ValidatedProviderHTTPRequest {
        var headers = DirectProviderCredentialTester.authenticationHeaders(providerID: providerID, credential: credential)
        configuration.customHeaders.forEach { headers[$0.key] = $0.value }
        switch configuration.contentTypePolicy {
        case .applicationJSON:
            headers["Content-Type"] = "application/json"
        }
        let payload: [String: Any]
        let path: String
        if providerID == .anthropicAPI {
            path = "\(endpoint.basePath)/messages"
            var body: [String: Any] = [
                "model": model,
                "max_tokens": configuration.maximumOutputTokens,
                "stream": true,
                "messages": [["role": "user", "content": prompt]]
            ]
            Self.attachTemperature(from: settings, to: &body)
            payload = body
        } else {
            path = providerID == .customOpenAICompatible
                ? (endpoint.basePath.hasSuffix("/v1") ? "\(endpoint.basePath)/chat/completions" : "\(endpoint.basePath)/v1/chat/completions")
                : "\(endpoint.basePath)/chat/completions"
            var body: [String: Any] = [
                "model": model,
                "max_tokens": configuration.maximumOutputTokens,
                "stream": true,
                "messages": [["role": "user", "content": prompt]]
            ]
            if providerID == .openAIAPI, let tier = settings["provider.serviceTier"] {
                guard ["auto", "default", "flex", "priority", "scale"].contains(tier) else {
                    throw ServiceAPIError(code: .invalidRequest, message: "OpenAI service tier is invalid")
                }
                body["service_tier"] = tier
            }
            if let effort = settings["provider.reasoningEffort"] {
                body["reasoning_effort"] = effort
            }
            Self.attachTemperature(from: settings, to: &body)
            payload = body
        }
        return .init(
            endpoint: endpoint,
            method: "POST",
            pathAndQuery: path,
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: payload),
            maximumResponseBodyBytes: min(8 * 1024 * 1024, max(64 * 1024, configuration.maximumOutputTokens * 32)),
            totalTimeout: .seconds(120)
        )
    }

    /// Desktop `effectiveTemperature`: attach only a non-zero global when the enable flag left it in the bag.
    static func attachTemperature(from settings: [String: String], to body: inout [String: Any]) {
        guard let raw = settings["models.temperature"], let temperature = Double(raw), temperature != 0 else { return }
        body["temperature"] = temperature
    }

    static func parseOutput(
        response: ValidatedProviderHTTPResponse,
        providerID: ProviderSettingsID,
        maximumBytes: Int,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> String {
        guard response.body.count <= min(8 * 1024 * 1024, maximumBytes * 8) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider response exceeded its bound")
        }
        var output = ""
        if response.contentType?.lowercased().contains("text/event-stream") == true {
            let text = String(decoding: response.body, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("data:") else { continue }
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if value == "[DONE]" { continue }
                guard let data = value.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let delta: String?
                if providerID == .anthropicAPI {
                    delta = (payload["delta"] as? [String: Any])?["text"] as? String
                } else {
                    delta = ((payload["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
                }
                if let delta, !delta.isEmpty {
                    guard output.utf8.count + delta.utf8.count <= maximumBytes else {
                        throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider output exceeded its bound")
                    }
                    output += delta
                    await onEvent(.assistantDelta(delta))
                }
            }
        } else {
            guard response.contentType?.lowercased().contains("json") == true,
                  let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider returned an invalid response") }
            if providerID == .anthropicAPI {
                let blocks = payload["content"] as? [[String: Any]] ?? []
                output = blocks.compactMap { $0["text"] as? String }.joined()
            } else {
                output = (((payload["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? ""
            }
            guard output.utf8.count <= maximumBytes else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider output exceeded its bound")
            }
            if !output.isEmpty { await onEvent(.assistantDelta(output)) }
        }
        guard !output.isEmpty else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Direct provider returned no assistant output")
        }
        await onEvent(.assistantFinal(output))
        return output
    }
}
