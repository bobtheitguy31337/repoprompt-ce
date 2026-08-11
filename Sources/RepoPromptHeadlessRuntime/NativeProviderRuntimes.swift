import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

enum NativeProviderRuntimeFactory {
    static func make(
        configuration: ProviderCLIConfiguration,
        processPort: PortableProcessSupervisionPort,
        processStore: SQLiteServiceStore?,
        outputDirectory: String,
        ephemeralHomeRoot: String,
        credentialEnvironment: any ProviderProcessEnvironmentProviding,
        credentialSource: any ProviderCredentialSourceProviding
    ) -> any AgentProviderRuntime {
        let support = NativeProviderProcessSupport(
            configuration: configuration,
            processPort: processPort,
            processStore: processStore,
            outputDirectory: outputDirectory,
            ephemeralHomeRoot: ephemeralHomeRoot,
            credentialEnvironment: credentialEnvironment,
            credentialSource: credentialSource
        )
        switch configuration.kind {
        case .codex:
            return CodexAppServerProviderRuntime(support: support)
        case .claudeCompatible:
            return ClaudeNativeProviderRuntime(support: support)
        case .openCodeACP:
            return ACPProviderRuntime(kind: .openCodeACP, arguments: ["acp"], support: support)
        case .cursorACP:
            return ACPProviderRuntime(kind: .cursorACP, arguments: ["--approve-mcps", "acp"], support: support)
        case .headlessAdapter:
            return NormalizedHeadlessProviderRuntime(kind: .headlessAdapter, support: support)
        case .mcp:
            // The bundled adapter otherwise defaults to the desktop bootstrap
            // socket. Linux server execution must select its canonical direct
            // headless backend; third-party MCP servers continue to receive no
            // RepoPrompt-specific arguments.
            let executableName = URL(fileURLWithPath: configuration.executable).lastPathComponent
            let arguments = executableName.hasPrefix("repoprompt-mcp") ? ["--backend", "headless"] : []
            return MCPStdioProviderRuntime(arguments: arguments, support: support)
        }
    }
}

private struct NativeProviderProcessSupport {
    private struct PreparedHome {
        let url: URL
        let resources: [OwnedResourceRecord]
    }

    let configuration: ProviderCLIConfiguration
    let processPort: PortableProcessSupervisionPort
    let processStore: SQLiteServiceStore?
    let outputDirectory: String
    let ephemeralHomeRoot: String
    let credentialEnvironment: any ProviderProcessEnvironmentProviding
    let credentialSource: any ProviderCredentialSourceProviding

    func capability(supportsResume: Bool, supportsSteering: Bool) -> ProviderCapability {
        let executable = FileManager.default.isExecutableFile(atPath: configuration.executable)
        return .init(
            kind: configuration.kind,
            enabled: executable,
            executable: executable ? configuration.executable : nil,
            supportsResume: supportsResume,
            supportsSteering: supportsSteering,
            version: configuration.expectedVersion,
            protocolVersion: configuration.protocolVersion,
            reasonUnavailable: executable ? nil : "configured binary is not executable"
        )
    }

    func preflight(supportsResume: Bool, supportsSteering: Bool, protocolName: String) async -> ProviderCapability {
        let base = capability(supportsResume: supportsResume, supportsSteering: supportsSteering)
        guard base.enabled else { return base }
        do {
            let runner = LocalWorkspaceCommandRunner()
            let output = try await runner.run(
                executable: configuration.executable,
                arguments: ["--version"],
                workingDirectory: FileManager.default.currentDirectoryPath,
                maximumBytes: 65536
            )
            let reported = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let expected = configuration.expectedVersion, reported?.contains(expected) != true {
                return .init(kind: configuration.kind, enabled: false, executable: configuration.executable, supportsResume: supportsResume, supportsSteering: supportsSteering, version: reported, protocolVersion: configuration.protocolVersion, reasonUnavailable: "provider version does not match the pinned image contract")
            }
            return .init(kind: configuration.kind, enabled: true, executable: configuration.executable, supportsResume: supportsResume, supportsSteering: supportsSteering, version: reported ?? configuration.expectedVersion, protocolVersion: configuration.protocolVersion ?? protocolName)
        } catch {
            return .init(kind: configuration.kind, enabled: false, executable: configuration.executable, supportsResume: supportsResume, supportsSteering: supportsSteering, version: configuration.expectedVersion, protocolVersion: configuration.protocolVersion, reasonUnavailable: "provider preflight failed: \(protocolName) executable probe")
        }
    }

