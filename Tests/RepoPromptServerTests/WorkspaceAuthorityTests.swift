import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

private struct InjectedFilesystemFault: Error {}

final class WorkspaceAuthorityTests: XCTestCase {
    func testDurableFilesystemFaultBoundariesProduceOnlyOldOrCompleteState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("complete durable payload".utf8)
        let preRename: [DurableFilesystemFaultPoint] = [.temporaryCreated, .contentsWritten, .temporarySynchronized]
        let postRename: [DurableFilesystemFaultPoint] = [.destinationRenamed, .directorySynchronized]

        for point in preRename + postRename {
            let temporary = root.appendingPathComponent("\(point.rawValue).tmp")
            let destination = root.appendingPathComponent("\(point.rawValue).json")
            let injector = DurableFilesystemFaultInjector { observed in
                if observed == point { throw InjectedFilesystemFault() }
            }
            XCTAssertThrowsError(try DurableFilesystem.publish(data: payload, temporary: temporary, destination: destination, faultInjector: injector))
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            if preRename.contains(point) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), point.rawValue)
            } else {
                XCTAssertEqual(try Data(contentsOf: destination), payload, point.rawValue)
            }
        }
    }

    func testProjectToolsAndSelectionAreAuthorizedAndDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha\nbeta needle\ngamma".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "struct Greeter {\n    func hello(name: String) -> String { name }\n}\n".write(to: root.appendingPathComponent("Greeter.swift"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }

        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(store: store)
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p", requestDigest: "p")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s", requestDigest: "s")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        XCTAssertEqual(project.roots.first?.canonicalPath, root.path)

        let tree = try await authority.projectTree(projectID: project.projectID, request: .init(rootID: rootID))
        XCTAssertEqual(tree.map(\.logicalPath), ["Greeter.swift", "notes.txt"])
        let hits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(hits.first?.line, 2)
        let file = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "notes.txt", startLine: 2, lineCount: 1))
        XCTAssertEqual(file.content, "beta needle")
        let codeMap = try await authority.projectCodeMap(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "Greeter.swift"))
        XCTAssertEqual(codeMap.status, "ready")
        XCTAssertEqual(codeMap.language, "swift")
        XCTAssertTrue(codeMap.content.contains("Greeter"))
        XCTAssertTrue(codeMap.content.contains("hello"))

        let entry = LogicalSelectionEntry(rootID: rootID, logicalPath: "notes.txt", mode: .full)
        let selected = try await authority.replaceSelection(sessionID: session.sessionID, entries: [entry], expectedRevision: 1, actor: actor)
        XCTAssertEqual(selected.revision, 2)
        do {
            _ = try await authority.replaceSelection(sessionID: session.sessionID, entries: [], expectedRevision: 1, actor: actor)
            XCTFail("expected stale selection revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        try await store.close()

        let reopened = try await SQLiteServiceStore.open(storage: .file(database.path))
        let recovered = RepoPromptHeadlessAuthority(store: reopened)
        try await recovered.recover()
        let recoveredSelection = try await recovered.selectionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(recoveredSelection, selected)
        try await reopened.close()
    }

    func testSymlinkEscapeIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p", requestDigest: "p")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        do {
            _ = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "escape/secret.txt"))
            XCTFail("expected root escape rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        try await store.close()
    }

    func testAuthorizedRootIdentityReplacementIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-root-identity", requestDigest: "p-root-identity")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        try "later".write(to: root.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        _ = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "later.txt"))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "replacement".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "value.txt"))
            XCTFail("expected root identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        try await store.close()
    }

    func testAuthorizedRootIdentityPersistsAcrossAuthorityRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let initialStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let initialAuthority = RepoPromptHeadlessAuthority(store: initialStore)
        let project = try await initialAuthority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "persisted-root", requestDigest: "persisted-root")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        try await initialStore.close()

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "replacement".write(to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)

        let recoveredStore = try await SQLiteServiceStore.open(storage: .file(database.path))
        let recoveredAuthority = RepoPromptHeadlessAuthority(store: recoveredStore)
        try await recoveredAuthority.recover()
        do {
            _ = try await recoveredAuthority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "value.txt"))
            XCTFail("expected persisted root identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        try await recoveredStore.close()
    }

    func testWorktreeServiceUsesValidatedGitArguments() async throws {
        let runner = RecordingWorkspaceRunner()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = try WorktreeRuntimeService(baseDirectory: base.path, runner: runner)
        let root = ProjectRootSnapshot(rootID: UUID(), logicalName: "source", canonicalPath: "/repo", writable: true)
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: .init(goblinUserID: "u", username: "u", displayName: "U"), state: .active, roots: [root], revision: 1, cursor: .init(storeID: UUID(), globalSequence: 1))
        let binding = try await service.create(project: project, root: root, sessionID: UUID(), baseRef: "main", branch: "rp/session")
        XCTAssertEqual(binding.ownershipState, .active)
        let calls = await runner.calls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.arguments.prefix(5), ["-C", "/repo", "worktree", "add", "-b"])
        do {
            _ = try await service.create(project: project, root: root, sessionID: UUID(), baseRef: "--help", branch: "bad")
            XCTFail("expected invalid ref")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
    }

    func testProjectTemplateSeedsRootSessionAndChildInheritsFrozenSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "template".write(to: root.appendingPathComponent("template.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = RepoPromptHeadlessAuthority(store: store)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-template", requestDigest: "p-template")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let entry = LogicalSelectionEntry(rootID: rootID, logicalPath: "template.txt", mode: .full)
        let template = try await authority.replaceProjectSelectionTemplate(projectID: project.projectID, entries: [entry], expectedRevision: 1, actor: actor, idempotencyKey: "template", requestDigest: "template")
        XCTAssertEqual(template.revision, 2)

        let parent = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "parent", requestDigest: "parent")
        let parentSelection = try await authority.selectionSnapshot(sessionID: parent.sessionID)
        XCTAssertEqual(parentSelection.entries, [entry])
        let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, initialPrompt: "child")
        let childSelection = try await authority.selectionSnapshot(sessionID: child.sessionID)
        XCTAssertEqual(childSelection.entries, [entry])
        XCTAssertEqual(child.rootSessionID, parent.sessionID)
        do {
            _ = try await authority.createSession(input: .init(projectID: project.projectID, parentSessionID: parent.sessionID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "external-child", requestDigest: "external-child")
            XCTFail("expected public child-session rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .authorizationDecisionRejected)
        }
        try await store.close()
    }

    func testContextBuilderOracleAndContextArtifactsUseConfiguredProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "important context".write(to: root.appendingPathComponent("important.txt"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = WorkflowWorkspaceRunner()
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let artifactService = try ArtifactRuntimeService(baseDirectory: artifacts.path)
        let authority = RepoPromptHeadlessAuthority(store: store, artifactService: artifactService, providerAdapter: provider)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p", requestDigest: "p")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s", requestDigest: "s")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        await runner.setContextBuilderResponse("{\"tool\":\"manage_selection\",\"args\":{\"op\":\"set\",\"entries\":[{\"rootID\":\"\(rootID.uuidString)\",\"path\":\"important.txt\"}]}}")

        let selection = try await authority.runContextBuilder(sessionID: session.sessionID, input: .init(expectedSelectionRevision: 1, instructions: "find important context", budget: 100), actor: actor)
        XCTAssertEqual(selection.entries.map(\.logicalPath), ["important.txt"])
        XCTAssertEqual(selection.response, "builder plan")
        XCTAssertNotNil(selection.chatID)
        let builderContext = try await authority.sessionContext(sessionID: session.sessionID)
        XCTAssertEqual(builderContext.prompt, "Use the selected important context.")
        let context = try await authority.buildContext(sessionID: session.sessionID, expectedSelectionRevision: selection.revision, include: ["files"], actor: actor)
        let contextData = try await authority.artifactContent(artifactID: context.artifactID, maximumBytes: 1_048_576)
        XCTAssertTrue(String(decoding: contextData, as: UTF8.self).contains("important context"))

        let oracle = try await authority.askOracle(sessionID: session.sessionID, input: .init(chatID: selection.chatID, prompt: "explain", contextMode: "selected"), actor: actor)
        XCTAssertEqual(oracle.response, "oracle response")
        XCTAssertNotNil(oracle.artifactID)
        XCTAssertEqual(oracle.revision, 2)
        let continuedOracle = try await authority.askOracle(sessionID: session.sessionID, input: .init(chatID: oracle.chatID, prompt: "continue", contextMode: "selected"), actor: actor)
        XCTAssertEqual(continuedOracle.chatID, oracle.chatID)
        XCTAssertEqual(continuedOracle.revision, 3)
        let oraclePrompts = await runner.oraclePrompts()
        XCTAssertTrue(oraclePrompts.last?.contains("<user>explain</user>") == true)
        let enabledProviders = await authority.providerCapabilities().filter(\.enabled).map(\.kind)
        XCTAssertEqual(enabledProviders, [.codex])
        try await store.close()
    }

    func testContextBuilderStaleCommitRetainsInspectableProposalArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "context".write(to: root.appendingPathComponent("Context.swift"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runtime = BlockingContextBuilderRuntime()
        let authority = try RepoPromptHeadlessAuthority(store: store, artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path), contextBuilderRuntime: runtime)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-cb-race", requestDigest: "p-cb-race")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-cb-race", requestDigest: "s-cb-race")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        await runtime.setProposal(.init(selection: [.init(rootID: rootID, logicalPath: "Context.swift", mode: .full)], response: "proposal", providerSessionID: "builder", rawProviderOutput: "fixture"))

        let builder = Task {
            try await authority.runContextBuilder(sessionID: session.sessionID, input: .init(expectedSelectionRevision: 1, instructions: "select", budget: 100), actor: actor)
        }
        for _ in 0 ..< 100 {
            if await runtime.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let didStart = await runtime.hasStarted()
        XCTAssertTrue(didStart)
        _ = try await authority.replaceSelection(sessionID: session.sessionID, entries: [], expectedRevision: 1, actor: actor)
        await runtime.release()
        do {
            _ = try await builder.value
            XCTFail("expected stale selection commit")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 2)
        }
        let retained = try await store.artifacts(sessionID: session.sessionID)
        XCTAssertEqual(retained.map(\.snapshot.kind), ["context-builder-proposal"])
        let data = try await authority.artifactContent(artifactID: XCTUnwrap(retained.first?.snapshot.artifactID), maximumBytes: 1_048_576)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Context.swift"))
        try await store.close()
    }

    func testContextBuilderClarifyingQuestionUsesDurableAuthorityInteraction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = QuestionWorkspaceRunner()
        let provider = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let authority = try RepoPromptHeadlessAuthority(store: store, artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path), providerAdapter: provider)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-question", requestDigest: "p-question")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-question", requestDigest: "s-question")

        let builder = Task {
            try await authority.runContextBuilder(
                sessionID: session.sessionID,
                input: .init(expectedSelectionRevision: 1, instructions: "clarify", budget: 100, allowClarifyingQuestions: true),
                actor: actor
            )
        }
        var pending: InteractionSnapshot?
        for _ in 0 ..< 100 {
            pending = try await authority.interactionSnapshots(sessionID: session.sessionID).first(where: { $0.state == .pending })
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let interaction = try XCTUnwrap(pending)
        XCTAssertEqual(interaction.kind, .question)
        _ = try await authority.answerInteraction(
            sessionID: session.sessionID,
            interactionID: interaction.interactionID,
            expectedRevision: interaction.revision,
            payload: Data(#"{"answer":"Use the service target"}"#.utf8),
            actor: actor
        )
        let result = try await builder.value
        XCTAssertEqual(result.revision, 2)
        let receivedAnswer = await runner.receivedAnswer
        XCTAssertTrue(receivedAnswer)
        try await store.close()
    }

    func testProjectExecutionWorkspaceRoutesEveryWritableRepositoryAcrossRestartAndResume() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceA = base.appendingPathComponent("source-a", isDirectory: true)
        let sourceB = base.appendingPathComponent("source-b", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        let database = base.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let command = LocalWorkspaceCommandRunner()
        for (root, content) in [(sourceA, "source checkout A"), (sourceB, "source checkout B")] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try content.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = try await command.run(executable: "/usr/bin/git", arguments: ["init", "-b", "main", root.path], workingDirectory: base.path, maximumBytes: 65536)
            _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", root.path, "add", "README.md"], workingDirectory: root.path, maximumBytes: 65536)
            _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"], workingDirectory: root.path, maximumBytes: 65536)
        }

        let provider = MultiRootWorkspaceProvider()
        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        var authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store),
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(
            input: .init(name: "P", roots: [
                .init(logicalName: "server", path: sourceA.path, writable: true),
                .init(logicalName: "ops", path: sourceB.path, writable: true)
            ]),
            externalActor: actor,
            idempotencyKey: "p-multi-wt",
            requestDigest: "p-multi-wt"
        )
        XCTAssertEqual(project.roots.count, 2)
        _ = try await authority.replaceProjectSelectionTemplate(
            projectID: project.projectID,
            entries: project.roots.map { .init(rootID: $0.rootID, logicalPath: "README.md", mode: .full) },
            expectedRevision: 1,
            actor: actor,
            idempotencyKey: "template-multi-wt",
            requestDigest: "template-multi-wt"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession, initialPrompt: "modify both roots", startImmediately: true),
            externalActor: actor,
            idempotencyKey: "s-multi-wt",
            requestDigest: "s-multi-wt"
        )
        await authority.waitForProviderRunsToSettle()

        let bindings = try await authority.worktreeSnapshots(projectID: project.projectID).filter { $0.sessionID == session.sessionID && $0.ownershipState == .active }
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(Set(bindings.map(\.rootID)), Set(project.roots.map(\.rootID)))
        XCTAssertEqual(Set(bindings.map(\.physicalPath)).count, 2)
        XCTAssertTrue(bindings.allSatisfy { $0.physicalPath.hasPrefix(worktrees.path) })
        let initialRequests = await provider.requests()
        let firstRequest = try XCTUnwrap(initialRequests.first)
        XCTAssertTrue(firstRequest.workingDirectory.contains("/.execution-workspaces/"))
        XCTAssertNotEqual(firstRequest.workingDirectory, bindings[0].physicalPath)
        XCTAssertNotEqual(firstRequest.workingDirectory, bindings[1].physicalPath)
        let expectedWritableRoots = try project.roots.map { root in
            try XCTUnwrap(bindings.first(where: { $0.rootID == root.rootID })?.physicalPath)
        }
        XCTAssertEqual(firstRequest.writableRoots, expectedWritableRoots)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstRequest.workingDirectory).appendingPathComponent("workspace.json").path))
        let initialWorkspaceIdentity = try FileManager.default.attributesOfItem(atPath: firstRequest.workingDirectory)[.systemFileNumber] as? NSNumber
        for root in project.roots {
            let binding = try XCTUnwrap(bindings.first(where: { $0.rootID == root.rootID }))
            let route = URL(fileURLWithPath: firstRequest.workingDirectory).appendingPathComponent("roots/\(root.rootID.uuidString.lowercased())")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: route.path), binding.physicalPath)
            let isolated = try String(contentsOf: URL(fileURLWithPath: binding.physicalPath).appendingPathComponent("README.md"), encoding: .utf8)
            XCTAssertTrue(isolated.contains(root.rootID.uuidString.lowercased()))
        }
        XCTAssertEqual(try String(contentsOf: sourceA.appendingPathComponent("README.md"), encoding: .utf8), "source checkout A")
        XCTAssertEqual(try String(contentsOf: sourceB.appendingPathComponent("README.md"), encoding: .utf8), "source checkout B")

        let rootArtifact = try await authority.buildContext(sessionID: session.sessionID, expectedSelectionRevision: 1, include: ["files"], actor: actor)
        let child = try await authority.spawnChildSession(parentSessionID: session.sessionID, initialPrompt: "inspect both")
        let childArtifact = try await authority.buildContext(sessionID: child.sessionID, expectedSelectionRevision: 1, include: ["files"], actor: actor)
        let rootContent = String(decoding: try await authority.artifactContent(artifactID: rootArtifact.artifactID, maximumBytes: 4096), as: UTF8.self)
        let childContent = String(decoding: try await authority.artifactContent(artifactID: childArtifact.artifactID, maximumBytes: 4096), as: UTF8.self)
        for root in project.roots {
            XCTAssertTrue(rootContent.contains(root.rootID.uuidString.lowercased()))
            XCTAssertTrue(childContent.contains(root.rootID.uuidString.lowercased()))
        }
        let childAuthoritySnapshot = try await authority.authoritySessionSnapshot(sessionID: child.sessionID)
        XCTAssertEqual(childAuthoritySnapshot.worktrees.count, 2)
        let reusedWorkspaceIdentity = try FileManager.default.attributesOfItem(atPath: firstRequest.workingDirectory)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(reusedWorkspaceIdentity, initialWorkspaceIdentity)

        try await store.close()
        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store),
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store),
            providerAdapter: provider
        )
        try await authority.recover()
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: actor,
            idempotencyKey: "resume-multi-wt",
            requestDigest: "resume-multi-wt"
        )
        await authority.waitForProviderRunsToSettle()
        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].workingDirectory, requests[0].workingDirectory)
        XCTAssertEqual(requests[1].writableRoots, expectedWritableRoots)
        let recoveredBindings = try await authority.authoritySessionSnapshot(sessionID: session.sessionID).worktrees
        XCTAssertEqual(Set(recoveredBindings.map(\.bindingID)), Set(bindings.map(\.bindingID)))
        let resources = try await store.ownedResources(states: [.active])
        XCTAssertEqual(resources.filter { $0.kind == .worktree && bindings.map(\.bindingID).contains($0.externalID) }.count, 2)
        try await store.close()
    }
}

