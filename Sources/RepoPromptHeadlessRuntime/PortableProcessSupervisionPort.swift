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
    private let bootID: String

    public init() throws {
        #if os(Linux)
        guard rp_enable_child_subreaper() == 0 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Unable to enable Linux child subreaper")
        }
        bootID = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown-linux-boot"
        #else
        bootID = "darwin-\(ProcessInfo.processInfo.systemUptime)"
        #endif
    }

    public func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity {
        try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdout: FileHandle.nullDevice, stderr: FileHandle.nullDevice)
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
            let identity = try await launchProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, stdout: stdout, stderr: stderr)
            return CapturedProcess(identity: identity, stdoutPath: stdoutPath, stderrPath: stderrPath)
        } catch {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(atPath: stdoutPath)
            try? FileManager.default.removeItem(atPath: stderrPath)
            throw error
        }
    }

    public func waitForCapturedProcess(_ captured: CapturedProcess, maximumBytes: Int) async throws -> String {
        guard let process = processes[captured.identity.pid] else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider process record is missing") }
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        process.waitUntilExit()
        try? (process.standardOutput as? FileHandle)?.close()
        try? (process.standardError as? FileHandle)?.close()
        let stdout = (try? Data(contentsOf: URL(fileURLWithPath: captured.stdoutPath))) ?? Data()
        let stderr = (try? Data(contentsOf: URL(fileURLWithPath: captured.stderrPath))) ?? Data()
        try? FileManager.default.removeItem(atPath: captured.stdoutPath)
        try? FileManager.default.removeItem(atPath: captured.stderrPath)
        try await reap(pid: captured.identity.pid)
        guard process.terminationStatus == 0 else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider command failed: \(String(decoding: stderr.prefix(8192), as: UTF8.self))")
        }
        return String(decoding: stdout.prefix(max(1, maximumBytes)), as: UTF8.self)
    }

    private func launchProcess(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String, stdout: FileHandle, stderr: FileHandle) async throws -> ProcessIdentity {
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
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in configured }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let pid = process.processIdentifier
        processes[pid] = process
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
        let proc = try FileManager.default.contentsOfDirectory(atPath: "/proc").compactMap(Int32.init)
        var observed: [Int32: ProcessIdentity] = [:]
        for candidate in proc {
            if let identity = try await inspectLinux(pid: candidate, helperTokenDigest: identities[pid]?.helperTokenDigest ?? "") { observed[candidate] = identity }
        }
        var result: [ProcessIdentity] = []
        var frontier = [pid]
        while let parent = frontier.popLast() {
            for identity in observed.values where identity.parentPID == parent && !result.contains(identity) {
                result.append(identity)
                frontier.append(identity.pid)
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

    public func reap(pid: Int32) async throws {
        var status: Int32 = 0
        _ = rp_waitpid_nohang(pid, &status)
        if let process = processes[pid], !process.isRunning { process.waitUntilExit() }
        processes[pid] = nil
        identities[pid] = nil
        try reapAdoptedChildren()
    }

    public func reapAdoptedChildren() throws {
        var status: Int32 = 0
        while rp_waitpid_nohang(-1, &status) > 0 {}
    }

    private func inspectLinux(pid: Int32, helperTokenDigest: String) async throws -> ProcessIdentity? {
        #if os(Linux)
        guard let statLine = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let stat = ProcStatParser.parse(statLine) else { return nil }
        let executable = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")) ?? ""
        return ProcessIdentity(pid: stat.pid, parentPID: stat.parentPID, processGroupID: stat.processGroupID, sessionID: stat.sessionID, startTimeTicks: stat.startTimeTicks, bootID: bootID, executablePath: executable, helperTokenDigest: helperTokenDigest)
        #else
        guard let identity = identities[pid], processes[pid]?.isRunning == true else { return nil }
        return identity
        #endif
    }

    private func systemKill(_ pid: Int32, _ signal: Int32) -> Int32 {
        #if os(Linux)
        Glibc.kill(pid, signal)
        #else
        Darwin.kill(pid, signal)
        #endif
    }
}
