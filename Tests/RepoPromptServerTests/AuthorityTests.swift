import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class AuthorityTests: XCTestCase {
    func testCollaborationRevisionsAndExecutionPermissionsAreOperational() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: DelayedProviderRunner())
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let owner = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let controller = ExternalActor(goblinUserID: "u2", username: "bob", displayName: "Bob")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: owner, idempotencyKey: "policy-project", requestDigest: "policy-project")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "hello"), externalActor: owner, idempotencyKey: "policy-session", requestDigest: "policy-session")

        let initialPermission = try await authority.permissionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(initialPermission?.mode, "workspaceWrite")
        let initial = try await authority.collaborationMetadata(sessionID: session.sessionID)
        XCTAssertEqual(initial.controllerUserID, owner.goblinUserID)
        XCTAssertEqual(initial.policyRevision, 1)

        let transferred = try await authority.updateCollaborationMetadata(
            sessionID: session.sessionID,
            input: .init(expectedPolicyRevision: 1, expectedControllerRevision: 1, expectedMembershipRevision: 1, visibility: .collaborative, collaborativeSteeringEnabled: true, controllerUserID: controller.goblinUserID),
            actor: owner,
            idempotencyKey: "policy-transfer",
            requestDigest: "policy-transfer"
        )
        XCTAssertEqual(transferred.policyRevision, 2)
        XCTAssertEqual(transferred.controllerRevision, 2)
        XCTAssertEqual(transferred.membershipRevision, 2)

        _ = try await authority.execute(command: .sendFollowup(text: "collaborator", expectedSessionRevision: 2), sessionID: session.sessionID, externalActor: owner, idempotencyKey: "collaborator-followup", requestDigest: "collaborator-followup")
        _ = try await authority.updatePermissions(sessionID: session.sessionID, expectedRevision: 1, mode: "disabled", providerSettings: [:], actor: controller, idempotencyKey: "disable-provider", requestDigest: "disable-provider")
        do {
            _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: "fresh"), sessionID: session.sessionID, externalActor: controller, idempotencyKey: "disabled-run", requestDigest: "disabled-run")
            XCTFail("expected execution policy rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
        try await store.close()
    }

    func testProviderRunSupportsSteeringCompletionAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = DelayedProviderRunner()
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-run", requestDigest: "p-run")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "first"), externalActor: actor, idempotencyKey: "s-run", requestDigest: "s-run")

        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: "fresh"), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "resume", requestDigest: "resume")
        _ = try await authority.execute(command: .steerSession(text: "second", targetTurnEpoch: 1), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "steer", requestDigest: "steer")
        try await Task.sleep(for: .milliseconds(150))
        let completed = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.transcript.suffix(2).map(\.content), ["second", "provider:second"])

        let cancelSession = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "cancel"), externalActor: actor, idempotencyKey: "s-cancel", requestDigest: "s-cancel")
        await runner.setDelay(.seconds(10))
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: "fresh"), sessionID: cancelSession.sessionID, externalActor: actor, idempotencyKey: "resume-cancel", requestDigest: "resume-cancel")
        _ = try await authority.execute(command: .cancelSession(expectedRunID: nil, expectedGeneration: 1), sessionID: cancelSession.sessionID, externalActor: actor, idempotencyKey: "cancel", requestDigest: "cancel")
        let canceled = try await authority.sessionSnapshot(sessionID: cancelSession.sessionID)
        XCTAssertEqual(canceled.state, .canceled)
        try await store.close()
    }

    func testProjectRoutingAndSessionPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .collaborative, initialPrompt: "hello"), externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")
        XCTAssertEqual(session.projectID, project.projectID)
        XCTAssertEqual(session.transcript.first?.content, "hello")
        let restored = try await authority.sessionSnapshot(sessionID: session.sessionID)
        let events = try await authority.events(after: nil, limit: 10)
        XCTAssertEqual(restored.rootSessionID, session.sessionID)
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .sessionCreated, .agentStarted])
        try await store.close()
    }

    func testProjectUpdateAndRemovalUseExpectedRevisionAndArchiveAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "Old", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-mutate", requestDigest: "p-mutate")
        let updated = try await authority.updateProject(projectID: project.projectID, input: .init(expectedRevision: project.revision, name: "New", roots: [.init(logicalName: "renamed", path: root.path, writable: false)]), actor: actor, idempotencyKey: "p-update", requestDigest: "p-update")
        XCTAssertEqual(updated.name, "New")
        XCTAssertEqual(updated.roots.first?.rootID, project.roots.first?.rootID)
        XCTAssertEqual(updated.roots.first?.writable, false)

        try await authority.removeProject(projectID: project.projectID, expectedRevision: updated.revision, actor: actor, idempotencyKey: "p-remove", requestDigest: "p-remove")
        let activeProjects = await authority.projectSnapshots()
        let archived = try await store.project(id: project.projectID)
        let events = try await store.events(after: nil, limit: 10)
        XCTAssertTrue(activeProjects.isEmpty)
        XCTAssertEqual(archived?.state, .archived)
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .projectUpdated, .projectRemoved])
        try await store.close()
    }

    func testIdempotencyReturnsOriginalSnapshotsAndCommandReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let projectInput = CreateProjectInput(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)])
        let project = try await authority.createProject(input: projectInput, externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        let repeatedProject = try await authority.createProject(input: projectInput, externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        XCTAssertEqual(project, repeatedProject)

        let sessionInput = CreateSessionInput(projectID: project.projectID, provider: .codex, visibility: .collaborative)
        let session = try await authority.createSession(input: sessionInput, externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")
        let repeatedSession = try await authority.createSession(input: sessionInput, externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")
        XCTAssertEqual(session, repeatedSession)

        let command = SessionCommand.sendFollowup(text: "next", expectedSessionRevision: session.revision)
        let receipt = try await authority.execute(command: command, sessionID: session.sessionID, externalActor: actor, idempotencyKey: "command-key", requestDigest: "command-digest")
        let repeatedReceipt = try await authority.execute(command: command, sessionID: session.sessionID, externalActor: actor, idempotencyKey: "command-key", requestDigest: "command-digest")
        XCTAssertEqual(receipt, repeatedReceipt)

        let events = try await authority.events(after: nil, limit: 10)
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .sessionCreated, .agentStarted, .transcriptMessage])
        try await store.close()
    }

    func testRootCancellationClosesDescendantsAndFencesNewChildren() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = DelayedProviderRunner()
        await runner.setDelay(.seconds(10))
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-tree-cancel", requestDigest: "p-tree-cancel")
        let rootSession = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "root"), externalActor: actor, idempotencyKey: "s-tree-cancel", requestDigest: "s-tree-cancel")
        let child = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "child", role: "explore", label: "probe")

        let hierarchy = try await authority.agentSnapshots(rootSessionID: rootSession.sessionID)
        XCTAssertEqual(hierarchy.count, 2)
        XCTAssertEqual(hierarchy.first(where: { $0.sessionID == child.sessionID })?.parentAgentID, rootSession.sessionID)
        XCTAssertEqual(hierarchy.first(where: { $0.sessionID == child.sessionID })?.role, "explore")
        XCTAssertEqual(hierarchy.first(where: { $0.sessionID == child.sessionID })?.label, "probe")

        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: "fresh"), sessionID: rootSession.sessionID, externalActor: actor, idempotencyKey: "resume-tree", requestDigest: "resume-tree")
        _ = try await authority.execute(command: .cancelSession(expectedRunID: nil, expectedGeneration: 1), sessionID: rootSession.sessionID, externalActor: actor, idempotencyKey: "cancel-tree", requestDigest: "cancel-tree")
        let canceledChild = try await authority.sessionSnapshot(sessionID: child.sessionID)
        let canceledRoot = try await authority.sessionSnapshot(sessionID: rootSession.sessionID)
        let canceledAgents = try await authority.agentSnapshots(rootSessionID: rootSession.sessionID)
        XCTAssertEqual(canceledChild.state, .canceled)
        XCTAssertEqual(canceledRoot.state, .canceled)
        XCTAssertEqual(canceledAgents.first(where: { $0.sessionID == child.sessionID })?.state, .canceled)

        do {
            _ = try await authority.spawnChildSession(parentSessionID: rootSession.sessionID, initialPrompt: "late")
            XCTFail("expected root cancellation barrier")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .quiescing)
        }
        try await store.close()
    }

    func testQuiesceInterruptsActiveProviderTreeBeforeCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = DelayedProviderRunner()
        await runner.setDelay(.seconds(10))
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-drain", requestDigest: "p-drain")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "run"), externalActor: actor, idempotencyKey: "s-drain", requestDigest: "s-drain")
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: "fresh"), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "resume-drain", requestDigest: "resume-drain")

        try await authority.quiesce()

        let ready = await authority.isReady()
        let interrupted = try await authority.sessionSnapshot(sessionID: session.sessionID)
        let interruptedAgent = try await authority.agentSnapshots(rootSessionID: session.sessionID).first
        XCTAssertFalse(ready)
        XCTAssertEqual(interrupted.state, .interrupted)
        XCTAssertEqual(interruptedAgent?.state, .interrupted)
        try await store.close()
    }

    func testIdempotencyKeyDigestConflictFailsClosed() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: cursor)
        let key = IdempotencyInput(actorID: actor.goblinUserID, operation: "createProject", key: "same-key", requestDigest: "digest-a")
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: key)

        do {
            _ = try await store.idempotencyResult(.init(actorID: actor.goblinUserID, operation: "createProject", key: "same-key", requestDigest: "digest-b"))
            XCTFail("expected conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyConflict)
        }
        try await store.close()
    }

    func testSubscriptionHandsOffFromDurableReplayToLiveEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "project-key", requestDigest: "project-digest")
        let stream = try await authority.subscribe(after: nil)
        _ = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "session-key", requestDigest: "session-digest")

        var iterator = stream.makeAsyncIterator()
        let replayed = try await iterator.next()
        let live = try await iterator.next()
        XCTAssertEqual(replayed?.eventType, .projectCreated)
        XCTAssertEqual(live?.eventType, .sessionCreated)
        XCTAssertEqual(live?.globalSequence, replayed.map { $0.globalSequence + 1 })
        try await store.close()
    }

    func testUnknownProjectFailsClosed() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        do { _ = try await authority.projectSnapshot(projectID: UUID())
            XCTFail("expected not found")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .notFound) }
        try await store.close()
    }

    func testVisibilityArchiveAndExactWorktreeRebindMutateDurableAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-transitions", requestDigest: "p-transitions")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-transitions", requestDigest: "s-transitions")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let binding = WorktreeBindingSnapshot(bindingID: UUID(), projectID: project.projectID, rootID: rootID, sessionID: nil, baseRef: "main", branch: "existing", physicalPath: root.path, ownershipState: .active, mergeState: .clean, revision: 1)
        _ = try await store.persistWorktree(binding, actor: actor, correlationID: UUID())

        let rebound = try await authority.bindWorktree(sessionID: session.sessionID, bindingID: binding.bindingID, expectedRevision: 1, expectedSelectionBindingRevision: 1, actor: actor, idempotencyKey: "bind", requestDigest: "bind")
        XCTAssertEqual(rebound.sessionID, session.sessionID)
        XCTAssertEqual(rebound.revision, 2)
        let reboundSelection = try await authority.selectionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(reboundSelection.bindingRevision, 2)

        _ = try await authority.execute(command: .setSessionVisibility(expectedPolicyRevision: 1, visibility: .collaborative, collaborativeSteeringEnabled: false, controllerUserID: actor.goblinUserID), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "visibility", requestDigest: "visibility")
        let visible = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(visible.visibility, .collaborative)
        _ = try await authority.execute(command: .archiveSession(expectedRevision: visible.revision), sessionID: session.sessionID, externalActor: actor, idempotencyKey: "archive", requestDigest: "archive")
        let archived = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(archived.state, .archived)
        try await store.close()
    }

    func testInteractionResolutionRequiresExactProviderAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let delivery = RecordingInteractionDelivery()
        let authority = RepoPromptHeadlessAuthority(store: store, interactionDelivery: delivery)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-interaction", requestDigest: "p-interaction")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-interaction", requestDigest: "s-interaction")
        let requested = try await authority.requestInteraction(sessionID: session.sessionID, kind: .approval, payload: Data("approve?".utf8))
        let resolved = try await authority.answerInteraction(sessionID: session.sessionID, interactionID: requested.interactionID, expectedRevision: requested.revision, payload: Data("approveOnce".utf8), actor: actor, idempotencyKey: "answer", requestDigest: "answer")
        XCTAssertEqual(resolved.state, .resolved)
        XCTAssertEqual(resolved.revision, 3)
        let deliveryCount = await delivery.deliveryCount()
        let stored = try await authority.interactionSnapshots(sessionID: session.sessionID)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertEqual(stored.first?.state, .resolved)
        try await store.close()
    }
}

private actor DelayedProviderRunner: WorkspaceCommandRunning {
    private var delay: Duration = .milliseconds(50)

    func setDelay(_ value: Duration) {
        delay = value
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        try await Task.sleep(for: delay)
        return "provider:\(arguments.last ?? "")"
    }
}

private actor RecordingInteractionDelivery: InteractionDeliveryPort {
    private var count = 0

    func deliverAnswer(session _: SessionSnapshot, interaction _: InteractionSnapshot, answer _: Data) async throws {
        count += 1
    }

    func deliveryCount() -> Int {
        count
    }
}