private actor MultiRootWorkspaceProvider: AgentProviderDispatcher {
    struct CapturedRequest: Sendable {
        let workingDirectory: String
        let writableRoots: [String]
    }

    private var captured: [CapturedRequest] = []

    func capabilities() -> [ProviderCapability] {
        [.init(kind: .codex, enabled: true, executable: "/usr/bin/true", supportsResume: false, supportsSteering: false)]
    }

    func preflight() -> [ProviderCapability] { capabilities() }
    func recoverProcessFamilies() throws {}
    func cancel(runID _: UUID) throws {}

    func execute(
        kind _: ProviderKind,
        model _: String?,
        prompt _: String,
        workingDirectory _: String,
        maximumBytes _: Int,
        runID _: UUID?,
        resumeProviderSessionID _: String?,
        onProviderSessionIdentity _: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        ProviderExecutionResult(output: "unused", providerSessionID: nil)
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        captured.append(.init(workingDirectory: request.workingDirectory, writableRoots: request.policy.writableRoots))
        let routes = URL(fileURLWithPath: request.workingDirectory).appendingPathComponent("roots", isDirectory: true)
        let roots = try FileManager.default.contentsOfDirectory(at: routes, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard roots.count == 2 else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Provider did not receive the complete project workspace")
        }
        for root in roots {
            try "isolated \(root.lastPathComponent)".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
        await onEvent(.completed(providerSessionID: nil))
        return ProviderExecutionResult(output: "modified both roots", providerSessionID: nil)
    }

    func requests() -> [CapturedRequest] { captured }
}

private actor RecordingWorkspaceRunner: WorkspaceCommandRunning {
    struct Call {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
    }

    private var recorded: [Call] = []

    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes _: Int) async throws -> String {
        recorded.append(Call(executable: executable, arguments: arguments, workingDirectory: workingDirectory))
        if arguments.suffix(2) == ["rev-parse", "--show-toplevel"], arguments.count >= 2 {
            return arguments[1]
        }
        return ""
    }

    func calls() -> [Call] {
        recorded
    }
}

