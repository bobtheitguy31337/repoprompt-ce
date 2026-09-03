import Foundation
import RepoPromptServiceProtocol

struct ProjectFileEntry: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case file, folder }

    let name: String
    let path: String
    let kind: Kind
    let byteSize: Int64?
    let modifiedAt: Date
    let revision: String
    let writable: Bool
}

struct ProjectFileListing: Codable, Sendable {
    let projectID: UUID
    let projectName: String
    let path: String
    let entries: [ProjectFileEntry]
    let breadcrumbs: [ProjectFileBreadcrumb]
    let writable: Bool
}

struct ProjectFileBreadcrumb: Codable, Hashable, Sendable {
    let name: String
    let path: String
}

struct ProjectFileMutationRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case createFolder, move, delete }

    let operation: Operation
    let path: String
    let destinationPath: String?
}

/// Files exposed to Gabblin are resolved from the project's authoritative root
/// snapshots. Every operation re-resolves symlinks and remains fenced inside a
/// configured root; browser-provided paths are never treated as host paths.
final class ProjectFileService: @unchecked Sendable {
    static let maximumFileBytes = 20 * 1_024 * 1_024

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func listing(project: ProjectSnapshot, worktrees: [WorktreeBindingSnapshot] = [], path: String) throws -> ProjectFileListing {
        let components = try pathComponents(path)
        if components.isEmpty {
            let roots = browserRoots(project: project, worktrees: worktrees)
            let entries = roots.compactMap { root -> ProjectFileEntry? in
                let url = URL(fileURLWithPath: root.canonicalPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
                return try? entry(name: root.logicalName, path: root.identifier, url: url, writable: root.writable)
            }.sorted(by: entryOrder)
            return ProjectFileListing(
                projectID: project.projectID,
                projectName: project.name,
                path: "",
                entries: entries,
                breadcrumbs: [.init(name: project.name, path: "")],
                writable: false
            )
        }

        let resolved = try resolve(project: project, worktrees: worktrees, components: components, mustExist: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServiceAPIError(code: .notFound, message: "Project directory was not found")
        }
        let children = try fileManager.contentsOfDirectory(
            at: resolved.url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        let entries = children.compactMap { child -> ProjectFileEntry? in
            guard (try? checkedContained(child, root: resolved.rootURL)) != nil else { return nil }
            let childPath = (components + [child.lastPathComponent]).joined(separator: "/")
            return try? entry(name: child.lastPathComponent, path: childPath, url: child, writable: resolved.root.writable)
        }.sorted(by: entryOrder)
        return ProjectFileListing(
            projectID: project.projectID,
            projectName: project.name,
            path: components.joined(separator: "/"),
            entries: entries,
            breadcrumbs: breadcrumbs(project: project, root: resolved.root, components: components),
            writable: resolved.root.writable
        )
    }

    func read(project: ProjectSnapshot, worktrees: [WorktreeBindingSnapshot] = [], path: String) throws -> (data: Data, entry: ProjectFileEntry, mediaType: String) {
        let components = try pathComponents(path)
        guard components.count > 1 else { throw ServiceAPIError(code: .invalidRequest, message: "A file path is required") }
        let resolved = try resolve(project: project, worktrees: worktrees, components: components, mustExist: true)
        let values = try resolved.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ServiceAPIError(code: .notFound, message: "Project file was not found") }
        guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Project file exceeds the remote editing limit")
        }
        return (
            try Data(contentsOf: resolved.url, options: .mappedIfSafe),
            try entry(name: resolved.url.lastPathComponent, path: components.joined(separator: "/"), url: resolved.url, writable: resolved.root.writable),
            mediaType(for: resolved.url)
        )
    }

