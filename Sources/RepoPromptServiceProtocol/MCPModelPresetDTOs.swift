import Foundation

public enum MCPModelPresetAvailability: String, Codable, CaseIterable, Sendable {
    case chat
    case plan
    case review
}

public struct MCPModelPreset: Codable, Hashable, Sendable {
    public let presetID: UUID
    public let name: String
    public let description: String?
    public let target: AgentModelTarget
    public let availability: [MCPModelPresetAvailability]
    public let enabled: Bool
    public let order: Int

    public init(
        presetID: UUID,
        name: String,
        description: String? = nil,
        target: AgentModelTarget,
        availability: [MCPModelPresetAvailability],
        enabled: Bool = true,
        order: Int
    ) {
        self.presetID = presetID
        self.name = name
        self.description = description
        self.target = target
        self.availability = availability
        self.enabled = enabled
        self.order = order
    }
}

public struct MCPModelPresetsSnapshot: Codable, Hashable, Sendable {
    public let presets: [MCPModelPreset]
    public let revision: Int64
    public let updatedAt: Date

    public init(presets: [MCPModelPreset], revision: Int64, updatedAt: Date) {
        self.presets = presets
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct MCPModelDiscoverySnapshot: Codable, Sendable {
    public let providers: [ProviderSettingsSnapshot]
    public let presets: [MCPModelPreset]
    public let roleModelRestrictionApplied: Bool
    public let settingsRevision: Int64

    public init(
        providers: [ProviderSettingsSnapshot],
        presets: [MCPModelPreset],
        roleModelRestrictionApplied: Bool,
        settingsRevision: Int64
    ) {
        self.providers = providers
        self.presets = presets
        self.roleModelRestrictionApplied = roleModelRestrictionApplied
        self.settingsRevision = settingsRevision
    }
}

public struct ReplaceMCPModelPresetsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let presets: [MCPModelPreset]

    public init(expectedRevision: Int64, presets: [MCPModelPreset]) {
        self.expectedRevision = expectedRevision
        self.presets = presets
    }
}
