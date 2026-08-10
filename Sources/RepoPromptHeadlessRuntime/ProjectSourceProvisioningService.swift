import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public struct ProjectSourcePolicy: Sendable {
    public struct ConfiguredRoot: Codable, Hashable, Sendable {
        public let alias: String
        public let path: String
        public let writable: Bool

        public init(alias: String, path: String, writable: Bool) {
            self.alias = alias
            self.path = path
            self.writable = writable
        }
    }

    public struct RemoteRule: Codable, Hashable, Sendable {
        public let scheme: String
        public let host: String
        public let pathPrefix: String

        public init(scheme: String, host: String, pathPrefix: String) {
            self.scheme = scheme
            self.host = host
            self.pathPrefix = pathPrefix
        }
    }

    private struct Document: Decodable {
        struct Git: Decodable {
            let remoteRules: [RemoteRule]
            let allowedRefPatterns: [String]
            let deniedRefPatterns: [String]
            let maximumCloneBytes: Int64
            let maximumCloneSeconds: Int
            let maximumConcurrentClones: Int
            let maximumOutputBytes: Int
        }

        let schemaVersion: Int
        let configuredRoots: [ConfiguredRoot]
        let git: Git
    }

    public let configuredRoots: [String: ConfiguredRoot]
    public let remoteRules: [RemoteRule]
    public let allowedRefPatterns: [NSRegularExpression]
    public let deniedRefPatterns: [NSRegularExpression]
    public let maximumCloneBytes: Int64
    public let maximumCloneSeconds: Int
    public let maximumConcurrentClones: Int
    public let maximumOutputBytes: Int

    public static let disabled = ProjectSourcePolicy(
        configuredRoots: [:],
        remoteRules: [],
        allowedRefPatterns: [],
        deniedRefPatterns: [],
        maximumCloneBytes: 1_073_741_824,
        maximumCloneSeconds: 60,
        maximumConcurrentClones: 1,
        maximumOutputBytes: 65_536
    )

    public static func decode(_ data: Data) throws -> Self {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw ServiceAPIError(code: .invalidRequest, message: "Project source policy is invalid")
        }
        guard document.schemaVersion == 1,
              (1_048_576 ... 10_737_418_240).contains(document.git.maximumCloneBytes),
              (1 ... 900).contains(document.git.maximumCloneSeconds),
              (1 ... 8).contains(document.git.maximumConcurrentClones),
              (4_096 ... 1_048_576).contains(document.git.maximumOutputBytes)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Project source policy bounds are invalid")
        }

        var roots: [String: ConfiguredRoot] = [:]
        for root in document.configuredRoots {
            let pathComponents = root.path.split(separator: "/", omittingEmptySubsequences: false)
            guard Self.safeAlias(root.alias), root.path.hasPrefix("/"), URL(fileURLWithPath: root.path).standardizedFileURL.path == root.path,
                  !root.path.contains("\\"), !pathComponents.contains(where: { $0 == "." || $0 == ".." }),
                  root.path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  roots[root.alias] == nil
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "Configured project root policy is invalid")
            }
            roots[root.alias] = root
        }

        let remoteRules = try document.git.remoteRules.map { rule in
            let scheme = rule.scheme.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let host = rule.host.lowercased()
            let prefix = try Self.normalizedPathPrefix(rule.pathPrefix)
            guard ["https", "ssh"].contains(scheme), Self.safeHost(host) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Git remote policy is invalid")
            }
            return RemoteRule(scheme: scheme, host: host, pathPrefix: prefix)
        }
        guard Set(remoteRules).count == remoteRules.count else {
            throw ServiceAPIError(code: .invalidRequest, message: "Git remote policy contains duplicates")
        }

        func expressions(_ patterns: [String]) throws -> [NSRegularExpression] {
            try patterns.map { pattern in
                guard !pattern.isEmpty, pattern.utf8.count <= 512 else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Git ref policy is invalid")
                }
                do { return try NSRegularExpression(pattern: pattern) } catch {
                    throw ServiceAPIError(code: .invalidRequest, message: "Git ref policy is invalid")
                }
            }
        }

        return ProjectSourcePolicy(
            configuredRoots: roots,
            remoteRules: remoteRules,
            allowedRefPatterns: try expressions(document.git.allowedRefPatterns),
            deniedRefPatterns: try expressions(document.git.deniedRefPatterns),
            maximumCloneBytes: document.git.maximumCloneBytes,
            maximumCloneSeconds: document.git.maximumCloneSeconds,
            maximumConcurrentClones: document.git.maximumConcurrentClones,
            maximumOutputBytes: document.git.maximumOutputBytes
        )
    }

    public func capabilities() -> ProjectSourceCapabilities {
        ProjectSourceCapabilities(
            gitRemoteRules: remoteRules.map {
                ProjectSourceCapabilities.GitRemoteRule(scheme: $0.scheme, host: $0.host, pathPrefix: $0.pathPrefix)
            },
            gitCloneEnabled: !remoteRules.isEmpty
        )
    }

    fileprivate func authorizedRemote(_ remote: String) throws -> String {
        let normalized = try Self.normalizedRemote(remote)
        guard remoteRules.contains(where: {
            $0.scheme == normalized.scheme && $0.host == normalized.host && normalized.path.hasPrefix($0.pathPrefix)
        }) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Git remote is not approved")
        }
        return normalized.value
    }

    fileprivate func authorizeRef(_ ref: String) throws {
        guard ref.utf8.count <= 256, ref.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil,
              !ref.contains(".."), !ref.contains("@{"), !ref.contains("//"), !ref.hasSuffix("/"), !ref.hasSuffix("."),
              !ref.split(separator: "/").contains(where: { $0.hasSuffix(".lock") })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Git ref is invalid")
        }
        let range = NSRange(ref.startIndex ..< ref.endIndex, in: ref)
        func matchesEntire(_ expression: NSRegularExpression) -> Bool {
            expression.firstMatch(in: ref, range: range)?.range == range
        }
        guard !deniedRefPatterns.contains(where: matchesEntire),
              allowedRefPatterns.isEmpty || allowedRefPatterns.contains(where: matchesEntire)
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Git ref is not approved")
        }
    }

    private init(
        configuredRoots: [String: ConfiguredRoot],
        remoteRules: [RemoteRule],
        allowedRefPatterns: [NSRegularExpression],
        deniedRefPatterns: [NSRegularExpression],
        maximumCloneBytes: Int64,
        maximumCloneSeconds: Int,
        maximumConcurrentClones: Int,
        maximumOutputBytes: Int
    ) {
        self.configuredRoots = configuredRoots
        self.remoteRules = remoteRules
        self.allowedRefPatterns = allowedRefPatterns
        self.deniedRefPatterns = deniedRefPatterns
        self.maximumCloneBytes = maximumCloneBytes
        self.maximumCloneSeconds = maximumCloneSeconds
        self.maximumConcurrentClones = maximumConcurrentClones
        self.maximumOutputBytes = maximumOutputBytes
    }

    private static func safeAlias(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    private static func safeHost(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$", options: .regularExpression) != nil
            && !value.contains("..")
    }

    private static func normalizedPathPrefix(_ value: String) throws -> String {
        guard value.hasPrefix("/"), value.utf8.count <= 1024, !value.contains("\\"), !value.contains("%") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Git remote path policy is invalid")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Git remote path policy is invalid")
        }
        return "/" + components.joined(separator: "/") + "/"
    }

    private static func normalizedRemote(_ value: String) throws -> (scheme: String, host: String, path: String, value: String) {
        guard value.utf8.count <= 2_048, let components = URLComponents(string: value),
              let rawScheme = components.scheme, let rawHost = components.host,
              components.query == nil, components.fragment == nil, components.password == nil
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Git remote is invalid")
        }
        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        guard ["https", "ssh"].contains(scheme), safeHost(host),
              (scheme == "ssh" ? components.user == nil || components.user == "git" : components.user == nil),
              components.port == nil || (scheme == "https" && components.port == 443) || (scheme == "ssh" && components.port == 22),
              !components.percentEncodedPath.contains("%"), !components.path.contains("\\")
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Git remote is invalid")
        }
        let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count >= 2,
              !pathComponents.contains(where: { $0 == "." || $0 == ".." }),
              pathComponents.allSatisfy({ $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil })
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Git remote is invalid")
        }
        let path = "/" + pathComponents.joined(separator: "/")
        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host
        normalized.user = components.user
        normalized.path = path
        guard let normalizedValue = normalized.url?.absoluteString else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Git remote is invalid")
        }
        return (scheme, host, path + "/", normalizedValue)
    }
}

