import Foundation
import MCP
import RepoPromptRemoteProtocol
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class RemoteMutationBehaviorTests: XCTestCase {
    func testMCPInvalidParamsBecomeActionableRemoteRejection() {
        let message = WindowRemoteAgentControlService.remoteRejectionMessage(
            for: MCPError.invalidParams("The requested agent session is not currently available.")
        )

        XCTAssertEqual(message, "The requested agent session is not currently available.")
    }

    func testMCPInternalFailuresDoNotExposeInternalDetails() {
        let sensitive = "/private/sensitive/provider-state.json"
        let failures: [MCPError] = [
            .internalError(sensitive),
            .serverError(code: -32000, message: sensitive),
            .parseError(sensitive),
            .methodNotFound(sensitive)
        ]

        for failure in failures {
            let message = WindowRemoteAgentControlService.remoteRejectionMessage(for: failure)
            XCTAssertEqual(message, "The Mac could not deliver this command to the agent session.")
            XCTAssertFalse(message.contains(sensitive))
        }
    }

    func testMCPTransportFailureDoesNotExposeInternalDetails() {
        let message = WindowRemoteAgentControlService.remoteRejectionMessage(
            for: MCPError.transportError(NSError(
                domain: "fixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "/private/sensitive/socket failed"]
            ))
        )

        XCTAssertEqual(
            message,
            "The Mac lost its connection to the agent while delivering this command. Try again."
        )
        XCTAssertFalse(message.contains("/private/sensitive"))
    }

    func testRemoteMutationBoundaryRejectsIncompleteRequestsForEveryMutation() async {
        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)

        for operation in RemoteMutationFailurePolicy.mutationOperations {
            do {
                _ = try await service.execute(RemoteCommandRequest(operation: operation))
                XCTFail("Incomplete \(operation.rawValue) request must be rejected.")
            } catch let error as RemoteAgentControlServiceError {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            } catch {
                XCTFail("Expected a typed remote rejection for \(operation.rawValue), got \(error).")
            }
        }
    }

    func testCancelRejectsTerminalSessionWithoutChangingItsState() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        let sessionID = UUID()
        _ = agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .completed

        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.id.uuidString)
        let request = RemoteCommandRequest(
            operation: .cancel,
            workspaceID: workspaceID,
            sessionID: sessionID
        )
        let service = WindowRemoteAgentControlService(windowStatesManager: WindowStatesManager.shared)

        do {
            _ = try await service.execute(request)
            XCTFail("A terminal session must not accept cancellation.")
        } catch let error as RemoteAgentControlServiceError {
            guard case .commandRejected = error else {
                return XCTFail("Expected command rejection, got \(error).")
            }
        }
        XCTAssertEqual(session.runState, .completed)
    }

    func testConfigureSessionRejectsActiveRunWithoutChangingSelection() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let agentMode = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.composeTabs.first?.id)
        let session = await agentMode.ensureSessionReady(tabID: tabID)
        let sessionID = UUID()
        _ = agentMode.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        session.runState = .running
        let originalAgent = session.selectedAgent
        let originalModel = session.selectedModelRaw

        do {
            _ = try await agentMode.mcpConfigureRemoteSession(
                tabID: tabID,
                sessionID: sessionID,
                agentRaw: nil,
                modelRaw: "unavailable-model",
                reasoningEffortRaw: nil
            )
            XCTFail("An active run must reject selection changes.")
        } catch let error as MCPError {
            XCTAssertEqual(
                WindowRemoteAgentControlService.remoteRejectionMessage(for: error),
                "Model and effort controls are locked during an active run."
            )
        }
        XCTAssertEqual(session.selectedAgent, originalAgent)
        XCTAssertEqual(session.selectedModelRaw, originalModel)
    }

    func testProvisionalSessionRollbackReportsCompleteCleanup() async throws {
        let window = try await makeWindow()
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let target = try await window.agentModeViewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Remote rollback fixture"
        )

        let cleanupCompleted = await window.agentModeViewModel.mcpDiscardSessionTarget(target)

        XCTAssertTrue(cleanupCompleted)
        XCTAssertNil(window.agentModeViewModel.session(for: target.tabID, createIfNeeded: false))
    }

    private func makeWindow() async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)

        let workspace = window.workspaceManager.createWorkspace(
            name: "Remote mutation (UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "remoteMutationTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }
}
