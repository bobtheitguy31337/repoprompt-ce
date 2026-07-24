import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteProtocol
import XCTest

@MainActor
final class RemoteSnapshotProjectionTests: XCTestCase {
    func testAvailabilityPolicyCoversActiveWaitingAndTerminalStates() {
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.opening))
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.working))
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.waitingForInput))
        XCTAssertTrue(RemoteAvailabilityController.requiresSleepAssertion(.blocked))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.idle))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.completed))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.failed))
        XCTAssertFalse(RemoteAvailabilityController.requiresSleepAssertion(.cancelled))
    }

    func testFixtureProjectsOpeningBlockedAndCancelledTransitions() async {
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 200)
        let records = [
            fixtureSession(id: UUID(), workspaceID: workspaceID, state: .opening, date: now),
            fixtureSession(id: UUID(), workspaceID: workspaceID, state: .blocked, date: now.addingTimeInterval(-1)),
            fixtureSession(id: UUID(), workspaceID: workspaceID, state: .cancelled, date: now.addingTimeInterval(-2))
        ]
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: FixtureWorkspaceCatalog(records: [
                RemoteWorkspaceRecord(
                    workspaceID: workspaceID,
                    name: "Lifecycle fixture",
                    repositoryRootSummary: "repo",
                    isOpen: true,
                    activeSessionIDs: [],
                    lastActivityAt: now
                )
            ]),
            sessionQuery: FixtureSessionQuery(records: records),
            workflowCatalog: StaticRemoteCatalogService()
        )

        let revisionEpoch = UUID()
        let snapshot = await builder.build(
            desktop: RemoteDesktopSummary(
                instanceID: "lifecycle-desktop",
                displayName: "Fixture Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            transcriptRevisionEpoch: revisionEpoch
        )

        XCTAssertEqual(snapshot.transcriptRevisionEpoch, revisionEpoch)
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .opening })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .blocked })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .cancelled })
        XCTAssertEqual(snapshot.attentionItems.count, 0)
    }

    func testCredentialAuthorityRejectsRevokedExpiredAndMismatchedCredentials() {
        let now = Date(timeIntervalSince1970: 100)
        let credential = RemoteStoredDeviceCredential(
            deviceID: "device-1",
            credential: "credential-1",
            expiresAt: now.addingTimeInterval(60),
            deviceName: "Test phone"
        )
        XCTAssertTrue(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer credential-1",
            credential: credential,
            at: now
        ))
        XCTAssertFalse(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer old-credential",
            credential: credential,
            at: now
        ))
        XCTAssertFalse(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer credential-1",
            credential: credential,
            at: now.addingTimeInterval(61)
        ))
        XCTAssertFalse(RemoteCredentialAuthority.accepts(
            authorizationHeader: "Bearer credential-1",
            credential: nil,
            at: now
        ))
    }

    func testWorkspaceActivationPlannerHandlesReusableClosingAndMissingWindows() {
        XCTAssertEqual(
            RemoteWorkspaceActivationPlanner.decision(
                workspaceExists: true,
                reusableWindowExists: true
            ),
            .reuseExistingWindow
        )
        XCTAssertEqual(
            RemoteWorkspaceActivationPlanner.decision(
                workspaceExists: true,
                reusableWindowExists: false
            ),
            .openNewWindow
        )
        XCTAssertEqual(
            RemoteWorkspaceActivationPlanner.decision(
                workspaceExists: false,
                reusableWindowExists: false
            ),
            .workspaceNotFound
        )
    }

    func testMutationFailurePolicyCoversEveryRemoteMutation() {
        XCTAssertEqual(
            Set(RemoteMutationFailurePolicy.mutationOperations),
            Set([
                .startRun,
                .configureSession,
                .configureTools,
                .followUp,
                .steer,
                .respond,
                .cancel,
                .resume,
                .contextBuilder
            ])
        )
        XCTAssertEqual(
            RemoteMutationFailurePolicy.disposition(for: .startRun),
            .rollbackProvisionalSession
        )

        for operation in RemoteMutationFailurePolicy.mutationOperations where operation != .startRun {
            XCTAssertEqual(
                RemoteMutationFailurePolicy.disposition(for: operation),
                .preserveExistingSession,
                "A failed \(operation.rawValue) mutation must not claim acceptance or discard an existing session."
            )
        }
    }

    func testProjectionRebuildsAfterRestartAndPreservesLifecycleState() async {
        let workspaceID = UUID()
        let waitingID = UUID()
        let cancelledID = UUID()
        let now = Date(timeIntervalSince1970: 250)
        let workspace = RemoteWorkspaceRecord(
            workspaceID: workspaceID,
            name: "Restart fixture",
            repositoryRootSummary: "repo",
            isOpen: false,
            activeSessionIDs: [],
            lastActivityAt: now
        )
        let records = [
            RemoteSessionRecord(
                sessionID: waitingID,
                workspaceID: workspaceID,
                composeTabID: UUID(),
                parentSessionID: nil,
                sessionName: "Waiting",
                workflow: nil,
                agent: nil,
                model: nil,
                reasoningEffort: nil,
                runState: .waitingForInput,
                lifecycleStage: "waiting",
                latestMeaningfulActivity: "Waiting for input",
                pendingInteraction: RemoteInteractionSummary(
                    id: "waiting",
                    kind: .question,
                    prompt: "Continue?"
                ),
                worktreeSummary: nil,
                mergeAttention: nil,
                failureSummary: nil,
                lastUpdatedAt: now,
                isLive: true
            ),
            RemoteSessionRecord(
                sessionID: cancelledID,
                workspaceID: workspaceID,
                composeTabID: UUID(),
                parentSessionID: nil,
                sessionName: "Cancelled",
                workflow: nil,
                agent: nil,
                model: nil,
                reasoningEffort: nil,
                runState: .cancelled,
                lifecycleStage: "cancelled",
                latestMeaningfulActivity: "Cancelled",
                pendingInteraction: nil,
                worktreeSummary: nil,
                mergeAttention: nil,
                failureSummary: nil,
                lastUpdatedAt: now.addingTimeInterval(-1),
                isLive: false
            )
        ]

        func build() async -> RemoteSnapshot {
            await RemoteSnapshotBuilder(
                workspaceCatalog: FixtureWorkspaceCatalog(records: [workspace]),
                sessionQuery: FixtureSessionQuery(records: records),
                workflowCatalog: StaticRemoteCatalogService()
            ).build(
                desktop: RemoteDesktopSummary(
                    instanceID: "restart-desktop",
                    displayName: "Fixture Mac",
                    appVersion: "test",
                    isAvailable: true
                ),
                connection: RemoteConnectionSummary(state: .connected),
                authorization: RemoteAuthorizationState()
            )
        }

        let beforeRestart = await build()
        let afterRestart = await build()

        XCTAssertEqual(afterRestart.workspaces, beforeRestart.workspaces)
        XCTAssertEqual(afterRestart.sessions, beforeRestart.sessions)
        XCTAssertTrue(afterRestart.sessions.contains { $0.runState == .waitingForInput })
        XCTAssertTrue(afterRestart.sessions.contains { $0.runState == .cancelled })
        XCTAssertTrue(afterRestart.workspaces.contains { !$0.isOpen })
    }

    func testProjectionHandlesLargeFleetWithParentChildRelationships() async {
        let workspaceID = UUID()
        let now = Date(timeIntervalSince1970: 300)
        let sessionIDs = (0 ..< 2000).map { _ in UUID() }
        let records = sessionIDs.enumerated().map { index, sessionID in
            RemoteSessionRecord(
                sessionID: sessionID,
                workspaceID: workspaceID,
                composeTabID: UUID(),
                parentSessionID: index == 0 ? nil : (index.isMultiple(of: 10) ? nil : sessionIDs[index / 10]),
                sessionName: "Fleet (index)",
                workflow: index.isMultiple(of: 2) ? "review" : "implement",
                agent: "codex",
                model: "default",
                reasoningEffort: "medium",
                runState: index.isMultiple(of: 3) ? .working : .idle,
                lifecycleStage: "running",
                latestMeaningfulActivity: "Processing item (index)",
                pendingInteraction: nil,
                worktreeSummary: nil,
                mergeAttention: nil,
                failureSummary: nil,
                lastUpdatedAt: now.addingTimeInterval(TimeInterval(-index)),
                isLive: true
            )
        }
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: FixtureWorkspaceCatalog(records: [
                RemoteWorkspaceRecord(
                    workspaceID: workspaceID,
                    name: "Large fleet",
                    repositoryRootSummary: "repo",
                    isOpen: true,
                    activeSessionIDs: sessionIDs,
                    lastActivityAt: now
                )
            ]),
            sessionQuery: FixtureSessionQuery(records: records),
            workflowCatalog: StaticRemoteCatalogService()
        )

        let snapshot = await builder.build(
            desktop: RemoteDesktopSummary(
                instanceID: "large-fleet-desktop",
                displayName: "Fixture Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState()
        )

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.sessions.count, 2000)
        XCTAssertEqual(snapshot.sessions.count(where: { !$0.childSessionIDs.isEmpty }), 200)
        XCTAssertEqual(snapshot.sessions.reduce(0) { $0 + $1.childSessionIDs.count }, 1800)
    }

    func testFixtureProjectsLiveWaitingFailedCompletedAndChildSessions() async {
        let liveWorkspaceID = UUID()
        let closedWorkspaceID = UUID()
        let liveSessionID = UUID()
        let waitingSessionID = UUID()
        let failedSessionID = UUID()
        let completedSessionID = UUID()
        let childSessionID = UUID()
        let now = Date(timeIntervalSince1970: 100)

        let workspaces = FixtureWorkspaceCatalog(
            records: [
                RemoteWorkspaceRecord(
                    workspaceID: liveWorkspaceID,
                    name: "Live workspace",
                    repositoryRootSummary: "repo",
                    isOpen: true,
                    activeSessionIDs: [liveSessionID, waitingSessionID],
                    lastActivityAt: now
                ),
                RemoteWorkspaceRecord(
                    workspaceID: closedWorkspaceID,
                    name: "Closed workspace",
                    repositoryRootSummary: "archived-repo",
                    isOpen: false,
                    activeSessionIDs: [],
                    lastActivityAt: now.addingTimeInterval(-10)
                )
            ]
        )
        let sessions = FixtureSessionQuery(
            records: [
                RemoteSessionRecord(
                    sessionID: liveSessionID,
                    workspaceID: liveWorkspaceID,
                    composeTabID: UUID(),
                    parentSessionID: nil,
                    sessionName: "Live run",
                    workflow: "Engineer",
                    agent: "codex",
                    model: "gpt",
                    reasoningEffort: "high",
                    runState: .working,
                    lifecycleStage: "running",
                    latestMeaningfulActivity: "Editing files",
                    pendingInteraction: nil,
                    worktreeSummary: nil,
                    mergeAttention: nil,
                    failureSummary: nil,
                    lastUpdatedAt: now,
                    isLive: true,
                    workflowID: AgentWorkflow.orchestrate.definition.id,
                    runStartedAt: now.addingTimeInterval(-5),
                    transcriptRevision: 7
                ),
                RemoteSessionRecord(
                    sessionID: waitingSessionID,
                    workspaceID: liveWorkspaceID,
                    composeTabID: UUID(),
                    parentSessionID: nil,
                    sessionName: "Needs input",
                    workflow: nil,
                    agent: "claude",
                    model: "sonnet",
                    reasoningEffort: nil,
                    runState: .waitingForInput,
                    lifecycleStage: "waiting",
                    latestMeaningfulActivity: "Waiting for your answer",
                    pendingInteraction: RemoteInteractionSummary(
                        id: "question-1",
                        kind: .question,
                        title: "Choose a direction",
                        prompt: "Which option should the agent use?"
                    ),
                    worktreeSummary: nil,
                    mergeAttention: nil,
                    failureSummary: nil,
                    lastUpdatedAt: now,
                    isLive: true
                ),
                fixtureSession(id: failedSessionID, workspaceID: closedWorkspaceID, state: .failed, date: now.addingTimeInterval(-2)),
                fixtureSession(id: completedSessionID, workspaceID: closedWorkspaceID, state: .completed, date: now.addingTimeInterval(-3)),
                RemoteSessionRecord(
                    sessionID: childSessionID,
                    workspaceID: liveWorkspaceID,
                    composeTabID: UUID(),
                    parentSessionID: liveSessionID,
                    sessionName: "Child run",
                    workflow: nil,
                    agent: "codex",
                    model: "gpt",
                    reasoningEffort: nil,
                    runState: .working,
                    lifecycleStage: "running",
                    latestMeaningfulActivity: "Delegated task",
                    pendingInteraction: nil,
                    worktreeSummary: nil,
                    mergeAttention: nil,
                    failureSummary: nil,
                    lastUpdatedAt: now,
                    isLive: true
                )
            ]
        )
        let builder = RemoteSnapshotBuilder(
            workspaceCatalog: workspaces,
            sessionQuery: sessions,
            workflowCatalog: StaticRemoteCatalogService()
        )

        let snapshot = await builder.build(
            desktop: RemoteDesktopSummary(
                instanceID: "fixture-desktop",
                displayName: "Fixture Mac",
                appVersion: "test",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState()
        )

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertTrue(snapshot.workspaces.contains { $0.workspaceID == closedWorkspaceID.uuidString && !$0.isOpen })
        XCTAssertEqual(snapshot.sessions.count, 5)
        let liveSummary = snapshot.sessions.first { $0.sessionID == liveSessionID }
        XCTAssertEqual(liveSummary?.childSessionIDs, [childSessionID])
        XCTAssertEqual(liveSummary?.workflow, "Engineer")
        XCTAssertEqual(liveSummary?.workflowID, AgentWorkflow.orchestrate.definition.id)
        XCTAssertEqual(liveSummary?.runStartedAt, now.addingTimeInterval(-5))
        XCTAssertEqual(liveSummary?.transcriptRevision, 7)
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .waitingForInput })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .failed })
        XCTAssertTrue(snapshot.sessions.contains { $0.runState == .completed })
        XCTAssertTrue(snapshot.attentionItems.contains { $0.kind == .agentNeedsInput && $0.sessionID == waitingSessionID })
        XCTAssertTrue(snapshot.attentionItems.contains { $0.kind == .failed && $0.sessionID == failedSessionID })
    }

    private func fixtureSession(
        id: UUID,
        workspaceID: UUID,
        state: RemoteRunState,
        date: Date
    ) -> RemoteSessionRecord {
        RemoteSessionRecord(
            sessionID: id,
            workspaceID: workspaceID,
            composeTabID: UUID(),
            parentSessionID: nil,
            sessionName: state.rawValue,
            workflow: nil,
            agent: nil,
            model: nil,
            reasoningEffort: nil,
            runState: state,
            lifecycleStage: nil,
            latestMeaningfulActivity: nil,
            pendingInteraction: nil,
            worktreeSummary: nil,
            mergeAttention: nil,
            failureSummary: state == .failed ? "failed" : nil,
            lastUpdatedAt: date,
            isLive: false
        )
    }
}

@MainActor
private final class FixtureWorkspaceCatalog: WorkspaceCatalogService {
    let records: [RemoteWorkspaceRecord]

    init(records: [RemoteWorkspaceRecord]) {
        self.records = records
    }

    func allSavedWorkspaces() async -> [RemoteWorkspaceRecord] {
        records
    }
}

@MainActor
private final class FixtureSessionQuery: SessionQueryService {
    let records: [RemoteSessionRecord]

    init(records: [RemoteSessionRecord]) {
        self.records = records
    }

    func remoteSessions() async -> [RemoteSessionRecord] {
        records
    }
}
