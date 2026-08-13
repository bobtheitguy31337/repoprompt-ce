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

    private struct PresentationUnit {
        let sequence: Int64
        let beforeSequence: Int64
        let turn: AgentPresentationTurnWire
    }

    private struct LegacyTextAccumulator {
        var content = ""
        var lastEntry: TranscriptEntry?
        var revision: Int64 = 0

        mutating func append(_ entry: TranscriptEntry) {
            content = AgentTranscriptPresentationService.mergingLegacyFragment(content, entry.content)
            lastEntry = entry
            revision += 1
        }
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
        let legacyUnits = Self.reconstructedLegacyUnits(legacyCandidates)
        var units: [PresentationUnit] = []

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
                guard interaction.runID == record.identity.runID, Self.isActionable(interaction) else { return nil }
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
            units.append(.init(sequence: record.lastSequence, beforeSequence: record.lastSequence, turn: projected))
        }

        let remaining = max(0, boundedLimit - units.count)
        let pageLegacy = Array(legacyUnits.suffix(remaining))
        units.append(contentsOf: pageLegacy)
        units.sort { $0.sequence < $1.sequence }

        let oldest = units.first?.beforeSequence
        let hasMoreSemantic = semantic.count > pageSemantic.count
        let hasMoreLegacy = legacyUnits.count > pageLegacy.count
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
        let pending = interactions.filter(Self.isActionable).map { Self.interactionWire($0, turnID: "live-tail", mutable: mutableInteractions) }
        return .init(presentationRevision: revision, presentationCursor: CanonicalSigning.bodyDigest(Data(cursorSeed.utf8)), turns: units.map(\.turn), nextPageToken: next, pendingInteractions: pending)
    }

    nonisolated static func isActionable(_ interaction: InteractionSnapshot) -> Bool {
        interaction.state == .pending || interaction.state == .deliveryIntent
    }

    private static func reconstructedLegacyUnits(_ transcript: [TranscriptEntry]) -> [PresentationUnit] {
        let sorted = transcript.sorted {
            $0.sessionSequence == $1.sessionSequence
                ? $0.entryID.uuidString < $1.entryID.uuidString
                : $0.sessionSequence < $1.sessionSequence
        }
        var groups: [[TranscriptEntry]] = []
        var current: [TranscriptEntry] = []
        for entry in sorted {
            if entry.kind == .human, !current.isEmpty {
                groups.append(current)
                current.removeAll(keepingCapacity: true)
            }
            current.append(entry)
        }
        if !current.isEmpty { groups.append(current) }
        return groups.compactMap(projectLegacyGroup)
    }

    private static func projectLegacyGroup(_ entries: [TranscriptEntry]) -> PresentationUnit? {
        guard let first = entries.first, let last = entries.last else { return nil }
        let request = entries.first { $0.kind == .human }
        var assistant = LegacyTextAccumulator()
        var reasoning = LegacyTextAccumulator()
        var activities: [AgentSemanticPresentationActivity] = []

        for entry in entries {
            let id = "legacy:\(entry.entryID.uuidString.lowercased())"
            switch entry.kind {
            case .human:
                continue
            case .assistant:
                assistant.append(entry)
            case .reasoning:
                reasoning.append(entry)
            case .progress:
                activities.append(.init(id: id, sequence: entry.sessionSequence, revision: 1, kind: "progress", content: entry.content))
            case .tool:
                activities.append(.init(id: id, sequence: entry.sessionSequence, revision: 1, kind: "note", content: entry.content, summary: "Tool activity"))
            case .system:
                activities.append(.init(id: id, sequence: entry.sessionSequence, revision: 1, kind: "note", content: entry.content))
            }
        }
        if let entry = reasoning.lastEntry, !reasoning.content.isEmpty {
            activities.append(.init(
                id: "legacy:\(entry.entryID.uuidString.lowercased()):reasoning",
                sequence: entry.sessionSequence,
                revision: reasoning.revision,
                kind: "reasoning",
                content: reasoning.content
            ))
        }
        if let entry = assistant.lastEntry, !assistant.content.isEmpty {
            activities.append(.init(
                id: "legacy:\(entry.entryID.uuidString.lowercased()):assistant",
                sequence: entry.sessionSequence,
                revision: assistant.revision,
                kind: "assistant",
                content: assistant.content
            ))
        }

        let turnID = "legacy:\((request ?? first).entryID.uuidString.lowercased())"
        let projected = AgentTranscriptPresentationCore.project(.init(
            turnID: turnID,
            responseSpanID: nil,
            requestAnchorID: request?.entryID,
            requestText: request?.content ?? "",
            activities: activities
        ))
        let blocks = request == nil ? projected.blocks.filter { block in
            if case .request = block { return false }
            return true
        } : projected.blocks
        guard !blocks.isEmpty else { return nil }
        let turn = AgentPresentationTurnWire(
            turnID: turnID,
            responseSpanID: projected.responseSpanID,
            requestAnchorID: projected.requestAnchorID,
            terminalState: projected.terminalState,
            blocks: blocks,
            interactions: projected.interactions,
            legacyStandalone: true
        )
        return .init(sequence: last.sessionSequence, beforeSequence: first.sessionSequence, turn: turn)
    }

    private static func mergingLegacyFragment(_ current: String, _ incoming: String) -> String {
        guard !incoming.isEmpty else { return current }
        guard !current.isEmpty else { return String(incoming.prefix(262_144)) }
        if incoming == current || current.hasPrefix(incoming) { return current }
        if incoming.hasPrefix(current) { return String(incoming.prefix(262_144)) }

        let normalizedCurrent = current.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let normalizedIncoming = incoming.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        if normalizedIncoming == normalizedCurrent {
            return current.count >= incoming.count ? current : String(incoming.prefix(262_144))
        }
        return String((current + incoming).prefix(262_144))
    }

    private func encodePageToken(actorID: String, sessionID: UUID, beforeSequence: Int64) throws -> String {
        let binding = "\(actorID)\u{0}\(sessionID.uuidString.lowercased())\u{0}\(beforeSequence)"
        let token = PageToken(actorID: actorID, sessionID: sessionID, beforeSequence: beforeSequence, digest: CanonicalSigning.bodyDigest(Data(binding.utf8)))
        return try JSONEncoder.serviceEncoder.encode(token).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private func decodePageToken(_ value: String?, actorID: String, sessionID: UUID) throws -> Int64? {
        guard let value else { return nil }
        var standardBase64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standardBase64 += String(repeating: "=", count: (4 - standardBase64.count % 4) % 4)
        guard value.utf8.count <= 2048,
              let data = Data(base64Encoded: standardBase64),
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
