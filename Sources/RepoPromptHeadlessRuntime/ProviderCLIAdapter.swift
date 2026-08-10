import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public struct ProviderCLIConfiguration: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let executable: String
    public let expectedVersion: String?
    public let protocolVersion: String?
    public let credentialSourceDirectory: String?

    public init(kind: ProviderKind, executable: String, expectedVersion: String? = nil, protocolVersion: String? = nil, credentialSourceDirectory: String? = nil) {
        self.kind = kind
        self.executable = executable
        self.expectedVersion = expectedVersion
        self.protocolVersion = protocolVersion
        self.credentialSourceDirectory = credentialSourceDirectory
    }
}

public actor ProviderCLIAdapter {
    private let configurations: [ProviderKind: ProviderCLIConfiguration]
    private let runner: any WorkspaceCommandRunning
    private let processPort: PortableProcessSupervisionPort?
    private let processSupervisor: ProviderProcessSupervisor?
    private let outputDirectory: String
    private let ephemeralHomeRoot: String

    public init(configurations: [ProviderCLIConfiguration], runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(), processPort: PortableProcessSupervisionPort? = nil, processStore: SQLiteServiceStore? = nil, outputDirectory: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-output").path, ephemeralHomeRoot: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-homes").path) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.kind, $0) })
        self.runner = runner
        self.processPort = processPort
        processSupervisor = processPort.map { ProviderProcessSupervisor(processPort: $0, store: processStore) }
        self.outputDirectory = outputDirectory
        self.ephemeralHomeRoot = ephemeralHomeRoot
    }

    public func recoverProcessFamilies() async throws {
        try await processSupervisor?.recoverPersistedFamilies()
    }

    public func capabilities() -> [ProviderCapability] {
        ProviderKind.allCases.map { kind in
            guard let configuration = configurations[kind] else {
                return ProviderCapability(kind: kind, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "not configured")
            }
            let executable = FileManager.default.isExecutableFile(atPath: configuration.executable)
            return ProviderCapability(
                kind: kind,
                enabled: executable,
                executable: executable ? configuration.executable : nil,
                supportsResume: kind == .codex || kind == .claudeCompatible,
                supportsSteering: kind != .mcp,
                version: configuration.expectedVersion,
                protocolVersion: configuration.protocolVersion,
                reasonUnavailable: executable ? nil : "configured binary is not executable"
            )
        }
    }

    public func preflight() async -> [ProviderCapability] {
        var results: [ProviderCapability] = []
        for capability in capabilities() {
            guard capability.enabled, let configuration = configurations[capability.kind] else {
                results.append(capability)
                continue
            }
            do {
                let output = try await runner.run(executable: configuration.executable, arguments: ["--version"], workingDirectory: FileManager.default.currentDirectoryPath, maximumBytes: 65_536)
                let reported = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let expected = configuration.expectedVersion, reported?.contains(expected) != true {
                    results.append(ProviderCapability(kind: capability.kind, enabled: false, executable: capability.executable, supportsResume: capability.supportsResume, supportsSteering: capability.supportsSteering, version: reported, protocolVersion: capability.protocolVersion, reasonUnavailable: "provider version does not match the pinned image contract"))
                } else {
                    results.append(ProviderCapability(kind: capability.kind, enabled: true, executable: capability.executable, supportsResume: capability.supportsResume, supportsSteering: capability.supportsSteering, version: reported ?? configuration.expectedVersion, protocolVersion: capability.protocolVersion))
                }
            } catch {
                results.append(ProviderCapability(kind: capability.kind, enabled: false, executable: capability.executable, supportsResume: capability.supportsResume, supportsSteering: capability.supportsSteering, version: configuration.expectedVersion, protocolVersion: capability.protocolVersion, reasonUnavailable: "provider preflight failed"))
            }
        }
        return results
    }

    public func complete(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int = 8_388_608, runID requestedRunID: UUID? = nil) async throws -> String {
        guard let configuration = configurations[kind], FileManager.default.isExecutableFile(atPath: configuration.executable) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Requested provider is not installed")
        }
        let arguments: [String]
        switch kind {
        case .codex:
            arguments = ["exec", "--skip-git-repo-check", "--color", "never"] + (model.map { ["--model", $0] } ?? []) + [prompt]
        case .claudeCompatible:
            arguments = ["--print", "--output-format", "text"] + (model.map { ["--model", $0] } ?? []) + [prompt]
        case .openCodeACP:
            arguments = ["run"] + (model.map { ["--model", $0] } ?? []) + [prompt]
        case .cursorACP:
            arguments = ["--print"] + (model.map { ["--model", $0] } ?? []) + [prompt]
        case .headlessAdapter, .mcp:
            throw ServiceAPIError(code: .capabilityMissing, message: "Requested provider kind cannot execute a CLI workflow directly")
        }
        guard let processPort, let processSupervisor else {
            return try await runner.run(executable: configuration.executable, arguments: arguments, workingDirectory: workingDirectory, maximumBytes: maximumBytes)
        }
        let runID = requestedRunID ?? UUID()
        let helperToken = runID.uuidString
        let home = try prepareEphemeralHome(runID: runID, configuration: configuration)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config", isDirectory: true).path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache", isDirectory: true).path,
            "DISABLE_AUTOUPDATER": "1",
            "CURSOR_AGENT_DISABLE_AUTO_UPDATE": "1"
        ]
        let captured = try await processPort.launchCaptured(executable: configuration.executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, helperToken: helperToken, outputDirectory: outputDirectory)
        try await processSupervisor.register(runID: runID, leader: captured.identity)
        do {
            let output = try await withTaskCancellationHandler {
                try await processPort.waitForCapturedProcess(captured, maximumBytes: maximumBytes)
            } onCancel: {
                Task { try? await processSupervisor.cancel(runID: runID) }
            }
            await processSupervisor.forget(runID: runID)
            return output
        } catch {
            if !(error is CancellationError) { await processSupervisor.forget(runID: runID) }
            throw error
        }
    }

    private func prepareEphemeralHome(runID: UUID, configuration: ProviderCLIConfiguration) throws -> URL {
        let root = URL(fileURLWithPath: ephemeralHomeRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
        if let sourcePath = configuration.credentialSourceDirectory {
            let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Configured provider credential source is unavailable")
            }
            try FileManager.default.copyItem(at: source, to: home)
        } else {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cache", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }
}
