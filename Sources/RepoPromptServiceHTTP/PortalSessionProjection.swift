import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptDomainRuntime
import RepoPromptPortalProtocol
import RepoPromptServiceProtocol

enum RepoPromptPortalSessionProjection {
    static let maximumPromptBytes = 64_000
    static let maximumModelBytes = 256
    static let maximumEntryBytes = 128 * 1024
    static let maximumPageBytes = 1 * 1024 * 1024

    static func tools() -> [PortalToolSummary] {
        MCPDomainToolCatalog.entries.map {
            PortalToolSummary(
                name: $0.name,
                scope: $0.scope.rawValue,
                capability: $0.capability.externalName,
                admissionClass: $0.admissionClass.rawValue
            )
        }
    }

    static func project(_ project: ProjectSnapshot) -> PortalProjectSummary {
        PortalProjectSummary(
            projectID: project.projectID,
            name: project.name,
            state: project.state,
            rootNames: project.roots.map(\.logicalName),
            revision: project.revision
        )
    }

    static func project(
        _ session: SessionSnapshot,
        agentControl: AgentSessionActionSnapshotWire? = nil,
        sidebarDepth: Int = 0
    ) -> PortalSessionSummary {
        PortalSessionSummary(
            sessionID: session.sessionID,
            projectID: session.projectID,
            parentSessionID: session.parentSessionID,
            title: title(for: session),
            provider: session.provider,
            providerSettingsID: session.providerSettingsID,
            model: session.model,
            state: session.state,
            revision: session.revision,
            runGeneration: session.runGeneration,
            turnEpoch: session.turnEpoch,
            lastActivityAt: session.transcript.last?.timestamp,
            sidebarDepth: sidebarDepth,
            effectiveContextWindowTokens: AgentContextWindowAuthority.effectiveTokens(
                reportedTokens: session.contextUsage?.modelContextWindow,
                providerID: session.providerSettingsID,
                runtimeKind: session.provider,
                modelRaw: session.model
            ),
            runPresentation: session.runPresentation,
            agentControl: agentControl,
            contextUsage: session.contextUsage
        )
    }

