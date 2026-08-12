import RepoPromptAgentRuntimeCore
@testable import RepoPromptApp
import RepoPromptServiceProtocol
import XCTest

@MainActor
final class AgentCatalogAuthorityDesktopAdapterTests: XCTestCase {
    func testDesktopDynamicRegistryAndProviderProfileFlowThroughSharedAuthority() throws {
        let suite = "AgentCatalogAuthorityDesktopAdapterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: nil,
            codexMCPServerEntries: { [] }
        )
        preferences.setCodexBashToolEnabled(false)
        preferences.setCodexSearchToolEnabled(false)
        preferences.setCodexGoalSupportEnabled(false)
        preferences.setCodexReasoningSummariesEnabled(true)
        preferences.setCodexMemoriesEnabled(true)
        preferences.setPermissionLevel(.codex(.autoReview))
        let preferenceProfile = preferences.composerCatalogProfile(selectedAgent: .codexExec)
        let profile = AgentCatalogProviderProfile(
            toolControls: preferenceProfile.toolControls,
            permissionControl: preferenceProfile.permissionControl,
            modelCapabilities: .init(nativeImages: true, steering: true)
        )

        let remote = CodexAppServerClient.RemoteModel(
            id: "provider-discovered-model",
            model: "provider-discovered-model",
            displayName: "Provider Discovered Model",
            description: "Runtime metadata",
            isDefault: true,
            supportedReasoningEfforts: [
                .init(reasoningEffort: "low", description: "Low"),
                .init(reasoningEffort: "xhigh", description: "Extra high")
            ],
            defaultReasoningEffort: "xhigh"
        )
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false
        )
        let resolution = AgentModelCatalog.sharedAuthorityResolution(
            availability: availability,
            codexDynamicModels: [remote],
            profiles: [.codex: profile]
        )
        let provider = try XCTUnwrap(resolution.providers.first { $0.providerID == .codex })
        let model = try XCTUnwrap(provider.models.first { $0.descriptor.modelID == remote.id })

        XCTAssertEqual(model.descriptor.supportedEffortIDs, ["low", "xhigh"])
        XCTAssertEqual(model.descriptor.defaultEffortID, "xhigh")
        XCTAssertEqual(model.descriptor.providerRawValue, "provider-discovered-model-xhigh")
        XCTAssertEqual(model.descriptor.capabilities, .init(nativeImages: true, steering: true))
        XCTAssertEqual(provider.toolControls, profile.toolControls)
        XCTAssertEqual(provider.permissionControl, profile.permissionControl)
        XCTAssertEqual(resolution.selection?.providerID, .codex)
        XCTAssertEqual(resolution.selection?.modelID, remote.id)
        XCTAssertEqual(resolution.selection?.effortID, "xhigh")
        XCTAssertEqual(resolution.selection?.permissionID, "codex.autoReview")
        XCTAssertEqual(resolution.selection?.toolValues["codex.bash"], .boolean(false))
        XCTAssertEqual(resolution.selection?.toolValues["codex.reasoningSummaries"], .boolean(true))
    }
}
