import Foundation
import RepoPromptServiceProtocol

public struct DirectProviderRuntimeDefaults: Sendable, Equatable {
    public let mode: String
    public let providerSettings: [String: String]

    public init(mode: String, providerSettings: [String: String]) {
        self.mode = mode
        self.providerSettings = providerSettings
    }
}

public protocol DirectProviderRuntimeDefaultsProviding: Sendable {
    func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults
}

public struct ResolvedSubagentPermission: Sendable, Equatable {
    public let mode: String
    public let providerSettings: [String: String]
    public let policy: SubagentPermissionPolicy
    public let settingsRevision: Int64

    public init(
        mode: String,
        providerSettings: [String: String],
        policy: SubagentPermissionPolicy,
        settingsRevision: Int64
    ) {
        self.mode = mode
        self.providerSettings = providerSettings
        self.policy = policy
        self.settingsRevision = settingsRevision
    }
}

public struct SubagentPermissionResolver: Sendable {
    private let settings: ServerSettingsService?
    private let directDefaults: (any DirectProviderRuntimeDefaultsProviding)?

    public init(
        settings: ServerSettingsService?,
        directDefaults: (any DirectProviderRuntimeDefaultsProviding)?
    ) {
        self.settings = settings
        self.directDefaults = directDefaults
    }

    public func resolve(providerID: ProviderSettingsID) async -> ResolvedSubagentPermission {
        let snapshot = await settings?.subagentPermissions()
            ?? SubagentPermissionSettingsSnapshot(
                settings: .safeManaged,
                revision: 0,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        let inherited: DirectProviderRuntimeDefaults?
        if let directDefaults {
            inherited = try? await directDefaults.directProviderRuntimeDefaults(for: providerID)
        } else {
            inherited = nil
        }
        let resolved: DirectProviderRuntimeDefaults
        switch snapshot.settings.policy {
        case .inheritProviderSettings:
            resolved = inherited ?? safeDefaults(providerID: providerID, preserving: [:])
        case .safeManaged:
            resolved = safeDefaults(providerID: providerID, preserving: inherited?.providerSettings ?? [:])
        case .custom:
            resolved = customDefaults(
                providerID: providerID,
                settings: snapshot.settings,
                preserving: inherited?.providerSettings ?? [:]
            )
        }
        var providerSettings = resolved.providerSettings
        providerSettings["provider.settingsID"] = providerID.rawValue
        providerSettings["subagent.permissionPolicy"] = snapshot.settings.policy.rawValue
        providerSettings["subagent.permissionSettingsRevision"] = String(snapshot.revision)
        return .init(
            mode: resolved.mode,
            providerSettings: providerSettings,
            policy: snapshot.settings.policy,
            settingsRevision: snapshot.revision
        )
    }

    private func safeDefaults(
        providerID: ProviderSettingsID,
        preserving settings: [String: String]
    ) -> DirectProviderRuntimeDefaults {
        switch providerID {
        case .codex:
            return codex(.autoReview, preserving: settings)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            return claude(.requireApproval, preserving: settings)
        case .openCodeACP, .cursorACP, .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible, .xAI:
            return managed(.managedDefault, preserving: settings)
        }
    }

    private func customDefaults(
        providerID: ProviderSettingsID,
        settings: SubagentPermissionSettings,
        preserving providerSettings: [String: String]
    ) -> DirectProviderRuntimeDefaults {
        switch providerID {
        case .codex:
            codex(settings.codex, preserving: providerSettings)
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            claude(settings.claude, preserving: providerSettings)
        case .openCodeACP:
            managed(settings.openCode, preserving: providerSettings)
        case .cursorACP:
            managed(settings.cursor, preserving: providerSettings)
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible, .xAI:
            managed(.managedDefault, preserving: providerSettings)
        }
    }

    private func codex(
        _ mode: SubagentCodexPermissionMode,
        preserving settings: [String: String]
    ) -> DirectProviderRuntimeDefaults {
        var values = settings
        values["codex.approvalPolicy"] = mode == .defaultPermission ? "untrusted" : "on-request"
        let executionMode: String = switch mode {
        case .readOnly: "readOnly"
        case .defaultPermission, .autoReview: "workspaceWrite"
        case .fullAccess: "fullAccess"
        }
        return .init(mode: executionMode, providerSettings: values)
    }

    private func claude(
        _ mode: SubagentClaudePermissionMode,
        preserving settings: [String: String]
    ) -> DirectProviderRuntimeDefaults {
        var values = settings
        values["claude.permissionMode"] = switch mode {
        case .requireApproval: "default"
        case .autoApproveEdits: "acceptEdits"
        case .auto: "auto"
        case .fullAccess: "bypassPermissions"
        }
        return .init(
            mode: mode == .fullAccess ? "fullAccess" : "workspaceWrite",
            providerSettings: values
        )
    }

    private func managed(
        _ mode: SubagentManagedPermissionMode,
        preserving settings: [String: String]
    ) -> DirectProviderRuntimeDefaults {
        .init(
            mode: mode == .fullAccess ? "fullAccess" : "workspaceWrite",
            providerSettings: settings
        )
    }
}
