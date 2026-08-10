import Foundation
import RepoPromptCodeMapCore
import RepoPromptServiceProtocol

public protocol WorkspaceCommandRunning: Sendable {
    func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int) async throws -> String
}

public actor LocalWorkspaceCommandRunner: WorkspaceCommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String], workingDirectory: String, maximumBytes: Int) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Required workspace executable is unavailable")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        async let outputData = output.fileHandleForReading.readToEnd()
        async let errorData = errors.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        let stdout = try await outputData ?? Data()
        let stderr = try await errorData ?? Data()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.prefix(8192), as: UTF8.self)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Workspace command failed: \(message)")
        }
        return String(decoding: stdout.prefix(maximumBytes), as: UTF8.self)
    }
}

public actor ProjectToolAuthority {
    private let project: ProjectAuthority
    private let filesystem: any FilesystemAuthorityPort
    private let commandRunner: any WorkspaceCommandRunning
    private let gitExecutable: String

    public init(project: ProjectAuthority, filesystem: any FilesystemAuthorityPort, commandRunner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(), gitExecutable: String = "/usr/bin/git") {
        self.project = project
        self.filesystem = filesystem
        self.commandRunner = commandRunner
        self.gitExecutable = gitExecutable
    }

    public func tree(_ request: ProjectTreeRequest) async throws -> [ProjectTreeEntry] {
        let root = try await project.root(rootID: request.rootID)
        let start = request.logicalPath.isEmpty
            ? root.snapshot.canonicalPath
            : try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        let maximumDepth = max(0, min(request.maximumDepth, 32))
        let maximumEntries = max(1, min(request.maximumEntries, 20000))
        var entries: [ProjectTreeEntry] = []
        try walkTree(rootID: request.rootID, rootPath: root.snapshot.canonicalPath, currentPath: start, depth: 0, maximumDepth: maximumDepth, maximumEntries: maximumEntries, entries: &entries)
        return entries
    }

    public func search(_ request: ProjectSearchRequest) async throws -> [ProjectSearchHit] {
        guard !request.query.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Search query is required") }
        let root = try await project.root(rootID: request.rootID)
        let start = request.logicalPath.isEmpty
            ? root.snapshot.canonicalPath
            : try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        let maximumResults = max(1, min(request.maximumResults, 2000))
        let maximumFileBytes = max(1, min(request.maximumFileBytes, 8_388_608))
        let expression = try request.useRegex ? NSRegularExpression(pattern: request.query) : nil
        return try searchFiles(request: request, start: start, rootPath: root.snapshot.canonicalPath, maximumResults: maximumResults, maximumFileBytes: maximumFileBytes, expression: expression)
    }

    private func searchFiles(request: ProjectSearchRequest, start: String, rootPath: String, maximumResults: Int, maximumFileBytes: Int, expression: NSRegularExpression?) throws -> [ProjectSearchHit] {
        var hits: [ProjectSearchHit] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: start), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            if hits.count >= maximumResults { break }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileBytes else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let content = String(data: data, encoding: .utf8) else { continue }
            let relative = Self.relativePath(url.path, root: rootPath)
            for (offset, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let matched = if let expression {
                    expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                } else {
                    text.localizedCaseInsensitiveContains(request.query)
                }
                if matched {
                    hits.append(ProjectSearchHit(rootID: request.rootID, logicalPath: relative, line: offset + 1, preview: String(text.prefix(1000))))
                    if hits.count >= maximumResults { break }
                }
            }
        }
        return hits
    }

    public func readFile(_ request: ProjectFileRequest) async throws -> ProjectFileSnapshot {
        let path = try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ServiceAPIError(code: .notFound, message: "Authorized file was not found")
        }
        let maximumBytes = max(1, min(request.maximumBytes, 8_388_608))
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard let source = String(data: data.prefix(maximumBytes), encoding: .utf8) else {
            throw ServiceAPIError(code: .invalidRequest, message: "File is not UTF-8 text")
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (request.startLine ?? 1) - 1)
        let end = min(lines.count, start + max(1, min(request.lineCount ?? lines.count, 20000)))
        let content = start < end ? lines[start ..< end].joined(separator: "\n") : ""
        return ProjectFileSnapshot(rootID: request.rootID, logicalPath: request.logicalPath, content: content, contentDigest: CanonicalSigning.bodyDigest(data), truncated: data.count > maximumBytes || end < lines.count)
    }

    public func codeMap(_ request: ProjectCodeMapRequest) async throws -> ProjectCodeMapSnapshot {
        let path = try await project.authorize(rootID: request.rootID, logicalPath: request.logicalPath, filesystem: filesystem)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ServiceAPIError(code: .notFound, message: "Authorized file was not found")
        }
        let maximumBytes = max(1, min(request.maximumBytes, 5_242_880))
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            return ProjectCodeMapSnapshot(rootID: request.rootID, logicalPath: request.logicalPath, status: PortableCodeMapResult.Status.oversize.rawValue, language: nil, content: "", contentDigest: CanonicalSigning.bodyDigest(data))
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ServiceAPIError(code: .invalidRequest, message: "File is not UTF-8 text")
        }
        let result = try PortableCodeMapService.build(content: source, fileExtension: URL(fileURLWithPath: path).pathExtension)
        return ProjectCodeMapSnapshot(rootID: request.rootID, logicalPath: request.logicalPath, status: result.status.rawValue, language: result.language, content: result.content, contentDigest: result.contentDigest)
    }

    public func diff(_ request: ProjectDiffRequest) async throws -> ProjectDiffSnapshot {
        guard Self.safeRevision(request.comparison) else { throw ServiceAPIError(code: .invalidRequest, message: "Git comparison is invalid") }
        let root = try await project.root(rootID: request.rootID)
        for path in request.logicalPaths {
            _ = try await project.authorize(rootID: request.rootID, logicalPath: path, filesystem: filesystem)
        }
        let maximumBytes = max(1, min(request.maximumBytes, 8_388_608))
        let arguments = ["-C", root.snapshot.canonicalPath, "diff", "--no-ext-diff", "--no-textconv", "--color=never", request.comparison, "--"] + request.logicalPaths
        let patch = try await commandRunner.run(executable: gitExecutable, arguments: arguments, workingDirectory: root.snapshot.canonicalPath, maximumBytes: maximumBytes)
        let data = Data(patch.utf8)
        return ProjectDiffSnapshot(rootID: request.rootID, comparison: request.comparison, patch: patch, truncated: data.count >= maximumBytes, contentDigest: CanonicalSigning.bodyDigest(data))
    }

    private func walkTree(rootID: UUID, rootPath: String, currentPath: String, depth: Int, maximumDepth: Int, maximumEntries: Int, entries: inout [ProjectTreeEntry]) throws {
        guard entries.count < maximumEntries, depth <= maximumDepth else { return }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: currentPath), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            guard entries.count < maximumEntries else { return }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { continue }
            let relative = Self.relativePath(url.path, root: rootPath)
            entries.append(ProjectTreeEntry(rootID: rootID, logicalPath: relative, isDirectory: values.isDirectory == true, size: values.isDirectory == true ? nil : Int64(values.fileSize ?? 0)))
            if values.isDirectory == true, depth < maximumDepth {
                try walkTree(rootID: rootID, rootPath: rootPath, currentPath: url.path, depth: depth + 1, maximumDepth: maximumDepth, maximumEntries: maximumEntries, entries: &entries)
            }
        }
    }

    private static func relativePath(_ path: String, root: String) -> String {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.filter { $0 != "/" }
        let rootComponents = URL(fileURLWithPath: root).standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !rootComponents.isEmpty, pathComponents.count >= rootComponents.count else { return URL(fileURLWithPath: path).lastPathComponent }
        for start in 0 ... (pathComponents.count - rootComponents.count) where Array(pathComponents[start ..< start + rootComponents.count]) == rootComponents {
            return pathComponents.dropFirst(start + rootComponents.count).joined(separator: "/")
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func safeRevision(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.range(of: "^[A-Za-z0-9_./~^{}-]+$", options: .regularExpression) != nil
    }
}

public actor WorktreeRuntimeService {
    private let baseDirectory: String
    private let runner: any WorkspaceCommandRunning
    private let gitExecutable: String
    private let resources: (any OwnedResourceRepository)?
    private let ownerInstanceID: UUID

    public init(
        baseDirectory: String,
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        gitExecutable: String = "/usr/bin/git",
        resources: (any OwnedResourceRepository)? = nil,
        ownerInstanceID: UUID = UUID()
    ) throws {
        self.baseDirectory = URL(fileURLWithPath: baseDirectory).standardizedFileURL.path
        self.runner = runner
        self.gitExecutable = gitExecutable
        self.resources = resources
        self.ownerInstanceID = ownerInstanceID
        try FileManager.default.createDirectory(atPath: self.baseDirectory, withIntermediateDirectories: true)
    }

    public func create(project: ProjectSnapshot, root: ProjectRootSnapshot, sessionID: UUID, baseRef: String, branch: String) async throws -> WorktreeBindingSnapshot {
        guard root.writable else { throw ServiceAPIError(code: .rootUnauthorized, message: "Worktree root is read-only") }
        guard Self.safeRef(baseRef), Self.safeBranch(branch) else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree ref or branch is invalid") }
        let bindingID = UUID()
        let candidate = URL(fileURLWithPath: baseDirectory).appendingPathComponent(project.projectID.uuidString).appendingPathComponent(bindingID.uuidString).path
        let path = try DurableFilesystem.standardizedContainedPath(root: baseDirectory, candidate: candidate)
        let reservation = OwnedResourceRecord(
            kind: .worktree,
            projectID: project.projectID,
            sessionID: sessionID,
            externalID: bindingID,
            internalPathIdentity: path,
            lifecycleState: .preparing,
            metadata: ["sourceRoot": root.canonicalPath, "baseRef": baseRef, "branch": branch],
            retentionDeadline: Date().addingTimeInterval(15 * 60)
        )
        try await resources?.reserveOwnedResource(reservation)
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        do {
            _ = try await runner.run(executable: gitExecutable, arguments: ["-C", root.canonicalPath, "worktree", "add", "-b", branch, path, baseRef], workingDirectory: root.canonicalPath, maximumBytes: 65536)
            let verification = try await runner.run(executable: gitExecutable, arguments: ["-C", path, "rev-parse", "--show-toplevel"], workingDirectory: path, maximumBytes: 65536)
            guard URL(fileURLWithPath: verification.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path == path else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Created Git worktree identity did not match its reservation")
            }
            _ = try await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing],
                to: .prepared,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: nil
            )
            return WorktreeBindingSnapshot(bindingID: bindingID, projectID: project.projectID, rootID: root.rootID, sessionID: sessionID, baseRef: baseRef, branch: branch, physicalPath: path, ownershipState: .active, mergeState: .clean, revision: 1)
        } catch {
            let cleanupError = await cleanupFailedWorktree(path: path, sourceRoot: root.canonicalPath)
            _ = try? await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing, .prepared],
                to: cleanupError == nil ? .failed : .quarantined,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: cleanupError
            )
            throw error
        }
    }

    public func merge(_ binding: WorktreeBindingSnapshot, targetPath: String, strategy: String) async throws -> WorktreeBindingSnapshot {
        guard ["merge", "squash"].contains(strategy) else { throw ServiceAPIError(code: .invalidRequest, message: "Unsupported worktree merge strategy") }
        guard binding.ownershipState == .active else { throw ServiceAPIError(code: .worktreeConflict, message: "Only an active worktree can be merged") }
        let preMergeStatus = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", targetPath, "status", "--porcelain"],
            workingDirectory: targetPath,
            maximumBytes: 65536
        )
        guard preMergeStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Merge target must be clean before acquiring a lease")
        }
        let preMergeHead = try await runner.run(executable: gitExecutable, arguments: ["-C", targetPath, "rev-parse", "HEAD"], workingDirectory: targetPath, maximumBytes: 4096).trimmingCharacters(in: .whitespacesAndNewlines)
        let lease = WorktreeMergeLeaseRecord(
            bindingID: binding.bindingID,
            expectedBindingRevision: binding.revision,
            strategy: strategy,
            targetPath: URL(fileURLWithPath: targetPath).standardizedFileURL.path,
            preMergeHead: preMergeHead,
            ownerInstanceID: ownerInstanceID,
            expiresAt: Date().addingTimeInterval(2 * 60)
        )
        try await resources?.acquireWorktreeMergeLease(lease)
        _ = try await resources?.transitionWorktreeMergeLease(leaseID: lease.leaseID, expectedStates: [.preparing], to: .running, conflictArtifactPath: nil, errorCode: nil)
        let leaseHeartbeat = resources.map { resources in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    try? await resources.renewWorktreeMergeLease(
                        leaseID: lease.leaseID,
                        ownerInstanceID: ownerInstanceID,
                        expiresAt: Date().addingTimeInterval(2 * 60)
                    )
                }
            }
        }
        defer { leaseHeartbeat?.cancel() }
        do {
            var arguments = ["-C", targetPath, "merge", "--no-edit"]
            if strategy == "squash" { arguments.append("--squash") }
            arguments.append(binding.branch)
            _ = try await runner.run(executable: gitExecutable, arguments: arguments, workingDirectory: targetPath, maximumBytes: 1_048_576)
            _ = try await resources?.transitionWorktreeMergeLease(leaseID: lease.leaseID, expectedStates: [.running], to: .prepared, conflictArtifactPath: nil, errorCode: nil)
            return WorktreeBindingSnapshot(bindingID: binding.bindingID, projectID: binding.projectID, rootID: binding.rootID, sessionID: binding.sessionID, baseRef: binding.baseRef, branch: binding.branch, physicalPath: binding.physicalPath, ownershipState: binding.ownershipState, mergeState: .merged, revision: binding.revision + 1)
        } catch {
            let conflictPath = try? await publishConflictSnapshot(binding: binding, lease: lease, targetPath: targetPath)
            _ = try? await resources?.transitionWorktreeMergeLease(
                leaseID: lease.leaseID,
                expectedStates: [.running, .preparing],
                to: .conflicted,
                conflictArtifactPath: conflictPath,
                errorCode: "git_merge_failed"
            )
            throw ServiceAPIError(code: .worktreeConflict, message: "Worktree merge requires conflict recovery")
        }
    }

    public func abortConflictedMerge(
        _ binding: WorktreeBindingSnapshot,
        targetPath: String,
        leaseID: UUID
    ) async throws -> WorktreeBindingSnapshot {
        guard let resources else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Durable merge recovery requires an owned-resource repository")
        }
        let leases = try await resources.worktreeMergeLeases(nonterminalOnly: true)
        guard let lease = leases.first(where: { $0.leaseID == leaseID }),
              lease.bindingID == binding.bindingID,
              lease.state == .conflicted,
              lease.targetPath == URL(fileURLWithPath: targetPath).standardizedFileURL.path
        else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Conflicted merge lease does not match the requested binding")
        }
        do {
            _ = try await runner.run(
                executable: gitExecutable,
                arguments: ["-C", targetPath, "merge", "--abort"],
                workingDirectory: targetPath,
                maximumBytes: 65536
            )
        } catch {
            _ = try await runner.run(
                executable: gitExecutable,
                arguments: ["-C", targetPath, "reset", "--merge", lease.preMergeHead],
                workingDirectory: targetPath,
                maximumBytes: 65536
            )
        }
        let recoveredHead = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", targetPath, "rev-parse", "HEAD"],
            workingDirectory: targetPath,
            maximumBytes: 4096
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let recoveredStatus = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", targetPath, "status", "--porcelain"],
            workingDirectory: targetPath,
            maximumBytes: 65536
        )
        guard recoveredHead == lease.preMergeHead,
              recoveredStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ServiceAPIError(code: .worktreeConflict, message: "Merge abort did not restore the fenced clean pre-merge state")
        }
        _ = try await resources.transitionWorktreeMergeLease(
            leaseID: leaseID,
            expectedStates: [.conflicted],
            to: .aborted,
            conflictArtifactPath: lease.conflictArtifactPath,
            errorCode: nil
        )
        return WorktreeBindingSnapshot(
            bindingID: binding.bindingID,
            projectID: binding.projectID,
            rootID: binding.rootID,
            sessionID: binding.sessionID,
            baseRef: binding.baseRef,
            branch: binding.branch,
            physicalPath: binding.physicalPath,
            ownershipState: binding.ownershipState,
            mergeState: .clean,
            revision: binding.revision + 1
        )
    }

    private func cleanupFailedWorktree(path: String, sourceRoot: String) async -> String? {
        do {
            if FileManager.default.fileExists(atPath: path) {
                _ = try await runner.run(executable: gitExecutable, arguments: ["-C", sourceRoot, "worktree", "remove", "--force", path], workingDirectory: sourceRoot, maximumBytes: 65536)
            }
            _ = try await runner.run(executable: gitExecutable, arguments: ["-C", sourceRoot, "worktree", "prune"], workingDirectory: sourceRoot, maximumBytes: 65536)
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            return nil
        } catch {
            return "worktree_cleanup_failed"
        }
    }

    private func publishConflictSnapshot(binding: WorktreeBindingSnapshot, lease: WorktreeMergeLeaseRecord, targetPath: String) async throws -> String {
        let directory = URL(fileURLWithPath: baseDirectory).appendingPathComponent(".conflicts", isDirectory: true)
        let destination = directory.appendingPathComponent("\(lease.leaseID.uuidString).json")
        let temporary = directory.appendingPathComponent(".\(lease.leaseID.uuidString).tmp")
        let payload = try JSONEncoder().encode([
            "schemaVersion": "1", "bindingId": binding.bindingID.uuidString, "leaseId": lease.leaseID.uuidString,
            "strategy": lease.strategy, "preMergeHead": lease.preMergeHead, "targetState": "conflicted"
        ])
        try DurableFilesystem.publish(data: payload, temporary: temporary, destination: destination)
        let record = OwnedResourceRecord(
            kind: .mergeConflict,
            projectID: binding.projectID,
            sessionID: binding.sessionID,
            externalID: lease.leaseID,
            internalPathIdentity: destination.path,
            lifecycleState: .active,
            observedBytes: Int64(payload.count),
            contentDigest: CanonicalSigning.bodyDigest(payload),
            metadata: ["bindingId": binding.bindingID.uuidString]
        )
        try await resources?.reserveOwnedResource(record)
        return destination.path
    }

    private static func safeRef(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.range(of: "^[A-Za-z0-9_./~^{}-]+$", options: .regularExpression) != nil
    }

    private static func safeBranch(_ value: String) -> Bool {
        safeRef(value) && !value.contains("..") && !value.hasSuffix(".lock")
    }
}