public struct ProjectSourceGitCredentials: Sendable {
    public let sshPrivateKeyPath: String?
    public let sshKnownHostsPath: String?

    public init(sshPrivateKeyPath: String? = nil, sshKnownHostsPath: String? = nil) throws {
        func validated(_ path: String?) throws -> String? {
            guard let path, !path.isEmpty else { return nil }
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard path.hasPrefix("/"), path.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil,
                  values?.isRegularFile == true, values?.isSymbolicLink != true
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "Runtime Git credential configuration is invalid")
            }
            return path
        }
        self.sshPrivateKeyPath = try validated(sshPrivateKeyPath)
        self.sshKnownHostsPath = try validated(sshKnownHostsPath)
        guard (self.sshPrivateKeyPath == nil) == (self.sshKnownHostsPath == nil) else {
            throw ServiceAPIError(code: .invalidRequest, message: "SSH key and known-hosts mounts must be configured together")
        }
    }
}

public struct ProjectSourceGitInvocation: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let outputPath: String
    public let observedDirectory: String
    public let maximumOutputBytes: Int
    public let maximumDirectoryBytes: Int64
    public let timeoutSeconds: Int
}

public protocol ProjectSourceGitRunning: Sendable {
    func run(_ invocation: ProjectSourceGitInvocation) async throws -> String
}

