import Foundation
import RepoPromptRuntimeModel

public enum ProviderTurnConfigurationError: Error, Equatable, Sendable {
    case providerModelMismatch
    case settingsMismatch
    case unsupportedEffort(String)
    case unsupportedPermission(ProviderPermissionID)
}

public struct ProviderTurnConfigurationInput: Sendable {
    public let model: ProviderModelDescriptor
    public let effortID: String?
    public let permissionID: ProviderPermissionID
    public let settings: ProviderTurnSettings
    public let scopedResources: Set<OwnedResourceReference>

    public init(
        model: ProviderModelDescriptor,
        effortID: String? = nil,
        permissionID: ProviderPermissionID,
        settings: ProviderTurnSettings,
        scopedResources: Set<OwnedResourceReference> = []
    ) {
        self.model = model
        self.effortID = effortID
        self.permissionID = permissionID
        self.settings = settings
        self.scopedResources = scopedResources
    }
}

public struct CompiledProviderTurnConfiguration: Sendable {
    public let runtimeKind: ProviderKind
    public let providerRawModelValue: String
    public let effortID: String?
    public let permissions: ResolvedProviderPermissions
    public let supportsNativeImages: Bool
    public let providerSettings: [String: String]

    public init(
        runtimeKind: ProviderKind,
        providerRawModelValue: String,
        effortID: String?,
        permissions: ResolvedProviderPermissions,
        supportsNativeImages: Bool,
        providerSettings: [String: String]
    ) {
        self.runtimeKind = runtimeKind
        self.providerRawModelValue = providerRawModelValue
        self.effortID = effortID
        self.permissions = permissions
        self.supportsNativeImages = supportsNativeImages
        self.providerSettings = providerSettings
    }
}

public protocol ProviderTurnConfigurationAdapter: Sendable {
    var providerID: ProviderSettingsID { get }
    func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration
}

public enum ProviderTurnConfigurationAdapters {
    /// Bump only when a stable permission or provider-setting mapping changes meaning.
    public static let interpretationRevision = "provider-turn-configuration-v3-desktop-profile"

    public static func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        let adapter: any ProviderTurnConfigurationAdapter = switch input.model.providerID {
        case .codex:
            CodexTurnConfigurationAdapter()
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            ClaudeCompatibleTurnConfigurationAdapter(providerID: input.model.providerID)
        case .openCodeACP, .cursorACP, .grokBuildACP:
            TextOnlyACPTurnConfigurationAdapter(providerID: input.model.providerID)
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible,
             .gemini, .azure, .deepseek, .fireworks, .xAI, .groq, .zAI, .ollama:
            DirectAPITurnConfigurationAdapter(providerID: input.model.providerID)
        }
        return try adapter.compile(input)
    }

    static func resolvedEffort(_ input: ProviderTurnConfigurationInput) throws -> String? {
        let effort = input.effortID ?? input.model.defaultEffortID
        if let effort, !input.model.supportedEffortIDs.contains(effort) {
            throw ProviderTurnConfigurationError.unsupportedEffort(effort)
        }
        return effort
    }

    static func permissions(
        for permissionID: ProviderPermissionID,
        readOnly: Set<String>,
        workspaceWrite: Set<String>,
        fullAccess: Set<String>,
        scopedResources: Set<OwnedResourceReference>
    ) throws -> ResolvedProviderPermissions {
        if readOnly.contains(permissionID.rawValue) {
            return .readOnly(scopedResources: scopedResources)
        }
        if workspaceWrite.contains(permissionID.rawValue) {
            return .workspaceWrite(scopedResources: scopedResources)
        }
        if fullAccess.contains(permissionID.rawValue) {
            return .fullAccess(scopedResources: scopedResources)
        }
        throw ProviderTurnConfigurationError.unsupportedPermission(permissionID)
    }
}

public struct CodexTurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID = ProviderSettingsID.codex

    public init() {}

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard input.model.providerID == providerID else {
            throw ProviderTurnConfigurationError.providerModelMismatch
        }
        guard case let .codex(settings) = input.settings else {
            throw ProviderTurnConfigurationError.settingsMismatch
        }
        let effort = try ProviderTurnConfigurationAdapters.resolvedEffort(input)
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            for: input.permissionID,
            readOnly: ["codex.readOnly"],
            workspaceWrite: ["codex.defaultPermission", "codex.autoReview"],
            fullAccess: ["codex.fullAccess"],
            scopedResources: input.scopedResources
        )
        var native: [String: String] = [
            "codex.bashEnabled": String(settings.bashEnabled),
            "codex.searchEnabled": String(settings.searchEnabled),
            "codex.goalsEnabled": String(settings.goalsEnabled),
            "codex.reasoningSummariesEnabled": String(settings.reasoningSummariesEnabled),
            "codex.memoriesEnabled": String(settings.memoriesEnabled),
            "codex.mcpServers": settings.mcpServerIDs.sorted().joined(separator: ","),
            "codex.approvalsReviewer": input.permissionID.rawValue == "codex.autoReview" ? "auto_review" : "user",
            "provider.permissionId": input.permissionID.rawValue
        ]
        if let effort { native["provider.reasoningEffort"] = effort }
        if let serviceTier = input.model.serviceTier { native["provider.serviceTier"] = serviceTier }
        return .init(
            runtimeKind: .codex,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            supportsNativeImages: input.model.capabilities.nativeImages,
            providerSettings: native
        )
    }
}

