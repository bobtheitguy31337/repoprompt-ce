import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

private struct ImmediateClock: RuntimeClock {
    func now() -> Date {
        Date(timeIntervalSince1970: 0)
    }

    func sleep(for duration: Duration) async throws {}
}

private actor FakeProcessPort: ProcessSupervisionPort {
    private let leader: ProcessIdentity
    private let children: [ProcessIdentity]
    private let lateChildren: [ProcessIdentity]
    private var observedSignals: [Int32] = []
    private var observedProcessGroups: [Int32] = []
    private var reapedPIDs: [Int32] = []
    private var reconstructed: [(ProcessIdentity, String)] = []
    private var descendantScans = 0

    init(leader: ProcessIdentity, children: [ProcessIdentity], lateChildren: [ProcessIdentity] = []) {
        self.leader = leader
        self.children = children
        self.lateChildren = lateChildren
    }

    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity {
        leader
    }

    func inspect(pid: Int32) async throws -> ProcessIdentity? {
        ([leader] + children).first { $0.pid == pid }
    }

    func descendants(of pid: Int32) async throws -> [ProcessIdentity] {
        descendantScans += 1
        guard pid == leader.pid else { return [] }
        return descendantScans >= 3 ? children + lateChildren : children
    }

    func signal(_ signal: Int32, processGroupID: Int32, verifiedMembers: [ProcessIdentity]) async throws {
        observedSignals.append(signal)
        observedProcessGroups.append(processGroupID)
    }

    func reap(pid: Int32) async throws {
        reapedPIDs.append(pid)
    }

    func containmentMode(for _: ProcessIdentity) async throws -> String {
        "cgroup-v2"
    }

    func reconstruct(leader: ProcessIdentity, containmentMode: String) async throws {
        reconstructed.append((leader, containmentMode))
    }

    func result() -> (signals: [Int32], processGroups: [Int32], reaped: [Int32], reconstructed: [(ProcessIdentity, String)]) {
        (observedSignals, observedProcessGroups, reapedPIDs, reconstructed)
    }
}

