import Foundation

public struct AdvancedServerSettings: Codable, Hashable, Sendable {
    public let respectRepoIgnore: Bool
    public let respectCursorIgnore: Bool
    public let respectNestedIgnoreFiles: Bool
    public let followSymbolicLinks: Bool
    public let showEmptyFolders: Bool
    public let codeMapsEnabled: Bool
    public let historyIdleThresholdMinutes: Int

    public init(
        respectRepoIgnore: Bool = true,
        respectCursorIgnore: Bool = true,
        respectNestedIgnoreFiles: Bool = true,
        followSymbolicLinks: Bool = false,
        showEmptyFolders: Bool = true,
        codeMapsEnabled: Bool = true,
        historyIdleThresholdMinutes: Int = 5
    ) {
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorIgnore = respectCursorIgnore
        self.respectNestedIgnoreFiles = respectNestedIgnoreFiles
        self.followSymbolicLinks = followSymbolicLinks
        self.showEmptyFolders = showEmptyFolders
        self.codeMapsEnabled = codeMapsEnabled
        self.historyIdleThresholdMinutes = historyIdleThresholdMinutes
    }

    public static let `default` = AdvancedServerSettings()
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
