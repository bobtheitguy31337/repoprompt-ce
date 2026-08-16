import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptHeadlessRuntime

public actor PortalDesktopSettingsService: ClaudeCompatibleBackendSettingsProviding, DirectProviderRuntimeDefaultsProviding {
    public struct RuntimeDefaults: Sendable, Equatable {
        public let mode: String
        public let providerSettings: [String: String]
    }

    private let store: SQLiteServiceStore

    public init(store: SQLiteServiceStore) {
        self.store = store
    }

    public func snapshot() async throws -> PortalDesktopSettingsSnapshot {
        guard let stored = try await store.portalDesktopSettings() else {
            return .init(revision: 0, values: PortalDesktopSettingKey.defaultValues, updatedAt: .init(timeIntervalSince1970: 0))
        }
        var values = PortalDesktopSettingKey.defaultValues
        for (rawKey, value) in stored.values {
            guard let key = PortalDesktopSettingKey(rawValue: rawKey) else { continue }
            values[rawKey] = try key.validated(value)
        }
        return .init(revision: stored.revision, values: values, updatedAt: stored.updatedAt)
    }

    public func update(_ request: UpdatePortalDesktopSettingsRequest) async throws -> PortalDesktopSettingsSnapshot {
        let current = try await snapshot()
        guard current.revision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Settings revision is stale", currentRevision: current.revision)
        }
        guard !request.changes.isEmpty, request.changes.count <= PortalDesktopSettingKey.allCases.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Settings changes are empty or exceed the supported bound")
        }
        var values = current.values
        for (rawKey, value) in request.changes {
            guard let key = PortalDesktopSettingKey(rawValue: rawKey) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Unknown server setting")
            }
            guard key.isMutable else {
                let code: ServiceErrorCode = key.mutability == .supersededByTypedSettings ? .capabilityMissing : .invalidRequest
                throw ServiceAPIError(code: code, message: "Legacy setting is read-only; use its typed server authority")
            }
            values[rawKey] = try key.validated(value)
        }
        let updated = PortalDesktopSettingsSnapshot(
            revision: current.revision + 1,
            values: values,
            updatedAt: Date()
        )
        return try await store.upsertPortalDesktopSettings(updated, expectedRevision: current.revision)
    }

    /// Projects persisted portal defaults into concrete composer controls. The
    /// browser receives the effective choice instead of inventing a separate
    /// "Default" permission with no execution meaning of its own.
    public func composerCatalogProfile(for providerID: ProviderSettingsID) async throws -> AgentCatalogProviderProfile {
        let values = try await snapshot().values
        var toolValues: [String: AgentControlValue] = [:]
        let permissionID: String?

        let typed = await liveDirectAgentPermissions(values: values)
        switch providerID {
        case .codex:
            toolValues = [
                "codex.bash": .boolean(typed.codex.bashEnabled),
                "codex.search": .boolean(Self.boolean(.codexSearchEnabled, values: values)),
                "codex.goals": .boolean(Self.boolean(.codexGoalsEnabled, values: values)),
                "codex.reasoningSummaries": .boolean(Self.boolean(.codexReasoningSummariesEnabled, values: values)),
                "codex.memories": .boolean(Self.boolean(.codexMemoriesEnabled, values: values)),
                "codex.mcpServers": .choices(["repoprompt"])
            ]
            permissionID = "codex.\(typed.codex.permissionLevel)"
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            toolValues = [
                "claude.bash": .boolean(typed.claude.bashEnabled),
                "claude.mcpStrictMode": .boolean(typed.claude.mcpStrictModeEnabled),
                "claude.toolSearch": .boolean(Self.boolean(.claudeToolSearchEnabled, values: values)),
                "claude.promptDelivery": .choice("nativeSystemPrompt")
            ]
            permissionID = "claude.\(typed.claude.permissionLevel)"
        case .openCodeACP:
            permissionID = typed.openCode.permissionLevel == .fullAccess
                ? "opencode.fullAccess"
                : "opencode.managedDefault"
        case .cursorACP:
            permissionID = typed.cursor.permissionLevel == .fullAccess
                ? "cursor.fullAccess"
                : "cursor.managedDefault"
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible, .xAI:
            permissionID = nil
        }

        return .init(
            toolControls: ProviderComposerStableControls.descriptors(
                providerID: providerID,
                values: toolValues,
                mutable: true,
                lockReasonCode: nil
            ),
            permissionControl: ProviderComposerStableControls.permissionDescriptor(
                providerID: providerID,
                selectedID: permissionID,
                mutable: true,
                lockReasonCode: nil
            )
        )
    }

    public func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults {
        let defaults = try await runtimeDefaults(for: providerID)
        return .init(mode: defaults.mode, providerSettings: defaults.providerSettings)
    }

    public func runtimeDefaults(for providerID: ProviderSettingsID) async throws -> RuntimeDefaults {
        let values = try await snapshot().values
        let typed = await liveDirectAgentPermissions(values: values)
        let projection = typed.projection(for: providerID)
        let fallbackMode = values[PortalDesktopSettingKey.serverDefaultExecutionMode.rawValue] ?? "workspaceWrite"
        guard providerID.hasTypedDirectAgentProfile else {
            return .init(mode: fallbackMode, providerSettings: [:])
        }
        switch providerID {
        case .codex:
            var providerSettings = projection.providerSettings
            providerSettings["codex.searchEnabled"] = values[PortalDesktopSettingKey.codexSearchEnabled.rawValue] ?? "true"
            providerSettings["codex.goalsEnabled"] = values[PortalDesktopSettingKey.codexGoalsEnabled.rawValue] ?? "true"
            providerSettings["codex.reasoningSummariesEnabled"] = values[PortalDesktopSettingKey.codexReasoningSummariesEnabled.rawValue] ?? "false"
            providerSettings["codex.memoriesEnabled"] = values[PortalDesktopSettingKey.codexMemoriesEnabled.rawValue] ?? "false"
            providerSettings["codex.enabledMCPServers"] = values[PortalDesktopSettingKey.codexEnabledMCPServers.rawValue] ?? "[\"RepoPromptCE\"]"
            return .init(mode: projection.mode, providerSettings: providerSettings)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            var providerSettings = projection.providerSettings
            providerSettings["claude.toolSearchEnabled"] = values[PortalDesktopSettingKey.claudeToolSearchEnabled.rawValue] ?? "true"
            if providerID != .claudeCompatible {
                let backend = try Self.backendSettings(providerID: providerID, values: values)
                providerSettings["claude.backendID"] = providerID.rawValue
                providerSettings["claude.backendBaseURL"] = backend.baseURL
                providerSettings["claude.backendAuthHeader"] = backend.authHeader.rawValue
                providerSettings["claude.backendModelBehavior"] = backend.modelBehavior.rawValue
                providerSettings["claude.backendHaikuModel"] = backend.haikuModel
                providerSettings["claude.backendSonnetModel"] = backend.sonnetModel
                providerSettings["claude.backendOpusModel"] = backend.opusModel
            }
            return .init(mode: projection.mode, providerSettings: providerSettings)
        case .openCodeACP, .cursorACP:
            return .init(mode: projection.mode, providerSettings: projection.providerSettings)
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible, .xAI:
            return .init(mode: fallbackMode, providerSettings: [:])
        }
    }

    public func backendSettings(for providerID: ProviderSettingsID) async throws -> ClaudeCompatibleBackendSettings? {
        guard [.claudeGLM, .claudeKimi, .claudeCustom].contains(providerID) else { return nil }
        let values = try await snapshot().values
        return try Self.backendSettings(providerID: providerID, values: values)
    }

    private nonisolated static func backendSettings(providerID: ProviderSettingsID, values: [String: String]) throws -> ClaudeCompatibleBackendSettings {
        let keys: (PortalDesktopSettingKey, PortalDesktopSettingKey, PortalDesktopSettingKey, PortalDesktopSettingKey, PortalDesktopSettingKey, PortalDesktopSettingKey, PortalDesktopSettingKey)
        let defaultBehavior: ClaudeCompatibleBackendModelBehavior
        switch providerID {
        case .claudeGLM:
            keys = (.claudeGLMDisplayName, .claudeGLMBaseURL, .claudeGLMAuthHeader, .claudeGLMHaikuModel, .claudeGLMSonnetModel, .claudeGLMOpusModel, .claudeCustomModelBehavior)
            defaultBehavior = .claudeSlotMapping
        case .claudeKimi:
            keys = (.claudeKimiDisplayName, .claudeKimiBaseURL, .claudeKimiAuthHeader, .claudeCustomHaikuModel, .claudeCustomSonnetModel, .claudeCustomOpusModel, .claudeCustomModelBehavior)
            defaultBehavior = .noModel
        case .claudeCustom:
            keys = (.claudeCustomDisplayName, .claudeCustomBaseURL, .claudeCustomAuthHeader, .claudeCustomHaikuModel, .claudeCustomSonnetModel, .claudeCustomOpusModel, .claudeCustomModelBehavior)
            defaultBehavior = ClaudeCompatibleBackendModelBehavior(rawValue: values[keys.6.rawValue] ?? "") ?? .noModel
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Claude-compatible backend settings were requested for an unrelated provider")
        }
        let auth = ClaudeCompatibleBackendAuthHeader(rawValue: values[keys.2.rawValue] ?? "") ?? .anthropicAPIKey
        return .init(
            providerID: providerID,
            displayName: values[keys.0.rawValue] ?? keys.0.defaultValue,
            baseURL: values[keys.1.rawValue] ?? keys.1.defaultValue,
            authHeader: auth,
            modelBehavior: defaultBehavior,
            haikuModel: values[keys.3.rawValue] ?? keys.3.defaultValue,
            sonnetModel: values[keys.4.rawValue] ?? keys.4.defaultValue,
            opusModel: values[keys.5.rawValue] ?? keys.5.defaultValue
        )
    }

    private func liveDirectAgentPermissions(values: [String: String]) async -> DirectAgentPermissionsSettings {
        if let stored = try? await store.directAgentPermissionDocument() {
            return stored.value
        }
        return .projected(fromPortalValues: values)
    }

    private nonisolated static func boolean(_ key: PortalDesktopSettingKey, values: [String: String]) -> Bool {
        values[key.rawValue] == "true"
    }
}