    func makeSession(runID: UUID, arguments: [String], workingDirectory: String, model: String? = nil, policy: ProviderExecutionPolicy = .init(), includeCredentials: Bool = true, launchValidation: @escaping @Sendable () throws -> Void = {}) async throws -> NativeJSONLineProcess {
        let preparedHome = try await prepareEphemeralHome(runID: runID, includeCredentials: includeCredentials)
        var environment = providerEnvironment(home: preparedHome.url, workingDirectory: workingDirectory, policy: policy)
        let injected = includeCredentials ? try await credentialEnvironment.environment(for: configuration.kind, model: model, policy: policy) : [:]
        let reserved = Set(["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "CODEX_HOME", "CODEX_SQLITE_HOME", "CLAUDE_CONFIG_DIR", "PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD"])
        guard injected.keys.allSatisfy({ !reserved.contains($0) }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider credential environment attempted to override an isolated runtime key")
        }
        environment.merge(injected) { _, injected in injected }
        let supervisor = ProviderProcessSupervisor(processPort: processPort, store: processStore)
        do {
            return try await NativeJSONLineProcess.launch(
                runID: runID,
                executable: configuration.executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                home: preparedHome.url,
                processPort: processPort,
                supervisor: supervisor,
                outputDirectory: outputDirectory,
                resourceRepository: processStore,
                homeResources: preparedHome.resources,
                launchValidation: launchValidation
            )
        } catch {
            try? FileManager.default.removeItem(at: preparedHome.url)
            for resource in preparedHome.resources {
                let remains = FileManager.default.fileExists(atPath: resource.internalPathIdentity)
                _ = try? await processStore?.transitionOwnedResource(
                    resourceID: resource.resourceID,
                    expectedStates: [.active, .prepared, .preparing],
                    to: remains ? .quarantined : .deleted,
                    observedBytes: nil,
                    contentDigest: nil,
                    cleanupError: remains ? "provider_launch_cleanup_incomplete" : nil
                )
            }
            throw error
        }
    }

    func recover() async throws {
        try await ProviderProcessSupervisor(processPort: processPort, store: processStore).recoverPersistedFamilies()
    }

    private func providerEnvironment(home: URL, workingDirectory: String, policy: ProviderExecutionPolicy) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let inheritedKeys = ["PATH", "LANG", "LC_ALL", "TERM", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"]
        var environment = Dictionary(uniqueKeysWithValues: inheritedKeys.compactMap { key in source[key].map { (key, $0) } })
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
        environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache", isDirectory: true).path
        environment["CODEX_HOME"] = home.appendingPathComponent(".codex", isDirectory: true).path
        environment["CODEX_SQLITE_HOME"] = home.appendingPathComponent(".codex-sqlite", isDirectory: true).path
        environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude", isDirectory: true).path
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["CURSOR_AGENT_DISABLE_AUTO_UPDATE"] = "1"
        if configuration.kind == .claudeCompatible {
            environment["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
            if policy.providerSettings["claude.toolSearchEnabled"] != "true" {
                environment["ENABLE_TOOL_SEARCH"] = "false"
            }
        }
        if configuration.kind == .claudeCompatible,
           let effort = policy.providerSettings["provider.reasoningEffort"],
           ["low", "medium", "high", "xhigh", "max"].contains(effort)
        {
            environment["CLAUDE_CODE_EFFORT_LEVEL"] = effort
        }
        if configuration.kind == .mcp,
           URL(fileURLWithPath: configuration.executable).lastPathComponent.hasPrefix("repoprompt-mcp")
        {
            // Direct MCP refuses implicit cwd authority. Bind the exact
            // authority-approved provider working directory and keep its
            // standalone SQLite/workspace state inside this run's disposable
            // credential home.
            environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = home.appendingPathComponent("mcp-profile", isDirectory: true).path
            environment["REPOPROMPT_MCP_WORKING_DIRS"] = workingDirectory
        }
        return environment
    }

    private func prepareEphemeralHome(runID: UUID, includeCredentials: Bool) async throws -> PreparedHome {
        let root = URL(fileURLWithPath: ephemeralHomeRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
        var records: [OwnedResourceRecord] = []
        let homeRecord = OwnedResourceRecord(
            kind: .providerHome,
            runID: runID,
            externalID: UUID(),
            internalPathIdentity: home.path,
            lifecycleState: .preparing,
            metadata: ["provider": configuration.kind.rawValue],
            retentionDeadline: Date()
        )
        try await processStore?.reserveOwnedResource(homeRecord)
        records.append(homeRecord)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for child in [".config", ".cache", ".codex", ".codex-sqlite", ".claude"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            _ = try? await processStore?.transitionOwnedResource(resourceID: homeRecord.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "provider_home_create_failed")
            throw error
        }

        if includeCredentials, let sourcePath = try await credentialSource.sourceDirectory(for: configuration.kind) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                try? FileManager.default.removeItem(at: home)
                _ = try? await processStore?.transitionOwnedResource(resourceID: homeRecord.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "credential_source_unavailable")
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Configured provider credential source is unavailable")
            }
            let credentialDestination: URL = switch configuration.kind {
            case .codex: home.appendingPathComponent(".codex", isDirectory: true)
            case .claudeCompatible: home.appendingPathComponent(".claude", isDirectory: true)
            case .openCodeACP, .cursorACP: home.appendingPathComponent(".config", isDirectory: true)
            case .headlessAdapter, .mcp: home.appendingPathComponent(".credentials", isDirectory: true)
            }
            let credentialRecord = OwnedResourceRecord(
                kind: .providerCredentialCopy,
                runID: runID,
                externalID: UUID(),
                internalPathIdentity: credentialDestination.path,
                lifecycleState: .preparing,
                metadata: ["provider": configuration.kind.rawValue],
                retentionDeadline: Date()
            )
            try await processStore?.reserveOwnedResource(credentialRecord)
            records.append(credentialRecord)
            do {
                try FileManager.default.removeItem(at: credentialDestination)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath, isDirectory: true), to: credentialDestination)
            } catch {
                try? FileManager.default.removeItem(at: home)
                for record in records {
                    _ = try? await processStore?.transitionOwnedResource(resourceID: record.resourceID, expectedStates: [.preparing], to: .failed, observedBytes: nil, contentDigest: nil, cleanupError: "credential_copy_failed")
                }
                throw error
            }
        }
        var activated: [OwnedResourceRecord] = []
        for record in records {
            try await activated.append(processStore?.transitionOwnedResource(resourceID: record.resourceID, expectedStates: [.preparing], to: .active, observedBytes: nil, contentDigest: nil, cleanupError: nil) ?? record.replacing(lifecycleState: .active))
        }
        return PreparedHome(url: home, resources: activated)
    }
}

