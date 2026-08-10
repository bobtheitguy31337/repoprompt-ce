import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol
import XCTest

final class ProtocolAndLifecycleTests: XCTestCase {
    func testCanonicalRequestSigningMatchesGoblinGoldenVector() throws {
        let key = Data("test-key".utf8)
        let timestamp = "2026-08-10T12:34:56.789Z"
        let nonce = "YWJjZGVmZ2hpamtsbW5vcA"
        let bodyDigest = CanonicalSigning.bodyDigest(Data("{}".utf8))
        let decisionDigest = CanonicalSigning.bodyDigest(Data())
        let canonical = CanonicalSigning.requestString(method: "post", pathAndQuery: "/internal/v1/sessions?x=1", timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: "key-1")
        let signature = CanonicalSigning.hmacSHA256(message: canonical, key: key)
        XCTAssertEqual(signature, "8e595f118f914ac3f931c4a90c0bd6ebc53ef6a7e7588be0a71bd6d1419674b4")
        XCTAssertEqual(signature.count, 64)
        let parsedTimestamp = try XCTUnwrap(CanonicalSigning.parseISO8601(timestamp))
        XCTAssertEqual(parsedTimestamp.timeIntervalSince1970, 1_786_365_296.789, accuracy: 0.001)
        XCTAssertEqual(CanonicalSigning.base64URLDecode(CanonicalSigning.base64URLEncode(Data("decision".utf8))), Data("decision".utf8))
        XCTAssertNotEqual(signature, CanonicalSigning.hmacSHA256(message: canonical + "x", key: key))
    }

    func testV1DTOsUseLowerCamelKeysAndLogicalOnlyProjections() throws {
        let storeID = UUID()
        let cursor = ServiceCursor(storeID: storeID, globalSequence: 7)
        let rootID = UUID()
        let actor = ExternalActor(goblinUserID: "user-1", username: "alice", displayName: "Alice")
        let project = ProjectSnapshot(projectID: UUID(), name: "P", creator: actor, state: .active, roots: [.init(rootID: rootID, logicalName: "source", canonicalPath: "/private/source", writable: true)], revision: 1, cursor: cursor)
        let projectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectWireSnapshot(project))) as? [String: Any])
        XCTAssertNotNil(projectJSON["projectId"])
        XCTAssertNil(projectJSON["projectID"])
        let roots = try XCTUnwrap(projectJSON["roots"] as? [[String: Any]])
        XCTAssertNotNil(roots.first?["rootId"])
        XCTAssertNil(roots.first?["canonicalPath"])

        let worktree = WorktreeBindingSnapshot(bindingID: UUID(), projectID: project.projectID, rootID: rootID, sessionID: UUID(), baseRef: "main", branch: "audit", physicalPath: "/private/worktree", ownershipState: .active, mergeState: .clean, revision: 1)
        let worktreeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorktreeWireSnapshot(worktree))) as? [String: Any])
        XCTAssertNotNil(worktreeJSON["bindingId"])
        XCTAssertNil(worktreeJSON["bindingID"])
        XCTAssertNil(worktreeJSON["physicalPath"])

        let commandData = try JSONEncoder().encode(SessionCommand.cancelSession(expectedRunID: UUID(), expectedGeneration: 3))
        let commandJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: commandData) as? [String: Any])
        XCTAssertEqual(commandJSON["operation"] as? String, "cancelSession")
        XCTAssertNotNil(commandJSON["expectedRunId"])
        XCTAssertNil(commandJSON["cancelSession"])

        let pageData = try JSONEncoder().encode(Page(items: [ProjectWireSnapshot(project)], nextPageToken: "opaque", cursor: cursor))
        let pageJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: pageData) as? [String: Any])
        XCTAssertNotNil(pageJSON["nextPageToken"])
        XCTAssertNotNil(pageJSON["cursor"])
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
