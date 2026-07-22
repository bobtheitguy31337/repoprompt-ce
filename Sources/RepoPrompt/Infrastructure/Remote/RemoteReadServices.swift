import Foundation
import RepoPromptRemoteProtocol

struct RemoteTranscriptPageRecord: Sendable {
    let sessionID: UUID
    let items: [RemoteTranscriptItem]
    let nextSequenceIndex: Int?
    let hasMore: Bool
}

struct RemoteHistoryPageRecord: Sendable {
    let entries: [RemoteHistoryEntry]
    let hasMore: Bool
}

@MainActor
protocol RemoteTranscriptReadService: AnyObject {
    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int?,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPageRecord
}

@MainActor
protocol RemoteHistoryReadService: AnyObject {
    func history(query: String?, limit: Int) async -> RemoteHistoryPageRecord
}

/// Read-only adapters for the mobile conversation surfaces. They prefer the
/// authoritative live TabSession and fall back to the persisted AgentSession
/// store for closed or unloaded sessions.
@MainActor
final class WindowRemoteReadService: RemoteTranscriptReadService, RemoteHistoryReadService {
    private let contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)]

    init(contexts: [(agentMode: AgentModeViewModel, workspaceManager: WorkspaceManagerViewModel)]) {
        self.contexts = contexts
    }

    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int?,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPageRecord {
        let boundedLimit = min(max(limit, 1), 200)
        var transcript: AgentTranscript?

        for context in contexts {
            if let liveSession = context.agentMode.sessions.values.first(where: { $0.activeAgentSessionID == sessionID }) {
                transcript = liveSession.transcript
                break
            }

            for workspace in context.workspaceManager.workspaces where !workspace.isEphemeral {
                if let persisted = try? await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: workspace) {
                    transcript = persisted.transcript ?? .empty
                    break
                }
            }
            if transcript != nil { break }
        }

        guard let transcript else {
            throw RemoteReadServiceError.sessionNotFound
        }

        let allItems = Self.project(transcript: transcript, includeDetails: includeDetails)
        let start = afterSequenceIndex.map { index in
            allItems.firstIndex(where: { $0.sequenceIndex > index }) ?? allItems.count
        } ?? 0
        let end = min(start + boundedLimit, allItems.count)
        let pageItems = Array(allItems[start ..< end])
        let hasMore = end < allItems.count
        return RemoteTranscriptPageRecord(
            sessionID: sessionID,
            items: pageItems,
            nextSequenceIndex: hasMore ? pageItems.last?.sequenceIndex : nil,
            hasMore: hasMore
        )
    }

    func history(query: String?, limit: Int) async -> RemoteHistoryPageRecord {
        let boundedLimit = min(max(limit, 1), 100)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var entries: [RemoteHistoryEntry] = []

        for context in contexts {
            for workspace in context.workspaceManager.workspaces where !workspace.isEphemeral {
                let records = (try? await AgentSessionDataService.shared.indexedAgentSessionMetadataRecords(for: workspace)) ?? []
                entries.append(contentsOf: records.compactMap { record in
                    let workspaceID = record.workspaceID ?? workspace.id
                    let searchable = "\(record.name) \(record.id.uuidString)".lowercased()
                    if let normalizedQuery, !normalizedQuery.isEmpty, !searchable.contains(normalizedQuery) {
                        return nil
                    }
                    return RemoteHistoryEntry(
                        id: record.id,
                        workspaceID: workspaceID.uuidString,
                        sessionName: record.name,
                        lastActivityAt: record.lastActivityAt ?? record.lastUserMessageAt ?? record.savedAt,
                        turnCount: record.transcriptProjectionCounts?.canonicalVisibleRowCount ?? record.itemCount,
                        runState: Self.mapRunState(record.lastRunStateRaw)
                    )
                })
            }
        }

        var deduplicated: [UUID: RemoteHistoryEntry] = [:]
        for entry in entries {
            if let existing = deduplicated[entry.id], existing.lastActivityAt >= entry.lastActivityAt { continue }
            deduplicated[entry.id] = entry
        }
        let sorted = deduplicated.values.sorted { $0.lastActivityAt > $1.lastActivityAt }
        return RemoteHistoryPageRecord(
            entries: Array(sorted.prefix(boundedLimit)),
            hasMore: sorted.count > boundedLimit
        )
    }

    private static func project(
        transcript: AgentTranscript,
        includeDetails: Bool
    ) -> [RemoteTranscriptItem] {
        var projected: [RemoteTranscriptItem] = []
        for turn in transcript.turns {
            if let request = turn.request {
                projected.append(
                    RemoteTranscriptItem(
                        id: request.id,
                        turnID: turn.id,
                        timestamp: request.timestamp,
                        sequenceIndex: request.sequenceIndex,
                        kind: .request,
                        role: "user",
                        text: request.text,
                        summaryOnly: turn.retentionTier != .full,
                        detailAvailable: false
                    )
                )
            }

            for activity in turn.allActivities {
                let detail = includeDetails ? remoteDetail(for: activity) : nil
                projected.append(
                    RemoteTranscriptItem(
                        id: activity.id,
                        turnID: turn.id,
                        timestamp: activity.timestamp,
                        sequenceIndex: activity.sequenceIndex,
                        kind: .activity,
                        role: activity.role.rawValue,
                        text: activity.text.isEmpty ? nil : activity.text,
                        toolName: activity.toolExecution?.toolName,
                        toolStatus: activity.toolExecution?.status.rawValue,
                        summaryOnly: turn.retentionTier != .full || activity.toolExecution?.summaryOnly == true,
                        detailAvailable: hasDetail(for: activity),
                        detailText: detail.map(renderDetail),
                        detail: detail
                    )
                )
            }

            if turn.retentionTier != .full,
               let summary = turn.summary,
               let text = summary.conclusionText ?? summary.middleSummaryText ?? summary.requestText
            {
                let summarySequenceIndex = turn.allActivities.map(\.sequenceIndex).max()
                    ?? turn.request?.sequenceIndex
                    ?? 0
                projected.append(
                    RemoteTranscriptItem(
                        id: summary.middleSummaryItemID,
                        turnID: turn.id,
                        timestamp: turn.lastActivityAt ?? turn.startedAt,
                        sequenceIndex: summarySequenceIndex + 1,
                        kind: .summary,
                        role: "summary",
                        text: text,
                        summaryOnly: true,
                        detailAvailable: false
                    )
                )
            }
        }
        return projected.sorted {
            if $0.sequenceIndex == $1.sequenceIndex { return $0.timestamp < $1.timestamp }
            return $0.sequenceIndex < $1.sequenceIndex
        }
    }

    private static func hasDetail(for activity: AgentTranscriptActivity) -> Bool {
        guard let execution = activity.toolExecution else {
            return activity.reasoning?.isEmpty == false
        }
        return execution.argsJSON != nil
            || execution.resultJSON != nil
            || activity.reasoning?.isEmpty == false
            || !execution.keyPaths.isEmpty
            || execution.processID != nil
            || execution.exitCode != nil
            || execution.summaryText != nil
    }

    private static func remoteDetail(for activity: AgentTranscriptActivity) -> RemoteTranscriptDetail? {
        guard hasDetail(for: activity) else { return nil }
        let execution = activity.toolExecution
        return RemoteTranscriptDetail(
            argumentsJSON: execution?.argsJSON.map(sanitizeDetailText),
            resultJSON: execution?.resultJSON.map(sanitizeDetailText),
            reasoning: activity.reasoning.map(sanitizeDetailText),
            keyPaths: Array(execution?.keyPaths.prefix(100) ?? []),
            processID: execution?.processID,
            exitCode: execution?.exitCode,
            summaryText: execution?.summaryText.map(sanitizeDetailText),
            toolIsError: execution?.toolIsError
        )
    }

    private static func renderDetail(_ detail: RemoteTranscriptDetail) -> String {
        var sections: [String] = []
        if let args = detail.argumentsJSON, !args.isEmpty {
            sections.append("Arguments:\n\(args)")
        }
        if let result = detail.resultJSON, !result.isEmpty {
            sections.append("Result:\n\(result)")
        }
        if let reasoning = detail.reasoning, !reasoning.isEmpty {
            sections.append("Reasoning:\n\(reasoning)")
        }
        if !detail.keyPaths.isEmpty {
            sections.append("Files/worktree:\n\(detail.keyPaths.joined(separator: "\n"))")
        }
        if let summary = detail.summaryText, !summary.isEmpty {
            sections.append("Summary:\n\(summary)")
        }
        if let processID = detail.processID {
            sections.append("Process: \(processID)")
        }
        if let exitCode = detail.exitCode {
            sections.append("Exit code: \(exitCode)")
        }
        guard !sections.isEmpty else { return "No additional detail." }
        let rendered = sections.joined(separator: "\n\n")
        return rendered.count > 16_000 ? String(rendered.prefix(16_000)) + "\n…" : rendered
    }

    private static func sanitizeDetailText(_ raw: String) -> String {
        var detail = raw
        let secretPattern = #"(?i)("(?:api[_-]?key|token|password|secret|authorization)"\s*:\s*")([^"]*)(")"#
        if let regex = try? NSRegularExpression(pattern: secretPattern) {
            let range = NSRange(detail.startIndex..., in: detail)
            detail = regex.stringByReplacingMatches(
                in: detail,
                range: range,
                withTemplate: "$1[REDACTED]$3"
            )
        }
        detail = detail.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        if detail.count > 8_000 {
            detail = String(detail.prefix(8_000)) + "\n…"
        }
        return detail
    }

    private static func mapRunState(_ rawValue: String?) -> RemoteRunState {
        switch rawValue {
        case AgentSessionRunState.running.rawValue: .working
        case AgentSessionRunState.waitingForUser.rawValue,
             AgentSessionRunState.waitingForQuestion.rawValue,
             AgentSessionRunState.waitingForApproval.rawValue: .waitingForInput
        case AgentSessionRunState.completed.rawValue: .completed
        case AgentSessionRunState.cancelled.rawValue: .cancelled
        case AgentSessionRunState.failed.rawValue: .failed
        default: .idle
        }
    }
}

enum RemoteReadServiceError: LocalizedError {
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: "The requested session could not be found."
        }
    }
}
