import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol
import XCTest

final class ProtocolAndLifecycleTests: XCTestCase {
    func testCanonicalRequestSigningIsStableAndSensitive() {
        let key = Data("test-key".utf8)
        let canonical = CanonicalSigning.requestString(method: "post", pathAndQuery: "/internal/v1/sessions?x=1", timestamp: "1", nonce: "abcdefghijklmnop", bodyDigest: "body", authorizationDecisionDigest: "decision", keyID: "key-1")
        let first = CanonicalSigning.hmacSHA256(message: canonical, key: key)
        let second = CanonicalSigning.hmacSHA256(message: canonical, key: key)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, CanonicalSigning.hmacSHA256(message: canonical + "x", key: key))
    }

    func testLifecycleGateAcceptsOneTerminalResult() {
        let binding = RunBindingIdentity(runID: UUID(), generation: 7, turnEpoch: 3, connectionGeneration: 2)
        var gate = AgentRunLifecycleGate(binding: binding)
        XCTAssertEqual(gate.accept(binding: binding), .accepted)
        XCTAssertEqual(gate.accept(binding: binding, terminal: .sessionCompleted), .accepted)
        XCTAssertEqual(gate.accept(binding: binding, terminal: .sessionFailed), .terminalAlreadySettled)
        XCTAssertEqual(gate.terminalEvent, .sessionCompleted)
    }

    func testLifecycleGateFencesStaleGenerationEpochAndConnection() {
        let binding = RunBindingIdentity(runID: UUID(), generation: 2, turnEpoch: 4, connectionGeneration: 6)
        var gate = AgentRunLifecycleGate(binding: binding)
        XCTAssertEqual(gate.accept(binding: .init(runID: binding.runID, generation: 1, turnEpoch: 4, connectionGeneration: 6)), .staleGeneration)
        XCTAssertEqual(gate.accept(binding: .init(runID: binding.runID, generation: 2, turnEpoch: 3, connectionGeneration: 6)), .staleTurnEpoch)
        XCTAssertEqual(gate.accept(binding: .init(runID: binding.runID, generation: 2, turnEpoch: 4, connectionGeneration: 5)), .staleConnection)
    }
}
