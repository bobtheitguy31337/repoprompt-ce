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

    public init(baseDirectory: String, runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(), gitExecutable: String = "/usr/bin/git") throws {
        self.baseDirectory = URL(fileURLWithPath: baseDirectory).standardizedFileURL.path
        self.runner = runner
        self.gitExecutable = gitExecutable
        try FileManager.default.createDirectory(atPath: self.baseDirectory, withIntermediateDirectories: true)
    }

    public func create(project: ProjectSnapshot, root: ProjectRootSnapshot, sessionID: UUID, baseRef: String, branch: String) async throws -> WorktreeBindingSnapshot {
        guard root.writable else { throw ServiceAPIError(code: .rootUnauthorized, message: "Worktree root is read-only") }
        guard Self.safeRef(baseRef), Self.safeBranch(branch) else { throw ServiceAPIError(code: .invalidRequest, message: "Worktree ref or branch is invalid") }
        let bindingID = UUID()
        let path = URL(fileURLWithPath: baseDirectory).appendingPathComponent(project.projectID.uuidString).appendingPathComponent(bindingID.uuidString).path
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        _ = try await runner.run(executable: gitExecutable, arguments: ["-C", root.canonicalPath, "worktree", "add", "-b", branch, path, baseRef], workingDirectory: root.canonicalPath, maximumBytes: 65536)
        return WorktreeBindingSnapshot(bindingID: bindingID, projectID: project.projectID, rootID: root.rootID, sessionID: sessionID, baseRef: baseRef, branch: branch, physicalPath: path, ownershipState: .active, mergeState: .clean, revision: 1)
    }

    public func merge(_ binding: WorktreeBindingSnapshot, targetPath: String, strategy: String) async throws -> WorktreeBindingSnapshot {
        guard ["merge", "squash"].contains(strategy) else { throw ServiceAPIError(code: .invalidRequest, message: "Unsupported worktree merge strategy") }
        var arguments = ["-C", targetPath, "merge", "--no-edit"]
        if strategy == "squash" { arguments.append("--squash") }
        arguments.append(binding.branch)
        _ = try await runner.run(executable: gitExecutable, arguments: arguments, workingDirectory: targetPath, maximumBytes: 1_048_576)
        return WorktreeBindingSnapshot(bindingID: binding.bindingID, projectID: binding.projectID, rootID: binding.rootID, sessionID: binding.sessionID, baseRef: binding.baseRef, branch: binding.branch, physicalPath: binding.physicalPath, ownershipState: binding.ownershipState, mergeState: .merged, revision: binding.revision + 1)
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

    public init(baseDirectory: String) throws {
        self.baseDirectory = URL(fileURLWithPath: baseDirectory).standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: self.baseDirectory, withIntermediateDirectories: true)
    }

    public func store(projectID: UUID, sessionID: UUID?, kind: String, logicalName: String, content: Data, cursor: ServiceCursor) throws -> (ArtifactSnapshot, storageReference: String) {
        guard content.count <= 64 * 1024 * 1024 else { throw ServiceAPIError(code: .invalidRequest, message: "Artifact exceeds the 64 MiB service limit") }
        let artifactID = UUID()
        let projectDirectory = URL(fileURLWithPath: baseDirectory).appendingPathComponent(projectID.uuidString)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let destination = projectDirectory.appendingPathComponent(artifactID.uuidString)
        let temporary = projectDirectory.appendingPathComponent(".\(artifactID.uuidString).tmp")
        try content.write(to: temporary, options: [.atomic])
        try FileManager.default.moveItem(at: temporary, to: destination)
        let digest = CanonicalSigning.bodyDigest(content)
        return (ArtifactSnapshot(artifactID: artifactID, projectID: projectID, sessionID: sessionID, kind: kind, logicalName: logicalName, contentDigest: digest, size: Int64(content.count), createdCursor: cursor), destination.path)
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
    public func workflows() throws -> [WorkflowSnapshot] {
        let rootURL = Bundle.module.url(forResource: "canonical-workflows-v62", withExtension: "json")
        let nestedURL = Bundle.module.url(forResource: "canonical-workflows-v62", withExtension: "json", subdirectory: "Resources")
        guard let url = rootURL ?? nestedURL else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Canonical workflow catalog resource is missing")
        }
        let definitions = try JSONDecoder().decode([BundledWorkflowDefinition].self, from: Data(contentsOf: url))
        let expectedIDs = Set(["rp-build", "rp-investigate", "rp-deep-plan", "rp-reminder", "rp-oracle-export", "rp-review", "rp-refactor", "rp-orchestrate", "rp-optimize"])
        guard definitions.count == expectedIDs.count, Set(definitions.map(\.id)) == expectedIDs else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Canonical workflow catalog is incomplete or contains duplicate IDs")
        }
        return try definitions.map { definition in
            guard definition.definition.contains("repoprompt_skills_version: 62"), definition.definition.contains("repoprompt_variant: mcp") else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Canonical workflow catalog version is invalid")
            }
            return WorkflowSnapshot(
                workflowID: definition.id,
                source: "builtin",
                name: definition.name,
                definition: definition.definition,
                contentDigest: CanonicalSigning.bodyDigest(Data(definition.definition.utf8)),
                enabled: true
            )
        }
    }

    private struct BundledWorkflowDefinition: Decodable {
        let id: String
        let name: String
        let description: String
        let definition: String
    }
}