private actor NativeJSONLineProcess {
    private let runID: UUID
    private let captured: PortableProcessSupervisionPort.CapturedProcess
    private let home: URL
    private let processPort: PortableProcessSupervisionPort
    private let supervisor: ProviderProcessSupervisor
    private let resourceRepository: (any OwnedResourceRepository)?
    private let ownedResources: [OwnedResourceRecord]
    private var offset = 0
    private var buffer = Data()
    private var nextRequestID = 1
    private var finished = false

    private init(runID: UUID, captured: PortableProcessSupervisionPort.CapturedProcess, home: URL, processPort: PortableProcessSupervisionPort, supervisor: ProviderProcessSupervisor, resourceRepository: (any OwnedResourceRepository)?, ownedResources: [OwnedResourceRecord]) {
        self.runID = runID
        self.captured = captured
        self.home = home
        self.processPort = processPort
        self.supervisor = supervisor
        self.resourceRepository = resourceRepository
        self.ownedResources = ownedResources
    }

    static func launch(runID: UUID, executable: String, arguments: [String], environment: [String: String], workingDirectory: String, home: URL, processPort: PortableProcessSupervisionPort, supervisor: ProviderProcessSupervisor, outputDirectory: String, resourceRepository: (any OwnedResourceRepository)?, homeResources: [OwnedResourceRecord], launchValidation: @escaping @Sendable () throws -> Void) async throws -> NativeJSONLineProcess {
        let captureID = UUID()
        let outputRoot = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let outputRecord = OwnedResourceRecord(
            kind: .providerOutput,
            runID: runID,
            externalID: captureID,
            internalPathIdentity: outputRoot.appendingPathComponent("\(captureID.uuidString).stdout").path,
            temporaryPathIdentity: outputRoot.appendingPathComponent("\(captureID.uuidString).stderr").path,
            lifecycleState: .preparing,
            metadata: ["transport": "stdio"],
            retentionDeadline: Date()
        )
        try await resourceRepository?.reserveOwnedResource(outputRecord)
        var capturedProcess: PortableProcessSupervisionPort.CapturedProcess?
        do {
            let captured = try await processPort.launchInteractiveCaptured(
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                helperToken: runID.uuidString,
                outputDirectory: outputDirectory,
                captureID: captureID,
                launchValidation: launchValidation
            )
            capturedProcess = captured
            try await supervisor.register(runID: runID, leader: captured.identity)
            let activeOutput = try await resourceRepository?.transitionOwnedResource(resourceID: outputRecord.resourceID, expectedStates: [.preparing], to: .active, observedBytes: 0, contentDigest: nil, cleanupError: nil) ?? outputRecord.replacing(lifecycleState: .active, observedBytes: 0)
            return NativeJSONLineProcess(runID: runID, captured: captured, home: home, processPort: processPort, supervisor: supervisor, resourceRepository: resourceRepository, ownedResources: homeResources + [activeOutput])
        } catch {
            if let capturedProcess {
                try? await supervisor.cancel(runID: runID, graceScans: 5)
                await processPort.cleanupCapturedFiles(capturedProcess)
            } else {
                for path in [outputRecord.internalPathIdentity, outputRecord.temporaryPathIdentity].compactMap(\.self) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            let remains = [outputRecord.internalPathIdentity, outputRecord.temporaryPathIdentity].compactMap(\.self).contains {
                FileManager.default.fileExists(atPath: $0)
            }
            _ = try? await resourceRepository?.transitionOwnedResource(
                resourceID: outputRecord.resourceID,
                expectedStates: [.preparing, .active],
                to: remains ? .quarantined : .deleted,
                observedBytes: nil,
                contentDigest: nil,
                cleanupError: remains ? "provider_output_launch_cleanup_incomplete" : nil
            )
            throw error
        }
    }

    func notify(method: String, params: [String: Any]? = nil) async throws {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { object["params"] = params }
        try await send(object)
    }

    func request(method: String, params: [String: Any]? = nil, onFrame: @escaping @Sendable (Data) async throws -> Void) async throws -> Data {
        let id = try await beginRequest(method: method, params: params)
        while true {
            let line = try await nextLine()
            guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if (frame["id"] as? Int) == id {
                if let error = frame["error"] as? [String: Any] {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol request \(method) failed: \(error["message"] as? String ?? "unknown error")")
                }
                return try JSONSerialization.data(withJSONObject: frame["result"] ?? [:])
            }
            try await onFrame(line)
        }
    }

    /// Starts a JSON-RPC request without creating another transport reader.
    /// Active-turn controllers use this for native steering; their one reader
    /// observes and fences the eventual response by request ID.
    func beginRequest(method: String, params: [String: Any]? = nil) async throws -> Int {
        let id = nextRequestID
        nextRequestID += 1
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { object["params"] = params }
        try await send(object)
        return id
    }

    func sendResponse(id: Any, result: Any) async throws {
        try await send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func sendRaw(_ data: Data) async throws {
        var line = data
        line.append(0x0A)
        try await processPort.write(line, to: captured)
    }

    func nextLine() async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
                continue
            }
            let chunk = try await processPort.capturedOutput(captured, after: offset, maximumBytes: 262_144)
            offset = chunk.nextOffset
            buffer.append(chunk.data)
            if chunk.data.isEmpty {
                if !chunk.running {
                    if !buffer.isEmpty { defer { buffer.removeAll() }
                        return buffer
                    }
                    let diagnostic = (try? String(contentsOfFile: captured.stderrPath, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = diagnostic.map { ": \($0.prefix(2048))" } ?? ""
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider protocol transport closed\(suffix)")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func interrupt(protocolAction: @Sendable (NativeJSONLineProcess) async -> Void) async {
        guard !finished else { return }
        await protocolAction(self)
        // Give a native interrupt/cancel control frame a bounded opportunity
        // to reach the provider before enforcing process-family termination.
        try? await Task.sleep(for: .milliseconds(50))
        try? await supervisor.cancel(runID: runID, graceScans: 20)
        await cleanup()
    }

    func finish() async {
        guard !finished else { return }
        await processPort.closeInput(captured)
        for _ in 0 ..< 25 {
            if await (try? processPort.capturedOutput(captured, after: offset, maximumBytes: 1).running) != true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if await (try? processPort.capturedOutput(captured, after: offset, maximumBytes: 1).running) == true {
            try? await supervisor.cancel(runID: runID, graceScans: 5)
        } else {
            _ = try? await processPort.waitForCapturedProcess(captured, maximumBytes: 1)
            await supervisor.forget(runID: runID)
        }
        await cleanup()
    }

    private func send(_ object: [String: Any]) async throws {
        try await sendRaw(JSONSerialization.data(withJSONObject: object))
    }

    private func cleanup() async {
        guard !finished else { return }
        finished = true
        for resource in ownedResources {
            _ = try? await resourceRepository?.transitionOwnedResource(
                resourceID: resource.resourceID,
                expectedStates: [.preparing, .prepared, .active, .quarantined],
                to: .cleanupPending,
                observedBytes: observedBytes(for: resource),
                contentDigest: nil,
                cleanupError: nil
            )
        }
        await processPort.cleanupCapturedFiles(captured)
        try? FileManager.default.removeItem(at: home)
        for resource in ownedResources {
            let remains = resourcePaths(resource).contains { FileManager.default.fileExists(atPath: $0) }
            _ = try? await resourceRepository?.transitionOwnedResource(
                resourceID: resource.resourceID,
                expectedStates: [.cleanupPending],
                to: remains ? .quarantined : .deleted,
                observedBytes: observedBytes(for: resource),
                contentDigest: nil,
                cleanupError: remains ? "provider_resource_cleanup_incomplete" : nil
            )
        }
    }

    private func resourcePaths(_ resource: OwnedResourceRecord) -> [String] {
        [resource.internalPathIdentity, resource.temporaryPathIdentity].compactMap(\.self)
    }

    private func observedBytes(for resource: OwnedResourceRecord) -> Int64? {
        let sizes = resourcePaths(resource).compactMap { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

private actor CodexAppServerProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.codex
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    private var threadIDs: [UUID: String] = [:]
    private var turnIDs: [UUID: String] = [:]

    init(support: NativeProviderProcessSupport) {
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        let base = await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "app-server-v2")
        guard base.enabled else { return base }
        let runID = UUID()
        var preflightProcess: NativeJSONLineProcess?
        do {
            let process = try await support.makeSession(runID: runID, arguments: ["app-server"], workingDirectory: FileManager.default.currentDirectoryPath, includeCredentials: false)
            preflightProcess = process
            _ = try await process.request(method: "initialize", params: ["clientInfo": ["name": "repoprompt-server-preflight", "title": "RepoPrompt Server Preflight", "version": "1"], "capabilities": ["experimentalApi": true]], onFrame: { _ in })
            try await process.notify(method: "initialized")
            await process.finish()
            return base
        } catch {
            await preflightProcess?.interrupt { _ in }
            return .init(kind: kind, enabled: false, executable: base.executable, supportsResume: true, supportsSteering: true, version: base.version, protocolVersion: base.protocolVersion, reasonUnavailable: "Codex app-server initialize handshake failed: \(error)")
        }
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: ["app-server"], workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil
            threadIDs[request.runID] = nil
            turnIDs[request.runID] = nil
        }
        do {
            _ = try await process.request(method: "initialize", params: ["clientInfo": ["name": "repoprompt-server", "title": "RepoPrompt Server", "version": "1"], "capabilities": ["experimentalApi": true]], onFrame: { _ in })
            try await process.notify(method: "initialized")
            let policy = Self.codexPolicy(request.policy, workingDirectory: request.workingDirectory)
            var threadParams: [String: Any] = ["cwd": request.workingDirectory, "approvalPolicy": policy.approvalPolicy, "sandbox": policy.sandbox]
            let config = Self.codexConfig(request.policy.providerSettings)
            if !config.isEmpty { threadParams["config"] = config }
            if let model = request.model { threadParams["model"] = model }
            if let effort = request.policy.providerSettings["provider.reasoningEffort"] { threadParams["effort"] = effort }
            if let tier = request.policy.providerSettings["provider.serviceTier"] { threadParams["serviceTier"] = tier }
            let threadMethod: String
            if let existing = request.resumeProviderSessionID {
                threadMethod = "thread/resume"
                threadParams["threadId"] = existing
            } else {
                threadMethod = "thread/start"
            }
            let threadData = try await process.request(method: threadMethod, params: threadParams, onFrame: { line in try await Self.forward(line, output: onEvent) })
            let threadResult = try Self.object(threadData)
            guard let threadID = Self.string(in: threadResult, paths: [["thread", "id"], ["threadId"], ["id"]]) ?? request.resumeProviderSessionID else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "Codex app-server did not return a thread identity")
            }
            threadIDs[request.runID] = threadID
            await onEvent(.providerIdentity(threadID))
            var turnParams: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": request.prompt]], "cwd": request.workingDirectory, "approvalPolicy": policy.approvalPolicy, "sandboxPolicy": policy.sandboxPolicy]
            if let model = request.model { turnParams["model"] = model }
            if let effort = request.policy.providerSettings["provider.reasoningEffort"] { turnParams["effort"] = effort }
            if let tier = request.policy.providerSettings["provider.serviceTier"] { turnParams["serviceTier"] = tier }
            let turnData = try await process.request(method: "turn/start", params: turnParams, onFrame: { line in try await Self.forward(line, output: onEvent) })
            let turnResult = try Self.object(turnData)
            turnIDs[request.runID] = Self.string(in: turnResult, paths: [["turn", "id"], ["turnId"], ["id"]])
            var output = ""
            while true {
                let line = try await process.nextLine()
                let normalized = try Self.normalize(line)
                for event in normalized.events {
                    switch event {
                    case let .assistantDelta(text): output += text
                    case let .assistantFinal(text): output = text
                    default: break
                    }
                    await onEvent(event)
                }
                if normalized.completed { break }
            }
            await onEvent(.completed(providerSessionID: threadID))
            await process.finish()
            return .init(output: output, providerSessionID: threadID)
        } catch {
            await process.interrupt { session in try? await session.notify(method: "turn/interrupt", params: [:]) }
            throw error
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) async throws {
        guard let process = sessions[runID], let threadID = threadIDs[runID], let turnID = turnIDs[runID] else { throw ServiceAPIError(code: .notFound, message: "Codex turn is not active") }
        _ = try await process.beginRequest(method: "turn/steer", params: ["threadId": threadID, "expectedTurnId": turnID, "input": [["type": "text", "text": text]]])
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        let threadID = threadIDs[runID]
        let turnID = turnIDs[runID]
        await process.interrupt { session in
            guard let threadID, let turnID else { return }
            _ = try? await session.beginRequest(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
        }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Codex run is not active") }
        let id: Any = Int(providerRequestID) ?? providerRequestID
        let payload = (try? JSONSerialization.jsonObject(with: answer)) ?? ["decision": "decline"]
        try await process.sendResponse(id: id, result: payload)
    }

    private nonisolated static func codexConfig(_ settings: [String: String]) -> [String: Any] {
        let bash = settings["codex.bashEnabled"] != "false"
        let search = settings["codex.searchEnabled"] != "false"
        let goals = settings["codex.goalsEnabled"] != "false"
        let summaries = settings["codex.reasoningSummariesEnabled"] == "true"
        let memories = settings["codex.memoriesEnabled"] == "true"
        var config: [String: Any] = [
            "features.apps": false,
            "features.shell_tool": bash,
            "features.goals": goals,
            "features.memories": memories,
            "features.computer_use": false,
            "features.plugins": false,
            "features.tool_call_mcp_elicitation": false,
            "features.tool_suggest": false,
            "memories.generate_memories": memories,
            "memories.use_memories": memories,
            "web_search": search ? "live" : "disabled",
            "model_reasoning_summary": summaries ? "auto" : "none",
            "features.code_mode.direct_only_tool_namespaces": ["mcp__RepoPromptCE"]
        ]
        if !bash { config["features.unified_exec"] = false }
        if let encoded = settings["codex.enabledMCPServers"],
           let data = encoded.data(using: .utf8),
           let names = try? JSONDecoder().decode([String].self, from: data)
        {
            for name in names where name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0) }) {
                config["mcp_servers.\(name).enabled"] = true
            }
        }
        return config
    }

    private nonisolated static func codexPolicy(_ policy: ProviderExecutionPolicy, workingDirectory: String) -> (approvalPolicy: String, sandbox: String, sandboxPolicy: [String: Any]) {
        switch policy.mode {
        case .readOnly:
            return ("on-request", "read-only", ["type": "readOnly"])
        case .workspaceWrite:
            let configured = policy.providerSettings["codex.approvalPolicy"]
            let approval = configured.flatMap { ["on-request", "untrusted", "never"].contains($0) ? $0 : nil } ?? "on-request"
            let roots = policy.writableRoots.isEmpty ? [workingDirectory] : policy.writableRoots
            return (approval, "workspace-write", ["type": "workspaceWrite", "writableRoots": roots])
        case .fullAccess:
            return ("never", "danger-full-access", ["type": "dangerFullAccess"])
        }
    }

    private nonisolated static func forward(_ line: Data, output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws {
        for event in try normalize(line).events {
            await output(event)
        }
    }

    private nonisolated static func normalize(_ data: Data) throws -> (events: [ProviderRuntimeEvent], completed: Bool) {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], false) }
        let method = frame["method"] as? String ?? ""
        let params = frame["params"] as? [String: Any] ?? [:]
        if frame["id"] != nil, !method.isEmpty {
            let id = String(describing: frame["id"]!)
            let prompt = string(in: params, paths: [["reason"], ["message"], ["question"], ["item", "command"], ["item", "path"]]) ?? method
            let kind: ProviderInteractionKind = method == "item/tool/requestUserInput" || method == "mcpServer/elicitation/request" ? .question : .approval
            return ([.interactionRequested(providerRequestID: id, kind: kind, prompt: prompt, choices: kind == .approval ? ["accept", "decline"] : [])], false)
        }
        switch method {
        case "item/agentMessage/delta", "codex/event/agent_message_delta":
            return ([.assistantDelta(string(in: params, paths: [["delta"], ["text"]]) ?? "")], false)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return ([.reasoning(string(in: params, paths: [["delta"], ["text"]]) ?? "")], false)
        case "turn/started", "codex/event/turn_started":
            return ([.progress("turn started")], false)
        case "item/started":
            let item = params["item"] as? [String: Any] ?? params
            let id = item["id"] as? String ?? UUID().uuidString
            let name = item["type"] as? String ?? "tool"
            let arguments = try? JSONSerialization.data(withJSONObject: item)
            return ([.toolStarted(providerToolID: id, name: name, arguments: arguments)], false)
        case "item/commandExecution/outputDelta", "item/mcpToolCall/progress", "item/fileChange/outputDelta":
            let id = string(in: params, paths: [["itemId"], ["id"]]) ?? "tool"
            return ([.toolUpdated(providerToolID: id, output: string(in: params, paths: [["delta"], ["output"], ["message"]]) ?? "")], false)
        case "item/completed":
            let item = params["item"] as? [String: Any] ?? params
            if item["type"] as? String == "agentMessage" || item["type"] as? String == "agent_message" {
                return ([.assistantFinal(string(in: item, paths: [["text"], ["content"]]) ?? "")], false)
            }
            return ([.toolCompleted(providerToolID: item["id"] as? String ?? "tool", name: item["type"] as? String ?? "tool", output: string(in: item, paths: [["output"], ["aggregatedOutput"]]), failed: false)], false)
        case "turn/completed", "codex/event/turn_completed":
            return ([], true)
        default:
            return ([], false)
        }
    }

    fileprivate nonisolated static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    fileprivate nonisolated static func string(in object: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var value: Any = object
            for key in path {
                guard let dictionary = value as? [String: Any], let next = dictionary[key] else { value = NSNull()
                    break
                }
                value = next
            }
            if let string = value as? String, !string.isEmpty { return string }
        }
        return nil
    }
}