final class ProviderSupervisorTests: XCTestCase {
    func testCodexJSONLPublishesDurableIdentityAndUsesNativeResumeCommand() async throws {
        let runner = RecordingProviderRunner()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: "/usr/bin/true")], runner: runner)
        let first = try await adapter.execute(kind: .codex, model: "gpt-test", prompt: "first", workingDirectory: "/tmp")
        XCTAssertEqual(first.providerSessionID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(first.output, "done")
        _ = try await adapter.execute(kind: .codex, model: nil, prompt: "continue", workingDirectory: "/tmp", resumeProviderSessionID: first.providerSessionID)
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Array(calls[1].prefix(4)), ["exec", "resume", "--json", "--skip-git-repo-check"])
        XCTAssertTrue(calls[1].contains("11111111-1111-1111-1111-111111111111"))
        let capabilities = await adapter.capabilities()
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.supportsSteering, true)
    }

    func testProviderPublishesNativeIdentityBeforeProcessCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("provider")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.fakeCodexAppServerScript(finalTextShell: "done", delayBeforeCompletion: true).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = try PortableProcessSupervisionPort()
        let observer = ProviderIdentityObserver()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: executable.path)], processPort: port, outputDirectory: directory.appendingPathComponent("output").path, ephemeralHomeRoot: directory.appendingPathComponent("homes").path)

        let task = Task {
            try await adapter.execute(kind: .codex, model: nil, prompt: "prompt", workingDirectory: directory.path) { identity in
                await observer.record(identity)
            }
        }
        for _ in 0 ..< 30 {
            if await observer.value() != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let observedIdentity = await observer.value()
        XCTAssertEqual(observedIdentity, "22222222-2222-2222-2222-222222222222")
        let result = try await task.value
        XCTAssertEqual(result.output, "done")
    }

    func testProviderUsesAuthorityRunIDAndRemovesEphemeralCredentialHome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("provider")
        let homes = directory.appendingPathComponent("homes", isDirectory: true)
        let credentials = directory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: credentials.appendingPathComponent("auth.json"))
        try Data(Self.fakeCodexAppServerScript(finalTextShell: "$HOME", version: "provider 1.0").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let port = try PortableProcessSupervisionPort()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: executable.path, expectedVersion: "1.0", credentialSourceDirectory: credentials.path)], processPort: port, processStore: store, outputDirectory: directory.appendingPathComponent("output").path, ephemeralHomeRoot: homes.path)
        let capabilities = await adapter.preflight()
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.enabled, true)
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.version, "provider 1.0")
        let runID = UUID()

        let output = try await adapter.complete(kind: .codex, model: nil, prompt: "prompt", workingDirectory: directory.path, runID: runID)

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), homes.appendingPathComponent(runID.uuidString).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homes.appendingPathComponent(runID.uuidString).path))
        let processFamilyState = try await store.processFamilyState(runID: runID)
        XCTAssertEqual(processFamilyState, "exited")
        let resources = try await store.ownedResources(states: nil)
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerHome })
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerCredentialCopy })
        XCTAssertTrue(resources.contains { $0.runID == runID && $0.kind == .providerOutput })
        XCTAssertTrue(resources.filter { $0.runID == runID }.allSatisfy { $0.lifecycleState == .deleted })
        try await store.close()
    }

    func testNativePortableProviderMatrixExecutesProtocolContracts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(ProviderKind, String)] = [
            (.claudeCompatible, Self.fakeClaudeScript()),
            (.openCodeACP, Self.fakeACPScript(requiredArguments: "acp")),
            (.cursorACP, Self.fakeACPScript(requiredArguments: "--approve-mcps acp")),
            (.headlessAdapter, Self.fakeHeadlessAdapterScript()),
            (.mcp, Self.fakeMCPServerScript())
        ]
        let port = try PortableProcessSupervisionPort()
        var configurations: [ProviderCLIConfiguration] = []
        for (kind, script) in fixtures {
            let executable = directory.appendingPathComponent(kind.rawValue)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            configurations.append(.init(kind: kind, executable: executable.path, expectedVersion: "fixture 1.0"))
        }
        let adapter = ProviderCLIAdapter(
            configurations: configurations,
            processPort: port,
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let preflight = await adapter.preflight().filter(\.enabled)
        XCTAssertEqual(Set(preflight.map(\.kind)), Set(fixtures.map(\.0)))

        let expected: [(ProviderKind, String, String?)] = [
            (.claudeCompatible, "claude done", "claude-session"),
            (.openCodeACP, "acp done", "acp-session"),
            (.cursorACP, "acp done", "acp-session"),
            (.headlessAdapter, "headless done", "headless-session"),
            (.mcp, "file_search\nread_file", nil)
        ]
        for (kind, output, identity) in expected {
            let events = ProviderEventRecorder()
            let result = try await adapter.executeStreaming(.init(kind: kind, model: nil, prompt: "contract prompt", workingDirectory: directory.path, runID: UUID())) { event in
                await events.record(event)
            }
            XCTAssertEqual(result.output, output, kind.rawValue)
            XCTAssertEqual(result.providerSessionID, identity, kind.rawValue)
            let observed = await events.values()
            XCTAssertTrue(observed.contains { if case .assistantFinal = $0 { true } else { false } } || observed.contains { if case .assistantDelta = $0 { true } else { false } }, kind.rawValue)
            XCTAssertTrue(observed.contains { if case .completed = $0 { true } else { false } }, kind.rawValue)
        }
    }

    func testPortablePortCapturesAndReapsProviderOutput() async throws {
        let executable = ["/bin/echo", "/usr/bin/echo"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let echo = try XCTUnwrap(executable)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let port = try PortableProcessSupervisionPort()
        let captured = try await port.launchCaptured(executable: echo, arguments: ["provider-output"], environment: [:], workingDirectory: FileManager.default.temporaryDirectory.path, helperToken: UUID().uuidString, outputDirectory: output.path)
        let result = try await port.waitForCapturedProcess(captured, maximumBytes: 1024)
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "provider-output")
        let reaped = try await port.inspect(pid: captured.identity.pid)
        XCTAssertNil(reaped)
    }

    func testNativeProviderProtocolsReceiveReadOnlyExecutionPolicy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(ProviderKind, String)] = [
            (.codex, Self.policyCodexScript()),
            (.claudeCompatible, Self.policyClaudeScript()),
            (.openCodeACP, Self.policyACPScript()),
            (.headlessAdapter, Self.policyHeadlessScript())
        ]
        var configurations: [ProviderCLIConfiguration] = []
        for (kind, script) in fixtures {
            let executable = directory.appendingPathComponent(kind.rawValue)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            configurations.append(.init(kind: kind, executable: executable.path))
        }
        let adapter = try ProviderCLIAdapter(
            configurations: configurations,
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        for (kind, _) in fixtures {
            _ = try await adapter.executeStreaming(.init(
                kind: kind,
                model: nil,
                prompt: "inspect",
                workingDirectory: directory.path,
                runID: UUID(),
                policy: .init(mode: .readOnly)
            )) { _ in }
        }
        let codex = try String(contentsOf: directory.appendingPathComponent("codex.log"), encoding: .utf8)
        XCTAssertTrue(codex.contains(#""sandbox":"read-only""#))
        XCTAssertTrue(codex.contains(#""type":"readOnly""#))
        let claude = try String(contentsOf: directory.appendingPathComponent("claude.log"), encoding: .utf8)
        XCTAssertTrue(claude.contains("--permission-mode plan"))
        XCTAssertTrue(claude.contains("--disallowedTools Bash,Write,Edit,NotebookEdit"))
        let acp = try String(contentsOf: directory.appendingPathComponent("acp.log"), encoding: .utf8)
        XCTAssertTrue(acp.contains("set_config_option"), acp)
        XCTAssertTrue(acp.contains(#""value":"plan""#), acp)
        let headless = try String(contentsOf: directory.appendingPathComponent("headless.log"), encoding: .utf8)
        XCTAssertTrue(headless.contains(#""mode":"readOnly""#))
        XCTAssertTrue(headless.contains(#""writableRoots":[]"#))
    }

    func testNativeCodexResumeSteerAndApprovalUseOneLiveTransportReader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try Data(Self.controlCodexScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .codex, executable: executable.path)],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let runID = UUID()
        let events = ProviderEventRecorder()
        let task = Task {
            try await adapter.executeStreaming(.init(
                kind: .codex,
                model: nil,
                prompt: "continue",
                workingDirectory: directory.path,
                runID: runID,
                resumeProviderSessionID: "existing-thread"
            )) { event in
                await events.record(event)
            }
        }
        var interactionObserved = false
        for _ in 0 ..< 100 {
            if await events.values().contains(where: {
                if case .interactionRequested = $0 { true } else { false }
            }) {
                interactionObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard interactionObserved else {
            _ = try await task.value
            return XCTFail("ACP provider completed without requesting permission")
        }
        let observedInteraction = await events.values().contains(where: {
            if case .interactionRequested = $0 { true } else { false }
        })
        XCTAssertTrue(observedInteraction)
        try await adapter.deliverInteraction(runID: runID, providerRequestID: "99", answer: Data(#"{"decision":"accept"}"#.utf8))
        try await adapter.steer(runID: runID, text: "steer now", targetTurnEpoch: 1)
        let result = try await task.value

        XCTAssertEqual(result.providerSessionID, "existing-thread")
        XCTAssertEqual(result.output, "steered done")
        let log = try String(contentsOf: directory.appendingPathComponent("control.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(#"thread\/resume"#), log)
        XCTAssertTrue(log.contains(#"turn\/steer"#), log)
        XCTAssertTrue(log.contains(#""id":99"#), log)
        XCTAssertTrue(log.contains(#""decision":"accept""#), log)

        let interruptedRunID = UUID()
        let interruptedEvents = ProviderEventRecorder()
        let interrupted = Task {
            try await adapter.executeStreaming(.init(
                kind: .codex,
                model: nil,
                prompt: "interrupt",
                workingDirectory: directory.path,
                runID: interruptedRunID,
                resumeProviderSessionID: "existing-thread"
            )) { event in
                await interruptedEvents.record(event)
            }
        }
        for _ in 0 ..< 100 {
            if await interruptedEvents.values().contains(where: {
                if case .interactionRequested = $0 { true } else { false }
            }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await adapter.cancel(runID: interruptedRunID)
        do {
            _ = try await interrupted.value
            XCTFail("Interrupted native Codex run unexpectedly completed")
        } catch {}
        let interruptedLog = try String(contentsOf: directory.appendingPathComponent("control.log"), encoding: .utf8)
        XCTAssertTrue(interruptedLog.contains(#"turn\/interrupt"#), interruptedLog)
    }

    func testNativeACPResumeSteerAndApprovalFenceTheLatestPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        try Data(Self.controlACPScript().utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = try ProviderCLIAdapter(
            configurations: [.init(kind: .openCodeACP, executable: executable.path)],
            processPort: PortableProcessSupervisionPort(),
            outputDirectory: directory.appendingPathComponent("output").path,
            ephemeralHomeRoot: directory.appendingPathComponent("homes").path
        )
        let runID = UUID()
        let events = ProviderEventRecorder()
        let task = Task {
            try await adapter.executeStreaming(.init(
                kind: .openCodeACP,
                model: nil,
                prompt: "continue",
                workingDirectory: directory.path,
                runID: runID,
                resumeProviderSessionID: "existing-acp"
            )) { event in
                await events.record(event)
            }
        }
        var interactionObserved = false
        for _ in 0 ..< 100 {
            if await events.values().contains(where: {
                if case .interactionRequested = $0 { true } else { false }
            }) {
                interactionObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard interactionObserved else {
            _ = try await task.value
            return XCTFail("ACP provider completed without requesting permission")
        }
        try await adapter.deliverInteraction(runID: runID, providerRequestID: "50", answer: Data(#"{"optionId":"allow"}"#.utf8))
        try await adapter.steer(runID: runID, text: "replacement", targetTurnEpoch: 2)
        let result = try await task.value

        XCTAssertEqual(result.providerSessionID, "existing-acp")
        XCTAssertEqual(result.output, "replacement done")
        let log = try String(contentsOf: directory.appendingPathComponent("control.log"), encoding: .utf8)
        XCTAssertTrue(log.contains(#"session\/load"#), log)
        XCTAssertTrue(log.contains(#"session\/cancel"#), log)
        XCTAssertTrue(log.contains(#""id":50"#), log)
        XCTAssertTrue(log.contains(#""optionId":"allow""#), log)
    }

    func testProcStatParserHandlesSpacesAndParenthesesInCommand() {
        let fields = ["S", "1", "42", "42"] + Array(repeating: "0", count: 15) + ["987654"]
        let line = "123 (provider worker (sandbox)) " + fields.joined(separator: " ")
        let stat = ProcStatParser.parse(line)
        XCTAssertEqual(stat?.pid, 123)
        XCTAssertEqual(stat?.parentPID, 1)
        XCTAssertEqual(stat?.processGroupID, 42)
        XCTAssertEqual(stat?.sessionID, 42)
        XCTAssertEqual(stat?.startTimeTicks, 987_654)
    }

    func testCancellationUsesTermThenVerifiedKillAndReap() async throws {
        let leader = ProcessIdentity(pid: 100, parentPID: 1, processGroupID: 100, sessionID: 100, startTimeTicks: 10, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let child = ProcessIdentity(pid: 101, parentPID: 100, processGroupID: 100, sessionID: 100, startTimeTicks: 11, bootID: "boot", executablePath: "/helper", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [child])
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.signals, [15, 9])
        XCTAssertEqual(result.reaped.sorted(), [100, 101])
    }

    func testCancellationFindsLateForkDuringGraceWindow() async throws {
        let leader = ProcessIdentity(pid: 200, parentPID: 1, processGroupID: 200, sessionID: 200, startTimeTicks: 20, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let late = ProcessIdentity(pid: 201, parentPID: 200, processGroupID: 200, sessionID: 200, startTimeTicks: 21, bootID: "boot", executablePath: "/late-helper", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [], lateChildren: [late])
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.signals, [15, 9])
        XCTAssertEqual(result.reaped.sorted(), [200, 201])
    }

    func testCancellationSignalsVerifiedDescendantThatEscapedLeaderProcessGroup() async throws {
        let leader = ProcessIdentity(pid: 210, parentPID: 1, processGroupID: 210, sessionID: 210, startTimeTicks: 20, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let escaped = ProcessIdentity(pid: 211, parentPID: 210, processGroupID: 211, sessionID: 211, startTimeTicks: 21, bootID: "boot", executablePath: "/escaped-helper", helperTokenDigest: "token")
        let port = FakeProcessPort(leader: leader, children: [escaped])
        let supervisor = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock())
        let runID = UUID()
        try await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.processGroups.sorted(), [210, 210, 211, 211])
        XCTAssertEqual(result.reaped.sorted(), [210, 211])
    }

    func testPersistedFamilyIsReconciledAfterSupervisorRestart() async throws {
        let leader = ProcessIdentity(pid: 300, parentPID: 1, processGroupID: 300, sessionID: 300, startTimeTicks: 30, bootID: "boot", executablePath: "/provider", helperTokenDigest: "token")
        let child = ProcessIdentity(pid: 301, parentPID: 300, processGroupID: 300, sessionID: 300, startTimeTicks: 31, bootID: "boot", executablePath: "/helper", helperTokenDigest: "token")
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let port = FakeProcessPort(leader: leader, children: [child])
        let initial = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock(), store: store)
        let runID = UUID()
        try await initial.register(runID: runID, leader: leader, connectionGeneration: 7)
        let activeBeforeRecovery = try await store.activeProcessFamilies()
        XCTAssertEqual(activeBeforeRecovery.map(\.runID), [runID])
        XCTAssertEqual(activeBeforeRecovery.first?.containmentMode, "cgroup-v2")

        let recovered = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock(), store: store)
        try await recovered.recoverPersistedFamilies()

        let activeAfterRecovery = try await store.activeProcessFamilies()
        XCTAssertTrue(activeAfterRecovery.isEmpty)
        let result = await port.result()
        XCTAssertEqual(result.reaped.sorted(), [300, 301])
        XCTAssertEqual(result.reconstructed.count, 1)
        XCTAssertEqual(result.reconstructed.first?.0, leader)
        XCTAssertEqual(result.reconstructed.first?.1, "cgroup-v2")
        try await store.close()
    }

    private static func fakeCodexAppServerScript(finalTextShell: String, version: String = "provider 1.0", delayBeforeCompletion: Bool = false) -> String {
        let delay = delayBeforeCompletion ? "sleep 1" : ":"
        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '\(version)'; exit 0; fi
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*start*|*method*thread*resume*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"22222222-2222-2222-2222-222222222222"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1"}}}'
              \(delay)
              printf '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-1","type":"agentMessage","text":"%s"}}}\n' "\(finalTextShell)"
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1"}}}'
              ;;
          esac
        done
        """
    }

    private static func fakeClaudeScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        while IFS= read -r line; do
          echo '{"type":"assistant","session_id":"claude-session","message":{"content":[{"type":"thinking","thinking":"reason"},{"type":"text","text":"claude done"}]}}'
          echo '{"type":"result","session_id":"claude-session","result":"claude done"}'
          break
        done
        """
    }

    private static func fakeACPScript(requiredArguments: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$*" != "\(requiredArguments)" ]; then exit 64; fi
        while IFS= read -r line; do
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*new*) echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"acp-session"}}' ;;
            *session*prompt*)
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"reason"}}}}'
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"acp done"}}}}'
              echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
              ;;
          esac
        done
        """
    }

    private static func fakeHeadlessAdapterScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$1" != "--headless-provider-json" ]; then exit 64; fi
        while IFS= read -r line; do
          echo '{"type":"reasoning","content":"reason"}'
          echo '{"type":"toolCall","id":"tool-1","name":"read_file","args":{"path":"A.swift"}}'
          echo '{"type":"toolResult","id":"tool-1","name":"read_file","result":"ok","failed":false}'
          echo '{"type":"finalMessage","content":"headless done"}'
          echo '{"type":"completion","providerSessionID":"headless-session"}'
          break
        done
        """
    }

    private static func fakeMCPServerScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo 'fixture 1.0'; exit 0; fi
        if [ "$#" -ne 0 ]; then exit 64; fi
        while IFS= read -r line; do
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}' ;;
            *tools*list*) echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"read_file"},{"name":"file_search"}]}}' ;;
          esac
        done
        """
    }

    private static func policyCodexScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" >> "$PWD/codex.log"
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*start*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"policy-thread"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-1"}}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-1","type":"agentMessage","text":"done"}}}'
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1"}}}' ;;
          esac
        done
        """
    }

    private static func policyClaudeScript() -> String {
        """
        #!/bin/sh
        echo "$*" > "$PWD/claude.log"
        while IFS= read -r line; do
          echo '{"type":"result","session_id":"claude-policy","result":"done"}'
          break
        done
        """
    }

    private static func policyACPScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" >> "$PWD/acp.log"
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*new*) echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"acp-policy","configOptions":[{"id":"mode","category":"mode","currentValue":"build","options":[{"value":"plan"},{"value":"build"}]}]}}' ;;
            *session*set_config_option*) echo '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"mode","category":"mode","currentValue":"plan","options":[{"value":"plan"},{"value":"build"}]}]}}' ;;
            *session*prompt*)
              echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"done"}}}}'
              echo '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}' ;;
          esac
        done
        """
    }

    private static func policyHeadlessScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" > "$PWD/headless.log"
          echo '{"type":"finalMessage","content":"done"}'
          echo '{"type":"completion","providerSessionID":"headless-policy"}'
          break
        done
        """
    }

    private static func controlCodexScript() -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          echo "$line" >> "$PWD/control.log"
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
            *method*thread*resume*) echo '{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"existing-thread"}}}' ;;
            *method*turn*start*)
              echo '{"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"turn-control"}}}'
              echo '{"jsonrpc":"2.0","id":99,"method":"item/commandExecution/requestApproval","params":{"reason":"approve control"}}' ;;
            *method*turn*steer*)
              echo '{"jsonrpc":"2.0","id":4,"result":{}}'
              echo '{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"id":"message-control","type":"agentMessage","text":"steered done"}}}'
              echo '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-control"}}}' ;;
          esac
        done
        """
    }

    private static func controlACPScript() -> String {
        """
        #!/bin/sh
        prompts=0
        while IFS= read -r line; do
          echo "$line" >> "$PWD/control.log"
          case "$line" in
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}' ;;
            *session*load*) echo '{"jsonrpc":"2.0","id":2,"result":{}}' ;;
            *session*prompt*)
              prompts=$((prompts + 1))
              if [ "$prompts" -eq 1 ]; then
                echo '{"jsonrpc":"2.0","id":50,"method":"session/request_permission","params":{"toolCall":{"title":"approve acp"},"options":[{"optionId":"allow"},{"optionId":"deny"}]}}'
              else
                echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"replacement done"}}}}'
                echo '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
              fi ;;
          esac
        done
        """
    }
}

private actor RecordingProviderRunner: WorkspaceCommandRunning {
    private var arguments: [[String]] = []

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        self.arguments.append(arguments)
        return """
        {"type":"thread.started","thread_id":"11111111-1111-1111-1111-111111111111"}
        {"type":"item.completed","item":{"type":"agent_message","text":"done"}}
        """
    }

    func calls() -> [[String]] {
        arguments
    }
}

private actor ProviderIdentityObserver {
    private var identity: String?

    func record(_ value: String) {
        identity = value
    }

    func value() -> String? {
        identity
    }
}

private actor ProviderEventRecorder {
    private var events: [ProviderRuntimeEvent] = []

    func record(_ event: ProviderRuntimeEvent) {
        events.append(event)
    }

    func values() -> [ProviderRuntimeEvent] {
        events
    }
}
