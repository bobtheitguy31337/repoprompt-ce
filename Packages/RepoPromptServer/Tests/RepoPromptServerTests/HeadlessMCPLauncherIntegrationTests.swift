import Foundation
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServerExecutable
@testable import RepoPromptHeadlessRuntime
final class HeadlessMCPLauncherIntegrationTests: XCTestCase {
    func testPrivateHelperPublishesContractAndRejectsStandaloneLaunch() throws {
        let helper = try helperExecutable()
        let contract = try run(helper, arguments: ["--print-launcher-contract-version"])
        XCTAssertEqual(contract.status, 0)
        XCTAssertEqual(contract.stdout, "1\n")
        XCTAssertEqual(contract.stderr, "")

        let standalone = try run(helper, arguments: [])
        XCTAssertEqual(standalone.status, 64)
        XCTAssertEqual(standalone.stdout, "")
        XCTAssertTrue(standalone.stderr.contains("incompatible or missing launcher contract"))

        let incompatible = try run(
            helper,
            arguments: ["--launcher-contract-version", "999"]
        )
        XCTAssertEqual(incompatible.status, 64)
        XCTAssertTrue(incompatible.stderr.contains("incompatible or missing launcher contract"))
    }

    private func helperExecutable() throws -> URL {
        var cursor = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = cursor.appendingPathComponent("repoprompt-mcp-headless-runtime")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        throw XCTSkip("private helper product is not present beside the Server test bundle")
    }

    private func run(
        _ executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
