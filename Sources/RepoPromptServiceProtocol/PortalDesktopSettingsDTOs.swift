import Foundation

/// Browser-safe, server-authoritative projection of the settings that RepoPrompt
/// Desktop persists outside provider credential storage. Values use stable string
/// encodings so the portal can share one optimistic-concurrency contract across
/// booleans, choices, numbers, and small JSON collections without ever accepting
/// credential-shaped fields.
public struct PortalDesktopSettingsSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: Int64
    public let values: [String: String]
    public let updatedAt: Date

    public init(schemaVersion: Int = 1, revision: Int64, values: [String: String], updatedAt: Date) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.values = values
        self.updatedAt = updatedAt
    }
}

public struct UpdatePortalDesktopSettingsRequest: Codable, Sendable, Equatable {
    public let expectedRevision: Int64
    public let changes: [String: String]

    public init(expectedRevision: Int64, changes: [String: String]) {
        self.expectedRevision = expectedRevision
        self.changes = changes
    }
}

public enum PortalDesktopSettingMutability: String, Codable, Sendable {
    case runtimeBackedP0
    case supersededByTypedSettings
    case compatibilityReadOnly
}

public enum PortalDesktopSettingKey: String, CaseIterable, Codable, Sendable {
    // Agent Mode overview and models
    case providerConversationCleanupAction
    case agentSessionHandoffInstructions
    case oracleModel
    case contextBuilderAgent
    case contextBuilderModel
    case exploreRoleModel
    case engineerRoleModel
    case pairRoleModel
    case designRoleModel
    case restrictAgentDiscoveryToRoles

    // Direct providers and sub-agents
    case codexPermissionLevel
    case codexBashEnabled
    case codexSearchEnabled
    case codexGoalsEnabled
    case codexReasoningSummariesEnabled
    case codexMemoriesEnabled
    case codexEnabledMCPServers
    case claudePermissionLevel
    case claudeBashEnabled
    case claudeStrictMCPEnabled
    case claudeToolSearchEnabled
    case claudeGLMDisplayName
    case claudeGLMBaseURL
    case claudeGLMAuthHeader
    case claudeGLMHaikuModel
    case claudeGLMSonnetModel
    case claudeGLMOpusModel
    case claudeKimiDisplayName
    case claudeKimiBaseURL
    case claudeKimiAuthHeader
    case claudeCustomDisplayName
    case claudeCustomBaseURL
    case claudeCustomAuthHeader
    case claudeCustomModelBehavior
    case claudeCustomHaikuModel
    case claudeCustomSonnetModel
    case claudeCustomOpusModel
    case openCodePermissionLevel
    case cursorPermissionLevel
    case subagentPolicy
    case subagentCodexPermissionLevel
    case subagentClaudePermissionLevel
    case subagentOpenCodePermissionLevel
    case subagentCursorPermissionLevel

    // Agent workflows and Context Builder
    case includeWorkflowCleanupGuidance
    case featuredWorkflows
    case customWorkflows
    case contextBuilderBudget
    case contextBuilderEnhancementMode
    case contextBuilderQuestionTimeout
    case contextBuilderUIClarifyingQuestions
    case contextBuilderFollowUpAnalysis
    case contextBuilderAnalysisBudget
    case contextBuilderMCPClarifyingQuestions
    case contextBuilderCustomInstructions

    // MCP server
    case mcpToolsEnabled
    case mcpUseModelPresets
    case mcpDisabledTools
    case workspaceApprovalsGlobal
    case workspaceApprovalOperations
    case modelPresets

    // Models and providers
    case openAIServiceTier
    case openAIShowServiceTierVariants
    case openRouterIncludeDefaults
    case openRouterUseCustomSettings
    case openRouterMaxTokens
    case customProviderIncludeContentType
    case modelOverrides

    // Projects, worktrees, and server defaults
    case defaultWorktreeMode
    case worktreeBaseRef
    case removeCompletedWorktrees
    case serverDefaultExecutionMode

