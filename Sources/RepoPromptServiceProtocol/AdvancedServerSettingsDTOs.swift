import Foundation

/// Desktop `PromptSection`. Raw values are persisted; do not rename.
public enum PromptSection: String, CaseIterable, Codable, Sendable {
    case fileMap
    case fileContents
    case metaPrompts
    case userInstructions
    case gitDiff

    public static let defaultOrder: [PromptSection] = [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions]

    public static let defaultOrderJSON = #"["fileMap","fileContents","gitDiff","metaPrompts","userInstructions"]"#

    public static func resolvedOrder(from raw: String) -> [PromptSection] {
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PromptSection].self, from: data),
           decoded.count == allCases.count,
           Set(decoded) == Set(allCases)
        {
            return decoded
        }
        return defaultOrder
    }

    public static func encode(_ order: [PromptSection]) -> String {
        guard let data = try? JSONEncoder().encode(order), let raw = String(data: data, encoding: .utf8) else {
            return defaultOrderJSON
        }
        return raw
    }
}

public struct AdvancedServerSettings: Codable, Hashable, Sendable {
    public let respectRepoIgnore: Bool
    public let respectCursorIgnore: Bool
    public let respectNestedIgnoreFiles: Bool
    public let followSymbolicLinks: Bool
    public let showEmptyFolders: Bool
    public let codeMapsEnabled: Bool
    public let historyIdleThresholdMinutes: Int
    public let fileEditFormat: String
    public let customPlanningPrompt: String
    public let modelTemperature: Double
    public let setModelTemperature: Bool
    public let promptSectionsOrder: String
    public let duplicateUserInstructionsAtTop: Bool
    public let workflowPresets: WorkflowPresetDocument
    public let selectedCopyPresetID: UUID?
    public let selectedChatPresetID: UUID?
    public let savedPrompts: [SavedPromptRecord]
    public let includeSavedPromptsInClipboard: Bool
    public let filePathDisplayOption: String
    public let includeDatetimeInUserInstructions: Bool

    public init(
        respectRepoIgnore: Bool = true,
        respectCursorIgnore: Bool = true,
        respectNestedIgnoreFiles: Bool = true,
        followSymbolicLinks: Bool = false,
        showEmptyFolders: Bool = true,
        codeMapsEnabled: Bool = true,
        historyIdleThresholdMinutes: Int = 5,
        fileEditFormat: String = FileEditFormat.defaultRaw,
        customPlanningPrompt: String = "",
        modelTemperature: Double = 0.0,
        setModelTemperature: Bool = true,
        promptSectionsOrder: String = "",
        duplicateUserInstructionsAtTop: Bool = false,
        workflowPresets: WorkflowPresetDocument = .empty,
        selectedCopyPresetID: UUID? = nil,
        selectedChatPresetID: UUID? = nil,
        savedPrompts: [SavedPromptRecord] = [],
        includeSavedPromptsInClipboard: Bool = true,
        filePathDisplayOption: String = FilePathDisplay.defaultRaw,
        includeDatetimeInUserInstructions: Bool = false
    ) {
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorIgnore = respectCursorIgnore
        self.respectNestedIgnoreFiles = respectNestedIgnoreFiles
        self.followSymbolicLinks = followSymbolicLinks
        self.showEmptyFolders = showEmptyFolders
        self.codeMapsEnabled = codeMapsEnabled
        self.historyIdleThresholdMinutes = historyIdleThresholdMinutes
        self.fileEditFormat = fileEditFormat
        self.customPlanningPrompt = customPlanningPrompt
        self.modelTemperature = modelTemperature
        self.setModelTemperature = setModelTemperature
        self.promptSectionsOrder = promptSectionsOrder
        self.duplicateUserInstructionsAtTop = duplicateUserInstructionsAtTop
        self.workflowPresets = workflowPresets
        self.selectedCopyPresetID = selectedCopyPresetID
        self.selectedChatPresetID = selectedChatPresetID
        self.savedPrompts = savedPrompts
        self.includeSavedPromptsInClipboard = includeSavedPromptsInClipboard
        self.filePathDisplayOption = filePathDisplayOption
        self.includeDatetimeInUserInstructions = includeDatetimeInUserInstructions
    }