public struct ClaudeCompatibleTurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID: ProviderSettingsID

    public init(providerID: ProviderSettingsID) {
        self.providerID = providerID
    }

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard [.claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom].contains(providerID),
              input.model.providerID == providerID
        else {
            throw ProviderTurnConfigurationError.providerModelMismatch
        }
        guard case let .claudeCompatible(settings) = input.settings else {
            throw ProviderTurnConfigurationError.settingsMismatch
        }
        let effort = try ProviderTurnConfigurationAdapters.resolvedEffort(input)
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            for: input.permissionID,
            readOnly: [],
            workspaceWrite: ["claude.requireApproval", "claude.autoApproveEdits", "claude.auto"],
            fullAccess: ["claude.fullAccess"],
            scopedResources: input.scopedResources
        )
        let permissionMode: String = switch input.permissionID.rawValue {
        case "claude.requireApproval": "default"
        case "claude.autoApproveEdits": "acceptEdits"
        case "claude.auto": "auto"
        case "claude.fullAccess": "bypassPermissions"
        default: throw ProviderTurnConfigurationError.unsupportedPermission(input.permissionID)
        }
        var native: [String: String] = [
            "claude.bashEnabled": String(settings.bashEnabled),
            "claude.strictMCPEnabled": String(settings.strictMCPEnabled),
            "claude.toolSearchEnabled": String(settings.toolSearchEnabled),
            "claude.promptDelivery": settings.promptDelivery.rawValue,
            "claude.permissionMode": permissionMode,
            "provider.settingsId": providerID.rawValue,
            "provider.permissionId": input.permissionID.rawValue
        ]
        if let effort { native["provider.reasoningEffort"] = effort }
        return .init(
            runtimeKind: .claudeCompatible,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            supportsNativeImages: input.model.capabilities.nativeImages,
            providerSettings: native
        )
    }
}

public struct TextOnlyACPTurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID: ProviderSettingsID

    public init(providerID: ProviderSettingsID) {
        self.providerID = providerID
    }

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard [.openCodeACP, .cursorACP, .grokBuildACP].contains(providerID),
              input.model.providerID == providerID
        else {
            throw ProviderTurnConfigurationError.providerModelMismatch
        }
        guard case .acp = input.settings else {
            throw ProviderTurnConfigurationError.settingsMismatch
        }
        let effort = try ProviderTurnConfigurationAdapters.resolvedEffort(input)
        let prefix: String = switch providerID {
        case .openCodeACP: "opencode"
        case .cursorACP: "cursor"
        case .grokBuildACP: "grok"
        default: throw ProviderTurnConfigurationError.providerModelMismatch
        }
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            for: input.permissionID,
            readOnly: [],
            workspaceWrite: ["\(prefix).managedDefault"],
            fullAccess: ["\(prefix).fullAccess"],
            scopedResources: input.scopedResources
        )
        return .init(
            runtimeKind: providerID.runtimeKind,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            supportsNativeImages: input.model.capabilities.nativeImages,
            providerSettings: ["provider.permissionId": input.permissionID.rawValue]
        )
    }
}

public struct DirectAPITurnConfigurationAdapter: ProviderTurnConfigurationAdapter {
    public let providerID: ProviderSettingsID

    public init(providerID: ProviderSettingsID) {
        self.providerID = providerID
    }

    public func compile(_ input: ProviderTurnConfigurationInput) throws -> CompiledProviderTurnConfiguration {
        guard input.model.providerID == providerID else {
            throw ProviderTurnConfigurationError.providerModelMismatch
        }
        guard case .directAPI = input.settings else {
            throw ProviderTurnConfigurationError.settingsMismatch
        }
        let effort = try ProviderTurnConfigurationAdapters.resolvedEffort(input)
        let permissions = try ProviderTurnConfigurationAdapters.permissions(
            for: input.permissionID,
            readOnly: ["provider.readOnly"],
            workspaceWrite: ["provider.workspaceWrite"],
            fullAccess: ["provider.fullAccess"],
            scopedResources: input.scopedResources
        )
        var settings = [
            "provider.settingsId": providerID.rawValue,
            "provider.permissionId": input.permissionID.rawValue
        ]
        if let effort { settings["provider.reasoningEffort"] = effort }
        return .init(
            runtimeKind: .headlessAdapter,
            providerRawModelValue: input.model.providerRawValue,
            effortID: effort,
            permissions: permissions,
            supportsNativeImages: input.model.capabilities.nativeImages,
            providerSettings: settings
        )
    }
}
