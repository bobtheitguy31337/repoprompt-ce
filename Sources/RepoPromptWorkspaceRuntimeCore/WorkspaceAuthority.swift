import Foundation
import RepoPromptC
import RepoPromptServiceProtocol

public struct CanonicalRoot: Hashable, Sendable {
    public let snapshot: ProjectRootSnapshot
    public let filesystemIdentity: String
    public init(snapshot: ProjectRootSnapshot, filesystemIdentity: String) {
        self.snapshot = snapshot
        self.filesystemIdentity = filesystemIdentity
    }
}

public protocol FilesystemAuthorityPort: Sendable {
    func canonicalizeRoot(_ path: String) throws -> (path: String, identity: String, isDirectory: Bool)
    func contains(root: String, candidate: String) throws -> Bool
}

public struct LocalFilesystemAuthority: FilesystemAuthorityPort {
    public init() {}

    public func canonicalizeRoot(_ path: String) throws -> (path: String, identity: String, isDirectory: Bool) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root must be an existing directory")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        var identityComponents = [attributes[.systemNumber], attributes[.systemFileNumber]]
            .compactMap(\.self)
            .map(String.init(describing:))
        var birthSeconds: UInt64 = 0
        var birthNanoseconds: UInt32 = 0
        if url.path.withCString({ rp_filesystem_birth_identity($0, &birthSeconds, &birthNanoseconds) }) == 0 {
            identityComponents.append("\(birthSeconds):\(birthNanoseconds)")
        }
        let identity = identityComponents.joined(separator: ":")
        return (url.path, identity, true)
    }

    public func contains(root: String, candidate: String) throws -> Bool {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(prefix)
    }
}

public actor ProjectAuthority {
    public let projectID: UUID
    private var snapshotValue: ProjectSnapshot
    private let rootsByID: [UUID: CanonicalRoot]

    public init(snapshot: ProjectSnapshot, roots: [CanonicalRoot]) {
        projectID = snapshot.projectID
        snapshotValue = snapshot
        rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.snapshot.rootID, $0) })
    }

    public func snapshot() -> ProjectSnapshot {
        snapshotValue
    }

    public func root(rootID: UUID) throws -> CanonicalRoot {
        guard let root = rootsByID[rootID] else { throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root") }
        return root
    }

    public func roots() -> [CanonicalRoot] {
        rootsByID.values.sorted { $0.snapshot.logicalName < $1.snapshot.logicalName }
    }

    public func authorize(rootID: UUID, logicalPath: String, filesystem: any FilesystemAuthorityPort) throws -> String {
        guard let root = rootsByID[rootID] else { throw ServiceAPIError(code: .rootUnauthorized, message: "Unknown project root") }
        guard !logicalPath.hasPrefix("/") else { throw ServiceAPIError(code: .rootUnauthorized, message: "Logical paths must be relative") }
        let currentRoot = try filesystem.canonicalizeRoot(root.snapshot.canonicalPath)
        guard currentRoot.path == root.snapshot.canonicalPath, currentRoot.identity == root.filesystemIdentity else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Authorized project root identity changed")
        }
        let candidate = logicalPath.isEmpty
            ? root.snapshot.canonicalPath
            : URL(fileURLWithPath: root.snapshot.canonicalPath).appendingPathComponent(logicalPath).path
        guard try filesystem.contains(root: root.snapshot.canonicalPath, candidate: candidate) else { throw ServiceAPIError(code: .rootUnauthorized, message: "Path escapes the authorized root") }
        return URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public actor ProjectRuntimeSupervisor {
    private var projects: [UUID: ProjectAuthority] = [:]

    public init() {}
    public func install(_ project: ProjectAuthority) async {
        projects[project.projectID] = project
    }

    public func remove(projectID: UUID) {
        projects[projectID] = nil
    }

    public func authority(projectID: UUID) throws -> ProjectAuthority {
        guard let project = projects[projectID] else { throw ServiceAPIError(code: .notFound, message: "Project not found") }
        return project
    }

    public func snapshots() async -> [ProjectSnapshot] {
        var result: [ProjectSnapshot] = []
        for project in projects.values {
            await result.append(project.snapshot())
        }
        return result.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
    }
}
