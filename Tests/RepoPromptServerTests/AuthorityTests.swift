import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class AuthorityTests: XCTestCase {
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
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .sessionCreated])
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
        XCTAssertEqual(events.events.map(\.eventType), [.projectCreated, .sessionCreated, .transcriptMessage])
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
}
