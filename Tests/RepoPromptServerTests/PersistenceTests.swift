import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class PersistenceTests: XCTestCase {
    func testEventsAreSignedBeforeDurablePublication() async throws {
        let key = ServiceEventSigningKey(keyID: "event-v1", secret: Data("event-secret".utf8))
        let store = try await SQLiteServiceStore.open(storage: .memory, eventSigningKey: key)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: cursor)
        let event = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let expected = CanonicalSigning.hmacSHA256(message: "\(event.storeID.uuidString)\n\(event.globalSequence)\n\(event.digest)", key: key.secret)
        XCTAssertEqual(event.keyID, key.keyID)
        XCTAssertEqual(event.signature, expected)
        let persisted = try await store.events(after: nil, limit: 1)
        XCTAssertEqual(persisted.events.first?.signature, expected)
        try await store.close()
    }

    func testAtomicProjectPublicationUsesMonotonicSequence() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let projectID = UUID()
        let firstCursor = try await store.nextCursor()
        let first = ProjectSnapshot(projectID: projectID, name: "One", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: firstCursor)
        let firstEvent = try await store.persistProject(first, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let secondCursor = try await store.nextCursor()
        let second = ProjectSnapshot(projectID: projectID, name: "Two", creator: actor, state: .active, roots: first.roots, revision: 2, cursor: secondCursor)
        let secondEvent = try await store.persistProject(second, eventType: .projectUpdated, actor: actor, correlationID: UUID(), idempotency: nil)
        XCTAssertEqual(firstEvent.globalSequence + 1, secondEvent.globalSequence)
        let page = try await store.events(after: nil, limit: 10)
        XCTAssertEqual(page.events.map(\.globalSequence), [1, 2])
        try await store.close()
    }

    func testRestoreChangesStoreNamespace() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let prior = try await store.metadata().storeID
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let priorCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: priorCursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)

        let fresh = try await store.markRestored(from: prior, backupSequence: 1, digest: "digest")
        XCTAssertNotEqual(prior, fresh)
        let restored = try await store.metadata()
        XCTAssertEqual(restored.storeID, fresh)
        XCTAssertEqual(restored.replayFloor, 1)
        let restoredEvents = try await store.events(after: nil, limit: 10)
        let restoredProject = try await store.project(id: project.projectID)
        XCTAssertTrue(restoredEvents.events.isEmpty)
        XCTAssertEqual(restoredProject?.cursor.storeID, fresh)
        do {
            _ = try await store.events(after: priorCursor, limit: 10)
            XCTFail("expected prior namespace to expire")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .cursorExpired)
        }
        try await store.close()
    }

    func testUncleanRestartInterruptsNonterminalRunExactlyOnce() async throws {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: database.path + "-shm"))
        }
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let projectCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: projectCursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let sessionCursor = try await store.nextCursor()
        let sessionID = UUID()
        let session = SessionSnapshot(sessionID: sessionID, projectID: project.projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .running, runGeneration: 1, turnEpoch: 1, revision: 2, transcript: [], interactions: [], cursor: sessionCursor)
        _ = try await store.persistSession(session, eventType: .sessionResumed, actor: actor, correlationID: UUID(), idempotency: nil)
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        let authority = RepoPromptHeadlessAuthority(store: store)
        try await authority.recover()
        let recovered = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(recovered.state, .interrupted)
        let events = try await authority.events(after: nil, limit: 10)
        XCTAssertEqual(events.events.filter { $0.eventType == .serviceRecovery }.count, 1)
        try await store.close()
    }

    func testTerminalCheckpointAndImmutableEventArchiveAdvanceReplayFloor() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(goblinUserID: "u1", username: "alice", displayName: "Alice")
        let projectCursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: UUID(), logicalName: "root", canonicalPath: "/tmp", writable: true)], revision: 1, cursor: projectCursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let sessionID = UUID()
        let sessionCursor = try await store.nextCursor()
        let session = SessionSnapshot(sessionID: sessionID, projectID: project.projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .completed, runGeneration: 1, turnEpoch: 1, revision: 2, transcript: [], interactions: [], cursor: sessionCursor)
        _ = try await store.persistSession(session, eventType: .sessionCompleted, actor: nil, correlationID: UUID(), idempotency: nil)
        let checkpoints = try await store.snapshotCheckpoints(scope: "session:\(sessionID.uuidString)")
        XCTAssertEqual(checkpoints.map(\.sequence), [2])

        let archivedID = try await store.archiveEvents(through: 1)
        let archiveID = try XCTUnwrap(archivedID)
        let archive = try await store.archivedEvents(archiveID: archiveID)
        XCTAssertEqual(archive.map(\.eventType), [.projectCreated])
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.replayFloor, 1)
        do {
            _ = try await store.events(after: .init(storeID: projectCursor.storeID, globalSequence: 0), limit: 10)
            XCTFail("expected archived cursor to expire")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .cursorExpired)
        }
        try await store.close()
    }
}
