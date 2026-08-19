@testable import RepoPromptAgentRuntimeCore
import RepoPromptRuntimeModel
import XCTest

final class ProviderTurnConfigurationTests: XCTestCase {
    func testBuiltInProviderFamiliesCompileStablePermissions() throws {
        let codex = try ProviderTurnConfigurationAdapters.compile(.init(
            model: model(.codex, rawValue: "gpt-5", efforts: ["high"]),
            effortID: "high",
            permissionID: .init(rawValue: "codex.autoReview"),
            settings: .codex(.init())
        ))
        XCTAssertEqual(codex.runtimeKind, .codex)
        XCTAssertEqual(codex.permissions.executionMode, .workspaceWrite)
        XCTAssertEqual(codex.providerSettings["codex.approvalsReviewer"], "auto_review")
        XCTAssertEqual(codex.providerSettings["codex.mcpServers"], "repoprompt")

        let claude = try ProviderTurnConfigurationAdapters.compile(.init(
            model: model(.claudeGLM, rawValue: "glm"),
            permissionID: .init(rawValue: "claude.fullAccess"),
            settings: .claudeCompatible(.init())
        ))
        XCTAssertEqual(claude.runtimeKind, .claudeCompatible)
        XCTAssertEqual(claude.permissions.executionMode, .fullAccess)
        XCTAssertEqual(claude.providerSettings["claude.permissionMode"], "bypassPermissions")

        let acp = try ProviderTurnConfigurationAdapters.compile(.init(
            model: model(.cursorACP, rawValue: "cursor"),
            permissionID: .init(rawValue: "cursor.managedDefault"),
            settings: .acp
        ))
        XCTAssertEqual(acp.runtimeKind, .cursorACP)
        XCTAssertEqual(acp.permissions.executionMode, .workspaceWrite)

        let direct = try ProviderTurnConfigurationAdapters.compile(.init(
            model: model(.openRouter, rawValue: "openrouter/model"),
            permissionID: .init(rawValue: "provider.readOnly"),
            settings: .directAPI
        ))
        XCTAssertEqual(direct.runtimeKind, .headlessAdapter)
        XCTAssertEqual(direct.permissions.executionMode, .readOnly)
        XCTAssertFalse(direct.permissions.filesystemWrite)
    }

    func testMisconfiguredFamilyAdapterThrowsInsteadOfTrapping() throws {
        let adapter = ClaudeCompatibleTurnConfigurationAdapter(providerID: .codex)
        let input = try ProviderTurnConfigurationInput(
            model: model(.codex, rawValue: "gpt-5"),
            permissionID: .init(rawValue: "claude.requireApproval"),
            settings: .claudeCompatible(.init())
        )

        XCTAssertThrowsError(try adapter.compile(input)) { error in
            XCTAssertEqual(error as? ProviderTurnConfigurationError, .providerModelMismatch)
        }
    }

    func testTurnRuntimeUsesInjectedSettingsClockIDAndProvider() async throws {
        let turnID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let provider = RecordingProvider()
        let runtime = AgentTurnRuntime(
            settingsProvider: FixedSettingsProvider(snapshot: .init(
                permissionID: .init(rawValue: "codex.readOnly"),
                settings: .codex(.init(searchEnabled: false))
            )),
            provider: provider,
            clock: FixedClock(instant: .now),
            idGenerator: FixedIDGenerator(id: turnID)
        )
        let owner = RuntimeOwnerID(rawValue: "owner")
        let prepared = try await runtime.prepareAndExecute(.init(
            ownerID: owner,
            model: model(.codex, rawValue: "gpt-5"),
            workflow: WorkflowDefinition()
        ))

        XCTAssertEqual(prepared.turnID, turnID)
        XCTAssertEqual(prepared.ownerID, owner)
        XCTAssertEqual(prepared.configuration.permissions.executionMode, .readOnly)
        XCTAssertEqual(prepared.configuration.providerSettings["codex.searchEnabled"], "false")
        let executedTurnID = await provider.executedTurnID()
        XCTAssertEqual(executedTurnID, turnID)
    }

    private func model(
        _ providerID: ProviderSettingsID,
        rawValue: String,
        efforts: Set<String> = []
    ) throws -> ProviderModelDescriptor {
        try ProviderModelDescriptor(
            providerID: providerID,
            providerRawValue: rawValue,
            supportedEffortIDs: efforts
        )
    }
}

private struct FixedSettingsProvider: ProviderTurnSettingsProviding {
    let snapshot: ProviderTurnSettingsSnapshot

    func settings(for _: ProviderSettingsID) async throws -> ProviderTurnSettingsSnapshot {
        snapshot
    }
}

private actor RecordingProvider: ProviderTurnExecuting {
    private var turnID: UUID?

    func execute(_ turn: PreparedProviderTurn) async throws {
        turnID = turn.turnID
    }

    func executedTurnID() -> UUID? {
        turnID
    }
}

private struct FixedClock: RuntimeClock {
    let instant: ContinuousClock.Instant

    func now() -> ContinuousClock.Instant {
        instant
    }
}

private struct FixedIDGenerator: RuntimeIDGenerator {
    let id: UUID

    func makeID() -> UUID {
        id
    }
}
