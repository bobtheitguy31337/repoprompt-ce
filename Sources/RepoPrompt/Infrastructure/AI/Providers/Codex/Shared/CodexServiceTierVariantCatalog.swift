import Foundation
import RepoPromptAgentRuntimeCore

enum CodexServiceTierVariantCatalog {
    static let fastServiceTier = CodexServiceTierAvailability.fastServiceTier
    static let fastCostWarningText = CodexServiceTierAvailability.fastCostWarningText

    static func isFastEligible(baseModelID: String) -> Bool {
        CodexServiceTierAvailability.isFastEligible(baseModelID: baseModelID)
    }

    static func isFastVariant(rawModel: String?) -> Bool {
        let specifier = CodexModelSpecifier(raw: rawModel)
        guard let baseModel = specifier.baseModel else { return false }
        return supportedServiceTier(
            baseModelID: baseModel,
            serviceTier: specifier.serviceTier
        ) == fastServiceTier
    }

    static func serviceTierAwareBaseID(for rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let specifier = CodexModelSpecifier(raw: trimmed)
        var baseID = (specifier.baseModel ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        if let tier = supportedServiceTier(
            baseModelID: baseID,
            serviceTier: specifier.serviceTier
        ) {
            baseID += "-\(tier)"
        }
        return baseID
    }

    static func supportedServiceTier(baseModelID: String, serviceTier: String?) -> String? {
        guard let serviceTier else { return nil }
        let normalizedTier = serviceTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedTier == fastServiceTier,
              isFastEligible(baseModelID: baseModelID) else { return nil }
        return normalizedTier
    }

    static func fastVariantID(
        baseModelID: String,
        reasoningEffort: CodexReasoningEffort?
    ) -> String? {
        let baseModelID = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseModelID.isEmpty, isFastEligible(baseModelID: baseModelID) else { return nil }
        if let reasoningEffort {
            return "\(baseModelID)-\(fastServiceTier)-\(reasoningEffort.rawValue)"
        }
        return "\(baseModelID)-\(fastServiceTier)"
    }
}
