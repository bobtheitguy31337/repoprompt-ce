import Foundation
@testable import RepoPromptServiceHTTP
import RepoPromptServiceProtocol
import XCTest

final class ProjectFileServiceTests: XCTestCase {
    func testBrowseEditAndMutationsStayOnAuthoritativeProjectRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "before\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let rootID = UUID()
        let project = snapshot(rootID: rootID, root: root)
        let service = ProjectFileService()
        let rootPath = rootID.uuidString.lowercased()

        let roots = try service.listing(project: project, path: "")
        XCTAssertEqual(roots.entries.map(\.name), ["Source"])
        let initial = try service.read(project: project, path: "\(rootPath)/README.md")
        XCTAssertEqual(String(decoding: initial.data, as: UTF8.self), "before\n")

        let saved = try service.write(
            project: project,
            path: "\(rootPath)/README.md",
            data: Data("after\n".utf8),
            expectedRevision: initial.entry.revision
        )
        XCTAssertNotEqual(saved.revision, initial.entry.revision)
        XCTAssertThrowsError(try service.write(
            project: project,
            path: "\(rootPath)/README.md",
            data: Data("stale\n".utf8),
            expectedRevision: initial.entry.revision
        ))

        _ = try service.mutate(project: project, request: .init(operation: .createFolder, path: "\(rootPath)/Docs", destinationPath: nil))
        _ = try service.mutate(project: project, request: .init(operation: .move, path: "\(rootPath)/README.md", destinationPath: "\(rootPath)/Docs/Guide.md"))
        XCTAssertEqual(String(decoding: try service.read(project: project, path: "\(rootPath)/Docs/Guide.md").data, as: UTF8.self), "after\n")
        _ = try service.mutate(project: project, request: .init(operation: .delete, path: "\(rootPath)/Docs", destinationPath: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Docs").path))
    }

    func testRejectsTraversalAndSymlinksOutsideProjectRoot() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("project-file-fence-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("root")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let rootID = UUID()
        let project = snapshot(rootID: rootID, root: root)
        let service = ProjectFileService()

        XCTAssertThrowsError(try service.read(project: project, path: "\(rootID.uuidString)/../outside/secret.txt"))
        XCTAssertThrowsError(try service.read(project: project, path: "\(rootID.uuidString)/escape/secret.txt"))
    }

    func testActiveAgentWorktreeIsListedAlongsideProjectSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("project-workspace-files-\(UUID().uuidString)")
        let source = base.appendingPathComponent("source")
        let worktree = base.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let rootID = UUID()
        let project = snapshot(rootID: rootID, root: source)
        let binding = WorktreeBindingSnapshot(
            bindingID: UUID(),
            projectID: project.projectID,
            rootID: rootID,
            sessionID: UUID(),
            baseRef: "main",
            branch: "agent/change",
            physicalPath: worktree.path,
            ownershipState: .active,
            mergeState: .dirty,
            revision: 1
        )

        let listing = try ProjectFileService().listing(project: project, worktrees: [binding], path: "")
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertTrue(listing.entries.contains(where: { $0.name == "Source — Project source" }))
        XCTAssertTrue(listing.entries.contains(where: { $0.name == "Source — Agent workspace (agent/change)" }))
    }

    private func snapshot(rootID: UUID, root: URL) -> ProjectSnapshot {
        ProjectSnapshot(
            projectID: UUID(),
            name: "Project",
            creator: .init(userID: "owner", username: "owner", displayName: "Owner"),
            state: .active,
            roots: [.init(rootID: rootID, logicalName: "Source", canonicalPath: root.path, writable: true)],
            revision: 1,
            cursor: .init(storeID: UUID(), globalSequence: 1)
        )
    }
}