private actor ACPProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private let arguments: [String]
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    private var providerSessionIDs: [UUID: String] = [:]
    private var promptRequestIDs: [UUID: Int] = [:]

    init(kind: ProviderKind, arguments: [String], support: NativeProviderProcessSupport) {
        self.kind = kind
        self.arguments = arguments
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        let base = await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "acp-v1")
        guard base.enabled else { return base }
        var preflightProcess: NativeJSONLineProcess?
        do {
            let process = try await support.makeSession(runID: UUID(), arguments: arguments, workingDirectory: FileManager.default.currentDirectoryPath)
            preflightProcess = process
            let response = try await process.request(method: "initialize", params: ["protocolVersion": 1, "clientInfo": ["name": "RepoPrompt Preflight", "version": "1"], "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], onFrame: { _ in })
            let object = try CodexAppServerProviderRuntime.object(response)
            guard object["agentCapabilities"] is [String: Any] else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP initialize omitted agent capabilities")
            }
            await process.finish()
            return base
        } catch {
            await preflightProcess?.interrupt { _ in }
            return .init(kind: kind, enabled: false, executable: base.executable, supportsResume: true, supportsSteering: true, version: base.version, protocolVersion: base.protocolVersion, reasonUnavailable: "ACP initialize handshake failed: \(error)")
        }
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: arguments, workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil
            providerSessionIDs[request.runID] = nil
            promptRequestIDs[request.runID] = nil
        }
        do {
            let initialize = try await process.request(method: "initialize", params: ["protocolVersion": 1, "clientInfo": ["name": "RepoPrompt", "version": "1"], "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]], onFrame: { line in try await Self.forward(line, output: onEvent) })
            let capabilities = try CodexAppServerProviderRuntime.object(initialize)["agentCapabilities"] as? [String: Any] ?? [:]
            let sessionID: String
            let sessionOpenResult: [String: Any]
            if let resume = request.resumeProviderSessionID {
                guard capabilities["loadSession"] as? Bool == true else { throw ServiceAPIError(code: .resumeUnsupported, message: "ACP provider did not negotiate session/load") }
                let loaded = try await process.request(method: "session/load", params: ["sessionId": resume, "cwd": request.workingDirectory, "mcpServers": []], onFrame: { line in try await Self.forward(line, output: onEvent) })
                sessionOpenResult = try CodexAppServerProviderRuntime.object(loaded)
                sessionID = resume
            } else {
                let opened = try await process.request(method: "session/new", params: ["cwd": request.workingDirectory, "mcpServers": []], onFrame: { line in try await Self.forward(line, output: onEvent) })
                sessionOpenResult = try CodexAppServerProviderRuntime.object(opened)
                guard let id = CodexAppServerProviderRuntime.string(in: sessionOpenResult, paths: [["sessionId"]]) else { throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP session/new omitted sessionId") }
                sessionID = id
            }
            try await Self.configureExecutionMode(request.policy, sessionID: sessionID, sessionOpenResult: sessionOpenResult, process: process, output: onEvent)
            try await Self.configureModel(request.model, sessionID: sessionID, sessionOpenResult: sessionOpenResult, process: process, output: onEvent)
            providerSessionIDs[request.runID] = sessionID
            await onEvent(.providerIdentity(sessionID))
            let output = ProviderOutputAccumulator()
            promptRequestIDs[request.runID] = try await process.beginRequest(method: "session/prompt", params: ["sessionId": sessionID, "prompt": [["type": "text", "text": request.prompt]]])
            while true {
                let line = try await process.nextLine()
                for event in try Self.normalize(line) {
                    await output.record(event)
                    await onEvent(event)
                }
                guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let responseID = frame["id"] as? Int,
                      responseID == promptRequestIDs[request.runID]
                else { continue }
                if let error = frame["error"] as? [String: Any] {
                    throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP session/prompt failed: \(error["message"] as? String ?? "unknown error")")
                }
                break
            }
            await onEvent(.completed(providerSessionID: sessionID))
            await process.finish()
            return await .init(output: output.value(), providerSessionID: sessionID)
        } catch {
            await process.interrupt { session in try? await session.notify(method: "session/cancel", params: [:]) }
            throw error
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) async throws {
        guard let process = sessions[runID], let sessionID = providerSessionIDs[runID] else { throw ServiceAPIError(code: .notFound, message: "ACP run is not active") }
        try await process.notify(method: "session/cancel", params: ["sessionId": sessionID])
        promptRequestIDs[runID] = try await process.beginRequest(method: "session/prompt", params: ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]])
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        let sessionID = providerSessionIDs[runID]
        await process.interrupt { session in
            if let sessionID { try? await session.notify(method: "session/cancel", params: ["sessionId": sessionID]) }
        }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "ACP run is not active") }
        let answerObject = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        let optionID = answerObject?["optionId"] as? String
        let outcome: [String: Any] = optionID.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        try await process.sendResponse(id: Int(providerRequestID) ?? providerRequestID, result: ["outcome": outcome])
    }

    private nonisolated static func configureExecutionMode(
        _ policy: ProviderExecutionPolicy,
        sessionID: String,
        sessionOpenResult: [String: Any],
        process: NativeJSONLineProcess,
        output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws {
        let desired: String? = switch policy.mode {
        case .readOnly: policy.providerSettings["acp.readOnlyMode"] ?? "plan"
        case .workspaceWrite: policy.providerSettings["acp.mode"]
        case .fullAccess: policy.providerSettings["acp.fullAccessMode"]
        }
        guard let desired, !desired.isEmpty else { return }
        let options = sessionOpenResult["configOptions"] as? [[String: Any]] ?? []
        guard let mode = options.first(where: { ($0["category"] as? String)?.caseInsensitiveCompare("mode") == .orderedSame }),
              let configID = mode["id"] as? String
        else {
            if policy.mode == .readOnly {
                throw ServiceAPIError(code: .capabilityMissing, message: "ACP provider does not advertise an enforceable read-only mode")
            }
            return
        }
        let values = (mode["options"] as? [[String: Any]] ?? []).compactMap { ($0["value"] ?? $0["id"]) as? String }
        guard let canonical = values.first(where: { $0.caseInsensitiveCompare(desired) == .orderedSame }) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "ACP provider does not advertise requested execution mode")
        }
        if (mode["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame { return }
        let response = try await process.request(
            method: "session/set_config_option",
            params: ["sessionId": sessionID, "configId": configID, "value": canonical],
            onFrame: { line in try await forward(line, output: output) }
        )
        let updated = try CodexAppServerProviderRuntime.object(response)["configOptions"] as? [[String: Any]] ?? []
        guard updated.contains(where: { ($0["id"] as? String) == configID && (($0["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame) }) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP provider did not acknowledge the execution mode")
        }
    }

    private nonisolated static func configureModel(
        _ requestedModel: String?,
        sessionID: String,
        sessionOpenResult: [String: Any],
        process: NativeJSONLineProcess,
        output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws {
        guard let requestedModel = requestedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedModel.isEmpty else { return }
        let options = sessionOpenResult["configOptions"] as? [[String: Any]] ?? []
        guard let model = options.first(where: { ($0["category"] as? String)?.caseInsensitiveCompare("model") == .orderedSame }),
              let configID = model["id"] as? String
        else { throw ServiceAPIError(code: .capabilityMissing, message: "ACP provider does not advertise model selection") }
        let choices = model["options"] as? [[String: Any]] ?? []
        let canonical = choices.compactMap { ($0["value"] ?? $0["id"]) as? String }
            .first { $0.caseInsensitiveCompare(requestedModel) == .orderedSame }
        guard let canonical else { throw ServiceAPIError(code: .providerUnavailable, message: "Requested ACP model is not advertised by the provider") }
        if (model["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame { return }
        let response = try await process.request(
            method: "session/set_config_option",
            params: ["sessionId": sessionID, "configId": configID, "value": canonical],
            onFrame: { line in try await forward(line, output: output) }
        )
        let updated = try CodexAppServerProviderRuntime.object(response)["configOptions"] as? [[String: Any]] ?? []
        guard updated.contains(where: { ($0["id"] as? String) == configID && (($0["currentValue"] as? String)?.caseInsensitiveCompare(canonical) == .orderedSame) }) else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "ACP provider did not acknowledge the selected model")
        }
    }

    private nonisolated static func forward(_ line: Data, output: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws {
        for event in try normalize(line) {
            await output(event)
        }
    }

    private nonisolated static func normalize(_ data: Data) throws -> [ProviderRuntimeEvent] {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let method = frame["method"] as? String ?? ""
        let params = frame["params"] as? [String: Any] ?? [:]
        if frame["id"] != nil, method == "session/request_permission" {
            let id = String(describing: frame["id"]!)
            let tool = params["toolCall"] as? [String: Any] ?? [:]
            let choices = (params["options"] as? [[String: Any]] ?? []).compactMap { $0["optionId"] as? String }
            return [.interactionRequested(providerRequestID: id, kind: .approval, prompt: tool["title"] as? String ?? "Tool approval", choices: choices)]
        }
        guard method == "session/update", let update = params["update"] as? [String: Any] else { return [] }
        let type = update["sessionUpdate"] as? String ?? ""
        switch type {
        case "agent_message_chunk":
            return [.assistantDelta(CodexAppServerProviderRuntime.string(in: update, paths: [["content", "text"], ["text"]]) ?? "")]
        case "agent_thought_chunk":
            return [.reasoning(CodexAppServerProviderRuntime.string(in: update, paths: [["content", "text"], ["text"]]) ?? "")]
        case "plan":
            return [.progress(CodexAppServerProviderRuntime.string(in: update, paths: [["text"], ["content", "text"]]) ?? "plan updated")]
        case "tool_call":
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            let name = update["title"] as? String ?? update["kind"] as? String ?? "tool"
            return [.toolStarted(providerToolID: id, name: name, arguments: try? JSONSerialization.data(withJSONObject: update["rawInput"] ?? [:]))]
        case "tool_call_update":
            let id = update["toolCallId"] as? String ?? "tool"
            let status = update["status"] as? String ?? ""
            let output = CodexAppServerProviderRuntime.string(in: update, paths: [["content", "text"], ["output"]])
            if ["completed", "failed"].contains(status) {
                return [.toolCompleted(providerToolID: id, name: update["title"] as? String ?? "tool", output: output, failed: status == "failed")]
            }
            return [.toolUpdated(providerToolID: id, output: output ?? status)]
        default:
            return []
        }
    }
}

private actor ClaudeNativeProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.claudeCompatible
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]

    init(support: NativeProviderProcessSupport) {
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "bidirectional-stream-json")
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        var arguments = ["-p", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--permission-prompt-tool", "stdio"]
        switch request.policy.mode {
        case .readOnly:
            arguments += ["--permission-mode", "plan", "--disallowedTools", "Bash,Write,Edit,NotebookEdit"]
        case .workspaceWrite:
            let configured = request.policy.providerSettings["claude.permissionMode"] ?? "default"
            let mode = ["default", "acceptEdits", "auto"].contains(configured) ? configured : "default"
            arguments += ["--permission-mode", mode]
        case .fullAccess:
            arguments.append("--allow-dangerously-skip-permissions")
        }
        if request.policy.mode != .readOnly, request.policy.providerSettings["claude.bashEnabled"] == "false" {
            arguments += ["--disallowedTools", "Bash"]
        }
        if request.policy.providerSettings["claude.strictMCPEnabled"] == "true" {
            arguments.append("--strict-mcp-config")
        }
        if let resume = request.resumeProviderSessionID { arguments += ["--resume", resume] }
        let effectiveModel = Self.effectiveModel(request.model, settings: request.policy.providerSettings)
        if let effectiveModel { arguments += ["--model", effectiveModel] }
        let process = try await support.makeSession(runID: request.runID, arguments: arguments, workingDirectory: request.workingDirectory, model: request.model, policy: request.policy, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil }
        do {
            try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": request.prompt]]], "parent_tool_use_id": NSNull()]))
            var output = ""
            var identity = request.resumeProviderSessionID
            while true {
                let line = try await process.nextLine()
                guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if frame["type"] as? String == "control_request", let requestID = frame["request_id"] as? String, let payload = frame["request"] as? [String: Any] {
                    await onEvent(.interactionRequested(providerRequestID: requestID, kind: .approval, prompt: payload["description"] as? String ?? payload["tool_name"] as? String ?? "Tool approval", choices: ["accept", "decline"]))
                    continue
                }
                identity = identity ?? frame["session_id"] as? String
                if let identity { await onEvent(.providerIdentity(identity)) }
                let type = frame["type"] as? String ?? ""
                if type == "assistant", let message = frame["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text", let text = block["text"] as? String { output += text
                            await onEvent(.assistantDelta(text))
                        }
                        if block["type"] as? String == "thinking", let text = block["thinking"] as? String { await onEvent(.reasoning(text)) }
                        if block["type"] as? String == "tool_use" {
                            await onEvent(.toolStarted(providerToolID: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "tool", arguments: try? JSONSerialization.data(withJSONObject: block["input"] ?? [:])))
                        }
                    }
                }
                if type == "result" {
                    if let final = frame["result"] as? String, !final.isEmpty { output = final
                        await onEvent(.assistantFinal(final))
                    }
                    await onEvent(.completed(providerSessionID: identity))
                    break
                }
            }
            await process.finish()
            return .init(output: output, providerSessionID: identity)
        } catch {
            await process.interrupt { session in try? await Self.sendInterrupt(to: session) }
            throw error
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch _: Int64) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Claude run is not active") }
        try await Self.sendInterrupt(to: process)
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]], "parent_tool_use_id": NSNull()]))
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        await process.interrupt { session in try? await Self.sendInterrupt(to: session) }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Claude run is not active") }
        let answerObject = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
        let accepted = answerObject["decision"] as? String == "accept" || answerObject["accepted"] as? Bool == true
        let response: [String: Any] = accepted ? ["behavior": "allow"] : ["behavior": "deny", "message": "Declined by controller"]
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "control_response", "response": ["subtype": "success", "request_id": providerRequestID, "response": response]]))
    }

    private nonisolated static func sendInterrupt(to process: NativeJSONLineProcess) async throws {
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt", "reason": "authority control"]]))
    }

    private nonisolated static func effectiveModel(_ requested: String?, settings: [String: String]) -> String? {
        guard let backendID = settings["claude.backendID"] else { return requested }
        if backendID == ProviderSettingsID.claudeKimi.rawValue { return nil }
        if settings["claude.backendModelBehavior"] == ClaudeCompatibleBackendModelBehavior.noModel.rawValue { return nil }
        guard let requested else { return "sonnet" }
        let normalized = requested.lowercased()
        let slots = [
            ("claude.backendHaikuModel", "haiku"),
            ("claude.backendSonnetModel", "sonnet"),
            ("claude.backendOpusModel", "opus")
        ]
        return slots.first(where: { settings[$0.0]?.lowercased() == normalized })?.1
            ?? (["haiku", "sonnet", "opus"].contains(normalized) ? normalized : "sonnet")
    }
}

