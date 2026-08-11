import Foundation
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public actor PortalDesktopSettingsService {
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
            values[rawKey] = try key.validated(value)
        }
        let updated = PortalDesktopSettingsSnapshot(
            revision: current.revision + 1,
            values: values,
            updatedAt: Date()
        )
        return try await store.upsertPortalDesktopSettings(updated, expectedRevision: current.revision)
    }

    public func runtimeDefaults(for providerID: ProviderSettingsID) async throws -> RuntimeDefaults {
        let values = try await snapshot().values
        let fallbackMode = values[PortalDesktopSettingKey.serverDefaultExecutionMode.rawValue] ?? "workspaceWrite"
        switch providerID {
        case .codex:
            let permission = values[PortalDesktopSettingKey.codexPermissionLevel.rawValue] ?? "autoReview"
            let mode = Self.executionMode(permission, fallback: fallbackMode)
            return .init(mode: mode, providerSettings: [
                "codex.approvalPolicy": permission == "defaultPermission" ? "untrusted" : "on-request",
                "codex.bashEnabled": values[PortalDesktopSettingKey.codexBashEnabled.rawValue] ?? "true",
                "codex.searchEnabled": values[PortalDesktopSettingKey.codexSearchEnabled.rawValue] ?? "true",
                "codex.goalsEnabled": values[PortalDesktopSettingKey.codexGoalsEnabled.rawValue] ?? "true",
                "codex.reasoningSummariesEnabled": values[PortalDesktopSettingKey.codexReasoningSummariesEnabled.rawValue] ?? "false",
                "codex.memoriesEnabled": values[PortalDesktopSettingKey.codexMemoriesEnabled.rawValue] ?? "false",
                "codex.enabledMCPServers": values[PortalDesktopSettingKey.codexEnabledMCPServers.rawValue] ?? "[\"RepoPromptCE\"]"
            ])
        case .claudeCompatible:
            let permission = values[PortalDesktopSettingKey.claudePermissionLevel.rawValue] ?? "requireApproval"
            let mode = permission == "fullAccess" ? "fullAccess" : (permission == "requireApproval" ? "workspaceWrite" : fallbackMode)
            let claudeMode: String = switch permission {
            case "autoApproveEdits": "acceptEdits"
            case "auto": "auto"
            default: "default"
            }
            return .init(mode: mode, providerSettings: [
                "claude.permissionMode": claudeMode,
                "claude.bashEnabled": values[PortalDesktopSettingKey.claudeBashEnabled.rawValue] ?? "true",
                "claude.strictMCPEnabled": values[PortalDesktopSettingKey.claudeStrictMCPEnabled.rawValue] ?? "false",
                "claude.toolSearchEnabled": values[PortalDesktopSettingKey.claudeToolSearchEnabled.rawValue] ?? "true"
            ])
        case .openCodeACP:
            let permission = values[PortalDesktopSettingKey.openCodePermissionLevel.rawValue] ?? "managedDefault"
            return .init(mode: permission == "fullAccess" ? "fullAccess" : fallbackMode, providerSettings: [:])
        case .cursorACP:
            let permission = values[PortalDesktopSettingKey.cursorPermissionLevel.rawValue] ?? "managedDefault"
            return .init(mode: permission == "fullAccess" ? "fullAccess" : fallbackMode, providerSettings: [:])
        case .xAI:
            return .init(mode: fallbackMode, providerSettings: [:])
        }
    }

    private nonisolated static func executionMode(_ permission: String, fallback: String) -> String {
        switch permission {
        case "readOnly": "readOnly"
        case "fullAccess": "fullAccess"
        case "defaultPermission", "autoReview": "workspaceWrite"
        default: fallback
        }
    }
}