    /// Desktop keeps every sub-agent session adjacent to its parent and lets
    /// the freshest row in a subtree determine where that whole thread sits.
    /// Project the same ordering here so browser clients do not invent a
    /// second session-list state machine.
    static func sidebarSessions(
        _ sessions: [SessionSnapshot],
        controls: [UUID: AgentSessionActionSnapshotWire]
    ) -> [PortalSessionSummary] {
        let base = sessions.sorted { left, right in
            let leftActivity = left.transcript.last?.timestamp ?? .distantPast
            let rightActivity = right.transcript.last?.timestamp ?? .distantPast
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            return left.sessionID.uuidString < right.sessionID.uuidString
        }
        let indexByID = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($0.element.sessionID, $0.offset) })
        var childrenByParent: [UUID: [Int]] = [:]
        var childIndices = Set<Int>()

        for (index, session) in base.enumerated() {
            guard let parentID = session.parentSessionID,
                  parentID != session.sessionID,
                  let parentIndex = indexByID[parentID],
                  base[parentIndex].projectID == session.projectID
            else { continue }

            var visited: Set<UUID> = [session.sessionID]
            var cursor: UUID? = parentID
            var cycle = false
            while let current = cursor {
                guard visited.insert(current).inserted else {
                    cycle = true
                    break
                }
                cursor = indexByID[current].flatMap { base[$0].parentSessionID }
            }
            guard !cycle else { continue }
            childrenByParent[parentID, default: []].append(index)
            childIndices.insert(index)
        }

        var subtreePriorityByIndex: [Int: Int] = [:]
        func subtreePriority(_ index: Int) -> Int {
            if let cached = subtreePriorityByIndex[index] { return cached }
            var priority = index
            if let children = childrenByParent[base[index].sessionID] {
                for child in children {
                    priority = min(priority, subtreePriority(child))
                }
            }
            subtreePriorityByIndex[index] = priority
            return priority
        }

        var result: [PortalSessionSummary] = []
        result.reserveCapacity(base.count)
        func emit(_ index: Int, depth: Int) {
            let session = base[index]
            result.append(project(
                session,
                agentControl: controls[session.sessionID],
                sidebarDepth: min(depth, 6)
            ))
            let children = childrenByParent[session.sessionID] ?? []
            for child in children.sorted() {
                emit(child, depth: depth + 1)
            }
        }

        let roots = base.indices.filter { !childIndices.contains($0) }
        for root in roots.sorted(by: {
            let left = subtreePriority($0)
            let right = subtreePriority($1)
            return left == right ? $0 < $1 : left < right
        }) {
            emit(root, depth: 0)
        }
        return result
    }

    static func title(for session: SessionSnapshot) -> String {
        guard let firstHuman = session.transcript.first(where: {
            $0.kind == .human && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "Agent Session"
        }
        let normalized = firstHuman.content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "Agent Session" }
        let prefix = String(normalized.prefix(80))
        return normalized.count > prefix.count ? "\(prefix)…" : prefix
    }

    static func snapshotTitles(sessions: [SessionSnapshot], agents: [AgentSnapshot]) -> [String: String] {
        let labels = agents.reduce(into: [UUID: String]()) { result, agent in
            guard let label = agent.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return }
            result[agent.sessionID] = label
        }
        return Dictionary(uniqueKeysWithValues: sessions.map { session in
            (session.sessionID.uuidString, labels[session.sessionID] ?? title(for: session))
        })
    }

    static func presentationPage(
        session: SessionSnapshot,
        control: AgentSessionActionSnapshotWire,
        page: AgentTranscriptPresentationPageWire,
        sidebarSessions: [PortalSessionSummary] = []
    ) throws -> PortalSessionPresentationPage {
        let presentation = AgentTranscriptPresentationPageWire(
            schemaVersion: page.schemaVersion,
            presentationRevision: page.presentationRevision,
            presentationCursor: bounded(page.presentationCursor, bytes: 1_024),
            turns: Array(page.turns.prefix(25)).map(sanitize),
            nextPageToken: page.nextPageToken.map { bounded($0, bytes: 2_048) },
            pendingInteractions: Array(page.pendingInteractions.prefix(100)).map(sanitize)
        )
        guard try JSONEncoder.serviceEncoder.encode(presentation).count <= maximumPageBytes else {
            throw ServiceAPIError(code: .internalFailure, message: "Semantic transcript page exceeds the portal response bound")
        }
        return PortalSessionPresentationPage(
            session: project(session, agentControl: control),
            presentation: presentation,
            sidebarSessions: sidebarSessions
        )
    }

    private static func sanitize(_ turn: AgentPresentationTurnWire) -> AgentPresentationTurnWire {
        AgentPresentationTurnWire(
            turnID: bounded(turn.turnID, bytes: 1_024),
            responseSpanID: turn.responseSpanID.map { bounded($0, bytes: 1_024) },
            requestAnchorID: turn.requestAnchorID,
            terminalState: turn.terminalState.map { bounded($0, bytes: 1_024) },
            blocks: Array(turn.blocks.prefix(256)).map(sanitize),
            interactions: Array(turn.interactions.prefix(100)).map(sanitize),
            legacyStandalone: turn.legacyStandalone
        )
    }

    private static func sanitize(_ block: AgentPresentationBlockWire) -> AgentPresentationBlockWire {
        switch block {
        case let .request(id, row):
            .request(id: bounded(id, bytes: 1_024), row: sanitize(row))
        case let .activityCluster(id, rows, summary):
            .activityCluster(
                id: bounded(id, bytes: 1_024),
                rows: Array(rows.prefix(256)).map(sanitize),
                summary: AgentActivityClusterSummaryWire(
                    activityCount: summary.activityCount,
                    toolCount: summary.toolCount,
                    toolGroups: Array(summary.toolGroups.prefix(100)).map { bounded($0, bytes: 1_024) },
                    keyPaths: Array(summary.keyPaths.prefix(256)).map { bounded($0, bytes: 4_096) },
                    running: summary.running,
                    warning: summary.warning,
                    failed: summary.failed,
                    narration: summary.narration.map { bounded($0, bytes: maximumEntryBytes) },
                    title: bounded(summary.title, bytes: 4_096),
                    iconSemantic: bounded(summary.iconSemantic, bytes: 256),
                    defaultExpanded: summary.defaultExpanded
                )
            )
        case let .groupedHistory(id, rows, title):
            .groupedHistory(id: bounded(id, bytes: 1_024), rows: Array(rows.prefix(256)).map(sanitize), title: bounded(title, bytes: 4_096))
        case let .collapsedHistoryRange(id, count, title):
            .collapsedHistoryRange(id: bounded(id, bytes: 1_024), count: count, title: bounded(title, bytes: 4_096))
        case let .standaloneAssistant(id, row):
            .standaloneAssistant(id: bounded(id, bytes: 1_024), row: sanitize(row))
        case let .standaloneTool(id, row):
            .standaloneTool(id: bounded(id, bytes: 1_024), row: sanitize(row))
        case let .standaloneNote(id, row):
            .standaloneNote(id: bounded(id, bytes: 1_024), row: sanitize(row))
        case let .middleSummary(id, text):
            .middleSummary(id: bounded(id, bytes: 1_024), text: bounded(text, bytes: maximumEntryBytes))
        case let .conclusion(id, row):
            .conclusion(id: bounded(id, bytes: 1_024), row: sanitize(row))
        }
    }

    private static func sanitize(_ row: AgentPresentationRowWire) -> AgentPresentationRowWire {
        switch row {
        case let .userRequest(id, text, attachmentIDs, taggedFiles):
            .userRequest(
                id: bounded(id, bytes: 1_024),
                text: bounded(text, bytes: maximumEntryBytes),
                attachmentIDs: Array(attachmentIDs.prefix(100)),
                taggedFiles: Array(taggedFiles.prefix(100)).map {
                    ComposerTaggedFileReferenceWire(
                        rootID: $0.rootID,
                        logicalPath: bounded($0.logicalPath, bytes: 4_096),
                        worktreeBindingID: $0.worktreeBindingID,
                        displayName: bounded($0.displayName, bytes: 1_024)
                    )
                }
            )
        case let .assistant(id, text):
            .assistant(id: bounded(id, bytes: 1_024), text: bounded(text, bytes: maximumEntryBytes))
        case let .thinking(id, text):
            .thinking(id: bounded(id, bytes: 1_024), text: bounded(text, bytes: maximumEntryBytes))
        case let .progress(id, text):
            .progress(id: bounded(id, bytes: 1_024), text: bounded(text, bytes: maximumEntryBytes))
        case let .tool(id, tool):
            .tool(
                id: bounded(id, bytes: 1_024),
                tool: AgentPresentationToolWire(
                    executionID: bounded(tool.executionID, bytes: 1_024),
                    name: bounded(tool.name, bytes: 1_024),
                    status: tool.status,
                    summary: tool.summary.map { bounded($0, bytes: 4_096) },
                    displayArguments: tool.displayArguments.map { bounded($0, bytes: 64 * 1_024) },
                    displayResult: tool.displayResult.map { bounded($0, bytes: maximumEntryBytes) },
                    keyPaths: Array(tool.keyPaths.prefix(256)).map { bounded($0, bytes: 4_096) },
                    processID: tool.processID,
                    exitCode: tool.exitCode
                )
            )
        case let .note(id, text):
            .note(id: bounded(id, bytes: 1_024), text: bounded(text, bytes: maximumEntryBytes))
        case let .error(id, text, code):
            .error(id: bounded(id, bytes: 1_024), text: bounded(text, bytes: maximumEntryBytes), code: code.map { bounded($0, bytes: 1_024) })
        }
    }

    private static func sanitize(_ interaction: AgentPresentationInteractionWire) -> AgentPresentationInteractionWire {
        AgentPresentationInteractionWire(
            interactionID: interaction.interactionID,
            kind: interaction.kind,
            state: bounded(interaction.state, bytes: 256),
            prompt: bounded(interaction.prompt, bytes: 16 * 1_024),
            choices: Array(interaction.choices.prefix(100)).map { bounded($0, bytes: 4_096) },
            input: interaction.input.map(sanitize),
            resolution: interaction.resolution.map { bounded($0, bytes: 16 * 1_024) },
            turnID: bounded(interaction.turnID, bytes: 1_024),
            activityID: interaction.activityID.map { bounded($0, bytes: 1_024) },
            liveTail: interaction.liveTail,
            requiresAttention: interaction.requiresAttention,
            mutable: interaction.mutable,
            revision: interaction.revision
        )
    }

    private static func sanitize(
        _ input: AgentPresentationInteractionInputWire
    ) -> AgentPresentationInteractionInputWire {
        switch input {
        case let .singleChoice(choices, allowsCustom):
            .singleChoice(
                choices: Array(choices.prefix(100)).map(sanitize),
                allowsCustom: allowsCustom
            )
        case let .freeText(placeholder, multiline):
            .freeText(
                placeholder: placeholder.map { bounded($0, bytes: 4_096) },
                multiline: multiline
            )
        case let .questionnaire(questions):
            .questionnaire(
                questions: Array(questions.prefix(100)).map { question in
                    AgentPresentationQuestionWire(
                        id: bounded(question.id, bytes: 512),
                        prompt: bounded(question.prompt, bytes: 16 * 1_024),
                        choices: Array(question.choices.prefix(100)).map(sanitize),
                        allowsMultiple: question.allowsMultiple,
                        allowsCustom: question.allowsCustom,
                        required: question.required
                    )
                }
            )
        }
    }

    private static func sanitize(_ choice: AgentPresentationChoiceWire) -> AgentPresentationChoiceWire {
        AgentPresentationChoiceWire(
            id: bounded(choice.id, bytes: 512),
            displayName: bounded(choice.displayName, bytes: 2_048),
            detailText: choice.detailText.map { bounded($0, bytes: 4_096) }
        )
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        return String(decoding: value.utf8.prefix(bytes), as: UTF8.self)
    }

    static func validatedCreateInput(
        _ request: PortalCreateSessionRequest,
        provider: ProviderSettingsSnapshot,
        resolvedModel: String?,
        reasoningEffort: String?,
        runtimeDefaults: PortalDesktopSettingsService.RuntimeDefaults
    ) throws -> CreateSessionInput {
        let prompt = request.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Enter a message before starting a session")
        }
        guard prompt.utf8.count <= maximumPromptBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Initial prompt exceeds its portal bound")
        }
        guard (request.providerID == nil || provider.providerID == request.providerID),
              provider.deploymentAllowed,
              provider.effectiveEnabled,
              let runtimeKind = provider.providerID.runtimeKind
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "The selected provider is not available for new sessions", retryable: true)
        }
        if let model = resolvedModel {
            guard model.utf8.count <= maximumModelBytes,
                  provider.capabilities.supportsModelSelection,
                  provider.models.contains(where: { $0.id == model })
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "The selected model is not advertised by this provider")
            }
        }
        var providerSettings = runtimeDefaults.providerSettings
        providerSettings["provider.settingsID"] = provider.providerID.rawValue
        if let reasoningEffort { providerSettings["provider.reasoningEffort"] = reasoningEffort }
        return CreateSessionInput(
            projectID: request.projectID,
            provider: runtimeKind,
            providerSettingsID: provider.providerID,
            model: resolvedModel,
            visibility: .privateSession,
            initialPrompt: prompt,
            startImmediately: true,
            initialPermissionMode: runtimeDefaults.mode,
            initialProviderSettings: providerSettings
        )
    }

    static func validatedSendCommand(_ request: PortalSendMessageRequest) throws -> SessionCommand {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.expectedRevision > 0 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Session revision is invalid")
        }
        guard !text.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Enter a message before sending")
        }
        guard text.utf8.count <= maximumPromptBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Message exceeds its portal bound")
        }
        return .sendFollowup(text: text, expectedSessionRevision: request.expectedRevision)
    }
}