/// Portable normalized HeadlessAgentProvider wire. The helper emits the same
/// event vocabulary as AgentStreamEvent as NDJSON and accepts control NDJSON.
private actor NormalizedHeadlessProviderRuntime: AgentProviderRuntime {
    let kind: ProviderKind
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    init(kind: ProviderKind, support: NativeProviderProcessSupport) {
        self.kind = kind
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: true, supportsSteering: true)
    }

    func preflight() async -> ProviderCapability {
        await support.preflight(supportsResume: true, supportsSteering: true, protocolName: "repoprompt-headless-v1")
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: ["--headless-provider-json"], workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil }
        try await process.sendRaw(JSONSerialization.data(withJSONObject: [
            "operation": "start",
            "runID": request.runID.uuidString,
            "prompt": request.prompt,
            "model": request.model as Any,
            "resumeSessionID": request.resumeProviderSessionID as Any,
            "executionPolicy": [
                "mode": request.policy.mode.rawValue,
                "writableRoots": request.policy.writableRoots,
                "providerSettings": request.policy.providerSettings
            ]
        ]))
        var output = ""
        var identity = request.resumeProviderSessionID
        while true {
            let line = try await process.nextLine()
            guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch frame["type"] as? String {
            case "message": let text = frame["content"] as? String ?? ""
                output += text
                await onEvent(.assistantDelta(text))
            case "finalMessage": let text = frame["content"] as? String ?? ""
                output = text
                await onEvent(.assistantFinal(text))
            case "reasoning": await onEvent(.reasoning(frame["content"] as? String ?? ""))
            case "progress", "system": await onEvent(.progress(frame["message"] as? String ?? ""))
            case "toolCall": await onEvent(.toolStarted(providerToolID: frame["id"] as? String ?? UUID().uuidString, name: frame["name"] as? String ?? "tool", arguments: try? JSONSerialization.data(withJSONObject: frame["args"] ?? [:])))
            case "toolResult": await onEvent(.toolCompleted(providerToolID: frame["id"] as? String ?? "tool", name: frame["name"] as? String ?? "tool", output: frame["result"] as? String, failed: frame["failed"] as? Bool ?? false))
            case "interaction": await onEvent(.interactionRequested(providerRequestID: frame["requestID"] as? String ?? UUID().uuidString, kind: (frame["kind"] as? String) == "question" ? .question : .approval, prompt: frame["prompt"] as? String ?? "Provider input required", choices: frame["choices"] as? [String] ?? []))
            case "completion": identity = frame["providerSessionID"] as? String ?? identity
                await onEvent(.completed(providerSessionID: identity))
                await process.finish()
                return .init(output: output, providerSessionID: identity)
            default: break
            }
        }
    }

    func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Headless run is not active") }
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["operation": "steer", "text": text, "targetTurnEpoch": targetTurnEpoch]))
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        await process.interrupt { session in try? await session.sendRaw(try JSONSerialization.data(withJSONObject: ["operation": "interrupt"])) }
    }

    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws {
        guard let process = sessions[runID] else { throw ServiceAPIError(code: .notFound, message: "Headless run is not active") }
        try await process.sendRaw(JSONSerialization.data(withJSONObject: ["operation": "respond", "requestID": providerRequestID, "answer": (try? JSONSerialization.jsonObject(with: answer)) ?? NSNull()]))
    }
}

