import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
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
    private var observedSignals: [Int32] = []
    private var reapedPIDs: [Int32] = []

    init(leader: ProcessIdentity, children: [ProcessIdentity]) {
        self.leader = leader
        self.children = children
    }

    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity {
        leader
    }

    func inspect(pid: Int32) async throws -> ProcessIdentity? {
        ([leader] + children).first { $0.pid == pid }
    }

    func descendants(of pid: Int32) async throws -> [ProcessIdentity] {
        pid == leader.pid ? children : []
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
        await supervisor.register(runID: runID, leader: leader)

        try await supervisor.cancel(runID: runID)

        let result = await port.result()
        XCTAssertEqual(result.signals, [15, 9])
        XCTAssertEqual(result.reaped.sorted(), [100, 101])
    }
}
