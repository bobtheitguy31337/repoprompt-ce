import Foundation
import RepoPromptAgentRuntimeCore
@testable import RepoPromptApp
import RepoPromptRuntimeModel
import XCTest

final class PortableProviderMappingTests: XCTestCase {
    func testEveryDesktopProviderKindMapsToCanonicalPortableIdentity() {
        let expected: [AgentProviderKind: ProviderSettingsID] = [
            .claudeCode: .claudeCompatible,
            .codexExec: .codex,
            .openCode: .openCodeACP,
            .cursor: .cursorACP,
            .grokBuild: .grokBuildACP,
            .claudeCodeGLM: .claudeGLM,
            .kimiCode: .claudeKimi,
            .customClaudeCompatible: .claudeCustom
        ]
        XCTAssertEqual(Set(expected.keys), Set(AgentProviderKind.allCases))
        for (desktop, portable) in expected {
            XCTAssertEqual(desktop.portableSettingsID, portable, desktop.rawValue)
            XCTAssertEqual(desktop.portableSettingsID.runtimeKind, portable.runtimeKind)
        }
    }

    func testEveryDesktopPermissionMapsToPortableDescriptorChoice() throws {
        let portableProvider: [AgentProviderBindingID: ProviderSettingsID] = [
            .codex: .codex,
            .claude: .claudeCompatible,
            .openCode: .openCodeACP,
            .cursor: .cursorACP,
            .grokBuild: .grokBuildACP
        ]
        XCTAssertEqual(Set(portableProvider.keys), Set(AgentProviderBindingID.allCases))

        let fixture = try providerTurnFixture()
        XCTAssertEqual(fixture.prototypeCommit, "45c42d65e444884d1681f4504c10d25dcb7d858a")
        XCTAssertEqual(
            fixture.generatedFrom,
            "Packages/RepoPromptPortableRuntime/Sources/RepoPromptAgentRuntimeCore/ProviderTurnConfigurationAdapters.swift"
        )

        for bindingID in AgentProviderBindingID.allCases {
            let desktopIDs = Set(AgentProviderPermissionLevelID.options(for: bindingID).map(\.portablePermissionID.rawValue))
            let providerID = try XCTUnwrap(portableProvider[bindingID])
            let descriptor = try XCTUnwrap(ProviderComposerStableControls.permissionDescriptor(
                providerID: providerID,
                selectedID: nil,
                mutable: true,
                lockReasonCode: nil
            ))
            XCTAssertEqual(desktopIDs, Set(descriptor.choices.map(\.id)), bindingID.rawValue)
            let fixtureFamily = try XCTUnwrap(fixture.families.first { $0.providerIds.contains(providerID) })
            XCTAssertEqual(desktopIDs, Set(fixtureFamily.permissionModes.keys), bindingID.rawValue)
            XCTAssertTrue(desktopIDs.contains(
                AgentProviderPermissionLevelID.subagentDefault(for: bindingID).portablePermissionID.rawValue
            ))
        }
    }

    private func providerTurnFixture() throws -> DesktopProviderTurnFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "Packages/RepoPromptPortableRuntime/Tests/Fixtures/AgentParity/v1/provider-turn-semantics.json"
        )
        return try JSONDecoder().decode(DesktopProviderTurnFixture.self, from: Data(contentsOf: url))
    }

    func testEveryDesktopModelRawValueUsesPortableModelIdentity() {
        for model in AgentModel.allCases {
            XCTAssertEqual(model.portableModelIdentifier.rawValue, model.rawValue, model.rawValue)
        }
    }
}

private struct DesktopProviderTurnFixture: Decodable {
    let prototypeCommit: String
    let generatedFrom: String
    let families: [DesktopProviderTurnFamily]
}

private struct DesktopProviderTurnFamily: Decodable {
    let providerIds: [ProviderSettingsID]
    let permissionModes: [String: String]
}