    public var mutability: PortalDesktopSettingMutability {
        switch self {
        case .codexPermissionLevel,
             .codexBashEnabled,
             .codexSearchEnabled,
             .codexGoalsEnabled,
             .codexReasoningSummariesEnabled,
             .codexMemoriesEnabled,
             .codexEnabledMCPServers,
             .claudePermissionLevel,
             .claudeBashEnabled,
             .claudeStrictMCPEnabled,
             .claudeToolSearchEnabled,
             .claudeGLMDisplayName,
             .claudeGLMBaseURL,
             .claudeGLMAuthHeader,
             .claudeGLMHaikuModel,
             .claudeGLMSonnetModel,
             .claudeGLMOpusModel,
             .claudeKimiDisplayName,
             .claudeKimiBaseURL,
             .claudeKimiAuthHeader,
             .claudeCustomDisplayName,
             .claudeCustomBaseURL,
             .claudeCustomAuthHeader,
             .claudeCustomModelBehavior,
             .claudeCustomHaikuModel,
             .claudeCustomSonnetModel,
             .claudeCustomOpusModel,
             .openCodePermissionLevel,
             .cursorPermissionLevel,
             .serverDefaultExecutionMode:
            .runtimeBackedP0
        case .oracleModel,
             .contextBuilderAgent,
             .contextBuilderModel,
             .exploreRoleModel,
             .engineerRoleModel,
             .pairRoleModel,
             .designRoleModel,
             .restrictAgentDiscoveryToRoles,
             .subagentPolicy,
             .subagentCodexPermissionLevel,
             .subagentClaudePermissionLevel,
             .subagentOpenCodePermissionLevel,
             .subagentCursorPermissionLevel,
             .contextBuilderBudget,
             .contextBuilderEnhancementMode,
             .contextBuilderQuestionTimeout,
             .contextBuilderUIClarifyingQuestions,
             .contextBuilderFollowUpAnalysis,
             .contextBuilderAnalysisBudget,
             .contextBuilderMCPClarifyingQuestions,
             .contextBuilderCustomInstructions,
             .modelPresets:
            .supersededByTypedSettings
        default:
            .compatibilityReadOnly
        }
    }

    public var isMutable: Bool { mutability == .runtimeBackedP0 }

