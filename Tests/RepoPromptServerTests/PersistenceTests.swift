import Foundation
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class PersistenceTests: XCTestCase {
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
}
