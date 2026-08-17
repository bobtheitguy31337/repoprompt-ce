import Foundation
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

private enum AppDomainRuntimeMetrics {
    static let editFlowSink = DomainRuntimeMetricsSink { metric in
        let dimensions = EditFlowPerf.Dimensions(
            toolName: metric.dimensions["tool_name"],
            outcome: metric.dimensions["outcome"],
            queueDelayMicroseconds: metric.name == "mcp_domain_host_queue_wait"
                ? metric.dimensions["duration_microseconds"].flatMap(Int.init)
                : nil,
            durationMicroseconds: metric.name == "mcp_domain_host_execution"
                ? metric.dimensions["duration_microseconds"].flatMap(Int.init)
                : nil
        )
        switch metric.name {
        case "mcp_domain_host_queue_wait":
            EditFlowPerf.event(EditFlowPerf.Stage.MCPToolCall.domainHostQueueWait, dimensions)
        case "mcp_domain_host_execution":
            EditFlowPerf.event(EditFlowPerf.Stage.MCPToolCall.domainHostExecution, dimensions)
        default:
            break
        }
    }
}

/// App-process composition for the M2 workspace/context domain authority.
/// Read providers and protected mutations remain app-owned until later milestones.
final class AppDomainRuntimeComposition: Sendable {
    static let shared = AppDomainRuntimeComposition()

    private static let legacyRuntimeDefaultKeys = [
        "workspace.approvalSettings",
        "agentModeAutoEditEnabled"
    ]

    let runtime: MCPDomainRuntime

    static func collectLegacyRuntimeDefaults(from defaults: UserDefaults) -> [String: Data] {
        var collected: [String: Data] = [:]
        for key in legacyRuntimeDefaultKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                collected[key] = data
            } else if JSONSerialization.isValidJSONObject(["v": value]),
                      let data = try? JSONSerialization.data(
                          withJSONObject: value,
                          options: .fragmentsAllowed
                      )
            {
                collected[key] = data
            }
        }
        return collected
    }

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let defaults = UserDefaults.standard
        let customStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        var legacyRuntimeDefaults = Self.collectLegacyRuntimeDefaults(from: defaults)
        if let customStoragePath,
           let bytes = try? JSONEncoder().encode(customStoragePath)
        {
            legacyRuntimeDefaults["GlobalCustomStorageURL"] = bytes
        }
        let workspaceStorageDirectory = customStoragePath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? root.appendingPathComponent("Workspaces", isDirectory: true)
        runtime = MCPDomainRuntime(
            configuration: DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "default",
                storageDirectory: root,
                workspaceStorageDirectory: workspaceStorageDirectory,
                eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
                temporaryDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPrompt CE", isDirectory: true),
                legacyRuntimeDefaults: legacyRuntimeDefaults,
                metrics: AppDomainRuntimeMetrics.editFlowSink
            )
        )
    }
}

