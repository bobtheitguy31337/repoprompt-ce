import RepoPromptAgentRuntimeCore
@testable import RepoPromptApp
import RepoPromptRuntimeModel
import XCTest

final class PortableProviderMappingTests: XCTestCase {
    func testDesktopIdentityAndPermissionMappingsUsePortableOwners() {
        XCTAssertEqual(AgentModel.codexHigh.portableModelIdentifier.rawValue, AgentModel.codexHigh.rawValue)
        XCTAssertEqual(AgentProviderKind.codexExec.portableSettingsID, .codex)
        XCTAssertEqual(AgentProviderKind.claudeCodeGLM.portableSettingsID, .claudeGLM)
        XCTAssertEqual(
            AgentProviderPermissionLevelID.codex(.autoReview).portablePermissionID,
            ProviderPermissionID(rawValue: "codex.autoReview")
        )
        XCTAssertEqual(
            AgentProviderPermissionLevelID.cursor(.managedDefault).portablePermissionID,
            ProviderPermissionID(rawValue: "cursor.managedDefault")
        )
    }
}
