import Foundation
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public protocol ServerSettingsProviderCatalogProviding: Sendable {
    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse
}

public protocol ServerSettingsProjectCatalogProviding: Sendable {
    func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID>
}

public actor ServerSettingsService {
    public static let recommendationProfileVersion = "202_608"

    private let store: SQLiteServiceStore
    private let providerCatalog: any ServerSettingsProviderCatalogProviding
    private let projectCatalog: any ServerSettingsProjectCatalogProviding
    private let now: @Sendable () -> Date

    public init(
        store: SQLiteServiceStore,
        providerCatalog: any ServerSettingsProviderCatalogProviding,
        projectCatalog: any ServerSettingsProjectCatalogProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.providerCatalog = providerCatalog
        self.projectCatalog = projectCatalog
        self.now = now
    }

    public func agentModels(projectID: UUID? = nil) async throws -> AgentModelsSettingsSnapshot {
        if let projectID { _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID) }
        let global = try await store.agentModelsDocument(scopeID: "global")
        let globalProfile = global?.value.profile ?? .default
        let project: StoredSettingsDocument<AgentModelsScopeDocument>?
        if let projectID {
            project = try await store.agentModelsDocument(scopeID: scopeID(projectID))
        } else {
            project = nil
        }
        let projectMode = project?.value.mode ?? .inheritGlobal
        let projectProfile = project?.value.profile
        let effective = projectMode == .projectOverride ? (projectProfile ?? globalProfile) : globalProfile
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        return AgentModelsSettingsSnapshot(
            globalProfile: globalProfile,
            globalRevision: global?.revision ?? 0,
            projectID: projectID,
            projectMode: projectMode,
            projectProfile: projectProfile,
            projectRevision: project?.revision ?? 0,
            effectiveProfile: effective,
            recommendationProfileVersion: Self.recommendationProfileVersion,
            recommendations: recommendationRows(catalog: catalog),
            updatedAt: max(global?.updatedAt ?? epoch, project?.updatedAt ?? epoch)
        )
    }

    public func replaceGlobalAgentModels(
        _ request: ReplaceGlobalAgentModelsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let profile = try normalize(request.profile, catalog: catalog)
        let value = AgentModelsScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: "global",
            projectID: nil,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceGlobal", attribution: attribution, payload: value)
        )
        return try await agentModels()
    }

    public func replaceProjectAgentModels(
        projectID: UUID,
        request: ReplaceProjectAgentModelsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let value = try normalizeProjectAgentModels(mode: request.mode, profile: request.profile, catalog: catalog)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceProject", attribution: attribution, payload: value)
        )
        return try await agentModels(projectID: projectID)
    }

    public func copyGlobalAgentModelsToProject(
        projectID: UUID,
        request: CopyGlobalAgentModelsToProjectRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let global = try await store.agentModelsDocument(scopeID: "global")
        let observedGlobalRevision = global?.revision ?? 0
        guard observedGlobalRevision == request.expectedGlobalRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Global Agent Models revision is stale", currentRevision: observedGlobalRevision)
        }
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let profile = try normalize(global?.value.profile ?? .default, catalog: catalog)
        let value = AgentModelsScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedProjectRevision + 1, updatedAt: now())
        _ = try await store.upsertAgentModelsDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedProjectRevision,
            expectedGlobalRevision: request.expectedGlobalRevision,
            audit: try audit(operation: "copyGlobal", attribution: attribution, payload: value)
        )
        return try await agentModels(projectID: projectID)
    }

    public func applyGlobalAgentModelRecommendations(
        _ request: ApplyAgentModelRecommendationsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        let current = try await agentModels()
        guard current.globalRevision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Global Agent Models revision is stale", currentRevision: current.globalRevision)
        }
        let profile = applying(current.recommendations, to: current.globalProfile)
        return try await replaceGlobalAgentModels(
            .init(expectedRevision: request.expectedRevision, profile: profile),
            attribution: attribution
        )
    }

    public func applyProjectAgentModelRecommendations(
        projectID: UUID,
        request: ApplyAgentModelRecommendationsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AgentModelsSettingsSnapshot {
        let current = try await agentModels(projectID: projectID)
        guard current.projectRevision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Project Agent Models revision is stale", currentRevision: current.projectRevision)
        }
        let profile = applying(current.recommendations, to: current.effectiveProfile)
        return try await replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: request.expectedRevision, mode: .projectOverride, profile: profile),
            attribution: attribution
        )
    }

    public func resolveAgentTarget(
        projectID: UUID,
        target: AgentRoutingTarget
    ) async throws -> ResolvedAgentModelRoute? {
        let snapshot = try await agentModels(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        guard let assigned = snapshot.effectiveProfile[target] else { return nil }
        if let route = runtimeRoute(assigned, target: target, catalog: catalog, usedRecommendationFallback: false) {
            return route
        }
        if assigned.pinned {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "The pinned \(target.rawValue) Agent Model target is unavailable",
                retryable: true
            )
        }
        guard let recommended = recommendationTarget(target: target, catalog: catalog, requireEffective: true) else {
            return nil
        }
        return runtimeRoute(recommended, target: target, catalog: catalog, usedRecommendationFallback: true)
    }

    public func providerCatalogSnapshot() async throws -> ProviderSettingsCatalogResponse {
        try await providerCatalog.serverSettingsProviderCatalog()
    }

    public func subagentPermissions() async -> SubagentPermissionSettingsSnapshot {
        guard let document = try? await store.subagentPermissionDocument() else {
            return .init(settings: .safeManaged, revision: 0, updatedAt: epoch)
        }
        return .init(settings: document.value, revision: document.revision, updatedAt: document.updatedAt)
    }

    public func replaceSubagentPermissions(
        _ request: ReplaceSubagentPermissionSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> SubagentPermissionSettingsSnapshot {
        let document = StoredSettingsDocument(
            value: request.settings,
            revision: request.expectedRevision + 1,
            updatedAt: now()
        )
        let stored = try await store.upsertSubagentPermissionDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func contextBuilder(projectID: UUID? = nil) async throws -> ContextBuilderSettingsSnapshot {
        if let projectID { _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID) }
        let global = try await store.contextBuilderDocument(scopeID: "global")
        let globalProfile = global?.value.profile ?? .default
        let project: StoredSettingsDocument<ContextBuilderScopeDocument>?
        if let projectID {
            project = try await store.contextBuilderDocument(scopeID: scopeID(projectID))
        } else {
            project = nil
        }
        let projectMode = project?.value.mode ?? .inheritGlobal
        let projectProfile = project?.value.profile
        let effective = projectMode == .projectOverride ? (projectProfile ?? globalProfile) : globalProfile
        return .init(
            globalProfile: globalProfile,
            globalRevision: global?.revision ?? 0,
            projectID: projectID,
            projectMode: projectMode,
            projectProfile: projectProfile,
            projectRevision: project?.revision ?? 0,
            effectiveProfile: effective,
            updatedAt: max(global?.updatedAt ?? epoch, project?.updatedAt ?? epoch)
        )
    }

    public func replaceGlobalContextBuilder(
        _ request: ReplaceGlobalContextBuilderSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ContextBuilderSettingsSnapshot {
        let profile = try normalize(request.profile)
        let value = ContextBuilderScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertContextBuilderDocument(
            document,
            scopeID: "global",
            projectID: nil,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceGlobal", attribution: attribution, payload: value)
        )
        return try await contextBuilder()
    }

    public func replaceProjectContextBuilder(
        projectID: UUID,
        request: ReplaceProjectContextBuilderSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ContextBuilderSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let value = try normalizeProjectContextBuilder(mode: request.mode, profile: request.profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedRevision + 1, updatedAt: now())
        _ = try await store.upsertContextBuilderDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceProject", attribution: attribution, payload: value)
        )
        return try await contextBuilder(projectID: projectID)
    }

    public func copyGlobalContextBuilderToProject(
        projectID: UUID,
        request: CopyGlobalContextBuilderToProjectRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ContextBuilderSettingsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let global = try await store.contextBuilderDocument(scopeID: "global")
        let observedGlobalRevision = global?.revision ?? 0
        guard observedGlobalRevision == request.expectedGlobalRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Global Context Builder revision is stale", currentRevision: observedGlobalRevision)
        }
        let profile = try normalize(global?.value.profile ?? .default)
        let value = ContextBuilderScopeDocument(mode: .projectOverride, profile: profile)
        let document = StoredSettingsDocument(value: value, revision: request.expectedProjectRevision + 1, updatedAt: now())
        _ = try await store.upsertContextBuilderDocument(
            document,
            scopeID: scopeID(projectID),
            projectID: projectID,
            expectedRevision: request.expectedProjectRevision,
            expectedGlobalRevision: request.expectedGlobalRevision,
            audit: try audit(operation: "copyGlobal", attribution: attribution, payload: value)
        )
        return try await contextBuilder(projectID: projectID)
    }

    public func resolveContextBuilder(
        projectID: UUID,
        origin: ContextBuilderInvocationOrigin,
        overrides: ContextBuilderInvocationOverrides = .init()
    ) async throws -> EffectiveContextBuilderSettings {
        let profile = try await contextBuilder(projectID: projectID).effectiveProfile
        let allowQuestions = overrides.allowClarifyingQuestions ?? {
            switch origin {
            case .portal: profile.portalClarifyingQuestions
            case .mcp: profile.mcpClarifyingQuestions
            case .internal: false
            }
        }()
        let selected: [ContextBuilderSavedPrompt]
        if let selectedIDs = overrides.selectedPromptIDs {
            guard selectedIDs.count <= 100, Set(selectedIDs).count == selectedIDs.count else {
                throw ServiceAPIError(code: .invalidRequest, message: "Context Builder prompt selection is invalid")
            }
            let byID = Dictionary(uniqueKeysWithValues: profile.prompts.map { ($0.promptID, $0) })
            selected = try selectedIDs.map { id -> ContextBuilderSavedPrompt in
                guard let prompt = byID[id], prompt.enabled else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Context Builder prompt is unavailable")
                }
                return prompt
            }
        } else {
            selected = profile.prompts.filter(\.enabled).sorted { $0.order < $1.order }
        }
        let effective = ContextBuilderSettingsProfile(
            budget: overrides.budget ?? profile.budget,
            enhancementMode: overrides.enhancementMode ?? profile.enhancementMode,
            questionTimeoutSeconds: overrides.questionTimeoutSeconds ?? profile.questionTimeoutSeconds,
            portalClarifyingQuestions: allowQuestions,
            mcpClarifyingQuestions: allowQuestions,
            followUpAnalysis: overrides.followUpAnalysis ?? profile.followUpAnalysis,
            followUpBudget: overrides.followUpBudget ?? profile.followUpBudget,
            prompts: selected
        )
        let validated = try normalize(effective)
        return .init(
            budget: validated.budget,
            enhancementMode: validated.enhancementMode,
            allowClarifyingQuestions: allowQuestions,
            questionTimeoutSeconds: validated.questionTimeoutSeconds,
            followUpAnalysis: validated.followUpAnalysis,
            followUpBudget: validated.followUpBudget,
            prompts: validated.prompts
        )
    }

    public func renderContextBuilderInstructions(
        _ instructions: String,
        effective: EffectiveContextBuilderSettings
    ) throws -> String {
        guard !instructions.isEmpty, instructions.utf8.count <= 64_000 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder instructions are empty or exceed their bound")
        }
        switch effective.enhancementMode {
        case .preserve:
            return instructions
        case .augment:
            return [renderSavedPrompts(effective.prompts), instructions]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case .rewrite:
            let prompts = renderSavedPrompts(effective.prompts)
            return """
            <context-builder-enhancement mode="rewrite">
            Produce a replacement handoff prompt grounded in repository discovery. Preserve every material constraint from the caller and integrate the enabled saved instructions below.
            </context-builder-enhancement>
            \(prompts)

            <caller-instructions>
            \(instructions)
            </caller-instructions>
            """
        }
    }

    public func modelPresets() async throws -> MCPModelPresetsSnapshot {
        let document = try await store.mcpModelPresetsDocument()
        return .init(presets: document?.value ?? [], revision: document?.revision ?? 0, updatedAt: document?.updatedAt ?? epoch)
    }

    public func resolveModelPreset(
        presetID: UUID,
        availability: MCPModelPresetAvailability
    ) async throws -> ResolvedAgentModelRoute {
        let snapshot = try await modelPresets()
        guard let preset = snapshot.presets.first(where: { $0.presetID == presetID }), preset.enabled else {
            throw ServiceAPIError(code: .notFound, message: "MCP model preset is missing or disabled")
        }
        guard preset.availability.contains(availability) else {
            throw ServiceAPIError(code: .invalidRequest, message: "MCP model preset is unavailable for this Oracle mode")
        }
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        guard let route = runtimeRoute(preset.target, target: .oracle, catalog: catalog, usedRecommendationFallback: false) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "MCP model preset target is unavailable", retryable: true)
        }
        return route
    }

    public func modelDiscovery(projectID: UUID) async throws -> MCPModelDiscoverySnapshot {
        let profile = try await agentModels(projectID: projectID)
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let presets = try await modelPresets()
        guard profile.effectiveProfile.restrictDiscoveryToRoleModels else {
            return .init(
                providers: catalog.providers,
                presets: presets.presets.filter(\.enabled),
                roleModelRestrictionApplied: false,
                settingsRevision: max(max(profile.globalRevision, profile.projectRevision), presets.revision)
            )
        }
        var allowed = Set<String>()
        for target in AgentRoutingTarget.allCases {
            if let route = try await resolveAgentTarget(projectID: projectID, target: target), let model = route.modelID {
                allowed.insert("\(route.providerID.rawValue)\u{0}\(model)")
            }
        }
        let filtered = catalog.providers.compactMap { provider -> ProviderSettingsSnapshot? in
            let models = provider.models.filter { allowed.contains("\(provider.providerID.rawValue)\u{0}\($0.id)") }
            guard !models.isEmpty else { return nil }
            return ProviderSettingsSnapshot(
                providerID: provider.providerID,
                displayName: provider.displayName,
                category: provider.category,
                summary: provider.summary,
                deploymentAllowed: provider.deploymentAllowed,
                runtimePreflightVerified: provider.runtimePreflightVerified,
                effectiveEnabled: provider.effectiveEnabled,
                preference: provider.preference,
                cli: provider.cli,
                authentication: provider.authentication,
                connection: provider.connection,
                preflight: provider.preflight,
                capabilities: provider.capabilities,
                models: models
            )
        }
        return .init(
            providers: filtered,
            presets: presets.presets.filter(\.enabled),
            roleModelRestrictionApplied: true,
            settingsRevision: max(max(profile.globalRevision, profile.projectRevision), presets.revision)
        )
    }

    public func replaceModelPresets(
        _ request: ReplaceMCPModelPresetsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> MCPModelPresetsSnapshot {
        let catalog = try await providerCatalog.serverSettingsProviderCatalog()
        let presets = try normalize(request.presets, catalog: catalog)
        let document = StoredSettingsDocument(value: presets, revision: request.expectedRevision + 1, updatedAt: now())
        let stored = try await store.upsertMCPModelPresetsDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceGlobal", attribution: attribution, payload: presets)
        )
        return .init(presets: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func advanced() async throws -> AdvancedServerSettingsSnapshot {
        let document = try await store.advancedServerSettingsDocument()
        return .init(settings: document?.value ?? .default, revision: document?.revision ?? 0, updatedAt: document?.updatedAt ?? epoch)
    }

    public func replaceAdvanced(
        _ request: ReplaceAdvancedServerSettingsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> AdvancedServerSettingsSnapshot {
        guard (0 ... 60).contains(request.settings.historyIdleThresholdMinutes) else {
            throw ServiceAPIError(code: .invalidRequest, message: "History idle threshold is outside its supported range")
        }
        let document = StoredSettingsDocument(value: request.settings, revision: request.expectedRevision + 1, updatedAt: now())
        let stored = try await store.upsertAdvancedServerSettingsDocument(
            document,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceGlobal", attribution: attribution, payload: request.settings)
        )
        return .init(settings: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }

    public func selectionPresets(projectID: UUID) async throws -> ProjectSelectionPresetsSnapshot {
        _ = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let document = try await store.projectSelectionPresetsDocument(projectID: projectID)
        return .init(projectID: projectID, presets: document?.value ?? [], revision: document?.revision ?? 0, updatedAt: document?.updatedAt ?? epoch)
    }

    public func replaceSelectionPresets(
        projectID: UUID,
        request: ReplaceProjectSelectionPresetsRequest,
        attribution: SettingsMutationAttribution
    ) async throws -> ProjectSelectionPresetsSnapshot {
        let roots = try await projectCatalog.serverSettingsRootIDs(projectID: projectID)
        let presets = try normalize(request.presets, projectID: projectID, roots: roots)
        let document = StoredSettingsDocument(value: presets, revision: request.expectedRevision + 1, updatedAt: now())
        let stored = try await store.upsertProjectSelectionPresetsDocument(
            document,
            projectID: projectID,
            expectedRevision: request.expectedRevision,
            audit: try audit(operation: "replaceProject", attribution: attribution, payload: presets)
        )
        return .init(projectID: projectID, presets: stored.value, revision: stored.revision, updatedAt: stored.updatedAt)
    }
}

extension ProviderSettingsService: ServerSettingsProviderCatalogProviding {
    public func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse {
        try await catalog()
    }
}

extension SQLiteServiceStore: ServerSettingsProjectCatalogProviding {
    public func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID> {
        guard let project = try await project(id: projectID), project.state != .archived else {
            throw ServiceAPIError(code: .notFound, message: "Project not found")
        }
        return Set(project.roots.map(\.rootID))
    }
}

private extension ServerSettingsService {
    struct RecommendationCandidate {
        let providerID: ProviderSettingsID
        let modelTokens: [String]
        let reasoningEffort: String?
    }

    var epoch: Date { Date(timeIntervalSince1970: 0) }

    func scopeID(_ projectID: UUID) -> String { projectID.uuidString.lowercased() }

    func audit<Payload: Encodable>(
        operation: String,
        attribution: SettingsMutationAttribution,
        payload: Payload
    ) throws -> ServerSettingsAuditMutation {
        let data = try JSONEncoder.serviceEncoder.encode(payload)
        return .init(operation: operation, attribution: attribution, payloadDigest: CanonicalSigning.bodyDigest(data))
    }

    func normalizeProjectAgentModels(
        mode: AgentModelsScopeMode,
        profile: AgentModelsProfile?,
        catalog: ProviderSettingsCatalogResponse
    ) throws -> AgentModelsScopeDocument {
        switch mode {
        case .inheritGlobal:
            guard profile == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Inherited Agent Models settings cannot contain an override") }
            return .init(mode: mode, profile: nil)
        case .projectOverride:
            guard let profile else { throw ServiceAPIError(code: .invalidRequest, message: "Project Agent Models override is missing") }
            return .init(mode: mode, profile: try normalize(profile, catalog: catalog))
        }
    }

    func normalize(_ profile: AgentModelsProfile, catalog: ProviderSettingsCatalogResponse) throws -> AgentModelsProfile {
        func target(_ value: AgentModelTarget?) throws -> AgentModelTarget? {
            guard let value else { return nil }
            guard let provider = catalog.providers.first(where: { $0.providerID == value.providerID }) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Agent model provider is not in the server catalog")
            }
            let modelID = try normalizedText(value.modelID, maximumBytes: 256)
            let effort = try normalizedText(value.reasoningEffort, maximumBytes: 64)?.lowercased()
            if effort != nil, modelID == nil {
                throw ServiceAPIError(code: .invalidRequest, message: "Agent model reasoning effort requires a model")
            }
            if let modelID {
                guard let model = provider.models.first(where: { $0.id == modelID }) else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Agent model is not in the provider catalog")
                }
                if let effort, !model.reasoningEfforts.contains(effort) {
                    throw ServiceAPIError(code: .invalidRequest, message: "Agent model reasoning effort is not advertised")
                }
            }
            return AgentModelTarget(providerID: value.providerID, modelID: modelID, reasoningEffort: effort, pinned: value.pinned)
        }
        return try AgentModelsProfile(
            oracle: target(profile.oracle),
            contextBuilder: target(profile.contextBuilder),
            explore: target(profile.explore),
            engineer: target(profile.engineer),
            pair: target(profile.pair),
            design: target(profile.design),
            restrictDiscoveryToRoleModels: profile.restrictDiscoveryToRoleModels
        )
    }

    func applying(_ recommendations: [AgentModelRecommendationRow], to profile: AgentModelsProfile) -> AgentModelsProfile {
        recommendations.reduce(profile) { result, row in
            guard row.availability == .exact,
                  let target = row.recommendedTarget,
                  result[row.target]?.pinned != true
            else { return result }
            return result.replacing(row.target, with: target)
        }
    }

    func recommendationRows(catalog: ProviderSettingsCatalogResponse) -> [AgentModelRecommendationRow] {
        recommendationChains().map { target, candidates in
            if let exact = recommendationTarget(
                target: target,
                candidates: candidates,
                catalog: catalog,
                requireEffective: false
            ) {
                return AgentModelRecommendationRow(
                    target: target,
                    recommendedTarget: exact,
                    availability: .exact,
                    detail: "Exact profile \(Self.recommendationProfileVersion) target is advertised"
                )
            }
            let sawAdvertisedProvider = candidates.contains { candidate in
                candidate.providerID != .openCodeACP
                    && catalog.providers.contains { $0.providerID == candidate.providerID && $0.deploymentAllowed }
            }
            return .init(
                target: target,
                recommendedTarget: nil,
                availability: sawAdvertisedProvider ? .informational : .unavailable,
                detail: sawAdvertisedProvider ? "A provider is advertised but the exact profile target is unavailable" : "No recommendation provider is advertised"
            )
        }
    }

    func recommendationChains() -> [(AgentRoutingTarget, [RecommendationCandidate])] {
        let codex: (String) -> RecommendationCandidate = { effort in
            .init(providerID: .codex, modelTokens: ["gpt-5.6", "sol"], reasoningEffort: effort)
        }
        let claude: (String, String?) -> RecommendationCandidate = { family, effort in
            .init(providerID: .claudeCompatible, modelTokens: [family], reasoningEffort: effort)
        }
        let cursor: (Bool) -> RecommendationCandidate = { composer in
            .init(providerID: .cursorACP, modelTokens: composer ? ["composer", "2"] : ["auto"], reasoningEffort: nil)
        }
        return [
            (.oracle, [codex("high"), claude("opus", nil)]),
            (.contextBuilder, [codex("low"), claude("sonnet", nil), cursor(true)]),
            (.explore, [codex("low"), claude("sonnet", "high"), claude("haiku", nil), cursor(false)]),
            (.engineer, [codex("medium"), claude("sonnet", nil), cursor(true)]),
            (.pair, [codex("high"), claude("opus", nil), cursor(true)]),
            (.design, [claude("opus", nil), cursor(true), codex("medium")])
        ]
    }

    func recommendationTarget(
        target: AgentRoutingTarget,
        catalog: ProviderSettingsCatalogResponse,
        requireEffective: Bool
    ) -> AgentModelTarget? {
        guard let candidates = recommendationChains().first(where: { $0.0 == target })?.1 else { return nil }
        return recommendationTarget(target: target, candidates: candidates, catalog: catalog, requireEffective: requireEffective)
    }

    func recommendationTarget(
        target _: AgentRoutingTarget,
        candidates: [RecommendationCandidate],
        catalog: ProviderSettingsCatalogResponse,
        requireEffective: Bool
    ) -> AgentModelTarget? {
        for candidate in candidates where candidate.providerID != .openCodeACP {
            guard let provider = catalog.providers.first(where: { $0.providerID == candidate.providerID }),
                  provider.deploymentAllowed,
                  !requireEffective || provider.effectiveEnabled
            else { continue }
            guard let model = provider.models.first(where: { model in
                let text = "\(model.id) \(model.displayName)".lowercased()
                return candidate.modelTokens.allSatisfy { text.contains($0.lowercased()) }
            }) else { continue }
            if let effort = candidate.reasoningEffort, !model.reasoningEfforts.contains(effort) { continue }
            return .init(
                providerID: candidate.providerID,
                modelID: model.id,
                reasoningEffort: candidate.reasoningEffort
            )
        }
        return nil
    }

    func runtimeRoute(
        _ target: AgentModelTarget,
        target routingTarget: AgentRoutingTarget,
        catalog: ProviderSettingsCatalogResponse,
        usedRecommendationFallback: Bool
    ) -> ResolvedAgentModelRoute? {
        guard let provider = catalog.providers.first(where: { $0.providerID == target.providerID }),
              provider.deploymentAllowed,
              provider.effectiveEnabled,
              let runtimeKind = provider.providerID.runtimeKind
        else { return nil }
        if let modelID = target.modelID {
            guard let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
            if let effort = target.reasoningEffort, !model.reasoningEfforts.contains(effort) { return nil }
        } else if target.reasoningEffort != nil {
            return nil
        }
        return .init(
            routingTarget: routingTarget,
            providerID: provider.providerID,
            provider: runtimeKind,
            modelID: target.modelID ?? provider.preference.defaultModel,
            reasoningEffort: target.reasoningEffort ?? provider.preference.reasoningEffort,
            usedRecommendationFallback: usedRecommendationFallback
        )
    }

    func renderSavedPrompts(_ prompts: [ContextBuilderSavedPrompt]) -> String {
        guard !prompts.isEmpty else { return "" }
        return prompts.map { prompt in
            """
            --- BEGIN SAVED CONTEXT BUILDER PROMPT \(prompt.promptID.uuidString) [\(prompt.name)] ---
            \(prompt.instructions)
            --- END SAVED CONTEXT BUILDER PROMPT \(prompt.promptID.uuidString) ---
            """
        }.joined(separator: "\n")
    }

    func normalizeProjectContextBuilder(
        mode: ContextBuilderSettingsScopeMode,
        profile: ContextBuilderSettingsProfile?
    ) throws -> ContextBuilderScopeDocument {
        switch mode {
        case .inheritGlobal:
            guard profile == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Inherited Context Builder settings cannot contain an override") }
            return .init(mode: mode, profile: nil)
        case .projectOverride:
            guard let profile else { throw ServiceAPIError(code: .invalidRequest, message: "Project Context Builder override is missing") }
            return .init(mode: mode, profile: try normalize(profile))
        }
    }

    func normalize(_ profile: ContextBuilderSettingsProfile) throws -> ContextBuilderSettingsProfile {
        guard (10_000 ... 200_000).contains(profile.budget), profile.budget.isMultiple(of: 5_000) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder budget is outside its supported range or increment")
        }
        guard [30, 60, 120, 300].contains(profile.questionTimeoutSeconds) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder question timeout is unsupported")
        }
        guard (40_000 ... 200_000).contains(profile.followUpBudget), profile.followUpBudget.isMultiple(of: 5_000) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder follow-up budget is outside its supported range or increment")
        }
        guard profile.prompts.count <= 100, Set(profile.prompts.map(\.promptID)).count == profile.prompts.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder prompt collection is invalid")
        }
        var names = Set<String>()
        var totalInstructions = 0
        let prompts = try profile.prompts.sorted { ($0.order, $0.promptID.uuidString) < ($1.order, $1.promptID.uuidString) }.enumerated().map { index, prompt in
            guard let name = try normalizedText(prompt.name, maximumBytes: 128), !name.isEmpty,
                  let instructions = try normalizedText(prompt.instructions, maximumBytes: 16 * 1024), !instructions.isEmpty,
                  names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "Context Builder prompt name or instructions are invalid")
            }
            totalInstructions += instructions.utf8.count
            return ContextBuilderSavedPrompt(promptID: prompt.promptID, name: name, instructions: instructions, enabled: prompt.enabled, order: index)
        }
        guard totalInstructions <= 256 * 1024 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Context Builder prompt collection exceeds its total instruction bound")
        }
        return .init(
            budget: profile.budget,
            enhancementMode: profile.enhancementMode,
            questionTimeoutSeconds: profile.questionTimeoutSeconds,
            portalClarifyingQuestions: profile.portalClarifyingQuestions,
            mcpClarifyingQuestions: profile.mcpClarifyingQuestions,
            followUpAnalysis: profile.followUpAnalysis,
            followUpBudget: profile.followUpBudget,
            prompts: prompts
        )
    }

    func normalize(_ presets: [MCPModelPreset], catalog: ProviderSettingsCatalogResponse) throws -> [MCPModelPreset] {
        guard presets.count <= 100, Set(presets.map(\.presetID)).count == presets.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "MCP model preset collection is invalid")
        }
        var names = Set<String>()
        return try presets.sorted { ($0.order, $0.presetID.uuidString) < ($1.order, $1.presetID.uuidString) }.enumerated().map { index, preset in
            guard let name = try normalizedText(preset.name, maximumBytes: 128), !name.isEmpty,
                  names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted,
                  !preset.availability.isEmpty,
                  Set(preset.availability).count == preset.availability.count
            else { throw ServiceAPIError(code: .invalidRequest, message: "MCP model preset name or availability is invalid") }
            let description = try normalizedText(preset.description, maximumBytes: 1024)
            let normalizedTarget = try normalize(
                AgentModelsProfile(oracle: preset.target),
                catalog: catalog
            ).oracle!
            return .init(
                presetID: preset.presetID,
                name: name,
                description: description,
                target: normalizedTarget,
                availability: preset.availability.sorted { $0.rawValue < $1.rawValue },
                enabled: preset.enabled,
                order: index
            )
        }
    }

    func normalize(
        _ presets: [ProjectSelectionPreset],
        projectID: UUID,
        roots: Set<UUID>
    ) throws -> [ProjectSelectionPreset] {
        guard presets.count <= 100, Set(presets.map(\.presetID)).count == presets.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Selection preset collection is invalid")
        }
        var names = Set<String>()
        return try presets.sorted { ($0.order, $0.presetID.uuidString) < ($1.order, $1.presetID.uuidString) }.enumerated().map { index, preset in
            guard preset.projectID == projectID,
                  preset.rowRevision >= 1,
                  preset.entries.count <= 20_000,
                  let name = try normalizedText(preset.name, maximumBytes: 256),
                  !name.isEmpty,
                  names.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted
            else { throw ServiceAPIError(code: .invalidRequest, message: "Selection preset metadata is invalid") }
            for entry in preset.entries {
                guard roots.contains(entry.rootID) else {
                    throw ServiceAPIError(code: .rootUnauthorized, message: "Selection preset contains an unauthorized root")
                }
                try validateSelectionEntry(entry)
            }
            return .init(
                presetID: preset.presetID,
                projectID: projectID,
                name: name,
                entries: preset.entries,
                order: index,
                rowRevision: preset.rowRevision
            )
        }
    }

    func validateSelectionEntry(_ entry: LogicalSelectionEntry) throws {
        let path = entry.logicalPath
        guard !path.isEmpty,
              path.utf8.count <= 4096,
              !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw ServiceAPIError(code: .invalidRequest, message: "Selection preset path is invalid") }
        switch entry.mode {
        case .slices:
            guard !entry.ranges.isEmpty, entry.ranges.allSatisfy({ $0.lowerBound >= 1 }) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Selection preset slice range is invalid")
            }
        case .full, .codeMap:
            guard entry.ranges.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Selection preset ranges require slice mode")
            }
        }
    }

    func normalizedText(_ value: String?, maximumBytes: Int) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= maximumBytes,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(normalized)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Typed setting text is invalid or resembles credential material") }
        return normalized
    }
}
