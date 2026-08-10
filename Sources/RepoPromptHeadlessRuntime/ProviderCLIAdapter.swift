import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public struct ProviderCLIConfiguration: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let executable: String

    public init(kind: ProviderKind, executable: String) {
        self.kind = kind
        self.executable = executable
    }
}

public actor ProviderCLIAdapter {
    private let configurations: [ProviderKind: ProviderCLIConfiguration]
    private let runner: any WorkspaceCommandRunning
    private let processPort: PortableProcessSupervisionPort?
    private let processSupervisor: ProviderProcessSupervisor?
    private let outputDirectory: String

    public init(configurations: [ProviderCLIConfiguration], runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(), processPort: PortableProcessSupervisionPort? = nil, processStore: SQLiteServiceStore? = nil, outputDirectory: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-output").path) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.kind, $0) })
        self.runner = runner
        self.processPort = processPort
        processSupervisor = processPort.map { ProviderProcessSupervisor(processPort: $0, store: processStore) }
        self.outputDirectory = outputDirectory
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
                _ = try await runner.run(executable: configuration.executable, arguments: ["--version"], workingDirectory: FileManager.default.currentDirectoryPath, maximumBytes: 65_536)
                results.append(capability)
            } catch {
                results.append(ProviderCapability(kind: capability.kind, enabled: false, executable: capability.executable, supportsResume: capability.supportsResume, supportsSteering: capability.supportsSteering, reasonUnavailable: "provider preflight failed"))
            }
        }
        return results
    }

    public func complete(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int = 8_388_608) async throws -> String {
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
        let runID = UUID()
        let helperToken = runID.uuidString
        let captured = try await processPort.launchCaptured(executable: configuration.executable, arguments: arguments, environment: [:], workingDirectory: workingDirectory, helperToken: helperToken, outputDirectory: outputDirectory)
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
}