final class ManagedProjectSourceProcess: @unchecked Sendable {
    private let lock = NSLock()

    #if os(Linux)
    private var supervisorPID: pid_t = 0
    private var statusDescriptor: Int32 = -1
    private var controlDescriptor: Int32 = -1
    private var gitStatus: Int32?
    private var releaseRequested = false
    private var supervisorReaped = false
    private var controlCommandsSent = 0
    #else
    private var process: Process?
    private var processGroup: pid_t?
    private var leaderReaped = false
    #endif

    deinit {
        #if os(Linux)
        if statusDescriptor >= 0 { close(statusDescriptor) }
        if controlDescriptor >= 0 { close(controlDescriptor) }
        #endif
    }

    #if os(Linux)
    func activateSupervisor(pid: pid_t, statusDescriptor: Int32, controlDescriptor: Int32) {
        lock.lock()
        supervisorPID = pid
        self.statusDescriptor = statusDescriptor
        self.controlDescriptor = controlDescriptor
        lock.unlock()
    }
    #else
    func prepare(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func activateProcessGroup(_ processGroup: pid_t?) {
        lock.lock()
        self.processGroup = processGroup
        lock.unlock()
    }
    #endif

    func signal(_ signal: Int32) {
        #if os(Linux)
        let isKill = signal == SIGKILL
        let command: UInt8 = isKill
            ? UInt8(RP_ANCHORED_COMMAND_KILL)
            : UInt8(RP_ANCHORED_COMMAND_TERM)
        lock.lock()
        if !supervisorReaped, controlDescriptor >= 0, !releaseRequested || isKill {
            if isKill, supervisorPID > 1 {
                // The unreaped direct child PID cannot be reused. SIGCONT makes
                // a stopped anchor consume the queued group-KILL command; Swift
                // never sends a signal to a numeric Linux process group.
                _ = kill(supervisorPID, SIGCONT)
            }
            if rp_anchored_process_send_command(controlDescriptor, command) == 0 {
                controlCommandsSent += 1
            }
        }
        lock.unlock()
        #else
        lock.lock()
        let process = self.process
        let processGroup = self.processGroup
        let processID = process?.processIdentifier ?? 0
        let leaderRunning = process?.isRunning == true
        lock.unlock()
        if leaderRunning, let processGroup, processGroup > 1,
           kill(-processGroup, signal) == 0 || errno == EPERM
        {
            return
        }
        if leaderRunning, processID > 1 { _ = kill(processID, signal) }
        #endif
    }

    func isRunning() -> Bool {
        terminationStatus() == nil
    }

    func terminationTargetExists() -> Bool {
        #if os(Linux)
        return pollSupervisorReap() == false
        #else
        lock.lock()
        let running = process?.isRunning == true
        lock.unlock()
        return running
        #endif
    }

    func terminationStatus() -> Int32? {
        #if os(Linux)
        lock.lock()
        if let gitStatus {
            lock.unlock()
            return gitStatus
        }
        let descriptor = statusDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return nil }
        var status: Int32 = 0
        let result = rp_anchored_process_poll_status(descriptor, &status)
        guard result != 0 else { return nil }
        lock.lock()
        if result == 1 {
            gitStatus = status
        } else {
            gitStatus = 127
        }
        let resolved = gitStatus
        lock.unlock()
        return resolved
        #else
        lock.lock()
        guard let process, !process.isRunning else {
            lock.unlock()
            return nil
        }
        if !leaderReaped {
            process.waitUntilExit()
            leaderReaped = true
        }
        let status = process.terminationStatus
        lock.unlock()
        return status
        #endif
    }

