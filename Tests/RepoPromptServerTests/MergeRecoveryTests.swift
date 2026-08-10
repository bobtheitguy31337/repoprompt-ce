import Foundation
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class MergeRecoveryTests: XCTestCase {
    func testMergeConflictLeasePublishesArtifactAndSupportsVerifiedAbortRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let owned = directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let runner = ConflictingMergeRunner(preMergeHead: "abc123")
        let service = try WorktreeRuntimeService(baseDirectory: owned.path, runner: runner, resources: store)
        let binding = WorktreeBindingSnapshot(
            bindingID: UUID(),
            projectID: UUID(),
            rootID: UUID(),
            sessionID: UUID(),
            baseRef: "main",
            branch: "feature",
            physicalPath: owned.appendingPathComponent("binding").path,
            ownershipState: .active,
            mergeState: .clean,
            revision: 1
        )
        do {
            _ = try await service.merge(binding, targetPath: target.path, strategy: "merge")
            XCTFail("expected merge conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .worktreeConflict)
        }
        let leases = try await store.worktreeMergeLeases(nonterminalOnly: true)
        let conflict = try XCTUnwrap(leases.first)
        XCTAssertEqual(conflict.state, .conflicted)
        let conflictPath = try XCTUnwrap(conflict.conflictArtifactPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictPath))
        let conflictResource = try await store.ownedResource(externalID: conflict.leaseID, kind: .mergeConflict)
        XCTAssertEqual(conflictResource?.lifecycleState, .active)

        let recovered = try await service.abortConflictedMerge(
            binding,
            targetPath: target.path,
            leaseID: conflict.leaseID
        )
        XCTAssertEqual(recovered.mergeState, .clean)
        XCTAssertEqual(recovered.revision, 2)
        let allLeases = try await store.worktreeMergeLeases(nonterminalOnly: false)
        XCTAssertEqual(allLeases.first?.state, .aborted)
        try await store.close()
    }
}

private actor ConflictingMergeRunner: WorkspaceCommandRunning {
    private let preMergeHead: String

    init(preMergeHead: String) {
        self.preMergeHead = preMergeHead
    }

    func run(
        executable _: String,
        arguments: [String],
        workingDirectory _: String,
        maximumBytes _: Int
    ) async throws -> String {
        if arguments.suffix(2) == ["rev-parse", "HEAD"] { return preMergeHead }
        if arguments.contains("--abort") { return "" }
        if arguments.contains("merge") {
            throw ServiceAPIError(code: .worktreeConflict, message: "injected merge conflict")
        }
        return ""
    }
}
