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

enum ProviderCLIProbeEnvironment {
    static func prepare(for kind: ProviderKind) throws -> [String: String] {
        let manager = FileManager.default
        let home = manager.temporaryDirectory
            .appendingPathComponent("repoprompt-provider-probes", isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)
        let config = home.appendingPathComponent(".config", isDirectory: true)
        let cache = home.appendingPathComponent(".cache", isDirectory: true)
        let data = home.appendingPathComponent(".local/share", isDirectory: true)
        for directory in [home, config, cache, data] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return [
            "HOME": home.path,
            "XDG_CONFIG_HOME": config.path,
            "XDG_CACHE_HOME": cache.path,
            "XDG_DATA_HOME": data.path,
            "DISABLE_AUTOUPDATER": "1",
            "CURSOR_AGENT_DISABLE_AUTO_UPDATE": "1"
        ]
    }
}

/// Provider-neutral runtime router. Provider protocol knowledge lives in the
/// individual native runtime controllers, never in this dispatcher.
public actor PortableAgentProviderDispatcher: AgentProviderDispatcher, InteractionDeliveryPort {
    private let runtimes: [ProviderKind: any AgentProviderRuntime]
    private let cataloguedConfigurations: [ProviderKind: ProviderCLIConfiguration]
    private var enabledProviders: Set<ProviderKind>
    private var runtimeDefaults: [ProviderKind: ProviderRuntimeDefaults]
    private var knownRuns: [UUID: ProviderKind] = [:]

    public init(runtimes: [any AgentProviderRuntime], cataloguedConfigurations: [ProviderCLIConfiguration] = [], enabledProviders: Set<ProviderKind>? = nil) {
        let initialEnabled = enabledProviders ?? Set(runtimes.map(\.kind))
        self.runtimes = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.kind, $0) })
        self.cataloguedConfigurations = Dictionary(uniqueKeysWithValues: cataloguedConfigurations.map { ($0.kind, $0) })
        self.enabledProviders = initialEnabled
        runtimeDefaults = Dictionary(uniqueKeysWithValues: runtimes.map {
            ($0.kind, ProviderRuntimeDefaults(enabled: initialEnabled.contains($0.kind)))
        })
    }

    public func capabilities() async -> [ProviderCapability] {
        var values: [ProviderCapability] = []
        for kind in ProviderKind.allCases {
            if enabledProviders.contains(kind), let runtime = runtimes[kind] {
                await values.append(runtime.capability())
            } else {
                values.append(unavailableCapability(for: kind))
            }
        }
        return values
    }

    public func preflight() async -> [ProviderCapability] {
        var values: [ProviderCapability] = []
        for kind in ProviderKind.allCases {
            if enabledProviders.contains(kind), let runtime = runtimes[kind] {
                await values.append(runtime.preflight())
            } else {
                values.append(unavailableCapability(for: kind))
            }
        }
        return values
    }

    public func recoverProcessFamilies() async throws {
        for runtime in runtimes.values {
            try await runtime.recoverProcessFamilies()
        }
    }

    public func applyRuntimeDefaults(kind: ProviderKind, defaults: ProviderRuntimeDefaults) throws {
        guard runtimes[kind] != nil, cataloguedConfigurations.isEmpty || cataloguedConfigurations[kind] != nil else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider is not configured")
        }
        runtimeDefaults[kind] = defaults
        if defaults.enabled {
            enabledProviders.insert(kind)
        } else {
            // Existing runs retain their native controller. New admission is
            // rejected immediately without terminating in-flight work.
            enabledProviders.remove(kind)
        }
    }

    public func execute(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int, runID: UUID?, resumeProviderSessionID: String?, onProviderSessionIdentity: @escaping @Sendable (String) async -> Void) async throws -> ProviderExecutionResult {
        let actualRunID = runID ?? UUID()
        return try await executeStreaming(.init(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, maximumBytes: maximumBytes, runID: actualRunID, resumeProviderSessionID: resumeProviderSessionID)) { event in
            if case let .providerIdentity(identity) = event { await onProviderSessionIdentity(identity) }
        }
    }

    public func executeStreaming(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        guard enabledProviders.contains(request.kind), let runtime = runtimes[request.kind] else {
            let message = cataloguedConfigurations[request.kind] == nil
                ? "Requested provider is not configured"
                : "Requested provider is administratively disabled"
            throw ServiceAPIError(code: .providerUnavailable, message: message)
        }
        knownRuns[request.runID] = request.kind
        let defaults = runtimeDefaults[request.kind] ?? ProviderRuntimeDefaults(enabled: true)
        return try await runtime.execute(request.applying(defaults: defaults), onEvent: onEvent)
    }

    public func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws {
        guard let runtime = await runtime(containing: runID) else {
            throw ServiceAPIError(code: .notFound, message: "Active provider run was not found")
        }
        for _ in 0 ..< 100 {
            if await runtime.hasActiveRun(runID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await runtime.hasActiveRun(runID) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider run did not become ready for steering")
        }
        try await runtime.steer(runID: runID, text: text, targetTurnEpoch: targetTurnEpoch)
    }

    public func cancel(runID: UUID) async throws {
        guard let runtime = await runtime(containing: runID) else { return }
        try await runtime.interrupt(runID: runID)
    }

    public func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let runtime = await runtime(containing: runID) else {
            throw ServiceAPIError(code: .notFound, message: "Active provider run was not found")
        }
        try await runtime.deliverInteraction(runID: runID, providerRequestID: providerRequestID, answer: answer)
    }

    public func deliverAnswer(session _: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws {
        guard let runID = interaction.runID,
              let payload = try? JSONDecoder().decode(ProviderInteractionPayload.self, from: interaction.payload)
        else { throw ServiceAPIError(code: .interactionSettled, message: "Provider interaction delivery metadata is unavailable") }
        try await deliverInteraction(runID: runID, providerRequestID: payload.providerRequestID, answer: answer)
    }

    public func prepareRun(kind: ProviderKind, runID: UUID) {
        knownRuns[runID] = kind
    }

    public func forgetRun(runID: UUID) {
        knownRuns[runID] = nil
    }

    private func runtime(containing runID: UUID) async -> (any AgentProviderRuntime)? {
        if let kind = knownRuns[runID], let runtime = runtimes[kind] { return runtime }
        for runtime in runtimes.values where await runtime.hasActiveRun(runID) {
            return runtime
        }
        return nil
    }

    private func unavailableCapability(for kind: ProviderKind) -> ProviderCapability {
        guard let configuration = cataloguedConfigurations[kind] else {
            return .init(kind: kind, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "not configured")
        }
        return .init(
            kind: kind,
            enabled: false,
            executable: configuration.executable,
            supportsResume: false,
            supportsSteering: false,
            version: configuration.expectedVersion,
            protocolVersion: configuration.protocolVersion,
            reasonUnavailable: "administratively disabled"
        )
    }
}

