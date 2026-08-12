import Foundation

public enum AgentRoutingTarget: String, Codable, CaseIterable, Sendable {
    case oracle
    case contextBuilder
    case explore
    case engineer
    case pair
    case design
}

public struct ResolvedAgentModelRoute: Codable, Hashable, Sendable {
    public let routingTarget: AgentRoutingTarget
    public let providerID: ProviderSettingsID
    public let provider: ProviderKind
    public let modelID: String?
    public let reasoningEffort: String?
    public let usedRecommendationFallback: Bool

    public init(
        routingTarget: AgentRoutingTarget,
        providerID: ProviderSettingsID,
        provider: ProviderKind,
        modelID: String?,
        reasoningEffort: String?,
        usedRecommendationFallback: Bool
    ) {
        self.routingTarget = routingTarget
        self.providerID = providerID
        self.provider = provider
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.usedRecommendationFallback = usedRecommendationFallback
    }
}

public struct AgentModelTarget: Codable, Hashable, Sendable {
    public let providerID: ProviderSettingsID
    public let modelID: String?
    public let reasoningEffort: String?
    public let pinned: Bool

    public init(providerID: ProviderSettingsID, modelID: String? = nil, reasoningEffort: String? = nil, pinned: Bool = false) {
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.pinned = pinned
    }
}

public struct AgentModelsProfile: Codable, Hashable, Sendable {
    public let oracle: AgentModelTarget?
    public let contextBuilder: AgentModelTarget?
    public let explore: AgentModelTarget?
    public let engineer: AgentModelTarget?
    public let pair: AgentModelTarget?
    public let design: AgentModelTarget?
    public let restrictDiscoveryToRoleModels: Bool

    public init(
        oracle: AgentModelTarget? = nil,
        contextBuilder: AgentModelTarget? = nil,
        explore: AgentModelTarget? = nil,
        engineer: AgentModelTarget? = nil,
        pair: AgentModelTarget? = nil,
        design: AgentModelTarget? = nil,
        restrictDiscoveryToRoleModels: Bool = false
    ) {
        self.oracle = oracle
        self.contextBuilder = contextBuilder
        self.explore = explore
        self.engineer = engineer
        self.pair = pair
        self.design = design
        self.restrictDiscoveryToRoleModels = restrictDiscoveryToRoleModels
    }

    public subscript(target: AgentRoutingTarget) -> AgentModelTarget? {
        switch target {
        case .oracle: oracle
        case .contextBuilder: contextBuilder
        case .explore: explore
        case .engineer: engineer
        case .pair: pair
        case .design: design
        }
    }

    public func replacing(_ target: AgentRoutingTarget, with value: AgentModelTarget?) -> AgentModelsProfile {
        AgentModelsProfile(
            oracle: target == .oracle ? value : oracle,
            contextBuilder: target == .contextBuilder ? value : contextBuilder,
            explore: target == .explore ? value : explore,
            engineer: target == .engineer ? value : engineer,
            pair: target == .pair ? value : pair,
            design: target == .design ? value : design,
            restrictDiscoveryToRoleModels: restrictDiscoveryToRoleModels
        )
    }

    public static let `default` = AgentModelsProfile()
}

public enum AgentModelsScopeMode: String, Codable, Sendable {
    case inheritGlobal
    case projectOverride
}

public struct AgentModelsScopeDocument: Codable, Hashable, Sendable {
    public let mode: AgentModelsScopeMode
    public let profile: AgentModelsProfile?

    public init(mode: AgentModelsScopeMode, profile: AgentModelsProfile?) {
        self.mode = mode
        self.profile = profile
    }
}

public enum AgentModelRecommendationAvailability: String, Codable, Sendable {
    case exact
    case informational
    case unavailable
}

public struct AgentModelRecommendationRow: Codable, Hashable, Sendable {
    public let target: AgentRoutingTarget
    public let recommendedTarget: AgentModelTarget?
    public let availability: AgentModelRecommendationAvailability
    public let detail: String

    public init(target: AgentRoutingTarget, recommendedTarget: AgentModelTarget?, availability: AgentModelRecommendationAvailability, detail: String) {
        self.target = target
        self.recommendedTarget = recommendedTarget
        self.availability = availability
        self.detail = detail
    }
}

public struct AgentModelsSettingsSnapshot: Codable, Hashable, Sendable {
    public let globalProfile: AgentModelsProfile
    public let globalRevision: Int64
    public let projectID: UUID?
    public let projectMode: AgentModelsScopeMode
    public let projectProfile: AgentModelsProfile?
    public let projectRevision: Int64
    public let effectiveProfile: AgentModelsProfile
    public let recommendationProfileVersion: String
    public let recommendations: [AgentModelRecommendationRow]
    public let updatedAt: Date

    public init(
        globalProfile: AgentModelsProfile,
        globalRevision: Int64,
        projectID: UUID?,
        projectMode: AgentModelsScopeMode,
        projectProfile: AgentModelsProfile?,
        projectRevision: Int64,
        effectiveProfile: AgentModelsProfile,
        recommendationProfileVersion: String = "202_608",
        recommendations: [AgentModelRecommendationRow] = [],
        updatedAt: Date
    ) {
        self.globalProfile = globalProfile
        self.globalRevision = globalRevision
        self.projectID = projectID
        self.projectMode = projectMode
        self.projectProfile = projectProfile
        self.projectRevision = projectRevision
        self.effectiveProfile = effectiveProfile
        self.recommendationProfileVersion = recommendationProfileVersion
        self.recommendations = recommendations
        self.updatedAt = updatedAt
    }
}

public struct ReplaceGlobalAgentModelsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let profile: AgentModelsProfile

    public init(expectedRevision: Int64, profile: AgentModelsProfile) {
        self.expectedRevision = expectedRevision
        self.profile = profile
    }
}

public struct ReplaceProjectAgentModelsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64
    public let mode: AgentModelsScopeMode
    public let profile: AgentModelsProfile?

    public init(expectedRevision: Int64, mode: AgentModelsScopeMode, profile: AgentModelsProfile?) {
        self.expectedRevision = expectedRevision
        self.mode = mode
        self.profile = profile
    }
}

public struct CopyGlobalAgentModelsToProjectRequest: Codable, Hashable, Sendable {
    public let expectedGlobalRevision: Int64
    public let expectedProjectRevision: Int64

    public init(expectedGlobalRevision: Int64, expectedProjectRevision: Int64) {
        self.expectedGlobalRevision = expectedGlobalRevision
        self.expectedProjectRevision = expectedProjectRevision
    }
}

public struct ApplyAgentModelRecommendationsRequest: Codable, Hashable, Sendable {
    public let expectedRevision: Int64

    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }
}
