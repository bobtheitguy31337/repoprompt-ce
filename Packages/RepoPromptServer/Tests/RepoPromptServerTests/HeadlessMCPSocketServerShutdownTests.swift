#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RepoPromptAuthorityAPI
import RepoPromptMCPAdapter
import RepoPromptRuntimeModel
@testable import RepoPromptServerExecutable
import XCTest

final class HeadlessMCPSocketServerShutdownTests: XCTestCase {
    func testSilentClientIsReleasedBySocketShutdownWithinChildDrainBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let adapter = RepoPromptMCPAdapter(serving: UnusedMCPServing())
        let server = HeadlessMCPSocketServer(socketURL: socketURL, adapter: adapter)
        try await server.start()

        let client = PortablePOSIX.unixStreamSocket()
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { PortablePOSIX.closeDescriptor(client) }
        var address = sockaddr_un()
        XCTAssertTrue(PortablePOSIX.fillUnixAddress(&address, path: socketURL.path))
        XCTAssertEqual(PortablePOSIX.connectUnix(client, &address), 0)

        let clock = ContinuousClock()
        let registrationDeadline = clock.now.advanced(by: .seconds(1))
        while await server.activeClientCount() == 0, clock.now < registrationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let activeClientCount = await server.activeClientCount()
        XCTAssertEqual(activeClientCount, 1)

        let started = clock.now
        let report = await server.stop(clientDrainTimeout: .milliseconds(200))
        let elapsed = started.duration(to: clock.now)
        XCTAssertEqual(report.clientCount, 1)
        XCTAssertTrue(report.clean)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        let repeatedReport = await server.stop(clientDrainTimeout: .zero)
        XCTAssertEqual(repeatedReport, report)
    }
}

private struct UnusedMCPServing: RepoPromptMCPServing {
    private enum StubError: Error { case unused }

    func projectSnapshot(id _: UUID) async throws -> ProjectSnapshot { throw StubError.unused }
    func sessionSnapshot(id _: UUID) async throws -> SessionSnapshot { throw StubError.unused }
    func events(after _: ServiceCursor?, limit _: Int) async throws -> EventPage { throw StubError.unused }
    func advertisedToolNames(isRootSession _: Bool) async -> Set<String> { [] }

    func invoke(
        toolName _: String,
        argumentsJSON _: Data,
        binding _: AuthorityMCPBinding
    ) async throws -> Data {
        throw StubError.unused
    }
}
