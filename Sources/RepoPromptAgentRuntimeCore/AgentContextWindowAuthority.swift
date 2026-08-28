import Foundation
import RepoPromptServiceProtocol

/// One portable policy for the context-window value shown by every RepoPrompt client.
/// Provider runtimes remain authoritative when they report a value. Known model
/// metadata is the next-best source; provider-family defaults are only a fallback.
public enum AgentContextWindowAuthority {
    public static let standardFallbackTokens = 200_000
    public static let grokFallbackTokens = 500_000

    public static func effectiveTokens(
        reportedTokens: Int?,
        compatibleBackendTokens: Int? = nil,
        resolvedModelTokens: Int? = nil,
        providerID: ProviderSettingsID? = nil,
        runtimeKind: ProviderKind? = nil,
        modelRaw: String? = nil
    ) -> Int {
        for candidate in [reportedTokens, compatibleBackendTokens, resolvedModelTokens, knownModelTokens(for: modelRaw)] {
            if let candidate, candidate > 0 { return candidate }
        }
        if providerID == .grokBuildACP || runtimeKind == .grokBuildACP {
            return grokFallbackTokens
        }
        return standardFallbackTokens
    }

    /// Portable subset of Desktop's verified model metadata. Dynamic providers
    /// should report their actual window; unknown model IDs deliberately fall back
    /// by provider family instead of being guessed in a browser client.
    public static func knownModelTokens(for rawModel: String?) -> Int? {
        guard var model = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !model.isEmpty else { return nil }
        if let separator = model.lastIndex(of: ":") {
            let effort = String(model[model.index(after: separator)...])
            if ["none", "minimal", "low", "medium", "high", "xhigh", "x-high", "max", "ultra"].contains(effort) {
                model = String(model[..<separator])
            }
        }
        switch model {
        case "claude-fable-5", "claude-sonnet-5", "claude-opus-5", "claude-opus-4-8", "opus[1m]", "glm-5.2[1m]":
            return 1_000_000
        case "sonnet", "opus", "haiku",
             "claude-sonnet-4-6", "claude-sonnet-4-5",
             "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
             "claude-haiku-4-5":
            return 200_000
        default:
            return nil
        }
    }
}