    func releaseSupervisor() -> Bool {
        #if os(Linux)
        lock.lock()
        guard !releaseRequested, !supervisorReaped, controlDescriptor >= 0 else {
            let released = releaseRequested
            lock.unlock()
            return released
        }
        let result = rp_anchored_process_send_command(
            controlDescriptor,
            UInt8(RP_ANCHORED_COMMAND_RELEASE)
        )
        if result == 0 {
            releaseRequested = true
            controlCommandsSent += 1
        }
        lock.unlock()
        return result == 0
        #else
        return true
        #endif
    }

    #if os(Linux)
    var testSupervisorProcessID: pid_t {
        lock.lock(); defer { lock.unlock() }
        return supervisorPID
    }

    var testControlCommandsSent: Int {
        lock.lock(); defer { lock.unlock() }
        return controlCommandsSent
    }

    private func pollSupervisorReap() -> Bool {
        lock.lock()
        if supervisorReaped {
            lock.unlock()
            return true
        }
        let pid = supervisorPID
        lock.unlock()
        guard pid > 1 else { return true }
        var status: Int32 = 0
        let result = rp_anchored_process_poll_reap(pid, &status)
        guard result != 0 else { return false }
        lock.lock()
        if !supervisorReaped {
            supervisorReaped = true
            if statusDescriptor >= 0 { close(statusDescriptor); statusDescriptor = -1 }
            if controlDescriptor >= 0 { close(controlDescriptor); controlDescriptor = -1 }
        }
        lock.unlock()
        return true
    }
    #endif
}

public struct LocalProjectSourceGitRunner: ProjectSourceGitRunning {
    public init() {}

    public func run(_ invocation: ProjectSourceGitInvocation) async throws -> String {
        let lifecycle = ManagedProjectSourceProcess()
        return try await withTaskCancellationHandler(operation: {
            do {
                return try await Self.execute(invocation, lifecycle: lifecycle)
            } catch {
                await Self.terminateAndReap(lifecycle)
                throw error
            }
        }, onCancel: {
            lifecycle.signal(SIGTERM)
        })
    }

    private static func execute(
        _ invocation: ProjectSourceGitInvocation,
        lifecycle: ManagedProjectSourceProcess
    ) async throws -> String {
            let manager = FileManager.default
            guard manager.isExecutableFile(atPath: invocation.executable) else {
                throw ServiceAPIError(code: .capabilityMissing, message: "Git executable is unavailable")
            }
            guard manager.createFile(atPath: invocation.outputPath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Git output staging could not be created")
            }
            defer { try? manager.removeItem(atPath: invocation.outputPath) }
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
            defer { try? output.close() }

            #if os(Linux)
            try spawnLinuxSupervisor(
                invocation,
                outputDescriptor: output.fileDescriptor,
                lifecycle: lifecycle
            )
            #else
            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
            process.environment = invocation.environment
            process.currentDirectoryURL = URL(fileURLWithPath: invocation.workingDirectory)
            process.standardOutput = output
            process.standardError = output
            lifecycle.prepare(process)
            try Task.checkCancellation()
            do { try process.run() } catch {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Git source operation could not start")
            }
            let processID = process.processIdentifier
            lifecycle.activateProcessGroup(setpgid(processID, processID) == 0 ? processID : nil)
            #endif
            try Task.checkCancellation()

            let deadline = Date().addingTimeInterval(TimeInterval(invocation.timeoutSeconds))
            while lifecycle.isRunning() {
                let now = Date()
                if now >= deadline
                    || Self.fileSize(invocation.outputPath) > Int64(invocation.maximumOutputBytes)
                    || Self.directorySize(invocation.observedDirectory, limit: invocation.maximumDirectoryBytes) > invocation.maximumDirectoryBytes
                {
                    await terminateAndReap(lifecycle)
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Git source operation exceeded a configured limit")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let terminationStatus = lifecycle.terminationStatus() else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Git source operation did not terminate cleanly")
            }
            try output.synchronize()
            guard Self.fileSize(invocation.outputPath) <= Int64(invocation.maximumOutputBytes),
                  Self.directorySize(invocation.observedDirectory, limit: invocation.maximumDirectoryBytes) <= invocation.maximumDirectoryBytes
            else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Git source operation exceeded a configured limit")
            }
            guard terminationStatus == 0 else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Git source operation failed")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: invocation.outputPath), options: [.mappedIfSafe])
            guard lifecycle.releaseSupervisor(),
                  await waitForTerminationTargetExit(lifecycle, timeout: .seconds(2))
            else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Git process supervisor could not be released")
            }
            return String(decoding: data, as: UTF8.self)
    }

    private static func terminateAndReap(_ lifecycle: ManagedProjectSourceProcess) async {
        lifecycle.signal(SIGTERM)
        if !(await waitForTerminationTargetExit(lifecycle, timeout: .milliseconds(500))) {
            lifecycle.signal(SIGKILL)
            _ = await waitForTerminationTargetExit(lifecycle, timeout: .seconds(2))
        }
        _ = lifecycle.terminationStatus()
    }

    private static func waitForTerminationTargetExit(
        _ lifecycle: ManagedProjectSourceProcess,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while lifecycle.terminationTargetExists(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !lifecycle.terminationTargetExists()
    }

    #if os(Linux)
    static func spawnLinuxSupervisor(
        _ invocation: ProjectSourceGitInvocation,
        outputDescriptor: Int32,
        lifecycle: ManagedProjectSourceProcess
    ) throws {
        let argumentBlob = try nullTerminatedBlob(invocation.arguments)
        let environmentBlob = try nullTerminatedBlob(
            invocation.environment.keys.sorted().map { "\($0)=\(invocation.environment[$0] ?? "")" }
        )
        var supervisorPID: pid_t = 0
        var statusDescriptor: Int32 = -1
        var controlDescriptor: Int32 = -1
        let spawnResult = invocation.executable.withCString { executable in
            invocation.workingDirectory.withCString { workingDirectory in
                argumentBlob.withUnsafeBytes { arguments in
                    environmentBlob.withUnsafeBytes { environment in
                        rp_anchored_process_spawn(
                            executable,
                            arguments.bindMemory(to: CChar.self).baseAddress,
                            arguments.count,
                            environment.bindMemory(to: CChar.self).baseAddress,
                            environment.count,
                            workingDirectory,
                            outputDescriptor,
                            &supervisorPID,
                            &statusDescriptor,
                            &controlDescriptor
                        )
                    }
                }
            }
        }
        guard spawnResult == 0 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Git source operation could not start")
        }
        lifecycle.activateSupervisor(
            pid: supervisorPID,
            statusDescriptor: statusDescriptor,
            controlDescriptor: controlDescriptor
        )
    }
    #endif

    private static func nullTerminatedBlob(_ values: [String]) throws -> Data {
        var data = Data()
        for value in values {
            guard !value.utf8.contains(0) else {
                throw ServiceAPIError(code: .invalidRequest, message: "Git invocation contains an invalid value")
            }
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        return data
    }

    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directorySize(_ path: String, limit: Int64) -> Int64 {
        guard FileManager.default.fileExists(atPath: path),
              let enumerator = FileManager.default.enumerator(
                  at: URL(fileURLWithPath: path),
                  includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
                  options: []
              )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            if total > limit { break }
        }
        return total
    }
}

