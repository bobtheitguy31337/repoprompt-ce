import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class WorkspaceAuthorityTests: XCTestCase {
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
        let child = try await authority.createSession(input: .init(projectID: project.projectID, parentSessionID: parent.sessionID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "child", requestDigest: "child")
        let childSelection = try await authority.selectionSnapshot(sessionID: child.sessionID)
        XCTAssertEqual(childSelection.entries, [entry])
        XCTAssertEqual(child.rootSessionID, parent.sessionID)
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

    func testDefaultWorktreeRoutesRootAndChildContextByExactBinding() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("source", isDirectory: true)
        let worktrees = base.appendingPathComponent("worktrees", isDirectory: true)
        let artifacts = base.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "source checkout".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let command = LocalWorkspaceCommandRunner()
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["init", "-b", "main", root.path], workingDirectory: base.path, maximumBytes: 65536)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", root.path, "add", "README.md"], workingDirectory: root.path, maximumBytes: 65536)
        _ = try await command.run(executable: "/usr/bin/git", arguments: ["-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"], workingDirectory: root.path, maximumBytes: 65536)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            worktreeService: WorktreeRuntimeService(baseDirectory: worktrees.path, resources: store),
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path, resources: store)
        )
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let project = try await authority.createProject(input: .init(name: "P", roots: [.init(logicalName: "source", path: root.path, writable: true)]), externalActor: actor, idempotencyKey: "p-default-wt", requestDigest: "p-default-wt")
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        _ = try await authority.replaceProjectSelectionTemplate(projectID: project.projectID, entries: [.init(rootID: rootID, logicalPath: "README.md", mode: .full)], expectedRevision: 1, actor: actor, idempotencyKey: "template-default-wt", requestDigest: "template-default-wt")
        let session = try await authority.createSession(input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession), externalActor: actor, idempotencyKey: "s-default-wt", requestDigest: "s-default-wt")
        let bindings = try await authority.worktreeSnapshots(projectID: project.projectID)
        let binding = try XCTUnwrap(bindings.first(where: { $0.sessionID == session.sessionID }))
        XCTAssertTrue(binding.physicalPath.hasPrefix(worktrees.path))
        try "isolated worktree".write(to: URL(fileURLWithPath: binding.physicalPath).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let rootArtifact = try await authority.buildContext(sessionID: session.sessionID, expectedSelectionRevision: 1, include: ["files"], actor: actor)
        let child = try await authority.spawnChildSession(parentSessionID: session.sessionID, initialPrompt: "inspect")
        let childArtifact = try await authority.buildContext(sessionID: child.sessionID, expectedSelectionRevision: 1, include: ["files"], actor: actor)
        let rootContent = try await authority.artifactContent(artifactID: rootArtifact.artifactID, maximumBytes: 1024)
        let childContent = try await authority.artifactContent(artifactID: childArtifact.artifactID, maximumBytes: 1024)
        XCTAssertTrue(String(decoding: rootContent, as: UTF8.self).contains("isolated worktree"))
        XCTAssertTrue(String(decoding: childContent, as: UTF8.self).contains("isolated worktree"))
        let resources = try await store.ownedResources(states: [.active])
        XCTAssertTrue(resources.contains { $0.kind == .worktree && $0.externalID == binding.bindingID })
        XCTAssertTrue(resources.contains { $0.kind == .artifact && $0.externalID == rootArtifact.artifactID })
        try await store.close()
    }
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
