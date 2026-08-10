import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
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

    func result() -> (signals: [Int32], processGroups: [Int32], reaped: [Int32]) {
        (observedSignals, observedProcessGroups, reapedPIDs)
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
        try Data("#!/bin/sh\necho '{\"type\":\"thread.started\",\"thread_id\":\"22222222-2222-2222-2222-222222222222\"}'\nsleep 2\necho '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}'\n".utf8).write(to: executable)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'provider 1.0'; exit 0; fi\ntouch \"$HOME/provider-wrote\"\nexec /bin/echo \"$HOME\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let port = try PortableProcessSupervisionPort()
        let adapter = ProviderCLIAdapter(configurations: [.init(kind: .codex, executable: executable.path, expectedVersion: "1.0")], processPort: port, processStore: store, outputDirectory: directory.appendingPathComponent("output").path, ephemeralHomeRoot: homes.path)
        let capabilities = await adapter.preflight()
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.enabled, true)
        XCTAssertEqual(capabilities.first { $0.kind == .codex }?.version, "provider 1.0")
        let runID = UUID()

        let output = try await adapter.complete(kind: .codex, model: nil, prompt: "prompt", workingDirectory: directory.path, runID: runID)

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), homes.appendingPathComponent(runID.uuidString).path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homes.appendingPathComponent(runID.uuidString).path))
        let processFamilyState = try await store.processFamilyState(runID: runID)
        XCTAssertEqual(processFamilyState, "exited")
        try await store.close()
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

        let recovered = ProviderProcessSupervisor(processPort: port, clock: ImmediateClock(), store: store)
        try await recovered.recoverPersistedFamilies()

        let activeAfterRecovery = try await store.activeProcessFamilies()
        XCTAssertTrue(activeAfterRecovery.isEmpty)
        let result = await port.result()
        XCTAssertEqual(result.reaped.sorted(), [300, 301])
        try await store.close()
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