private actor WorkflowWorkspaceRunner: WorkspaceCommandRunning {
    private var contextBuilderResponse = "[]"
    private var contextBuilderTurn = 0
    private var recordedOraclePrompts: [String] = []

    func setContextBuilderResponse(_ value: String) {
        contextBuilderResponse = value
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        let prompt = arguments.last ?? ""
        if prompt.contains("Context Builder") {
            contextBuilderTurn = 1
            return contextBuilderResponse
        }
        if prompt.contains("<tool_result>") {
            contextBuilderTurn += 1
            if contextBuilderTurn == 2 {
                return "{\"tool\":\"prompt\",\"args\":{\"op\":\"set\",\"text\":\"Use the selected important context.\"}}"
            }
            return "{\"tool\":\"finish\",\"args\":{\"response\":\"builder plan\"}}"
        }
        if prompt.contains("RepoPrompt Oracle") {
            recordedOraclePrompts.append(prompt)
            return "oracle response"
        }
        return "provider 1.0"
    }

    func oraclePrompts() -> [String] {
        recordedOraclePrompts
    }
}

private actor QuestionWorkspaceRunner: WorkspaceCommandRunning {
    private(set) var receivedAnswer = false

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        let prompt = arguments.last ?? ""
        if prompt.contains("Context Builder") {
            return #"{"tool":"ask_user","args":{"question":"Which target?","choices":["service","app"]}}"#
        }
        if prompt.contains("Use the service target") {
            receivedAnswer = true
            return #"{"tool":"finish","args":{}}"#
        }
        throw ServiceAPIError(code: .dependencyUnavailable, message: "unexpected Context Builder prompt")
    }
}

private actor BlockingContextBuilderRuntime: ContextBuilderRuntimeService {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var proposal = ContextBuilderRuntimeProposal(selection: [], response: nil, providerSessionID: nil, rawProviderOutput: "")

    func setProposal(_ proposal: ContextBuilderRuntimeProposal) {
        self.proposal = proposal
    }

    func propose(_: ContextBuilderRuntimeRequest) async -> ContextBuilderRuntimeProposal {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return proposal
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