    public static var defaultValues: [String: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultValue) })
    }

    public var defaultValue: String {
        switch self {
        case .restrictAgentDiscoveryToRoles,
             .codexReasoningSummariesEnabled,
             .codexMemoriesEnabled,
             .claudeStrictMCPEnabled,
             .contextBuilderFollowUpAnalysis,
             .contextBuilderMCPClarifyingQuestions,
             .workspaceApprovalsGlobal,
             .openAIShowServiceTierVariants,
             .openRouterUseCustomSettings,
             .removeCompletedWorktrees:
            "false"
        case .codexBashEnabled,
             .codexSearchEnabled,
             .codexGoalsEnabled,
             .claudeBashEnabled,
             .claudeToolSearchEnabled,
             .includeWorkflowCleanupGuidance,
             .contextBuilderUIClarifyingQuestions,
             .mcpToolsEnabled,
             .mcpUseModelPresets,
             .openRouterIncludeDefaults,
             .customProviderIncludeContentType:
            "true"
        case .providerConversationCleanupAction: "archive"
        case .agentSessionHandoffInstructions,
             .oracleModel,
             .contextBuilderModel,
             .exploreRoleModel,
             .engineerRoleModel,
             .pairRoleModel,
             .designRoleModel,
             .contextBuilderCustomInstructions,
             .worktreeBaseRef:
            ""
        case .claudeGLMDisplayName: "CC Zai"
        case .claudeGLMBaseURL: "https://api.z.ai/api/anthropic"
        case .claudeGLMAuthHeader: "anthropicAuthToken"
        case .claudeGLMHaikuModel: "glm-4.5-air"
        case .claudeGLMSonnetModel, .claudeGLMOpusModel: "glm-5.2[1m]"
        case .claudeKimiDisplayName: "CC Moonshot"
        case .claudeKimiBaseURL: "https://api.kimi.com/coding/"
        case .claudeKimiAuthHeader: "anthropicAPIKey"
        case .claudeCustomDisplayName: "CC Custom"
        case .claudeCustomBaseURL: ""
        case .claudeCustomAuthHeader: "anthropicAPIKey"
        case .claudeCustomModelBehavior: "noModel"
        case .claudeCustomHaikuModel, .claudeCustomSonnetModel, .claudeCustomOpusModel:
            ""
        case .contextBuilderAgent: "codexExec"
        case .codexPermissionLevel, .subagentCodexPermissionLevel: "autoReview"
        case .claudePermissionLevel, .subagentClaudePermissionLevel: "requireApproval"
        case .openCodePermissionLevel, .subagentOpenCodePermissionLevel,
             .cursorPermissionLevel, .subagentCursorPermissionLevel:
            "managedDefault"
        case .codexEnabledMCPServers:
            "[\"RepoPromptCE\"]"
        case .subagentPolicy: "safeManaged"
        case .featuredWorkflows:
            "[\"build\",\"investigate\",\"oracleExport\",\"orchestrate\",\"optimize\",\"deepPlan\"]"
        case .customWorkflows, .mcpDisabledTools, .modelPresets, .modelOverrides:
            "[]"
        case .contextBuilderBudget: "160000"
        case .contextBuilderEnhancementMode: "fullRewrite"
        case .contextBuilderQuestionTimeout: "60"
        case .contextBuilderAnalysisBudget: "32000"
        case .workspaceApprovalOperations: "[]"
        case .openAIServiceTier: "auto"
        case .openRouterMaxTokens: "0"
        case .defaultWorktreeMode: "isolated"
        case .serverDefaultExecutionMode: "workspaceWrite"
        }
    }

    public func validated(_ value: String) throws -> String {
        guard value.utf8.count <= 65_536 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Setting value exceeds its supported size")
        }

        switch self {
        case .restrictAgentDiscoveryToRoles,
             .codexBashEnabled,
             .codexSearchEnabled,
             .codexGoalsEnabled,
             .codexReasoningSummariesEnabled,
             .codexMemoriesEnabled,
             .claudeBashEnabled,
             .claudeStrictMCPEnabled,
             .claudeToolSearchEnabled,
             .includeWorkflowCleanupGuidance,
             .contextBuilderUIClarifyingQuestions,
             .contextBuilderFollowUpAnalysis,
             .contextBuilderMCPClarifyingQuestions,
             .mcpToolsEnabled,
             .mcpUseModelPresets,
             .workspaceApprovalsGlobal,
             .openAIShowServiceTierVariants,
             .openRouterIncludeDefaults,
             .openRouterUseCustomSettings,
             .customProviderIncludeContentType,
             .removeCompletedWorktrees:
            guard value == "true" || value == "false" else {
                throw ServiceAPIError(code: .invalidRequest, message: "Setting requires a Boolean value")
            }
        case .providerConversationCleanupAction:
            try Self.require(value, in: ["archive", "delete"])
        case .contextBuilderAgent:
            try Self.require(value, in: ["claudeCode", "codexExec", "openCode", "cursor"])
        case .codexPermissionLevel, .subagentCodexPermissionLevel:
            try Self.require(value, in: ["readOnly", "defaultPermission", "autoReview", "fullAccess"])
        case .claudePermissionLevel, .subagentClaudePermissionLevel:
            try Self.require(value, in: ["requireApproval", "autoApproveEdits", "auto", "fullAccess"])
        case .openCodePermissionLevel, .subagentOpenCodePermissionLevel,
             .cursorPermissionLevel, .subagentCursorPermissionLevel:
            try Self.require(value, in: ["managedDefault", "fullAccess"])
        case .subagentPolicy:
            try Self.require(value, in: ["safeManaged", "inheritProviderSettings", "custom"])
        case .contextBuilderEnhancementMode:
            try Self.require(value, in: ["fullRewrite", "augment", "preserve"])
        case .openAIServiceTier:
            try Self.require(value, in: ["auto", "default", "flex", "priority"])
        case .defaultWorktreeMode:
            try Self.require(value, in: ["isolated", "currentCheckout", "disabled"])
        case .serverDefaultExecutionMode:
            try Self.require(value, in: ["readOnly", "workspaceWrite", "fullAccess"])
        case .claudeGLMAuthHeader, .claudeKimiAuthHeader, .claudeCustomAuthHeader:
            try Self.require(value, in: ["anthropicAPIKey", "anthropicAuthToken"])
        case .claudeCustomModelBehavior:
            try Self.require(value, in: ["noModel", "claudeSlotMapping"])
        case .contextBuilderBudget:
            try Self.requireInteger(value, range: 8_000 ... 240_000)
        case .contextBuilderQuestionTimeout:
            try Self.requireInteger(value, range: 30 ... 300)
            try Self.require(value, in: ["30", "60", "120", "300"])
        case .contextBuilderAnalysisBudget:
            try Self.requireInteger(value, range: 8_000 ... 240_000)
        case .openRouterMaxTokens:
            try Self.requireInteger(value, range: 0 ... 2_000_000)
        case .codexEnabledMCPServers,
             .featuredWorkflows,
             .customWorkflows,
             .mcpDisabledTools,
             .workspaceApprovalOperations,
             .modelPresets,
             .modelOverrides:
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  object is [Any]
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "Setting requires a JSON array")
            }
        case .agentSessionHandoffInstructions,
             .oracleModel,
             .contextBuilderModel,
             .exploreRoleModel,
             .engineerRoleModel,
             .pairRoleModel,
             .designRoleModel,
             .contextBuilderCustomInstructions,
             .worktreeBaseRef,
             .claudeGLMDisplayName,
             .claudeGLMHaikuModel,
             .claudeGLMSonnetModel,
             .claudeGLMOpusModel,
             .claudeKimiDisplayName,
             .claudeCustomDisplayName,
             .claudeCustomHaikuModel,
             .claudeCustomSonnetModel,
             .claudeCustomOpusModel:
            try Self.requirePlainText(value)
        case .claudeGLMBaseURL, .claudeKimiBaseURL:
            try Self.requireHTTPSURL(value, allowEmpty: false)
        case .claudeCustomBaseURL:
            try Self.requireHTTPSURL(value, allowEmpty: true)
        }
        return value
    }

    private static func require(_ value: String, in allowed: Set<String>) throws {
        guard allowed.contains(value) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Setting value is not supported")
        }
    }

    private static func requireInteger(_ value: String, range: ClosedRange<Int>) throws {
        guard let number = Int(value), range.contains(number) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Setting number is outside its supported range")
        }
    }

    private static func requirePlainText(_ value: String) throws {
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Setting text is invalid") }
    }

    private static func requireHTTPSURL(_ value: String, allowEmpty: Bool) throws {
        if allowEmpty, value.isEmpty { return }
        guard value.utf8.count <= 2048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Backend URL must be a credential-free HTTPS URL") }
    }
}
