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
        XCTAssertEqual(tree.map(\.logicalPath), ["notes.txt"])
        let hits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(hits.first?.line, 2)
        let file = try await authority.projectFile(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "notes.txt", startLine: 2, lineCount: 1))
        XCTAssertEqual(file.content, "beta needle")

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
