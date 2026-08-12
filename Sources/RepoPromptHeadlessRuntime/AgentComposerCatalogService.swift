import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct AgentComposerWorkflowDescriptor: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let guidance: String?
    public let providerIDs: [ProviderSettingsID]
    public let featured: Bool

    public init(id: String, displayName: String, description: String? = nil, guidance: String? = nil, providerIDs: [ProviderSettingsID] = [], featured: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.guidance = guidance
        self.providerIDs = providerIDs
        self.featured = featured
    }
}

public actor AgentComposerCatalogService {
    private let providerSettings: ProviderSettingsService
    private let store: SQLiteServiceStore
    private let adapters: [ProviderSettingsID: any ProviderTurnConfigurationAdapter]
    private let workflows: [AgentComposerWorkflowDescriptor]
    private let suggestions: [ComposerSuggestionDescriptor]
    private let emptyState: AgentEmptyStateDescriptor

    public init(
        providerSettings: ProviderSettingsService,
        store: SQLiteServiceStore,
        adapters: [ProviderSettingsID: any ProviderTurnConfigurationAdapter] = ProviderTurnConfigurationAdapters.builtIn(),
        workflows: [AgentComposerWorkflowDescriptor] = [],
        suggestions: [ComposerSuggestionDescriptor] = [],
        emptyState: AgentEmptyStateDescriptor = .init(
            featuredWorkflowIDs: [],
            tips: [
                "Tag a file to add its current contents to only this turn.",
                "Choose a concrete model before sending.",
                "Use Shift+Return to add a new line."
            ]
        )
    ) {
        self.providerSettings = providerSettings
        self.store = store
        self.adapters = adapters
        self.workflows = workflows
        self.suggestions = suggestions
        self.emptyState = emptyState
    }

    public func snapshot(context: ComposerCatalogContext) async throws -> ComposerCatalogWireSnapshot {
        let catalog = try await providerSettings.catalog(refreshCLI: false, refreshRuntime: false)
        let storedDefaults: SessionNextTurnDefaultsRecord? = if let sessionID = context.sessionID { try await store.nextTurnDefaults(sessionID: sessionID) } else { nil }
        let selectedProvider = storedDefaults?.configuration.providerID
        let selectedModel = storedDefaults?.configuration.modelID
        let activeLock = context.activeRun ? ComposerLockWire(locked: true, reasonCode: "active_run", reasonText: "This setting cannot change during an active run.") : .init()
        let controllerLock = context.mcpControlled ? ComposerLockWire(locked: true, reasonCode: "mcp_controlled", reasonText: "The active MCP controller owns this setting.") : activeLock

        var descriptors: [ProviderSettingsID: [ProviderModelDescriptor]] = [:]
        var groups: [ComposerProviderGroupWire] = []
        for matrix in AgentComposerProviderMatrix.entries {
            guard let settings = catalog.providers.first(where: { $0.providerID == matrix.providerID }),
                  let adapter = adapters[matrix.providerID],
                  settings.effectiveEnabled,
                  settings.runtimePreflightVerified,
                  settings.preflight.ready
            else { continue }
            let availableModels = try await availableModels(matrix: matrix, settings: settings)
            let models = normalizedModels(availableModels, providerID: matrix.providerID)
            guard !models.isEmpty else { continue }
            descriptors[matrix.providerID] = models
            let values = storedDefaults?.configuration.providerID == matrix.providerID ? storedDefaults?.configuration.toolValues ?? [:] : [:]
            let mutable = !context.activeRun && !context.mcpControlled
            let reason = context.mcpControlled ? "mcp_controlled" : (context.activeRun ? "active_run" : nil)
            let controls = ProviderComposerStableControls.descriptors(providerID: matrix.providerID, values: values, mutable: mutable, lockReasonCode: reason).map(Self.controlWire)
            let permission = ProviderComposerStableControls.permissionDescriptor(
                providerID: matrix.providerID,
                selectedID: storedDefaults?.configuration.providerID == matrix.providerID ? storedDefaults?.configuration.permissionID : nil,
                mutable: mutable,
                lockReasonCode: reason
            ).map(Self.permissionWire)
            groups.append(.init(
                providerID: matrix.providerID,
                displayName: settings.displayName,
                models: models.map(Self.modelWire),
                toolControls: controls,
                permissionControl: permission
            ))
            _ = adapter
        }

        var selected: ComposerSelectionWire?
        if let providerID = selectedProvider, let modelID = selectedModel,
           descriptors[providerID]?.contains(where: { $0.modelID == modelID }) == true,
           let defaults = storedDefaults?.configuration
        {
            selected = .init(providerID: providerID, modelID: modelID, effortID: defaults.effortID, workflowID: defaults.workflowID, permissionID: defaults.permissionID, toolValues: defaults.toolValues.mapValues(Self.wireValue))
        } else if let providerID = selectedProvider, let modelID = selectedModel, let defaults = storedDefaults?.configuration {
            selected = .init(providerID: providerID, modelID: modelID, effortID: defaults.effortID, workflowID: defaults.workflowID, permissionID: defaults.permissionID, toolValues: defaults.toolValues.mapValues(Self.wireValue), unavailable: .init(providerID: providerID, modelID: modelID))
        } else if let firstGroup = groups.first, let firstModel = firstGroup.models.first {
            let provider = catalog.providers.first { $0.providerID == firstGroup.providerID }
            let preferredModel = provider?.preference.defaultModel.flatMap { preferred in firstGroup.models.first { $0.id == AgentModelIdentityNormalizer.normalize(providerID: firstGroup.providerID, rawModelID: preferred)?.modelID } } ?? firstModel
            selected = .init(providerID: firstGroup.providerID, modelID: preferredModel.id, effortID: provider?.preference.reasoningEffort ?? preferredModel.defaultEffortID, permissionID: Self.defaultPermissionID(firstGroup.providerID), toolValues: Self.defaultToolValues(firstGroup.providerID))
        }

        let workflowWire: [ComposerWorkflowOptionWire] = workflows.map { ComposerWorkflowOptionWire(id: $0.id, displayName: $0.displayName, description: $0.description, guidance: $0.guidance, providerIDs: $0.providerIDs, enabled: true) }
        let contextWire = ComposerContextWire(kind: context.kind == .project ? .project : .session, projectID: context.projectID, sessionID: context.sessionID)
        let capabilities = ComposerCapabilitiesWire(
            attachments: groups.contains { group in group.models.contains { $0.capabilities.nativeImages } },
            taggedFiles: true,
            suggestions: !suggestions.isEmpty,
            steering: groups.contains { group in group.models.contains { $0.capabilities.steering } }
        )
        let locks = ComposerLockSnapshotWire(model: controllerLock, effort: controllerLock, workflow: controllerLock, tools: controllerLock, permissions: controllerLock, attachments: activeLock, send: .init())
        let empty = AgentEmptyStateWire(
            heading: emptyState.heading,
            featuredWorkflowIDs: emptyState.featuredWorkflowIDs,
            tips: emptyState.tips.enumerated().map { .init(id: "tip-\($0.offset + 1)", text: $0.element) }
        )
        let seed = ComposerCatalogWireSnapshot(revision: "pending", context: contextWire, providerGroups: groups, workflows: workflowWire, selected: selected, locks: locks, capabilities: capabilities, emptyState: empty, mcpControlled: context.mcpControlled)
        let seedData = try JSONEncoder.serviceEncoder.encode(seed)
        let revision = CanonicalSigning.bodyDigest(seedData + Data(ProviderTurnConfigurationAdapters.interpretationRevision.utf8))
        return .init(revision: revision, context: contextWire, providerGroups: groups, workflows: workflowWire, selected: selected, locks: locks, capabilities: capabilities, emptyState: empty, mcpControlled: context.mcpControlled)
    }

    public func suggestions(context: ComposerCatalogContext, query: String, kinds: Set<ComposerSuggestionWire.Kind> = [.nativeCommand, .skill, .file], limit: Int = 50) async throws -> ComposerSuggestionPageWire {
        guard query.utf8.count <= 512 else { throw ServiceAPIError(code: .invalidRequest, message: "Suggestion query exceeds its bound") }
        let snapshot = try await snapshot(context: context)
        let selectedProvider = snapshot.selected?.providerID
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = suggestions.compactMap { item -> ComposerSuggestionWire? in
            guard let kind = ComposerSuggestionWire.Kind(rawValue: item.kind.rawValue), kinds.contains(kind), item.available,
                  item.providerIDs.isEmpty || selectedProvider.map(item.providerIDs.contains) == true,
                  normalized.isEmpty || item.displayName.lowercased().contains(normalized) || item.insertionText.lowercased().contains(normalized)
            else { return nil }
            return .init(kind: kind, id: item.id, insertionText: item.insertionText, displayName: item.displayName, detailText: item.detailText, providerIDs: item.providerIDs, available: item.available)
        }
        return .init(catalogRevision: snapshot.revision, items: Array(items.prefix(max(1, min(limit, 100)))))
    }

    public func validate(_ wire: AgentTurnConfigurationWire, context: ComposerCatalogContext, acceptedAt: Date) async throws -> (EffectiveTurnConfigurationRecord, CompiledProviderTurnConfiguration, ProviderModelDescriptor, String?) {
        guard wire.schemaVersion == 1 else { throw ServiceAPIError(code: .invalidRequest, message: "Turn configuration schema is unsupported") }
        let current = try await snapshot(context: context)
        guard wire.catalogRevision == current.revision else { throw ServiceAPIError(code: .staleRevision, message: "catalog_revision_stale") }
        guard let group = current.providerGroups.first(where: { $0.providerID == wire.providerID }),
              let modelWire = group.models.first(where: { $0.id == wire.modelID && $0.enabled })
        else { throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider model is unavailable") }
        let settings = try await providerSettings.catalog().providers.first { $0.providerID == wire.providerID }
        guard let settings,
              let matrix = AgentComposerProviderMatrix.entry(for: wire.providerID),
              let adapter = adapters[wire.providerID]
        else { throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider adapter is unavailable") }
        let availableModels = try await availableModels(matrix: matrix, settings: settings)
        guard let raw = availableModels.first(where: { AgentModelIdentityNormalizer.normalize(providerID: wire.providerID, rawModelID: $0.id)?.modelID == wire.modelID })
        else { throw ServiceAPIError(code: .capabilityMissing, message: "Selected provider model is unavailable") }
        let model = ProviderModelDescriptor(providerID: wire.providerID, modelID: modelWire.id, providerRawValue: raw.id, displayName: modelWire.displayName, description: modelWire.description, supportedEffortIDs: modelWire.supportedEffortIDs, defaultEffortID: modelWire.defaultEffortID, capabilities: .init(nativeImages: modelWire.capabilities.nativeImages, steering: modelWire.capabilities.steering))
        let workflow: ComposerWorkflowOptionWire? = if let workflowID = wire.workflowID {
            current.workflows.first { $0.id == workflowID && $0.enabled && ($0.providerIDs.isEmpty || $0.providerIDs.contains(wire.providerID)) }
        } else { nil }
        if wire.workflowID != nil, workflow == nil {
            throw ServiceAPIError(code: .staleRevision, message: "Selected workflow is unavailable")
        }
        let values = wire.toolValues.mapValues(Self.controlValue)
        let compiled = try adapter.compile(.init(providerID: wire.providerID, model: model, effortID: wire.effortID, permissionID: wire.permissionID, toolValues: values, workflowID: wire.workflowID))
        let capabilityDigest = CanonicalSigning.bodyDigest(try JSONEncoder.serviceEncoder.encode(model))
        let effective = try EffectiveTurnConfigurationRecord(catalogRevision: wire.catalogRevision, providerID: wire.providerID, modelID: wire.modelID, providerRawModelValue: compiled.providerRawModelValue, effortID: wire.effortID ?? model.defaultEffortID, workflowID: wire.workflowID, permissionID: wire.permissionID, toolValues: compiled.normalizedToolValues, capabilityDigest: capabilityDigest, actorID: context.actorID, acceptedAt: acceptedAt).validated()
        return (effective, compiled, model, workflow?.guidance)
    }

    public func compatibilityModels() async throws -> [ModelCatalogItem] {
        let catalog = try await providerSettings.catalog(refreshCLI: false, refreshRuntime: false)
        var result: [ModelCatalogItem] = []
        for matrix in AgentComposerProviderMatrix.entries {
            guard let provider = catalog.providers.first(where: { $0.providerID == matrix.providerID }), provider.effectiveEnabled, provider.runtimePreflightVerified, provider.preflight.ready, adapters[matrix.providerID] != nil, let runtime = matrix.runtimeKind else { continue }
            let available = try await availableModels(matrix: matrix, settings: provider)
            result.append(contentsOf: normalizedModels(available, providerID: matrix.providerID).map { model in
                ModelCatalogItem(id: model.modelID, provider: runtime, providerID: matrix.providerID, displayName: model.displayName, enabled: true, description: model.description, supportedEffortIDs: model.supportedEffortIDs, defaultEffortID: model.defaultEffortID)
            })
        }
        return result
    }

    private func availableModels(matrix: ProviderAvailabilityMatrixEntry, settings: ProviderSettingsSnapshot) async throws -> [ProviderModelCatalogEntry] {
        if !settings.models.isEmpty {
            if matrix.discoveryPolicy.allowsPersistedFallback {
                try await store.persistComposerProviderCatalog(.init(providerID: matrix.providerID, models: settings.models, observedAt: Date()))
            }
            return settings.models
        }
        guard matrix.discoveryPolicy.allowsPersistedFallback,
              let cached = try await store.composerProviderCatalog(providerID: matrix.providerID),
              Date().timeIntervalSince(cached.observedAt) <= TimeInterval(matrix.discoveryPolicy.persistedFallbackMaximumAgeSeconds)
        else { return [] }
        return cached.models
    }

    private func normalizedModels(_ entries: [ProviderModelCatalogEntry], providerID: ProviderSettingsID) -> [ProviderModelDescriptor] {
        var order: [String] = []
        var grouped: [String: (raw: ProviderModelCatalogEntry, efforts: Set<String>)] = [:]
        for entry in entries {
            guard let normalized = AgentModelIdentityNormalizer.normalize(providerID: providerID, rawModelID: entry.id) else { continue }
            if grouped[normalized.modelID] == nil { order.append(normalized.modelID); grouped[normalized.modelID] = (entry, []) }
            grouped[normalized.modelID]?.efforts.formUnion(entry.reasoningEfforts)
            if let effort = normalized.effortID { grouped[normalized.modelID]?.efforts.insert(effort) }
        }
        return order.compactMap { id in
            guard let value = grouped[id] else { return nil }
            let efforts = value.efforts.sorted { (AgentModelIdentityNormalizer.effortOrder.firstIndex(of: $0) ?? .max) < (AgentModelIdentityNormalizer.effortOrder.firstIndex(of: $1) ?? .max) }
            let nativeImages = providerID == .codex || [.claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom].contains(providerID)
            return .init(providerID: providerID, modelID: id, providerRawValue: value.raw.id, displayName: AgentModelIdentityNormalizer.displayName(providerID: providerID, modelID: id), description: value.raw.description, supportedEffortIDs: efforts, defaultEffortID: efforts.contains("medium") ? "medium" : efforts.first, capabilities: .init(nativeImages: nativeImages, steering: providerID.runtimeKind != nil))
        }
    }

    private static func modelWire(_ value: ProviderModelDescriptor) -> ComposerModelOptionWire {
        .init(id: value.modelID, displayName: value.displayName, description: value.description, supportedEffortIDs: value.supportedEffortIDs, defaultEffortID: value.defaultEffortID, capabilities: .init(nativeImages: value.capabilities.nativeImages, steering: value.capabilities.steering))
    }

    private static func controlWire(_ value: ProviderComposerControlDescriptor) -> ComposerControlWire {
        switch value {
        case let .toggle(id, name, detail, selected, required, mutable, warning, reason):
            .toggle(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), value: selected)
        case let .singleChoice(id, name, detail, selected, choices, required, mutable, warning, reason):
            .singleChoice(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), selectedID: selected, choices: choices.map(choiceWire))
        case let .multiChoice(id, name, detail, selected, choices, required, mutable, warning, reason):
            .multiChoice(common: .init(id: id, displayName: name, detailText: detail, required: required, mutable: mutable, warning: warning, lockReasonCode: reason), selectedIDs: selected, choices: choices.map(choiceWire))
        }
    }

    private static func permissionWire(_ value: ProviderPermissionDescriptor) -> ComposerPermissionControlWire {
        .init(id: value.id, displayName: value.displayName, selectedID: value.selectedID, choices: value.choices.map(choiceWire), externallyManaged: value.externallyManaged, mutable: value.mutable, lockReasonCode: value.lockReasonCode)
    }

    private static func choiceWire(_ value: ProviderComposerChoiceDescriptor) -> ComposerControlChoiceWire {
        .init(id: value.id, displayName: value.displayName, detailText: value.detailText, enabled: value.enabled, warning: value.warning)
    }

    private static func wireValue(_ value: AgentControlValue) -> ComposerControlValueWire {
        switch value { case let .boolean(v): .boolean(v); case let .choice(v): .choice(v); case let .choices(v): .choices(v) }
    }

    private static func controlValue(_ value: ComposerControlValueWire) -> AgentControlValue {
        switch value { case let .boolean(v): .boolean(v); case let .choice(v): .choice(v); case let .choices(v): .choices(v) }
    }

    private static func defaultPermissionID(_ provider: ProviderSettingsID) -> String? {
        switch provider {
        case .codex:
            "codex.workspaceWrite"
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom:
            "claude.requireApproval"
        case .openCodeACP:
            "opencode.managed"
        case .cursorACP:
            "cursor.managed"
        case .openAIAPI, .anthropicAPI, .openRouter, .customOpenAICompatible, .xAI:
            nil
        }
    }

    private static func defaultToolValues(_ provider: ProviderSettingsID) -> [String: ComposerControlValueWire] {
        switch provider {
        case .codex: ["codex.bash": .boolean(true), "codex.search": .boolean(true), "codex.goals": .boolean(true), "codex.reasoningSummaries": .boolean(true), "codex.memories": .boolean(true), "codex.mcpServers": .choices(["repoprompt"])]
        case .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom: ["claude.bash": .boolean(true), "claude.repoPromptOnlyMCP": .boolean(true), "claude.lazyToolLoading": .boolean(true), "claude.promptDelivery": .choice("structured")]
        default: [:]
        }
    }
}