/// Process-lifetime owner of the same durable Agent authority used by the
/// direct MCP/server composition. AppKit view models receive only snapshots
/// and embedded-run leases; they never construct a session lifecycle store.
actor AppAgentAuthorityComposition {
    static let shared = AppAgentAuthorityComposition()

    private struct Prepared {
        let store: SQLiteServiceStore
        let authority: RepoPromptHeadlessAuthority
    }

    private var prepared: Prepared?
    private var preparationTask: Task<Prepared, Error>?

    func authority() async throws -> RepoPromptHeadlessAuthority {
        if let prepared { return prepared.authority }
        if let preparationTask {
            return try await preparationTask.value.authority
        }
        let task = Task<Prepared, Error> {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let root = applicationSupport
                .appendingPathComponent("RepoPrompt CE", isDirectory: true)
                .appendingPathComponent("AgentAuthority", isDirectory: true)
            let artifacts = root.appendingPathComponent("Artifacts", isDirectory: true)
            let providerOutput = root.appendingPathComponent("ProviderOutput", isDirectory: true)
            let providerHomes = root.appendingPathComponent("ProviderHomes", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let store = try await SQLiteServiceStore.open(
                storage: .file(root.appendingPathComponent("repoprompt.sqlite").path)
            )
            let processPort = try PortableProcessSupervisionPort()
            let providers = try ProviderCLIAdapter(
                configurations: Self.providerConfigurations(),
                processPort: processPort,
                processStore: store,
                outputDirectory: providerOutput.path,
                ephemeralHomeRoot: providerHomes.path
            )
            let authority = try RepoPromptHeadlessAuthority(
                store: store,
                artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path),
                providerAdapter: providers
            )
            try await authority.recover()
            return Prepared(store: store, authority: authority)
        }
        preparationTask = task
        do {
            let value = try await task.value
            prepared = value
            preparationTask = nil
            return value.authority
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func shutdown() async {
        preparationTask?.cancel()
        preparationTask = nil
        guard let prepared else { return }
        self.prepared = nil
        try? await prepared.authority.quiesce()
        try? await prepared.store.close(clean: true)
    }

    private static func providerConfigurations() throws -> [ProviderCLIConfiguration] {
        var result: [ProviderCLIConfiguration] = []
        if case let .success(runtime) = CodexRuntimeAuthority.resolve() {
            try runtime.prepareState()
            result.append(ProviderCLIConfiguration(
                kind: .codex,
                executable: runtime.executableURL.path,
                expectedVersion: runtime.version.description,
                protocolVersion: "codex-app-server",
                credentialSourceDirectory: existingDirectory(runtime.statePaths.codexHome.path)
            ))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let definitions: [(ProviderKind, String, String, [String], String?)] = [
            (
                .claudeCompatible,
                "REPOPROMPT_CLAUDE_EXECUTABLE",
                "claude",
                CLIPathHints.claudeCode,
                existingDirectory(home.appendingPathComponent(".claude", isDirectory: true).path)
            ),
            (
                .openCodeACP,
                "REPOPROMPT_OPENCODE_EXECUTABLE",
                "opencode",
                CLIPathHints.openCode,
                existingDirectory(home.appendingPathComponent(".config/opencode", isDirectory: true).path)
            ),
            (
                .cursorACP,
                "REPOPROMPT_CURSOR_EXECUTABLE",
                "cursor-agent",
                CLIPathHints.cursor,
                existingDirectory(home.appendingPathComponent(".cursor", isDirectory: true).path)
            ),
            (
                .grokBuildACP,
                "REPOPROMPT_GROK_EXECUTABLE",
                "grok",
                CLIPathHints.grokBuild,
                existingDirectory(home.appendingPathComponent(".grok", isDirectory: true).path)
            )
        ]
        for (kind, environmentKey, command, hints, credentials) in definitions {
            guard let executable = resolveExecutable(
                environmentKey: environmentKey,
                command: command,
                hints: hints
            ) else { continue }
            result.append(ProviderCLIConfiguration(
                kind: kind,
                executable: executable,
                credentialSourceDirectory: credentials
            ))
        }
        return result
    }

    private static func resolveExecutable(
        environmentKey: String,
        command: String,
        hints: [String]
    ) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment[environmentKey],
           explicit.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: explicit)
        {
            return URL(fileURLWithPath: explicit).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let searchDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            + hints
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(command)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return path
    }
}

/// Coalesces one shared registration task while preventing a late waiter from
/// clearing a newer attempt. Waiters observe the shared task's `Result`
/// directly, so cancelling a waiter does not misclassify the shared work.
@MainActor
final class SharedRegistrationAttempt<Value: Sendable> {
    struct Attempt {
        let id: UInt64
        let task: Task<Value, Error>
    }

    struct Completion {
        let result: Result<Value, Error>
        let wasCurrent: Bool
    }

    private var nextID: UInt64 = 0
    private(set) var current: Attempt?

    func start(
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) -> Attempt {
        precondition(current == nil, "Registration attempt already active")
        nextID &+= 1
        let attempt = Attempt(
            id: nextID,
            task: Task { @MainActor in
                try await operation()
            }
        )
        current = attempt
        return attempt
    }

    func complete(_ attempt: Attempt) async -> Completion {
        let result = await attempt.task.result
        let wasCurrent = current?.id == attempt.id
        if wasCurrent {
            current = nil
        }
        return Completion(result: result, wasCurrent: wasCurrent)
    }
}

/// Process-lifetime owner for application-scoped MCP services. Registration is
/// coalesced so app startup, readiness, and test fixtures all join the same work
/// and no caller receives a handle it could use to remove another caller's tools.
@MainActor
final class AppGlobalMCPServiceComposition {
    enum RegistrationStatus: Equatable {
        case idle
        case registering
        case registered
        case failed(String)

        var diagnosticDescription: String {
            switch self {
            case .idle:
                "idle"
            case .registering:
                "registering"
            case .registered:
                "registered"
            case let .failed(error):
                "failed(\(error))"
            }
        }
    }

    static let shared = AppGlobalMCPServiceComposition(
        runtime: AppDomainRuntimeComposition.shared.runtime,
        windowStates: .shared,
        networkManager: .shared
    )

    private struct RegistrationHandles {
        let appSettings: MCPDomainToolRegistrationHandle
        let windowRouting: MCPDomainToolRegistrationHandle
    }

    private let runtime: MCPDomainRuntime
    private let networkManager: ServerNetworkManager
    private let appSettingsService: AppSettingsMCPService
    private let windowRoutingService: WindowRoutingService
    private var registrationHandles: RegistrationHandles?
    private let registrationAttempt = SharedRegistrationAttempt<RegistrationHandles>()
    private var status: RegistrationStatus = .idle

    private init(
        runtime: MCPDomainRuntime,
        windowStates: WindowStatesManager,
        networkManager: ServerNetworkManager
    ) {
        self.runtime = runtime
        self.networkManager = networkManager
        appSettingsService = AppSettingsMCPService()
        windowRoutingService = WindowRoutingService(
            windowStates: windowStates,
            networkMgr: networkManager
        )
    }

    func registrationStatus() -> RegistrationStatus {
        status
    }

    func ensureRegistered() async throws {
        if let registrationHandles,
           await AppDomainRuntimeComposition.shared.isActive(registrationHandles.appSettings),
           await AppDomainRuntimeComposition.shared.isActive(registrationHandles.windowRouting)
        {
            await restoreAvailabilityPublicationIfNeeded()
            status = .registered
            return
        }

        if let attempt = registrationAttempt.current {
            try await finishRegistration(attempt)
            return
        }

        status = .registering
        let attempt = registrationAttempt.start {
            @MainActor [runtime, networkManager, appSettingsService, windowRoutingService] in
            try await runtime.start()
            _ = try await AppAgentAuthorityComposition.shared.authority()
            await windowRoutingService.prepareDomainTools()
            let appSettingsTools = await appSettingsService.tools
            let windowRoutingTools = await windowRoutingService.tools
            let requests = try [
                MCPDomainToolRegistrationRequest(
                    registrationID: appSettingsService.domainRegistrationID,
                    scope: .application,
                    bindings: appSettingsTools.map { try $0.domainBinding() }
                ),
                MCPDomainToolRegistrationRequest(
                    registrationID: windowRoutingService.domainRegistrationID,
                    scope: .application,
                    bindings: windowRoutingTools.map { try $0.domainBinding() }
                )
            ]
            let results = try await runtime.toolRegistry.registerAtomically(requests)
            if results.contains(where: { $0.disposition != .unchanged }) {
                ToolAvailabilityStore.shared.registerTools(appSettingsTools + windowRoutingTools)
                await networkManager.broadcastToolListChanged()
            }
            return RegistrationHandles(
                appSettings: results[0].handle,
                windowRouting: results[1].handle
            )
        }
        try await finishRegistration(attempt)
    }

    private func finishRegistration(
        _ attempt: SharedRegistrationAttempt<RegistrationHandles>.Attempt
    ) async throws {
        let completion = await registrationAttempt.complete(attempt)
        switch completion.result {
        case let .success(handles):
            if completion.wasCurrent {
                registrationHandles = handles
                status = .registered
            }
            await restoreAvailabilityPublicationIfNeeded()
        case let .failure(error):
            if completion.wasCurrent {
                status = .failed(String(reflecting: error))
            }
            throw error
        }
    }

    private func restoreAvailabilityPublicationIfNeeded() async {
        let publishedNames = Set(ToolAvailabilityStore.shared.toolSummaries.map(\.name))
        guard !publishedNames.isSuperset(of: MCPGlobalToolName.orderedToolNames) else { return }

        let appSettingsTools = await appSettingsService.tools
        let windowRoutingTools = await windowRoutingService.tools
        ToolAvailabilityStore.shared.registerTools(appSettingsTools + windowRoutingTools)
    }
}