private actor ProviderOutputAccumulator {
    private var output = ""
    func record(_ event: ProviderRuntimeEvent) {
        switch event {
        case let .assistantDelta(text): output += text
        case let .assistantFinal(text): output = text
        default: break
        }
    }

    func value() -> String {
        output
    }
}

/// Executable MCP compatibility path: initialize and tools/list are real stdio
/// JSON-RPC exchanges. It is intentionally not a second session authority.
private actor MCPStdioProviderRuntime: AgentProviderRuntime {
    let kind = ProviderKind.mcp
    private let arguments: [String]
    private let support: NativeProviderProcessSupport
    private var sessions: [UUID: NativeJSONLineProcess] = [:]
    init(arguments: [String], support: NativeProviderProcessSupport) {
        self.arguments = arguments
        self.support = support
    }

    func capability() -> ProviderCapability {
        support.capability(supportsResume: false, supportsSteering: false)
    }

    func preflight() async -> ProviderCapability {
        let base = await support.preflight(supportsResume: false, supportsSteering: false, protocolName: "mcp-stdio-2025-03-26")
        guard base.enabled else { return base }
        var preflightProcess: NativeJSONLineProcess?
        do {
            let process = try await support.makeSession(runID: UUID(), arguments: arguments, workingDirectory: FileManager.default.currentDirectoryPath)
            preflightProcess = process
            let initialized = try await process.request(method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "RepoPromptServerPreflight", "version": "1"]], onFrame: { _ in })
            let object = try CodexAppServerProviderRuntime.object(initialized)
            guard object["protocolVersion"] is String else {
                throw ServiceAPIError(code: .dependencyUnavailable, message: "MCP initialize omitted protocol version")
            }
            try await process.notify(method: "notifications/initialized")
            _ = try await process.request(method: "tools/list", params: [:], onFrame: { _ in })
            await process.finish()
            return base
        } catch {
            await preflightProcess?.interrupt { _ in }
            return .init(kind: kind, enabled: false, executable: base.executable, supportsResume: false, supportsSteering: false, version: base.version, protocolVersion: base.protocolVersion, reasonUnavailable: "MCP initialize/tools-list handshake failed: \(error)")
        }
    }

    func recoverProcessFamilies() async throws {
        try await support.recover()
    }

    func hasActiveRun(_ runID: UUID) -> Bool {
        sessions[runID] != nil
    }

    func execute(_ request: ProviderExecutionRequest, onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void) async throws -> ProviderExecutionResult {
        let process = try await support.makeSession(runID: request.runID, arguments: arguments, workingDirectory: request.workingDirectory, launchValidation: { try request.validateLaunch() })
        sessions[request.runID] = process
        defer { sessions[request.runID] = nil }
        _ = try await process.request(method: "initialize", params: ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "RepoPromptServer", "version": "1"]], onFrame: { _ in })
        try await process.notify(method: "notifications/initialized")
        let tools = try await process.request(method: "tools/list", params: [:], onFrame: { _ in })
        let object = try CodexAppServerProviderRuntime.object(tools)
        let names = (object["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
        let output = names.joined(separator: "\n")
        await onEvent(.progress("MCP initialized with \(names.count) tools"))
        await onEvent(.assistantFinal(output))
        await onEvent(.completed(providerSessionID: nil))
        await process.finish()
        return .init(output: output, providerSessionID: nil)
    }

    func interrupt(runID: UUID) async throws {
        guard let process = sessions[runID] else { return }
        await process.interrupt { _ in }
    }
}