/// Compatibility name retained for existing callers. Production construction
/// uses native controllers whenever a process supervision port is supplied.
public actor ProviderCLIAdapter: AgentProviderDispatcher, InteractionDeliveryPort {
    private let dispatcher: PortableAgentProviderDispatcher

    public init(configurations: [ProviderCLIConfiguration], enabledProviders: Set<ProviderKind>? = nil, runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(), processPort: PortableProcessSupervisionPort? = nil, processStore: SQLiteServiceStore? = nil, outputDirectory: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-output").path, ephemeralHomeRoot: String = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-provider-homes").path, credentialEnvironment: any ProviderProcessEnvironmentProviding = EmptyProviderProcessEnvironment(), credentialSource: (any ProviderCredentialSourceProviding)? = nil) {
        let enabledProviders = enabledProviders ?? Set(configurations.map(\.kind))
        let credentialSource = credentialSource ?? StaticProviderCredentialSource(configurations: configurations)
        let runtimes: [any AgentProviderRuntime] = if let processPort {
            configurations.map {
                NativeProviderRuntimeFactory.make(configuration: $0, processPort: processPort, processStore: processStore, outputDirectory: outputDirectory, ephemeralHomeRoot: ephemeralHomeRoot, credentialEnvironment: credentialEnvironment, credentialSource: credentialSource)
            }
        } else {
            // Kept only for deterministic unit tests and legacy embedded callers
            // that do not provide the process authority required by native protocols.
            configurations.map { CommandCompatibilityProviderRuntime(configuration: $0, runner: runner) }
        }
        dispatcher = PortableAgentProviderDispatcher(runtimes: runtimes, cataloguedConfigurations: configurations, enabledProviders: enabledProviders)
    }

    public init(runtimes: [any AgentProviderRuntime]) {
        dispatcher = PortableAgentProviderDispatcher(runtimes: runtimes)
    }

    public func capabilities() async -> [ProviderCapability] {
        await dispatcher.capabilities()
    }

    public func preflight() async -> [ProviderCapability] {
        await dispatcher.preflight()
    }

    public func recoverProcessFamilies() async throws {
        try await dispatcher.recoverProcessFamilies()
    }

    public func applyRuntimeDefaults(kind: ProviderKind, defaults: ProviderRuntimeDefaults) async throws {
        try await dispatcher.applyRuntimeDefaults(kind: kind, defaults: defaults)
    }

    public func cancel(runID: UUID) async throws {
        try await dispatcher.cancel(runID: runID)
    }

    public func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws {
        try await dispatcher.steer(runID: runID, text: text, targetTurnEpoch: targetTurnEpoch)
    }

    public func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        try await dispatcher.deliverInteraction(runID: runID, providerRequestID: providerRequestID, answer: answer)
    }

    public func deliverAnswer(session: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws {
        try await dispatcher.deliverAnswer(session: session, interaction: interaction, answer: answer)
    }

    public func prepareRun(kind: ProviderKind, runID: UUID) async {
        await dispatcher.prepareRun(kind: kind, runID: runID)
    }

    public func forgetRun(runID: UUID) async {
        await dispatcher.forgetRun(runID: runID)
    }

    public func execute(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int = 8_388_608, runID: UUID? = nil, resumeProviderSessionID: String? = nil, onProviderSessionIdentity: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ProviderExecutionResult {
        try await dispatcher.execute(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, maximumBytes: maximumBytes, runID: runID, resumeProviderSessionID: resumeProviderSessionID, onProviderSessionIdentity: onProviderSessionIdentity)
    }

    public func executeStreaming(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        try await dispatcher.executeStreaming(request, onEvent: onEvent)
    }
}

private actor CommandCompatibilityProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private let configuration: ProviderCLIConfiguration
    private let runner: any WorkspaceCommandRunning
    private var activeRuns: Set<UUID> = []

    init(configuration: ProviderCLIConfiguration, runner: any WorkspaceCommandRunning) {
        kind = configuration.kind
        self.configuration = configuration
        self.runner = runner
    }

    func capability() -> ProviderCapability {
        let executable = FileManager.default.isExecutableFile(atPath: configuration.executable)
        return .init(kind: kind, enabled: executable, executable: executable ? configuration.executable : nil, supportsResume: kind == .codex || kind == .claudeCompatible, supportsSteering: kind == .codex || kind == .claudeCompatible, version: configuration.expectedVersion, protocolVersion: configuration.protocolVersion, reasonUnavailable: executable ? nil : "configured binary is not executable")
    }

    func preflight() async -> ProviderCapability {
        let base = capability()
        guard base.enabled else { return base }
        do {
            let environment = try ProviderCLIProbeEnvironment.prepare(for: kind)
            let output = try await runner.run(
                executable: configuration.executable,
                arguments: ["--version"],
                workingDirectory: FileManager.default.currentDirectoryPath,
                maximumBytes: 65536,
                environment: environment
            )
            return .init(kind: kind, enabled: true, executable: configuration.executable, supportsResume: base.supportsResume, supportsSteering: base.supportsSteering, version: output.split(whereSeparator: \.isNewline).first.map(String.init), protocolVersion: configuration.protocolVersion)
        } catch {
            return .init(kind: kind, enabled: false, executable: configuration.executable, supportsResume: base.supportsResume, supportsSteering: base.supportsSteering, version: configuration.expectedVersion, protocolVersion: configuration.protocolVersion, reasonUnavailable: "provider compatibility preflight failed")
        }
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        activeRuns.insert(request.runID)
        defer { activeRuns.remove(request.runID) }
        let arguments = compatibilityArguments(request)
        let raw = try await runner.run(
            executable: configuration.executable,
            arguments: arguments,
            workingDirectory: request.workingDirectory,
            maximumBytes: request.maximumBytes,
            launchValidation: { try request.validateLaunch() }
        )
        let parsed = Self.parse(raw, kind: kind)
        if let identity = parsed.providerSessionID { await onEvent(.providerIdentity(identity)) }
        await onEvent(.assistantFinal(parsed.output))
        await onEvent(.completed(providerSessionID: parsed.providerSessionID))
        return parsed
    }

    func interrupt(runID _: UUID) async throws {}
    func steer(runID: UUID, text _: String, targetTurnEpoch _: Int64) async throws {
        guard activeRuns.contains(runID) else { throw ServiceAPIError(code: .notFound, message: "Compatibility run is not active") }
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        activeRuns.contains(runID)
    }

    private func compatibilityArguments(_ request: ProviderExecutionRequest) -> [String] {
        switch kind {
        case .codex:
            (request.resumeProviderSessionID.map { ["exec", "resume", "--json", "--skip-git-repo-check", $0] } ?? ["exec", "--json", "--skip-git-repo-check", "--color", "never"])
                + (request.model.map { ["--model", $0] } ?? []) + [request.prompt]
        case .claudeCompatible:
            ["--print", "--output-format", "stream-json", "--verbose"] + (request.resumeProviderSessionID.map { ["--resume", $0] } ?? []) + (request.model.map { ["--model", $0] } ?? []) + [request.prompt]
        case .openCodeACP: ["run", request.prompt]
        case .cursorACP: ["--print", request.prompt]
        case .headlessAdapter, .mcp: [request.prompt]
        }
    }

    private nonisolated static func parse(_ output: String, kind: ProviderKind) -> ProviderExecutionResult {
        guard kind == .codex || kind == .claudeCompatible else { return .init(output: output, providerSessionID: nil) }
        var providerSessionID: String?
        var finalText: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            providerSessionID = providerSessionID ?? object["thread_id"] as? String ?? object["session_id"] as? String
            if let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message" { finalText = item["text"] as? String ?? finalText }
            if object["type"] as? String == "result" { finalText = object["result"] as? String ?? finalText }
        }
        return .init(output: finalText ?? output, providerSessionID: providerSessionID)
    }
}