public actor ProjectSourceProvisioningService {
    private struct ConfiguredRootAuthority: Sendable {
        let configuration: ProjectSourcePolicy.ConfiguredRoot
        let canonicalPath: String
        let filesystemIdentity: String
    }

    private let cloneRoot: String
    private let cloneRootIdentity: String
    private let pinnedCloneRoot: PinnedFilesystemRoot
    private let policy: ProjectSourcePolicy
    private let configuredRoots: [String: ConfiguredRootAuthority]
    private let credentials: ProjectSourceGitCredentials
    private let resources: any OwnedResourceRepository
    private let filesystem: any FilesystemAuthorityPort
    private let git: any ProjectSourceGitRunning
    private let gitExecutable = "/usr/bin/git"
    private var activeClones = 0

    public init(
        cloneRoot: String,
        policy: ProjectSourcePolicy,
        credentials: ProjectSourceGitCredentials,
        resources: any OwnedResourceRepository,
        filesystem: any FilesystemAuthorityPort = LocalFilesystemAuthority(),
        git: any ProjectSourceGitRunning = LocalProjectSourceGitRunner()
    ) throws {
        self.policy = policy
        self.credentials = credentials
        self.resources = resources
        self.filesystem = filesystem
        self.git = git
        guard !policy.remoteRules.contains(where: { $0.scheme == "ssh" })
                || (credentials.sshPrivateKeyPath != nil && credentials.sshKnownHostsPath != nil)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "SSH Git policy requires runtime identity and known-hosts mounts")
        }
        let standardizedCloneRoot = URL(fileURLWithPath: cloneRoot).standardizedFileURL.path
        let canonical = try filesystem.canonicalizeRoot(standardizedCloneRoot)
        guard canonical.path == standardizedCloneRoot, !Self.isSymbolicLink(standardizedCloneRoot) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project clone root must not be a symbolic link")
        }
        self.cloneRoot = canonical.path
        cloneRootIdentity = canonical.identity
        pinnedCloneRoot = try PinnedFilesystemRoot(path: canonical.path, identity: canonical.identity)
        configuredRoots = try Dictionary(uniqueKeysWithValues: policy.configuredRoots.map { alias, configuration in
            let standardized = URL(fileURLWithPath: configuration.path).standardizedFileURL.path
            let root = try filesystem.canonicalizeRoot(standardized)
            guard root.path == standardized, !Self.isSymbolicLink(standardized) else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project root is unsafe")
            }
            return (alias, ConfiguredRootAuthority(
                configuration: configuration,
                canonicalPath: root.path,
                filesystemIdentity: root.identity
            ))
        })
    }

    public func capabilities() -> ProjectSourceCapabilities {
        policy.capabilities()
    }

    public func projectWorkspaceDirectory(projectID: UUID) throws -> String {
        try validateImmutableCloneRoot()
        let workspaceParent = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: URL(fileURLWithPath: cloneRoot).appendingPathComponent(".project-workspaces").path
        )
        let workspace = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: URL(fileURLWithPath: workspaceParent).appendingPathComponent(projectID.uuidString).path
        )
        for path in [workspaceParent, workspace] {
            guard !Self.isSymbolicLink(path) else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Managed project workspace is unsafe")
            }
            if !FileManager.default.fileExists(atPath: path) {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            }
        }
        let canonical = try filesystem.canonicalizeRoot(workspace)
        guard canonical.path == workspace,
              try filesystem.contains(root: cloneRoot, candidate: canonical.path),
              !Self.isSymbolicLink(workspace)
        else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Managed project workspace escaped its configured volume")
        }
        return canonical.path
    }

    public func provisionRepository(
        input: AddProjectRepositoryInput,
        operationID: UUID,
        projectID: UUID,
        rootID: UUID
    ) async throws -> CanonicalRoot {
        let logicalName = input.logicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.schemaVersion == 1, input.expectedRevision >= 1,
              !logicalName.isEmpty, logicalName.utf8.count <= 128,
              logicalName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Repository addition is invalid")
        }
        let workspace = try projectWorkspaceDirectory(projectID: projectID)
        let repositories = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: URL(fileURLWithPath: workspace).appendingPathComponent("repositories").path
        )
        guard !Self.isSymbolicLink(repositories) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Managed repository directory is unsafe")
        }
        if !FileManager.default.fileExists(atPath: repositories) {
            try FileManager.default.createDirectory(atPath: repositories, withIntermediateDirectories: false)
        }
        let final = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: URL(fileURLWithPath: repositories).appendingPathComponent(rootID.uuidString).path
        )
        let internalInput = ProjectSourceOperationInput(
            operationID: operationID,
            expectedRevision: 0,
            name: "managed-workspace",
            logicalName: logicalName,
            source: .gitClone(remote: input.source.remote, ref: input.source.ref)
        )
        return try await clone(
            input: internalInput,
            projectID: projectID,
            rootID: rootID,
            remote: input.source.remote,
            ref: input.source.ref,
            resourceExternalID: rootID,
            finalPath: final
        )
    }

    public func provision(
        input: ProjectSourceOperationInput,
        projectID: UUID,
        rootID: UUID
    ) async throws -> CanonicalRoot {
        try validate(input)
        switch input.source {
        case let .configuredRoot(alias):
            guard let configured = configuredRoots[alias] else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project root alias is not approved")
            }
            let canonical = try filesystem.canonicalizeRoot(configured.canonicalPath)
            guard canonical.path == configured.canonicalPath,
                  canonical.identity == configured.filesystemIdentity,
                  !Self.isSymbolicLink(configured.canonicalPath)
            else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project root is unsafe")
            }
            return CanonicalRoot(
                snapshot: ProjectRootSnapshot(
                    rootID: rootID,
                    logicalName: input.logicalName,
                    canonicalPath: canonical.path,
                    writable: configured.configuration.writable
                ),
                filesystemIdentity: canonical.identity
            )
        case let .gitClone(remote, ref):
            return try await clone(input: input, projectID: projectID, rootID: rootID, remote: remote, ref: ref)
        }
    }

    public func abandonProvisionedClone(projectID: UUID) async {
        await abandonProvisionedClone(externalID: projectID)
    }

    public func abandonProvisionedRepository(rootID: UUID) async {
        await abandonProvisionedClone(externalID: rootID)
    }

    private func abandonProvisionedClone(externalID: UUID) async {
        guard let record = try? await resources.ownedResource(externalID: externalID, kind: .cloneStaging),
              record.lifecycleState != .active
        else { return }
        var cleanupFailed = false
        for path in [record.temporaryPathIdentity, record.internalPathIdentity].compactMap({ $0 })
            where FileManager.default.fileExists(atPath: path)
        {
            do { try cleanup(path: path) } catch { cleanupFailed = true }
        }
        _ = try? await resources.transitionOwnedResource(
            resourceID: record.resourceID,
            expectedStates: [.preparing, .prepared, .cleanupPending, .quarantined],
            to: cleanupFailed ? .quarantined : .failed,
            observedBytes: nil,
            contentDigest: nil,
            cleanupError: cleanupFailed ? "project_source_cleanup_failed" : "project_source_abandoned"
        )
    }

    private func clone(
        input: ProjectSourceOperationInput,
        projectID: UUID,
        rootID: UUID,
        remote: String,
        ref: String,
        resourceExternalID: UUID? = nil,
        finalPath: String? = nil
    ) async throws -> CanonicalRoot {
        guard activeClones < policy.maximumConcurrentClones else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Project clone concurrency limit is active")
        }
        activeClones += 1
        defer { activeClones -= 1 }

        let normalizedRemote = try policy.authorizedRemote(remote)
        try policy.authorizeRef(ref)
        try validateImmutableCloneRoot()

        let stagingParent = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: URL(fileURLWithPath: cloneRoot).appendingPathComponent(".source-staging").path
        )
        let operationDirectory = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: URL(fileURLWithPath: stagingParent).appendingPathComponent(input.operationID.uuidString).path
        )
        let checkout = try DurableFilesystem.standardizedContainedPath(
            root: operationDirectory,
            candidate: URL(fileURLWithPath: operationDirectory).appendingPathComponent("checkout").path
        )
        let final = try DurableFilesystem.standardizedContainedPath(
            root: cloneRoot,
            candidate: finalPath ?? URL(fileURLWithPath: cloneRoot).appendingPathComponent(projectID.uuidString).path
        )
        let output = try DurableFilesystem.standardizedContainedPath(
            root: operationDirectory,
            candidate: URL(fileURLWithPath: operationDirectory).appendingPathComponent("git-output").path
        )
        let reservation = OwnedResourceRecord(
            kind: .cloneStaging,
            projectID: projectID,
            externalID: resourceExternalID ?? projectID,
            internalPathIdentity: final,
            temporaryPathIdentity: operationDirectory,
            lifecycleState: .preparing,
            metadata: ["operationId": input.operationID.uuidString, "resourceKind": "project_source_v1"],
            retentionDeadline: Date().addingTimeInterval(15 * 60)
        )
        try await resources.reserveOwnedResource(reservation)
        do {
            guard !FileManager.default.fileExists(atPath: final), !FileManager.default.fileExists(atPath: operationDirectory) else {
                throw ServiceAPIError(code: .worktreeConflict, message: "Project source destination is already reserved")
            }
            try FileManager.default.createDirectory(atPath: operationDirectory, withIntermediateDirectories: true)
            guard try filesystem.contains(root: cloneRoot, candidate: operationDirectory),
                  !Self.isSymbolicLink(stagingParent), !Self.isSymbolicLink(operationDirectory)
            else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Project source staging path is unsafe")
            }
            let environment = gitEnvironment()
            _ = try await git.run(ProjectSourceGitInvocation(
                executable: gitExecutable,
                arguments: secureGitPrefix() + [
                    "clone", "--no-recurse-submodules", "--single-branch", "--no-tags", "--branch", ref, "--", normalizedRemote, checkout
                ],
                environment: environment,
                workingDirectory: cloneRoot,
                outputPath: output,
                observedDirectory: operationDirectory,
                maximumOutputBytes: policy.maximumOutputBytes,
                maximumDirectoryBytes: policy.maximumCloneBytes,
                timeoutSeconds: policy.maximumCloneSeconds
            ))
            guard !Self.isSymbolicLink(checkout), !Self.isSymbolicLink(URL(fileURLWithPath: checkout).appendingPathComponent(".git").path) else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Cloned project root is unsafe")
            }
            let top = try await gitText(["-C", checkout, "rev-parse", "--show-toplevel"], at: operationDirectory)
            guard URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath().path == checkout else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Cloned Git root validation failed")
            }
            let origin = try await gitText(["-C", checkout, "remote", "get-url", "origin"], at: operationDirectory)
            guard try policy.authorizedRemote(origin) == normalizedRemote else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Cloned Git origin validation failed")
            }
            let commit = try await gitText(["-C", checkout, "rev-parse", "--verify", "HEAD^{commit}"], at: operationDirectory)
            guard commit.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Cloned Git revision validation failed")
            }
            _ = try await gitText(["-C", checkout, "status", "--porcelain=v1", "--untracked-files=no"], at: operationDirectory)
            guard Self.directorySize(operationDirectory, limit: policy.maximumCloneBytes) <= policy.maximumCloneBytes else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Project clone exceeds its byte limit")
            }

            try validateImmutableCloneRoot()
            try pinnedCloneRoot.moveAtomically(from: checkout, to: final)
            if FileManager.default.fileExists(atPath: operationDirectory) {
                try pinnedCloneRoot.removeTree(at: operationDirectory)
            }
            let canonical = try filesystem.canonicalizeRoot(final)
            guard try filesystem.contains(root: cloneRoot, candidate: canonical.path) else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Promoted project root escaped its configured volume")
            }
            _ = try await resources.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing],
                to: .prepared,
                observedBytes: Self.directorySize(final, limit: policy.maximumCloneBytes),
                contentDigest: nil,
                cleanupError: nil
            )
            return CanonicalRoot(
                snapshot: ProjectRootSnapshot(
                    rootID: rootID,
                    logicalName: input.logicalName,
                    canonicalPath: canonical.path,
                    writable: true
                ),
                filesystemIdentity: canonical.identity
            )
        } catch {
            var cleanupFailed = false
            for path in [operationDirectory, final] where FileManager.default.fileExists(atPath: path) {
                do { try cleanup(path: path) } catch { cleanupFailed = true }
            }
            _ = try? await resources.transitionOwnedResource(
                resourceID: reservation.resourceID,
                expectedStates: [.preparing, .prepared],
                to: cleanupFailed ? .quarantined : .failed,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: cleanupFailed ? "project_source_cleanup_failed" : "project_source_failed"
            )
            if let serviceError = error as? ServiceAPIError { throw serviceError }
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Project source operation failed")
        }
    }

    private func gitText(_ arguments: [String], at operationDirectory: String) async throws -> String {
        let outputPath = try DurableFilesystem.standardizedContainedPath(
            root: operationDirectory,
            candidate: URL(fileURLWithPath: operationDirectory).appendingPathComponent("git-output-" + UUID().uuidString).path
        )
        let output = try await git.run(ProjectSourceGitInvocation(
            executable: gitExecutable,
            arguments: secureGitPrefix() + arguments,
            environment: gitEnvironment(),
            workingDirectory: cloneRoot,
            outputPath: outputPath,
            observedDirectory: operationDirectory,
            maximumOutputBytes: policy.maximumOutputBytes,
            maximumDirectoryBytes: policy.maximumCloneBytes,
            timeoutSeconds: min(policy.maximumCloneSeconds, 30)
        ))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func secureGitPrefix() -> [String] {
        [
            "-c", "core.hooksPath=/dev/null",
            "-c", "protocol.file.allow=never",
            "-c", "submodule.recurse=false",
            "-c", "fetch.recurseSubmodules=false"
        ]
    }

    private func gitEnvironment() -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/nonexistent",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_PROTOCOL_FROM_USER": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_ALLOW_PROTOCOL": Set(policy.remoteRules.map(\.scheme)).sorted().joined(separator: ":")
        ]
        if let key = credentials.sshPrivateKeyPath, let knownHosts = credentials.sshKnownHostsPath {
            environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -F /dev/null -oBatchMode=yes -oIdentitiesOnly=yes -oStrictHostKeyChecking=yes -oUserKnownHostsFile=\(knownHosts) -i\(key)"
        }
        return environment
    }

    private func validate(_ input: ProjectSourceOperationInput) throws {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let logicalName = input.logicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.schemaVersion == 1,
              !name.isEmpty, name.utf8.count <= 200,
              !logicalName.isEmpty, logicalName.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              logicalName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Project source operation is invalid")
        }
        guard input.expectedRevision == 0 else {
            throw ServiceAPIError(code: .staleRevision, message: "Project source operation revision is stale", currentRevision: 0)
        }
    }

    private func validateImmutableCloneRoot() throws {
        let current = try filesystem.canonicalizeRoot(cloneRoot)
        guard current.path == cloneRoot, current.identity == cloneRootIdentity, !Self.isSymbolicLink(cloneRoot) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Configured project clone root identity changed")
        }
    }

    private func cleanup(path: String) throws {
        try validateImmutableCloneRoot()
        guard try filesystem.contains(root: cloneRoot, candidate: path), !Self.isSymbolicLink(path) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project source cleanup path is unsafe")
        }
        try pinnedCloneRoot.removeTree(at: path)
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func directorySize(_ path: String, limit: Int64) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            if total > limit { break }
        }
        return total
    }
}