public actor ArtifactRuntimeService {
    private let baseDirectory: String
    private let resources: (any OwnedResourceRepository)?

    public init(baseDirectory: String, resources: (any OwnedResourceRepository)? = nil) throws {
        self.baseDirectory = URL(fileURLWithPath: baseDirectory).standardizedFileURL.path
        self.resources = resources
        try FileManager.default.createDirectory(atPath: self.baseDirectory, withIntermediateDirectories: true)
    }

    public func store(projectID: UUID, sessionID: UUID?, kind: String, logicalName: String, content: Data, cursor: ServiceCursor) async throws -> (ArtifactSnapshot, storageReference: String) {
        guard content.count <= 64 * 1024 * 1024 else { throw ServiceAPIError(code: .invalidRequest, message: "Artifact exceeds the 64 MiB service limit") }
        let artifactID = UUID()
        let projectDirectory = URL(fileURLWithPath: baseDirectory).appendingPathComponent(projectID.uuidString)
        let destination = projectDirectory.appendingPathComponent(artifactID.uuidString)
        let temporary = projectDirectory.appendingPathComponent(".\(artifactID.uuidString).tmp")
        let finalPath = try DurableFilesystem.standardizedContainedPath(root: baseDirectory, candidate: destination.path)
        let temporaryPath = try DurableFilesystem.standardizedContainedPath(root: baseDirectory, candidate: temporary.path)
        let digest = CanonicalSigning.bodyDigest(content)
        let reservation = OwnedResourceRecord(
            kind: .artifact,
            projectID: projectID,
            sessionID: sessionID,
            externalID: artifactID,
            internalPathIdentity: finalPath,
            temporaryPathIdentity: temporaryPath,
            lifecycleState: .preparing,
            observedBytes: Int64(content.count),
            contentDigest: digest,
            metadata: ["kind": kind, "logicalName": logicalName],
            retentionDeadline: Date().addingTimeInterval(15 * 60)
        )
        try await resources?.reserveOwnedResource(reservation)
        do {
            try DurableFilesystem.publish(data: content, temporary: URL(fileURLWithPath: temporaryPath), destination: URL(fileURLWithPath: finalPath))
            let persisted = try Data(contentsOf: URL(fileURLWithPath: finalPath), options: [.mappedIfSafe])
            guard persisted.count == content.count, CanonicalSigning.bodyDigest(persisted) == digest else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Published artifact failed durability verification")
            }
            _ = try await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing],
                to: .prepared,
                observedBytes: Int64(content.count),
                contentDigest: digest,
                cleanupError: nil
            )
            return (ArtifactSnapshot(artifactID: artifactID, projectID: projectID, sessionID: sessionID, kind: kind, logicalName: logicalName, contentDigest: digest, size: Int64(content.count), createdCursor: cursor), finalPath)
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            _ = try? await resources?.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing, .prepared],
                to: FileManager.default.fileExists(atPath: finalPath) ? .quarantined : .failed,
                observedBytes: Int64(content.count),
                contentDigest: digest,
                cleanupError: FileManager.default.fileExists(atPath: finalPath) ? "artifact_publication_unconfirmed" : nil
            )
            throw error
        }
    }

    public func content(storageReference: String, maximumBytes: Int) throws -> Data {
        let path = URL(fileURLWithPath: storageReference).standardizedFileURL.path
        let prefix = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
        guard path.hasPrefix(prefix) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Artifact storage reference escaped its service root") }
        return try Data(Data(contentsOf: URL(fileURLWithPath: path)).prefix(max(1, min(maximumBytes, 64 * 1024 * 1024))))
    }
}

public struct BuiltinWorkflowCatalog: Sendable {
    public init() {}
    public func workflows() -> [WorkflowSnapshot] {
        let definitions = [
            ("review", "Code Review", "Review the selected changes for correctness, security, and regressions."),
            ("plan", "Implementation Plan", "Create an implementation plan grounded in the selected repository context."),
            ("chat", "Repository Chat", "Answer a repository question using the frozen selected context.")
        ]
        return definitions.map { id, name, definition in
            WorkflowSnapshot(workflowID: id, source: "builtin", name: name, definition: definition, contentDigest: CanonicalSigning.bodyDigest(Data(definition.utf8)), enabled: true)
        }
    }
}
