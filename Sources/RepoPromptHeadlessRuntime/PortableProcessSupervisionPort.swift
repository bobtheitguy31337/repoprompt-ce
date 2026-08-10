import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptLinuxSupport
import RepoPromptServiceProtocol

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public actor PortableProcessSupervisionPort: ProcessSupervisionPort {
    public struct CapturedProcess: Sendable {
        public let identity: ProcessIdentity
        public let stdoutPath: String
        public let stderrPath: String
    }

    private var processes: [Int32: Process] = [:]
    private var identities: [Int32: ProcessIdentity] = [:]
    private var standardInputs: [Int32: FileHandle] = [:]
    private var cgroupPaths: [Int32: String] = [:]
    private let bootID: String
    private let delegatedCgroupRoot: String?

    public init(cgroupRoot: String? = ProcessInfo.processInfo.environment["REPOPROMPT_PROVIDER_CGROUP_ROOT"]) throws {
        #if os(Linux)
            guard rp_enable_child_subreaper() == 0 else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Unable to enable Linux child subreaper")
            }
            bootID = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown-linux-boot"
            delegatedCgroupRoot = Self.validatedCgroupV2Root(cgroupRoot)
        #else
            bootID = "darwin-\(ProcessInfo.processInfo.systemUptime)"
            delegatedCgroupRoot = nil
        #endif
    }

    public func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity {
        try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdin: FileHandle.nullDevice, stdout: FileHandle.nullDevice, stderr: FileHandle.nullDevice)
    }

    public func launchCaptured(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, outputDirectory: String) async throws -> CapturedProcess {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let stdoutPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stdout").path
        let stderrPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stderr").path
        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        let stdout = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        do {
            let identity = try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdin: FileHandle.nullDevice, stdout: stdout, stderr: stderr)
            return CapturedProcess(identity: identity, stdoutPath: stdoutPath, stderrPath: stderrPath)
        } catch {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(atPath: stdoutPath)
            try? FileManager.default.removeItem(atPath: stderrPath)
            throw error
        }
    }

    /// Launches a bidirectional provider protocol while retaining the same
    /// subreaper/process-family identity and captured-output guarantees.
    public func launchInteractiveCaptured(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, outputDirectory: String) async throws -> CapturedProcess {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let stdoutPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stdout").path
        let stderrPath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(id).stderr").path
        FileManager.default.createFile(atPath: stdoutPath, contents: nil)
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        let stdout = try FileHandle(forWritingTo: URL(fileURLWithPath: stdoutPath))
        let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: stderrPath))
        let input = Pipe()
        #if os(Linux)
            _ = Glibc.signal(SIGPIPE, SIG_IGN)
        #else
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        do {
            let identity = try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdin: input, stdout: stdout, stderr: stderr)
            standardInputs[identity.pid] = input.fileHandleForWriting
            return CapturedProcess(identity: identity, stdoutPath: stdoutPath, stderrPath: stderrPath)
        } catch {
            try? input.fileHandleForWriting.close()
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(atPath: stdoutPath)
            try? FileManager.default.removeItem(atPath: stderrPath)
            throw error
        }
    }

    public func write(_ data: Data, to captured: CapturedProcess) throws {
        guard let input = standardInputs[captured.identity.pid] else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol input is closed")
        }
        try input.write(contentsOf: data)
    }

    public func capturedOutput(_ captured: CapturedProcess, after offset: Int, maximumBytes: Int) throws -> (data: Data, nextOffset: Int, running: Bool) {
        let contents = try Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath))
        guard offset <= contents.count else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider output stream was truncated")
        }
        let end = min(contents.count, offset + max(1, maximumBytes))
        return (Data(contents[offset ..< end]), end, processes[captured.identity.pid]?.isRunning == true)
    }

    public func closeInput(_ captured: CapturedProcess) {
        try? standardInputs.removeValue(forKey: captured.identity.pid)?.close()
    }

    public func cleanupCapturedFiles(_ captured: CapturedProcess) {
        try? FileManager.default.removeItem(atPath: captured.stdoutPath)
        try? FileManager.default.removeItem(atPath: captured.stderrPath)
    }

    public func waitForCapturedProcess(
        _ captured: CapturedProcess,
        maximumBytes: Int,
        onOutput: (@Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        guard let process = processes[captured.identity.pid] else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process record is missing") }
        while process.isRunning {
            try Task.checkCancellation()
            if let onOutput,
               let data = try? Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath)),
               !data.isEmpty
            {
                await onOutput(String(decoding: data.prefix(max(1, maximumBytes)), as: UTF8.self))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Polling `isRunning` above has already made Foundation observe the
        // child's termination. A second `waitUntilExit()` can deadlock when
        // several Process instances terminate close together because
        // Foundation's shared child-status source has already consumed it.
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
        let stdout = (try? Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath))) ?? Data()
        let stderr = (try? Data(contentsOf: URL(fileURLWithPath: captured.stderrPath))) ?? Data()
        if let onOutput, !stdout.isEmpty {
            await onOutput(String(decoding: stdout.prefix(max(1, maximumBytes)), as: UTF8.self))
        }
        try? FileManager.default.removeItem(atPath: captured.stdoutPath)
        try? FileManager.default.removeItem(atPath: captured.stderrPath)
        try await reap(pid: captured.identity.pid)
        guard process.terminationStatus == 0 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider command failed: \(String(decoding: stderr.prefix(8192), as: UTF8.self))")
        }
        return String(decoding: stdout.prefix(max(1, maximumBytes)), as: UTF8.self)
    }

    private func launchProcess(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, stdin: Any, stdout: FileHandle, stderr: FileHandle) async throws -> ProcessIdentity {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider executable is unavailable") }
        let process = Process()
        #if os(Linux)
            if FileManager.default.isExecutableFile(atPath: "/usr/bin/setsid") {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
                process.arguments = [executable] + arguments
            } else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Linux setsid executable is required for isolated provider process groups")
            }
        #else
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        #endif
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // Provider processes receive an explicit allowlist assembled by the
        // runtime. Never inherit service signing keys, database credentials,
        // Docker endpoints, or unrelated host secrets.
        var launchEnvironment = environment
        launchEnvironment["REPOPROMPT_HELPER_TOKEN"] = helperToken
        process.environment = launchEnvironment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let pid = process.processIdentifier
        processes[pid] = process
        try attachToDelegatedCgroupIfAvailable(pid: pid, helperToken: helperToken)
        let digest = CanonicalSigning.bodyDigest(Data(helperToken.utf8))
        #if !os(Linux)
            let observed = ProcessIdentity(pid: pid, parentPID: getpid(), processGroupID: getpgid(pid), sessionID: getsid(pid), startTimeTicks: UInt64(ProcessInfo.processInfo.systemUptime * 100), bootID: bootID, executablePath: executable, helperTokenDigest: digest)
            identities[pid] = observed
            return observed
        #else
            for _ in 0 ..< 100 {
                if let observed = try await inspectLinux(pid: pid, helperTokenDigest: digest) {
                    identities[pid] = observed
                    return observed
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            process.terminate()
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process did not establish a verifiable identity")
        #endif
    }

    public func inspect(pid: Int32) async throws -> ProcessIdentity? {
        try await inspectLinux(pid: pid, helperTokenDigest: identities[pid]?.helperTokenDigest ?? "")
    }

    public func descendants(of pid: Int32) async throws -> [ProcessIdentity] {
        #if os(Linux)
            guard let expectedDigest = identities[pid]?.helperTokenDigest, !expectedDigest.isEmpty else { return [] }
            let proc = try FileManager.default.contentsOfDirectory(atPath: "/proc").compactMap(Int32.init)
            var result: [ProcessIdentity] = []
            for candidate in proc where candidate != pid {
                if let identity = try? await inspectLinux(pid: candidate, helperTokenDigest: expectedDigest) {
                    result.append(identity)
                }
            }
            return result
        #else
            return []
        #endif
    }

    public func signal(_ signal: Int32, processGroupID: Int32, verifiedMembers: [ProcessIdentity]) async throws {
        guard !verifiedMembers.isEmpty else { return }
        for expected in verifiedMembers {
            guard try await inspect(pid: expected.pid) == expected else { throw ServiceAPIError(code: .staleRevision, message: "Process identity changed before signaling") }
        }
        guard systemKill(-processGroupID, signal) == 0 || errno == ESRCH else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Unable to signal provider process group") }
    }

    public func terminateContainedFamily(leader: ProcessIdentity) async throws -> Bool {
        #if os(Linux)
            guard let path = cgroupPaths[leader.pid] else { return false }
            let killFile = URL(fileURLWithPath: path).appendingPathComponent("cgroup.kill").path
            guard FileManager.default.isWritableFile(atPath: killFile) else { return false }
            try Data("1\n".utf8).write(to: URL(fileURLWithPath: killFile))
            return true
        #else
            return false
        #endif
    }

    public func reap(pid: Int32) async throws {
        // Foundation owns the wait status for every child launched through
        // `Process`. Reaping it with waitpid, or redundantly waiting after
        // `isRunning` observed exit, can leave another Process blocked.
        if processes[pid] == nil {
            var status: Int32 = 0
            _ = rp_waitpid_nohang(pid, &status)
        }
        processes[pid] = nil
        identities[pid] = nil
        try? standardInputs.removeValue(forKey: pid)?.close()
        if let cgroup = cgroupPaths.removeValue(forKey: pid) { try? FileManager.default.removeItem(atPath: cgroup) }
        try reapAdoptedChildren()
    }

    public func reapAdoptedChildren() throws {
        #if os(Linux)
            var status: Int32 = 0
            while rp_waitpid_nohang(-1, &status) > 0 {}
        #endif
    }

    private func inspectLinux(pid: Int32, helperTokenDigest: String) async throws -> ProcessIdentity? {
        #if os(Linux)
            guard let statLine = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let stat = ProcStatParser.parse(statLine) else { return nil }
            let executable = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")) ?? ""
            let actualHelperDigest = try helperTokenDigest(pid: pid)
            guard helperTokenDigest.isEmpty || actualHelperDigest == helperTokenDigest else { return nil }
            return ProcessIdentity(pid: stat.pid, parentPID: stat.parentPID, processGroupID: stat.processGroupID, sessionID: stat.sessionID, startTimeTicks: stat.startTimeTicks, bootID: bootID, executablePath: executable, helperTokenDigest: actualHelperDigest)
        #else
            guard let identity = identities[pid], processes[pid]?.isRunning == true else { return nil }
            return identity
        #endif
    }

    private func helperTokenDigest(pid: Int32) throws -> String {
        #if os(Linux)
            let environment = try Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/environ"))
            let prefix = Data("REPOPROMPT_HELPER_TOKEN=".utf8)
            for entry in environment.split(separator: 0) where entry.starts(with: prefix) {
                return CanonicalSigning.bodyDigest(Data(entry.dropFirst(prefix.count)))
            }
            return ""
        #else
            return identities[pid]?.helperTokenDigest ?? ""
        #endif
    }

    private func systemKill(_ pid: Int32, _ signal: Int32) -> Int32 {
        #if os(Linux)
            Glibc.kill(pid, signal)
        #else
            Darwin.kill(pid, signal)
        #endif
    }

    private func attachToDelegatedCgroupIfAvailable(pid: Int32, helperToken: String) throws {
        #if os(Linux)
            guard let delegatedCgroupRoot else { return }
            let safeToken = helperToken.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
            let path = URL(fileURLWithPath: delegatedCgroupRoot, isDirectory: true).appendingPathComponent("run-\(safeToken)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                try Data("\(pid)\n".utf8).write(to: path.appendingPathComponent("cgroup.procs"))
                cgroupPaths[pid] = path.path
            } catch {
                try? FileManager.default.removeItem(at: path)
                // Lack of delegation is an expected deployment mode. The
                // subreaper + verified ancestry/PGID path remains authoritative.
            }
        #endif
    }

    private static func validatedCgroupV2Root(_ configured: String?) -> String? {
        #if os(Linux)
            guard let configured, !configured.isEmpty else { return nil }
            let root = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("cgroup.controllers").path),
                  FileManager.default.isWritableFile(atPath: root)
            else { return nil }
            return root
        #else
            return nil
        #endif
    }
}
