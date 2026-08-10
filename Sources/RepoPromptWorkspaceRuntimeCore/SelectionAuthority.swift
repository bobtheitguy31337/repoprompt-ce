import Foundation
import RepoPromptServiceProtocol

public struct LogicalSelectionEntry: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case full, slices, codeMap = "codemap_only" }
    public let rootID: UUID
    public let logicalPath: String
    public let mode: Mode
    public let ranges: [ClosedRange<Int>]
    public init(rootID: UUID, logicalPath: String, mode: Mode, ranges: [ClosedRange<Int>] = []) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.mode = mode
        self.ranges = ranges
    }
}

public actor SessionSelectionAuthority {
    public let sessionID: UUID
    private var entries: [LogicalSelectionEntry]
    private var revisionValue: Int64
    public init(sessionID: UUID, template: [LogicalSelectionEntry] = []) {
        self.sessionID = sessionID
        entries = template
        revisionValue = 1
    }

    public func snapshot() -> (entries: [LogicalSelectionEntry], revision: Int64) {
        (entries, revisionValue)
    }

    public func replace(_ next: [LogicalSelectionEntry], expectedRevision: Int64) throws {
        guard revisionValue == expectedRevision else { throw ServiceAPIError(code: .staleRevision, message: "Selection revision is stale", currentRevision: revisionValue) }
        entries = next
        revisionValue += 1
    }
}

public protocol ContextBuilderRuntimeService: Sendable {
    func propose(sessionID: UUID, expectedSelectionRevision: Int64, instructions: String, budget: Int) async throws -> [LogicalSelectionEntry]
}

public protocol OracleRuntimeService: Sendable {
    func ask(sessionID: UUID, chatID: UUID?, prompt: String, contextMode: String) async throws -> String
}