    func write(project: ProjectSnapshot, worktrees: [WorktreeBindingSnapshot] = [], path: String, data: Data, expectedRevision: String?) throws -> ProjectFileEntry {
        guard data.count <= Self.maximumFileBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Project file exceeds the remote editing limit")
        }
        let components = try pathComponents(path)
        guard components.count > 1 else { throw ServiceAPIError(code: .invalidRequest, message: "A file path is required") }
        let resolved = try resolve(project: project, worktrees: worktrees, components: components, mustExist: false)
        guard resolved.root.writable else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Project root is read-only") }
        try requireExpectedRevision(url: resolved.url, expectedRevision: expectedRevision)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ServiceAPIError(code: .invalidRequest, message: "A folder already exists at that path")
        }
        let existingPermissions = try? fileManager.attributesOfItem(atPath: resolved.url.path)[.posixPermissions]
        try data.write(to: resolved.url, options: .atomic)
        if let existingPermissions {
            try fileManager.setAttributes([.posixPermissions: existingPermissions], ofItemAtPath: resolved.url.path)
        }
        return try entry(name: resolved.url.lastPathComponent, path: components.joined(separator: "/"), url: resolved.url, writable: true)
    }

    func mutate(project: ProjectSnapshot, worktrees: [WorktreeBindingSnapshot] = [], request: ProjectFileMutationRequest) throws -> ProjectFileEntry? {
        let components = try pathComponents(request.path)
        guard components.count > 1 else { throw ServiceAPIError(code: .invalidRequest, message: "Project roots cannot be changed here") }
        let resolved = try resolve(project: project, worktrees: worktrees, components: components, mustExist: request.operation != .createFolder)
        guard resolved.root.writable else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Project root is read-only") }

        switch request.operation {
        case .createFolder:
            guard request.destinationPath == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Unexpected destination path") }
            do {
                try fileManager.createDirectory(at: resolved.url, withIntermediateDirectories: false)
            } catch {
                throw ServiceAPIError(code: .invalidRequest, message: "Folder could not be created")
            }
            return try entry(name: resolved.url.lastPathComponent, path: components.joined(separator: "/"), url: resolved.url, writable: true)
        case .move:
            guard let destinationPath = request.destinationPath else {
                throw ServiceAPIError(code: .invalidRequest, message: "A destination path is required")
            }
            let destinationComponents = try pathComponents(destinationPath)
            guard destinationComponents.count > 1 else { throw ServiceAPIError(code: .invalidRequest, message: "Project roots cannot be replaced") }
            let destination = try resolve(project: project, worktrees: worktrees, components: destinationComponents, mustExist: false)
            guard destination.root.writable else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Destination root is read-only") }
            guard !fileManager.fileExists(atPath: destination.url.path) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Destination already exists")
            }
            try fileManager.moveItem(at: resolved.url, to: destination.url)
            return try entry(name: destination.url.lastPathComponent, path: destinationComponents.joined(separator: "/"), url: destination.url, writable: true)
        case .delete:
            guard request.destinationPath == nil else { throw ServiceAPIError(code: .invalidRequest, message: "Unexpected destination path") }
            try fileManager.removeItem(at: resolved.url)
            return nil
        }
    }

    private struct BrowserRoot {
        let identifier: String
        let logicalName: String
        let canonicalPath: String
        let writable: Bool
    }

    private struct ResolvedPath {
        let root: BrowserRoot
        let rootURL: URL
        let url: URL
    }

    private func pathComponents(_ path: String) throws -> [String] {
        guard path.utf8.count <= 4_096, !path.contains("\\"), !path.contains("\0") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Project path is invalid")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Project path is invalid")
        }
        return components
    }

    private func resolve(project: ProjectSnapshot, worktrees: [WorktreeBindingSnapshot], components: [String], mustExist: Bool) throws -> ResolvedPath {
        guard let identifier = components.first,
              let root = browserRoots(project: project, worktrees: worktrees).first(where: { $0.identifier == identifier.lowercased() })
        else { throw ServiceAPIError(code: .notFound, message: "Project root was not found") }
        let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: rootURL.path) else { throw ServiceAPIError(code: .notFound, message: "Project root was not found") }
        let candidate = components.dropFirst().reduce(rootURL) { $0.appendingPathComponent($1) }.standardizedFileURL
        let checkedURL: URL
        if mustExist || fileManager.fileExists(atPath: candidate.path) {
            checkedURL = candidate.resolvingSymlinksInPath()
        } else {
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            try checkedContained(parent, root: rootURL)
            var parentIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
                throw ServiceAPIError(code: .notFound, message: "Parent directory was not found")
            }
            checkedURL = parent.appendingPathComponent(candidate.lastPathComponent)
        }
        try checkedContained(checkedURL, root: rootURL)
        if mustExist, !fileManager.fileExists(atPath: checkedURL.path) {
            throw ServiceAPIError(code: .notFound, message: "Project path was not found")
        }
        return ResolvedPath(root: root, rootURL: rootURL, url: checkedURL)
    }

    private func checkedContained(_ url: URL, root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Project path leaves its configured root")
        }
    }

    private func requireExpectedRevision(url: URL, expectedRevision: String?) throws {
        let exists = fileManager.fileExists(atPath: url.path)
        if !exists {
            guard expectedRevision == nil || expectedRevision == "*" else {
                throw ServiceAPIError(code: .staleRevision, message: "Project file changed before it was saved")
            }
            return
        }
        guard let expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "An existing file requires a revision") }
        let current = try revision(for: url)
        guard current == expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Project file changed before it was saved")
        }
    }

    private func entry(name: String, path: String, url: URL, writable: Bool) throws -> ProjectFileEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values.isDirectory == true
        return ProjectFileEntry(
            name: name,
            path: path,
            kind: isDirectory ? .folder : .file,
            byteSize: isDirectory ? nil : Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast,
            revision: try revision(for: url),
            writable: writable
        )
    }

    private func revision(for url: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(Int64(modified * 1_000_000_000)):\(size)"
    }

    private func breadcrumbs(project: ProjectSnapshot, root: BrowserRoot, components: [String]) -> [ProjectFileBreadcrumb] {
        var result = [ProjectFileBreadcrumb(name: project.name, path: "")]
        var path = root.identifier
        result.append(.init(name: root.logicalName, path: path))
        for component in components.dropFirst() {
            path += "/\(component)"
            result.append(.init(name: component, path: path))
        }
        return result
    }

    private func browserRoots(project: ProjectSnapshot, worktrees: [WorktreeBindingSnapshot]) -> [BrowserRoot] {
        let activeWorktrees = worktrees.filter { $0.ownershipState == .active }
        let worktreeRoots = activeWorktrees.compactMap { worktree -> BrowserRoot? in
            guard let root = project.roots.first(where: { $0.rootID == worktree.rootID }) else { return nil }
            return BrowserRoot(
                identifier: "worktree-\(worktree.bindingID.uuidString.lowercased())",
                logicalName: "\(root.logicalName) — Agent workspace (\(worktree.branch))",
                canonicalPath: worktree.physicalPath,
                writable: root.writable
            )
        }
        let sourceRoots = project.roots.map { root in
            BrowserRoot(
                identifier: root.rootID.uuidString.lowercased(),
                logicalName: activeWorktrees.contains(where: { $0.rootID == root.rootID }) ? "\(root.logicalName) — Project source" : root.logicalName,
                canonicalPath: root.canonicalPath,
                writable: root.writable
            )
        }
        return worktreeRoots + sourceRoots
    }

    private func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "md", "swift", "ts", "tsx", "js", "jsx", "css", "html", "sh", "py", "rb", "rs", "go", "java", "c", "h", "cpp", "hpp", "yml", "yaml", "toml": "text/plain; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        default: "application/octet-stream"
        }
    }

    private func entryOrder(_ left: ProjectFileEntry, _ right: ProjectFileEntry) -> Bool {
        if left.kind != right.kind { return left.kind == .folder }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}
