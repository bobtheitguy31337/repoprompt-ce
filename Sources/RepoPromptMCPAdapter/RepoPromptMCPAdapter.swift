import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

public struct RepoPromptMCPAdapter: Sendable {
    private let authority: RepoPromptHeadlessAuthority
    public init(authority: RepoPromptHeadlessAuthority) {
        self.authority = authority
    }

    public func projectSnapshot(id: UUID) async throws -> ProjectSnapshot {
        try await authority.projectSnapshot(projectID: id)
    }

    public func sessionSnapshot(id: UUID) async throws -> SessionSnapshot {
        try await authority.sessionSnapshot(sessionID: id)
    }

    public func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        try await authority.events(after: cursor, limit: limit)
    }
}
