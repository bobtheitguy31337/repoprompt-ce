import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public actor AgentTranscriptPresentationService {
    private struct PageToken: Codable {
        let actorID: String
        let sessionID: UUID
        let beforeSequence: Int64
        let digest: String
    }

    private let store: SQLiteServiceStore

    public init(store: SQLiteServiceStore) {
        self.store = store
    }

    public func page(
        sessionID: UUID,
        actorID: String,
        legacyTranscript: [TranscriptEntry],
        interactions: [InteractionSnapshot] = [],
        pageToken: String? = nil,
        limit: Int = 25,
        mutableInteractions: Bool = false
    ) async throws -> AgentTranscriptPresentationPageWire {
        let boundedLimit = max(1, min(limit, 50))
        let before = try decodePageToken(pageToken, actorID: actorID, sessionID: sessionID)
        let semantic = try await store.semanticTurns(sessionID: sessionID, beforeSequence: before, limit: boundedLimit + 1)
        let pageSemantic = Array(semantic.prefix(boundedLimit))
        let coveredRanges = pageSemantic.map { $0.firstSequence ... $0.lastSequence }
        let legacyCandidates = legacyTranscript
            .filter { entry in
                (before == nil || entry.sessionSequence < before!) && !coveredRanges.contains(where: { $0.contains(entry.sessionSequence) })
            }
            .sorted { $0.sessionSequence > $1.sessionSequence }
        var units: [(sequence: Int64, turn: AgentPresentationTurnWire)] = []

        for record in pageSemantic {
            let canonical = try JSONDecoder.serviceDecoder.decode(CanonicalUserTurn.self, from: record.canonicalUserTurnJSON)
            let activities = try await store.semanticActivities(turnID: record.identity.turnID)
            let tools = try await store.semanticTools(turnID: record.identity.turnID)
            let toolsByActivity = Dictionary(grouping: tools, by: \.activityID)
            let presentationActivities = activities.map { activity in
                let tool = toolsByActivity[activity.activityID]?.max(by: { $0.revision < $1.revision }).map { value in
                    AgentPresentationToolWire(
                        executionID: value.executionID,
                        name: AgentTranscriptPresentationCore.normalizedToolName(value.normalizedName),
                        status: value.status,
                        summary: value.summary,
                        displayArguments: value.displayArguments,
                        displayResult: value.displayResult,
                        keyPaths: value.keyPaths,
                        processID: value.processID,
                        exitCode: value.exitCode
                    )
                }
                return AgentSemanticPresentationActivity(
                    id: activity.activityID.uuidString.lowercased(),
                    sequence: activity.canonicalSequence,
                    revision: activity.revision,
                    kind: activity.kind.rawValue,
                    content: activity.content,
                    summary: activity.summary,
                    status: activity.status,
                    tool: tool
                )
            }
            let attachedInteractions = interactions.compactMap { interaction -> AgentPresentationInteractionWire? in
                guard interaction.runID == record.identity.runID else { return nil }
                return Self.interactionWire(interaction, turnID: record.identity.turnID.uuidString.lowercased(), mutable: mutableInteractions)
            }
            let projected = AgentTranscriptPresentationCore.project(.init(
                turnID: record.identity.turnID.uuidString.lowercased(),
                responseSpanID: record.identity.responseSpanID.uuidString.lowercased(),
                requestAnchorID: record.identity.requestAnchorID,
                requestText: canonical.text,
                attachmentIDs: canonical.attachments.map(\.attachmentID),
                taggedFiles: canonical.taggedFiles,
                terminalState: record.terminalState,
                activities: presentationActivities,
                interactions: attachedInteractions
            ))
            units.append((record.lastSequence, projected))
        }

        let remaining = max(0, boundedLimit - units.count)
        for entry in legacyCandidates.prefix(remaining) {
            if let projected = AgentTranscriptPresentationCore.projectLegacy(entry) {
                units.append((entry.sessionSequence, projected))
            }
        }
        units.sort { $0.sequence < $1.sequence }

        let oldest = units.first?.sequence
        let hasMoreSemantic = semantic.count > pageSemantic.count
        let hasMoreLegacy = oldest.map { sequence in legacyTranscript.contains { $0.sessionSequence < sequence } } ?? false
        let next: String? = if let oldest, hasMoreSemantic || hasMoreLegacy { try encodePageToken(actorID: actorID, sessionID: sessionID, beforeSequence: oldest) } else { nil }
        var watermark = try await store.semanticWatermark(sessionID: sessionID)
        let latestSemanticSequence = try await store.latestSemanticSequence(sessionID: sessionID)
        let latestLegacySequence = legacyTranscript.map(\.sessionSequence).max() ?? 0
        if latestLegacySequence > latestSemanticSequence, watermark?.lastLegacySequence ?? 0 < latestLegacySequence {
            try await store.advanceSemanticWatermark(sessionID: sessionID, semanticSequence: latestSemanticSequence, legacySequence: latestLegacySequence, gapDetected: true, at: Date())
            watermark = try await store.semanticWatermark(sessionID: sessionID)
        }
        let revision = watermark?.presentationRevision ?? 0
        let cursorSeed = "\(sessionID.uuidString.lowercased()):\(revision):\(legacyTranscript.last?.sessionSequence ?? 0)"
        let pending = interactions.filter { $0.state == .pending || $0.state == .deliveryIntent }.map { Self.interactionWire($0, turnID: "live-tail", mutable: mutableInteractions) }
        return .init(presentationRevision: revision, presentationCursor: CanonicalSigning.bodyDigest(Data(cursorSeed.utf8)), turns: units.map(\.turn), nextPageToken: next, pendingInteractions: pending)
    }

    private func encodePageToken(actorID: String, sessionID: UUID, beforeSequence: Int64) throws -> String {
        let binding = "\(actorID)\u{0}\(sessionID.uuidString.lowercased())\u{0}\(beforeSequence)"
        let token = PageToken(actorID: actorID, sessionID: sessionID, beforeSequence: beforeSequence, digest: CanonicalSigning.bodyDigest(Data(binding.utf8)))
        return try JSONEncoder.serviceEncoder.encode(token).base64EncodedString()
    }

    private func decodePageToken(_ value: String?, actorID: String, sessionID: UUID) throws -> Int64? {
        guard let value else { return nil }
        guard value.utf8.count <= 2048,
              let data = Data(base64Encoded: value),
              let token = try? JSONDecoder.serviceDecoder.decode(PageToken.self, from: data),
              token.actorID == actorID,
              token.sessionID == sessionID
        else { throw ServiceAPIError(code: .cursorExpired, message: "Presentation page token is invalid") }
        let binding = "\(actorID)\u{0}\(sessionID.uuidString.lowercased())\u{0}\(token.beforeSequence)"
        guard token.digest == CanonicalSigning.bodyDigest(Data(binding.utf8)) else {
            throw ServiceAPIError(code: .cursorExpired, message: "Presentation page token is invalid")
        }
        return token.beforeSequence
    }

    private static func interactionWire(_ value: InteractionSnapshot, turnID: String, mutable: Bool) -> AgentPresentationInteractionWire {
        let prompt = String(data: value.payload, encoding: .utf8).map { String($0.prefix(8_192)) } ?? "Provider interaction"
        return .init(
            interactionID: value.interactionID,
            kind: value.kind == .approval ? .approval : .question,
            state: value.state.rawValue,
            prompt: prompt,
            turnID: turnID,
            liveTail: true,
            requiresAttention: value.state == .pending,
            mutable: mutable && value.state == .pending,
            revision: value.revision
        )
    }
}
