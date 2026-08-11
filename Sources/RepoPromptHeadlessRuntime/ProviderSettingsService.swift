import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public protocol ProviderAuthFlowCoordinating: Sendable {
    func start(providerID: ProviderSettingsID, kind: ProviderAuthFlowKind) async throws -> ProviderAuthFlowChallenge
}

public struct UnavailableProviderAuthFlowCoordinator: ProviderAuthFlowCoordinating {
    public init() {}

    public func start(providerID _: ProviderSettingsID, kind _: ProviderAuthFlowKind) async throws -> ProviderAuthFlowChallenge {
        throw ServiceAPIError(code: .capabilityMissing, message: "A server-side provider authentication adapter is not installed")
    }
}

/// Provider/settings authority for the Linux portal. It owns only non-secret
/// preferences and browser-safe projections; native process/session authority
/// remains in `ProviderCLIAdapter`.
public actor ProviderSettingsService {
    private struct SanitizedAuthenticationDocument: Decodable {
        let authenticated: Bool
        let method: ProviderAuthenticationMethod?
        let expiresAt: Date?
    }

    private let store: SQLiteServiceStore
    private let adapter: ProviderCLIAdapter
    private let configurations: [ProviderKind: ProviderCLIConfiguration]
    private let initiallyEnabled: Set<ProviderKind>
    private let authenticationStatusFiles: [ProviderSettingsID: String]
    private let modelCatalogFiles: [ProviderSettingsID: String]
    private let authFlows: any ProviderAuthFlowCoordinating
    private let runner: any WorkspaceCommandRunning
    private var preferences: [ProviderSettingsID: ProviderSettingsPreference] = [:]
    private var cliHealth: [ProviderSettingsID: ProviderCLIHealth] = [:]
    private var runtimePreflight: [ProviderSettingsID: Bool] = [:]
    private var modelCatalogs: [ProviderSettingsID: [ProviderModelCatalogEntry]] = [:]

    public init(
        store: SQLiteServiceStore,
        adapter: ProviderCLIAdapter,
        configurations: [ProviderCLIConfiguration],
        initiallyEnabled: Set<ProviderKind>,
        authenticationStatusFiles: [ProviderSettingsID: String] = [:],
        modelCatalogFiles: [ProviderSettingsID: String] = [:],
        authFlows: any ProviderAuthFlowCoordinating = UnavailableProviderAuthFlowCoordinator(),
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner()
    ) {
        self.store = store
        self.adapter = adapter
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.kind, $0) })
        self.initiallyEnabled = initiallyEnabled
        self.authenticationStatusFiles = authenticationStatusFiles
        self.modelCatalogFiles = modelCatalogFiles
        self.authFlows = authFlows
        self.runner = runner
    }

    public func bootstrap() async throws {
        modelCatalogs = try loadModelCatalogs()
        let persisted = try await store.providerSettings()
        preferences = Dictionary(uniqueKeysWithValues: persisted.map { ($0.providerID, $0) })
        for providerID in ProviderSettingsID.allCases {
            if preferences[providerID] == nil {
                let initial = ProviderSettingsPreference(
                    providerID: providerID,
                    enabled: providerID.runtimeKind.map(initiallyEnabled.contains) ?? false,
                    defaultModel: defaultCatalog(for: providerID).first(where: \.isProviderDefault)?.id,
                    revision: 1
                )
                preferences[providerID] = try await store.upsertProviderSettings(initial, expectedRevision: 0)
            }
            try await applyRuntimePreference(providerID)
        }
        await refreshCLIHealth()
        await refreshRuntimePreflight()
    }

    public func catalog(refreshCLI: Bool = false) async throws -> ProviderSettingsCatalogResponse {
        if refreshCLI { await refreshCLIHealth() }
        await refreshRuntimePreflight()
        let snapshots = try ProviderSettingsID.allCases.map { try snapshot(for: $0) }
        return ProviderSettingsCatalogResponse(providers: snapshots)
    }

    public func update(providerID: ProviderSettingsID, request: UpdateProviderSettingsRequest) async throws -> ProviderSettingsSnapshot {
        guard let current = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        guard current.revision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Provider settings revision is stale", currentRevision: current.revision)
        }
        let definition = Self.definition(providerID)
        if request.enabled, providerID.runtimeKind == nil {
            throw ServiceAPIError(code: .capabilityMissing, message: "This provider has no portable server runtime yet")
        }
        if request.enabled, let kind = providerID.runtimeKind, !initiallyEnabled.contains(kind) {
            throw ServiceAPIError(code: .capabilityMissing, message: "Deployment configuration does not allow this provider")
        }
        try validateSelection(request, providerID: providerID, definition: definition)
        let next = ProviderSettingsPreference(
            providerID: providerID,
            enabled: request.enabled,
            defaultModel: normalized(request.defaultModel),
            reasoningEffort: normalized(request.reasoningEffort),
            speedMode: normalized(request.speedMode),
            serviceTier: normalized(request.serviceTier),
            revision: current.revision + 1
        )
        preferences[providerID] = try await store.upsertProviderSettings(next, expectedRevision: current.revision)
        try await applyRuntimePreference(providerID)
        await refreshRuntimePreflight()
        return try snapshot(for: providerID)
    }

    public func startAuthFlow(providerID: ProviderSettingsID, request: StartProviderAuthFlowRequest) async throws -> ProviderAuthFlowChallenge {
        let descriptor = Self.definition(providerID).capabilities.authFlows.first { $0.kind == request.kind }
        guard descriptor?.startable == true else {
            throw ServiceAPIError(code: .capabilityMissing, message: descriptor?.detail ?? "Provider authentication flow is unavailable")
        }
        return try await authFlows.start(providerID: providerID, kind: request.kind)
    }

    private func applyRuntimePreference(_ providerID: ProviderSettingsID) async throws {
        guard let kind = providerID.runtimeKind, let preference = preferences[providerID] else { return }
        guard configurations[kind] != nil else {
            if preference.enabled {
                throw ServiceAPIError(code: .providerUnavailable, message: "Provider executable is not configured")
            }
            return
        }
        let effectiveAdmission = preference.enabled && initiallyEnabled.contains(kind)
        try await adapter.applyRuntimeDefaults(
            kind: kind,
            defaults: ProviderRuntimeDefaults(
                enabled: effectiveAdmission,
                model: preference.defaultModel,
                reasoningEffort: preference.reasoningEffort,
                speedMode: preference.speedMode,
                serviceTier: preference.serviceTier
            )
        )
    }

    private func refreshCLIHealth() async {
        for (kind, configuration) in configurations {
            guard let providerID = Self.settingsID(kind) else { continue }
            guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
                cliHealth[providerID] = ProviderCLIHealth(installed: false, healthy: false, expectedVersion: configuration.expectedVersion, detail: "Configured CLI is not executable")
                continue
            }
            do {
                let output = try await runner.run(
                    executable: configuration.executable,
                    arguments: ["--version"],
                    workingDirectory: FileManager.default.currentDirectoryPath,
                    maximumBytes: 65_536
                )
                let reported = Self.validCLIVersionOutput(output)
                let matches = configuration.expectedVersion.map { reported?.contains($0) == true } ?? (reported != nil)
                cliHealth[providerID] = ProviderCLIHealth(
                    installed: true,
                    healthy: matches,
                    version: matches ? configuration.expectedVersion : nil,
                    expectedVersion: configuration.expectedVersion,
                    detail: reported == nil ? "CLI returned invalid version output" : (matches ? nil : "Installed version does not match the pinned server contract")
                )
            } catch {
                cliHealth[providerID] = ProviderCLIHealth(installed: true, healthy: false, expectedVersion: configuration.expectedVersion, detail: "CLI version probe failed")
            }
        }
    }

    private func refreshRuntimePreflight() async {
        let capabilities = await adapter.preflight()
        for capability in capabilities {
            guard let providerID = Self.settingsID(capability.kind) else { continue }
            runtimePreflight[providerID] = capability.enabled && capability.reasonUnavailable == nil
        }
    }

    private func snapshot(for providerID: ProviderSettingsID) throws -> ProviderSettingsSnapshot {
        guard let preference = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        let definition = Self.definition(providerID)
        let deploymentAllowed = providerID.runtimeKind.map(initiallyEnabled.contains) ?? false
        let preflightVerified = runtimePreflight[providerID] ?? false
        let models = modelCatalogs[providerID] ?? defaultCatalog(for: providerID)
        return ProviderSettingsSnapshot(
            providerID: providerID,
            displayName: definition.displayName,
            category: definition.category,
            summary: definition.summary,
            deploymentAllowed: deploymentAllowed,
            runtimePreflightVerified: preflightVerified,
            effectiveEnabled: preference.enabled && deploymentAllowed && preflightVerified,
            preference: preference,
            cli: providerID.runtimeKind == nil ? nil : cliHealth[providerID] ?? ProviderCLIHealth(installed: false, healthy: false, detail: "CLI health has not been checked"),
            authentication: authenticationStatus(providerID),
            capabilities: definition.capabilities,
            models: models
        )
    }

    private func authenticationStatus(_ providerID: ProviderSettingsID) -> ProviderAuthenticationStatus {
        if let path = authenticationStatusFiles[providerID],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let document = try? JSONDecoder.serviceDecoder.decode(SanitizedAuthenticationDocument.self, from: data)
        {
            return ProviderAuthenticationStatus(
                state: document.authenticated ? .authenticated : .attention,
                authenticated: document.authenticated,
                method: document.method,
                expiresAt: document.expiresAt,
                detail: document.authenticated ? "Authenticated" : "Authentication requires attention"
            )
        }
        if let kind = providerID.runtimeKind,
           let source = configurations[kind]?.credentialSourceDirectory,
           FileManager.default.fileExists(atPath: source)
        {
            return ProviderAuthenticationStatus(state: .unknown, authenticated: false, detail: "Credential home is mounted; sanitized account status is unavailable")
        }
        return ProviderAuthenticationStatus(state: .notConfigured, authenticated: false, detail: "Provision credentials on the server")
    }

    private func validateSelection(_ request: UpdateProviderSettingsRequest, providerID: ProviderSettingsID, definition: Definition) throws {
        let models = modelCatalogs[providerID] ?? defaultCatalog(for: providerID)
        let selectedModel: ProviderModelCatalogEntry?
        if let modelID = normalized(request.defaultModel) {
            guard definition.capabilities.supportsModelSelection,
                  let model = models.first(where: { $0.id == modelID })
            else { throw ServiceAPIError(code: .invalidRequest, message: "Default model is not in the provider catalog") }
            selectedModel = model
        } else {
            selectedModel = nil
        }
        try validateOption(normalized(request.reasoningEffort), allowed: selectedModel?.reasoningEfforts ?? [], capability: definition.capabilities.supportsReasoningEffort, label: "reasoning effort")
        try validateOption(normalized(request.speedMode), allowed: selectedModel?.speedModes ?? [], capability: definition.capabilities.supportsSpeedMode, label: "speed mode")
        try validateOption(normalized(request.serviceTier), allowed: selectedModel?.serviceTiers ?? [], capability: definition.capabilities.supportsServiceTier, label: "service tier")
    }

    private func validateOption(_ value: String?, allowed: [String], capability: Bool, label: String) throws {
        guard let value else { return }
        guard capability, allowed.contains(value) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Selected \(label) is not supported by this model")
        }
    }

    private func loadModelCatalogs() throws -> [ProviderSettingsID: [ProviderModelCatalogEntry]] {
        try modelCatalogFiles.reduce(into: [:]) { result, item in
            let data = try Data(contentsOf: URL(fileURLWithPath: item.value))
            let catalog = try JSONDecoder.serviceDecoder.decode([ProviderModelCatalogEntry].self, from: data)
            guard catalog.count <= 500,
                  Set(catalog.map(\.id)).count == catalog.count,
                  catalog.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.displayName.utf8.count <= 256 })
            else { throw ServiceAPIError(code: .invalidRequest, message: "Provider model catalog is invalid") }
            result[item.key] = catalog
        }
    }

    private func defaultCatalog(for providerID: ProviderSettingsID) -> [ProviderModelCatalogEntry] {
        switch providerID {
        case .codex:
            [
                .init(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", description: "Frontier coding model", reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], serviceTiers: ["fast"]),
                .init(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", description: "Balanced agentic coding model", reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], serviceTiers: ["fast"]),
                .init(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", description: "Efficient coding model", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"], serviceTiers: ["fast"])
            ]
        case .claudeCompatible:
            [
                .init(id: "claude-fable-5", displayName: "Fable 5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                .init(id: "claude-opus-5", displayName: "Opus 5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                .init(id: "claude-sonnet-5", displayName: "Sonnet 5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                .init(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5")
            ]
        case .cursorACP:
            [.init(id: "auto", displayName: "Auto", description: "Let Cursor choose the best advertised model", isProviderDefault: true)]
        case .openCodeACP, .xAI:
            // These catalogs are provider/account specific. A sanitized
            // server-side catalog file must opt in exact capabilities.
            []
        }
    }

    private struct Definition {
        let displayName: String
        let category: ProviderSettingsCategory
        let summary: String
        let capabilities: ProviderSettingsCapabilities
    }

    private nonisolated static func definition(_ providerID: ProviderSettingsID) -> Definition {
        let external = ProviderAuthFlowDescriptor(kind: .externalProvisioning, displayName: "Server credential provisioning", startable: false, detail: "Mount credentials or a provider key helper on the server; secret values never pass through the portal")
        switch providerID {
        case .codex:
            return Definition(displayName: "Codex", category: .cliProvider, summary: "OpenAI Codex app-server with isolated CODEX_HOME", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: true, authenticationMethods: [.browserOAuth, .deviceCodeBeta, .apiKey, .enterpriseAccessToken], authFlows: [
                .init(kind: .browserOAuth, displayName: "Browser OAuth", startable: false, detail: "Server-side OAuth adapter seam; not installed in this slice"),
                .init(kind: .deviceCodeBeta, displayName: "Device auth (beta)", startable: false, detail: "Device codes may only be returned transiently by a server-side adapter"), external
            ]))
        case .claudeCompatible:
            return Definition(displayName: "Claude Code", category: .cliProvider, summary: "Claude-compatible stream JSON with isolated CLAUDE_CONFIG_DIR", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false, authenticationMethods: [.apiKey, .authToken, .keyHelper, .workloadIdentityFederation], authFlows: [external]))
        case .openCodeACP:
            return Definition(displayName: "OpenCode", category: .cliProvider, summary: "Provider-specific ACP catalog and authentication", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false, authenticationMethods: [.providerSpecific], authFlows: [external]))
        case .cursorACP:
            return Definition(displayName: "Cursor", category: .cliProvider, summary: "Cursor ACP with browser login or server-side API key", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false, authenticationMethods: [.browserLogin, .apiKey], authFlows: [external]))
        case .xAI:
            return Definition(displayName: "xAI", category: .apiProvider, summary: "API-key-only provider; runtime extraction is pending", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: true, authenticationMethods: [.apiKey], authFlows: [external]))
        }
    }

    private nonisolated static func settingsID(_ kind: ProviderKind) -> ProviderSettingsID? {
        switch kind {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .headlessAdapter, .mcp: nil
        }
    }

    private nonisolated static func validCLIVersionOutput(_ output: String) -> String? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else { return nil }
        let value = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._+-/():"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private nonisolated func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(512))
    }
}
