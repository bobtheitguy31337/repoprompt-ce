import Foundation
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class ResourceReconciliationTests: XCTestCase {
    func testReconciliationDeletesOnlyRecordedExpiredArtifactsAndPreservesDirtyWorktrees() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let artifacts = directory.appendingPathComponent("artifacts", isDirectory: true)
        let worktrees = directory.appendingPathComponent("worktrees", isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let providerHomes = directory.appendingPathComponent("provider-homes", isDirectory: true)
        let providerOutput = directory.appendingPathComponent("provider-output", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerHomes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerOutput, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let artifactPath = artifacts.appendingPathComponent("owned.bin")
        let unknownPath = artifacts.appendingPathComponent("unknown.bin")
        let worktreePath = worktrees.appendingPathComponent("dirty", isDirectory: true)
        let providerHomePath = providerHomes.appendingPathComponent("expired", isDirectory: true)
        try Data("owned".utf8).write(to: artifactPath)
        try Data("unknown".utf8).write(to: unknownPath)
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerHomePath, withIntermediateDirectories: true)
        try Data("credential".utf8).write(to: providerHomePath.appendingPathComponent("auth.json"))
        let providerStdout = providerOutput.appendingPathComponent("expired.stdout")
        let providerStderr = providerOutput.appendingPathComponent("expired.stderr")
        try Data("out".utf8).write(to: providerStdout)
        try Data("err".utf8).write(to: providerStderr)

        let store = try await SQLiteServiceStore.open(storage: .memory)
        let deadline = Date().addingTimeInterval(15 * 60)
        let artifact = OwnedResourceRecord(
            kind: .artifact,
            externalID: UUID(),
            internalPathIdentity: artifactPath.path,
            lifecycleState: .prepared,
            observedBytes: 5,
            contentDigest: CanonicalSigning.bodyDigest(Data("owned".utf8)),
            retentionDeadline: deadline
        )
        let worktree = OwnedResourceRecord(
            kind: .worktree,
            externalID: UUID(),
            internalPathIdentity: worktreePath.path,
            lifecycleState: .prepared,
            metadata: ["sourceRoot": source.path],
            retentionDeadline: deadline
        )
        let providerHome = OwnedResourceRecord(
            kind: .providerHome,
            externalID: UUID(),
            internalPathIdentity: providerHomePath.path,
            lifecycleState: .cleanupPending,
            retentionDeadline: deadline
        )
        let providerCapture = OwnedResourceRecord(
            kind: .providerOutput,
            externalID: UUID(),
            internalPathIdentity: providerStdout.path,
            temporaryPathIdentity: providerStderr.path,
            lifecycleState: .cleanupPending,
            retentionDeadline: deadline
        )
        try await store.reserveOwnedResource(artifact)
        try await store.reserveOwnedResource(worktree)
        try await store.reserveOwnedResource(providerHome)
        try await store.reserveOwnedResource(providerCapture)
        let reconciler = OwnedResourceReconciliationService(
            repository: store,
            artifactRoot: artifacts.path,
            worktreeRoot: worktrees.path,
            providerHomeRoot: providerHomes.path,
            providerOutputRoot: providerOutput.path,
            runner: DirtyWorktreeRunner()
        )
        let report = await reconciler.reconcileStartup()
        XCTAssertEqual(report.deleted, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerHomePath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerStdout.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerStderr.path))
        let persistedWorktree = try await store.ownedResource(externalID: XCTUnwrap(worktree.externalID), kind: .worktree)
        XCTAssertEqual(persistedWorktree?.lifecycleState, .quarantined)
        try await store.close()
    }
}

private actor DirtyWorktreeRunner: WorkspaceCommandRunning {
    func run(
        executable _: String,
        arguments: [String],
        workingDirectory _: String,
        maximumBytes _: Int
    ) async throws -> String {
        if arguments.contains("status") { return " M important.txt\n" }
        return ""
    }
}
