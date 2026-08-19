import RepoPromptAuthorityAPI
@testable import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import XCTest

final class RepoPromptHeadlessRuntimeTests: XCTestCase {
    func testEndToEndOwnerResourceValidation() async throws {
        let runtime = RepoPromptHeadlessRuntime()
        let owner = RuntimeOwnerID(rawValue: "owner")
        try await runtime.registerOwner(owner)
        let reference = try await runtime.attach(RuntimeResourceID(rawValue: "repository"), to: owner)
        let workflow = try WorkflowDefinition(resources: [reference])
        try await runtime.validate(workflow, for: owner)

        await runtime.removeOwner(owner)
        do {
            try await runtime.validate(workflow, for: owner)
            XCTFail("Expected removed owner to be unavailable")
        } catch let error as AuthorityError {
            XCTAssertEqual(error, .ownerUnavailable(owner))
        }
    }

    func testAuthorityUpdatesProjectionOnlyAfterStoreCommit() async throws {
        let store = FailingAuthorityStore()
        let authority = try await RepoPromptHeadlessAuthority(store: store)

        do {
            _ = try await authority.apply(
                .setLifecycle(entityID: "session", state: .running),
                operationID: UUID()
            )
            XCTFail("Expected store failure")
        } catch {}

        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertTrue(snapshot.entities.isEmpty)
    }
}

private struct FailingAuthorityStore: RepoPromptAuthorityStore {
    enum Failure: Error { case expected }

    func loadAuthoritySnapshot() async throws -> AuthoritySnapshot {
        AuthoritySnapshot()
    }

    func commit(
        _: AuthorityTransitionCommand,
        expectedRevision _: Int64,
        operationID _: UUID
    ) async throws -> AuthorityTransitionReceipt {
        throw Failure.expected
    }
}