    public static let `default` = AdvancedServerSettings()

    private enum CodingKeys: String, CodingKey {
        case respectRepoIgnore
        case respectCursorIgnore
        case respectNestedIgnoreFiles
        case followSymbolicLinks
        case showEmptyFolders
        case codeMapsEnabled
        case historyIdleThresholdMinutes
        case fileEditFormat
        case customPlanningPrompt
        case modelTemperature
        case setModelTemperature
        case promptSectionsOrder
        case duplicateUserInstructionsAtTop
        case workflowPresets
        case selectedCopyPresetID
        case selectedChatPresetID
        case savedPrompts
        case includeSavedPromptsInClipboard
        case filePathDisplayOption
        case includeDatetimeInUserInstructions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        respectRepoIgnore = try container.decodeIfPresent(Bool.self, forKey: .respectRepoIgnore) ?? true
        respectCursorIgnore = try container.decodeIfPresent(Bool.self, forKey: .respectCursorIgnore) ?? true
        respectNestedIgnoreFiles = try container.decodeIfPresent(Bool.self, forKey: .respectNestedIgnoreFiles) ?? true
        followSymbolicLinks = try container.decodeIfPresent(Bool.self, forKey: .followSymbolicLinks) ?? false
        showEmptyFolders = try container.decodeIfPresent(Bool.self, forKey: .showEmptyFolders) ?? true
        codeMapsEnabled = try container.decodeIfPresent(Bool.self, forKey: .codeMapsEnabled) ?? true
        historyIdleThresholdMinutes = try container.decodeIfPresent(Int.self, forKey: .historyIdleThresholdMinutes) ?? 5
        fileEditFormat = try container.decodeIfPresent(String.self, forKey: .fileEditFormat) ?? FileEditFormat.defaultRaw
        customPlanningPrompt = try container.decodeIfPresent(String.self, forKey: .customPlanningPrompt) ?? ""
        modelTemperature = try container.decodeIfPresent(Double.self, forKey: .modelTemperature) ?? 0.0
        setModelTemperature = try container.decodeIfPresent(Bool.self, forKey: .setModelTemperature) ?? true
        promptSectionsOrder = try container.decodeIfPresent(String.self, forKey: .promptSectionsOrder) ?? ""
        duplicateUserInstructionsAtTop = try container.decodeIfPresent(Bool.self, forKey: .duplicateUserInstructionsAtTop) ?? false
        workflowPresets = try container.decodeIfPresent(WorkflowPresetDocument.self, forKey: .workflowPresets) ?? .empty
        selectedCopyPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedCopyPresetID)
        selectedChatPresetID = try container.decodeIfPresent(UUID.self, forKey: .selectedChatPresetID)
        savedPrompts = try container.decodeIfPresent([SavedPromptRecord].self, forKey: .savedPrompts) ?? []
        includeSavedPromptsInClipboard = try container.decodeIfPresent(Bool.self, forKey: .includeSavedPromptsInClipboard) ?? true
        filePathDisplayOption = try container.decodeIfPresent(String.self, forKey: .filePathDisplayOption) ?? FilePathDisplay.defaultRaw
        includeDatetimeInUserInstructions = try container.decodeIfPresent(Bool.self, forKey: .includeDatetimeInUserInstructions) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(respectRepoIgnore, forKey: .respectRepoIgnore)
        try container.encode(respectCursorIgnore, forKey: .respectCursorIgnore)
        try container.encode(respectNestedIgnoreFiles, forKey: .respectNestedIgnoreFiles)
        try container.encode(followSymbolicLinks, forKey: .followSymbolicLinks)
        try container.encode(showEmptyFolders, forKey: .showEmptyFolders)
        try container.encode(codeMapsEnabled, forKey: .codeMapsEnabled)
        try container.encode(historyIdleThresholdMinutes, forKey: .historyIdleThresholdMinutes)
        try container.encode(fileEditFormat, forKey: .fileEditFormat)
        try container.encode(customPlanningPrompt, forKey: .customPlanningPrompt)
        try container.encode(modelTemperature, forKey: .modelTemperature)
        try container.encode(setModelTemperature, forKey: .setModelTemperature)
        try container.encode(promptSectionsOrder, forKey: .promptSectionsOrder)
        try container.encode(duplicateUserInstructionsAtTop, forKey: .duplicateUserInstructionsAtTop)
        try container.encode(workflowPresets, forKey: .workflowPresets)
        try container.encodeIfPresent(selectedCopyPresetID, forKey: .selectedCopyPresetID)
        try container.encodeIfPresent(selectedChatPresetID, forKey: .selectedChatPresetID)
        try container.encode(savedPrompts, forKey: .savedPrompts)
        try container.encode(includeSavedPromptsInClipboard, forKey: .includeSavedPromptsInClipboard)
        try container.encode(filePathDisplayOption, forKey: .filePathDisplayOption)
        try container.encode(includeDatetimeInUserInstructions, forKey: .includeDatetimeInUserInstructions)
    }

    /// Desktop `PromptViewModel.FileEditFormat`: Diff / Whole / None. Missing or invalid raw → Diff.
    public enum FileEditFormat: String, CaseIterable, Sendable {
        case diff = "Diff"
        case whole = "Whole"
        case none = "None"

        public static let defaultRaw = FileEditFormat.diff.rawValue

        public static func resolved(from raw: String?) -> FileEditFormat {
            FileEditFormat(rawValue: raw ?? defaultRaw) ?? .diff
        }

        /// Desktop `targetFileEditFormat`: None stays None; a model that cannot diff is forced to Whole.
        public func target(modelCapableOfDiff: Bool) -> FileEditFormat {
            if self == .none { return .none }
            return modelCapableOfDiff ? self : .whole
        }
    }

    public func resolvedFileEditFormat(modelCapableOfDiff: Bool = true) -> FileEditFormat {
        FileEditFormat.resolved(from: fileEditFormat).target(modelCapableOfDiff: modelCapableOfDiff)
    }

    /// Desktop `FilePathDisplay`: Full / Relative. Missing or invalid raw → Full.
    public enum FilePathDisplay: String, CaseIterable, Sendable {
        case full = "Full"
        case relative = "Relative"

        public static let defaultRaw = FilePathDisplay.full.rawValue

        public static func resolved(from raw: String?) -> FilePathDisplay {
            FilePathDisplay(rawValue: raw ?? defaultRaw) ?? .full
        }

        public static func joinedFullPath(rootPath: String, logicalPath: String) -> String {
            if logicalPath.hasPrefix("/") { return logicalPath }
            var root = rootPath
            while root.hasSuffix("/") { root.removeLast() }
            return root.isEmpty ? logicalPath : "\(root)/\(logicalPath)"
        }
    }

    public func resolvedFilePathDisplay() -> FilePathDisplay {
        FilePathDisplay.resolved(from: filePathDisplayOption)
    }

    public func displayedFilePath(logicalPath: String, fullPath: String?) -> String {
        switch resolvedFilePathDisplay() {
        case .relative:
            return logicalPath
        case .full:
            return fullPath ?? logicalPath
        }
    }

    public func formattedUserInstructions(_ text: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return """
        <user_instructions date="\(formatter.string(from: now))">
        \(text)
        </user_instructions>
        """
    }

    public func packagedContextPreamble(selectionRevision: Int64) -> [String] {
        [
            "# RepoPrompt Context",
            "selection-revision: \(selectionRevision)",
            "file-edit-format: \(resolvedFileEditFormat().rawValue)",
        ]
    }

    public func resolvedPromptSectionOrder() -> [PromptSection] {
        PromptSection.resolvedOrder(from: promptSectionsOrder)
    }

    public func resolvedCopyPreset() -> CopyPresetRecord {
        workflowPresets.resolvedCopyPreset(selectedID: selectedCopyPresetID)
    }

    public func resolvedChatPreset() -> ChatPresetRecord {
        workflowPresets.resolvedChatPreset(selectedID: selectedChatPresetID)
    }

    public func resolvedSavedPrompts() -> [SavedPromptRecord] {
        SavedPromptRecord.resolvedCatalog(stored: savedPrompts)
    }

    /// Desktop copy vs chat selected IDs. Clipboard toggle omits metas from copy only.
    /// Chat `useStoredPromptsAsSystem` with one ID uses that body as system, not `<meta prompt>`.
    public func resolvedMetaPromptIDs(purpose: PromptPackagingPurpose) -> [UUID] {
        switch purpose {
        case .copy:
            guard includeSavedPromptsInClipboard else { return [] }
            let preset = resolvedCopyPreset()
            guard preset.includeMetaPrompts != false else { return [] }
            return preset.storedPromptIds ?? []
        case .chat:
            let preset = resolvedChatPreset()
            let ids = preset.storedPromptIds ?? []
            if preset.useStoredPromptsAsSystem == true, ids.count == 1 {
                return []
            }
            return ids
        }
    }

    public func resolvedMetaPromptsSnippet(purpose: PromptPackagingPurpose) -> String? {
        let ids = resolvedMetaPromptIDs(purpose: purpose)
        guard !ids.isEmpty else { return nil }
        let catalog = resolvedSavedPrompts()
        let selected = ids.compactMap { id in catalog.first(where: { $0.id == id }) }
        return SavedPromptRecord.metaPromptsSnippet(selected)
    }

    /// Desktop `PromptAssemblyBuilder`: optional top copy of user instructions, then live-read order.
    public func packagedContext(
        selectionRevision: Int64,
        snippets: [PromptSection: String],
        purpose: PromptPackagingPurpose = .copy,
        now: Date = Date()
    ) -> String {
        var parts = packagedContextPreamble(selectionRevision: selectionRevision)
        var effective = snippets
        if purpose == .copy, resolvedCopyPreset().includeFiles == false {
            effective[.fileContents] = nil
        }
        if effective[.metaPrompts] == nil, let meta = resolvedMetaPromptsSnippet(purpose: purpose) {
            effective[.metaPrompts] = meta
        }
        if includeDatetimeInUserInstructions,
           let user = effective[.userInstructions],
           !user.isEmpty
        {
            effective[.userInstructions] = formattedUserInstructions(user, now: now)
        }
        if duplicateUserInstructionsAtTop,
           let user = effective[.userInstructions],
           !user.isEmpty
        {
            parts.append(user)
        }
        for section in resolvedPromptSectionOrder() {
            guard let snippet = effective[section], !snippet.isEmpty else { continue }
            parts.append(snippet)
        }
        return parts.joined(separator: "\n\n")
    }

    public func replacing(
        fileEditFormat: String? = nil,
        customPlanningPrompt: String? = nil,
        modelTemperature: Double? = nil,
        setModelTemperature: Bool? = nil,
        promptSectionsOrder: String? = nil,
        duplicateUserInstructionsAtTop: Bool? = nil,
        workflowPresets: WorkflowPresetDocument? = nil,
        selectedCopyPresetID: UUID? = nil,
        selectedChatPresetID: UUID? = nil,
        savedPrompts: [SavedPromptRecord]? = nil,
        includeSavedPromptsInClipboard: Bool? = nil,
        filePathDisplayOption: String? = nil,
        includeDatetimeInUserInstructions: Bool? = nil
    ) -> AdvancedServerSettings {
        AdvancedServerSettings(
            respectRepoIgnore: respectRepoIgnore,
            respectCursorIgnore: respectCursorIgnore,
            respectNestedIgnoreFiles: respectNestedIgnoreFiles,
            followSymbolicLinks: followSymbolicLinks,
            showEmptyFolders: showEmptyFolders,
            codeMapsEnabled: codeMapsEnabled,
            historyIdleThresholdMinutes: historyIdleThresholdMinutes,
            fileEditFormat: fileEditFormat ?? self.fileEditFormat,
            customPlanningPrompt: customPlanningPrompt ?? self.customPlanningPrompt,
            modelTemperature: modelTemperature ?? self.modelTemperature,
            setModelTemperature: setModelTemperature ?? self.setModelTemperature,
            promptSectionsOrder: promptSectionsOrder ?? self.promptSectionsOrder,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop ?? self.duplicateUserInstructionsAtTop,
            workflowPresets: workflowPresets ?? self.workflowPresets,
            selectedCopyPresetID: selectedCopyPresetID ?? self.selectedCopyPresetID,
            selectedChatPresetID: selectedChatPresetID ?? self.selectedChatPresetID,
            savedPrompts: savedPrompts ?? self.savedPrompts,
            includeSavedPromptsInClipboard: includeSavedPromptsInClipboard ?? self.includeSavedPromptsInClipboard,
            filePathDisplayOption: filePathDisplayOption ?? self.filePathDisplayOption,
            includeDatetimeInUserInstructions: includeDatetimeInUserInstructions ?? self.includeDatetimeInUserInstructions
        )
    }

    /// Desktop `effectiveTemperature`: disabled or global 0.0 omits the field.
    public func resolvedAttachedTemperature() -> Double? {
        guard setModelTemperature, modelTemperature != 0.0 else { return nil }
        return modelTemperature
    }

    public func resolvedPlanningPrompt() -> String {
        let custom = customPlanningPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? Self.architectFallback : custom
    }

    /// Desktop Chat Planning Prompt empty default: built-in [Architect] body.
    public static let architectFallback = """
    You are producing an implementation-ready technical plan. The implementer will work from your plan without asking clarifying questions, so every design decision must be resolved, every touched component must be identified, and every behavioral change must be specified precisely.

    Your job:
    1. Analyze the requested change against the provided code — identify the relevant architecture, constraints, data flow, and extension points.
    2. Decide whether this is best solved by a targeted change or a broader refactor, and justify that decision.
    3. Produce a plan detailed enough that an engineer can implement it file-by-file without making design decisions of their own.

    Hard constraints:
    - Do not write production code, patches, diffs, or copy-paste-ready implementations.
    - Stay in analysis and architecture mode only.
    - Use illustrative snippets, interface shapes, sample signatures, state/data shapes, or pseudocode when they communicate the design more precisely than prose. Keep them partial — enough to remove ambiguity, not enough to copy-paste.
    - Scale your response to the complexity of the request. Small, localized changes need short plans; only expand sections for changes that genuinely require the detail.

    Please proceed with your analysis based on the following <user instructions>
    """
}

public struct AdvancedServerSettingsSnapshot: Codable, Hashable, Sendable {
    public let settings: AdvancedServerSettings
    public let revision: Int64
    public let scannerPolicyGeneration: Int64
    public let updatedAt: Date

    public init(settings: AdvancedServerSettings, revision: Int64, updatedAt: Date) {
        self.settings = settings
        self.revision = revision
        scannerPolicyGeneration = revision
        self.updatedAt = updatedAt
    }
}

public struct ReplaceAdvancedServerSettingsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let settings: AdvancedServerSettings

    public init(expectedRevision: Int64, settings: AdvancedServerSettings) {
        self.expectedRevision = expectedRevision
        self.settings = settings
    }
}
