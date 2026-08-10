import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
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
    }

    func reap(pid: Int32) async throws {
        reapedPIDs.append(pid)
    }

    func result() -> (signals: [Int32], reaped: [Int32]) {
        (observedSignals, reapedPIDs)
    }
}

final class ProviderSupervisorTests: XCTestCase {
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
