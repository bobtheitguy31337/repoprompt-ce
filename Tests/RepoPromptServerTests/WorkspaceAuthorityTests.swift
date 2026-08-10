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
        await runner.setContextBuilderResponse("[{\"rootID\":\"\(rootID.uuidString)\",\"path\":\"important.txt\"}]")

        let selection = try await authority.runContextBuilder(sessionID: session.sessionID, input: .init(expectedSelectionRevision: 1, instructions: "find important context", budget: 100), actor: actor)
        XCTAssertEqual(selection.entries.map(\.logicalPath), ["important.txt"])
        let context = try await authority.buildContext(sessionID: session.sessionID, expectedSelectionRevision: selection.revision, include: ["files"], actor: actor)
        let contextData = try await authority.artifactContent(artifactID: context.artifactID, maximumBytes: 1_048_576)
        XCTAssertTrue(String(decoding: contextData, as: UTF8.self).contains("important context"))

        let oracle = try await authority.askOracle(sessionID: session.sessionID, input: .init(chatID: nil, prompt: "explain", contextMode: "selected"), actor: actor)
        XCTAssertEqual(oracle.response, "oracle response")
        XCTAssertNotNil(oracle.artifactID)
        XCTAssertEqual(oracle.revision, 1)
        let continuedOracle = try await authority.askOracle(sessionID: session.sessionID, input: .init(chatID: oracle.chatID, prompt: "continue", contextMode: "selected"), actor: actor)
        XCTAssertEqual(continuedOracle.chatID, oracle.chatID)
        XCTAssertEqual(continuedOracle.revision, 2)
        let oraclePrompts = await runner.oraclePrompts()
        XCTAssertTrue(oraclePrompts.last?.contains("Human: explain") == true)
        let enabledProviders = await authority.providerCapabilities().filter(\.enabled).map(\.kind)
        XCTAssertEqual(enabledProviders, [.codex])
        try await store.close()
    }
}

private actor RecordingWorkspaceRunner: WorkspaceCommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let workingDirectory: String
    }

    private var recorded: [Call] = []

    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes _: Int) async throws -> String {
        recorded.append(Call(executable: executable, arguments: arguments, workingDirectory: workingDirectory))
        return ""
    }

    func calls() -> [Call] { recorded }
}

private actor WorkflowWorkspaceRunner: WorkspaceCommandRunning {
    private var contextBuilderResponse = "[]"
    private var recordedOraclePrompts: [String] = []

    func setContextBuilderResponse(_ value: String) { contextBuilderResponse = value }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        let prompt = arguments.last ?? ""
        if prompt.contains("Context Builder") { return contextBuilderResponse }
        if prompt.contains("RepoPrompt Oracle") {
            recordedOraclePrompts.append(prompt)
            return "oracle response"
        }
        return "provider 1.0"
    }

    func oraclePrompts() -> [String] { recordedOraclePrompts }
}
