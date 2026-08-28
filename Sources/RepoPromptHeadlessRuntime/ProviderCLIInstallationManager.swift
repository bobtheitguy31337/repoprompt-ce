import Foundation
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public actor ProviderCLIInstallationManager: ProviderCLIInstallationManaging {
    private let executable: String
    private let runner: any WorkspaceCommandRunning

    public init(
        executable: String,
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner()
    ) {
        self.executable = executable
        self.runner = runner
    }

    public func restoreSelected() async throws {
        _ = try await runner.run(
            executable: executable,
            arguments: ["restore"],
            workingDirectory: FileManager.default.currentDirectoryPath,
            maximumBytes: 65_536
        )
    }

    public func install(providerID: ProviderSettingsID) async throws {
        try await run("install", providerID: providerID)
    }

    public func update(providerID: ProviderSettingsID) async throws {
        try await run("update", providerID: providerID)
    }

    public func uninstall(providerID: ProviderSettingsID) async throws {
        try await run("uninstall", providerID: providerID)
    }

    private func run(_ action: String, providerID: ProviderSettingsID) async throws {
        guard providerID.ownsRuntimeAdmission,
              !providerID.isDirectAPI,
              providerID.runtimeKind != nil
        else {
            throw ServiceAPIError(code: .capabilityMissing, message: "This provider has no installable CLI runtime")
        }
        _ = try await runner.run(
            executable: executable,
            arguments: [action, providerID.rawValue],
            workingDirectory: FileManager.default.currentDirectoryPath,
            maximumBytes: 65_536
        )
    }
}
