import CryptoKit
import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

/// Main-actor projection adapter for the process-lifetime durable authority.
///
/// The adapter performs a one-time legacy import, submits explicit authority
/// commands, and projects returned snapshots. It never launches providers or
/// republishes UI-derived lifecycle/transcript state.
@MainActor
final class AgentModeAuthorityAdapter {
    static let shared = AgentModeAuthorityAdapter()

    private let actor = ExternalActor(
        userID: "macos-local-user",
        username: NSUserName(),
        displayName: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    )

    private init() {}

    func ensureSession(
        _ session: AgentModeViewModel.TabSession,
        workspace: WorkspaceModel,
        excludingCurrentUserMessage: String? = nil
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Agent tab has no persistent session identity")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let rootSessionID: UUID = if let parentSessionID = session.parentSessionID {
            try await authority
                .authoritySessionSnapshot(sessionID: parentSessionID)
                .session.rootSessionID
        } else {
            sessionID
        }
        let roots = workspace.repoPaths.enumerated().map { index, path in
            ProjectRootSnapshot(
                rootID: Self.stableUUID(namespace: workspace.id, value: path),
                logicalName: URL(fileURLWithPath: path).lastPathComponent.isEmpty
                    ? "root-\(index + 1)"
                    : URL(fileURLWithPath: path).lastPathComponent,
                canonicalPath: path,
                writable: true
            )
        }
        let rootIDsByPath = Dictionary(uniqueKeysWithValues: roots.map { ($0.canonicalPath, $0.rootID) })
        let worktrees = session.worktreeBindings.compactMap { binding -> WorktreeBindingSnapshot? in
            guard let rootID = rootIDsByPath[binding.logicalRootPath] else { return nil }
            return Self.worktreeSnapshot(
                binding,
                sessionID: sessionID,
                projectID: workspace.id,
                rootID: rootID,
                revision: 1
            )
        }
        var legacyItems = Self.authoritativeItems(session)
        if let excludingCurrentUserMessage,
           let lastHumanIndex = legacyItems.lastIndex(where: {
               $0.kind == .user && $0.text == excludingCurrentUserMessage
           })
        {
            legacyItems.remove(at: lastHumanIndex)
        }
        let snapshot = try await authority.ensureEmbeddedSession(EmbeddedSessionSeed(
            projectID: workspace.id,
            projectName: workspace.name,
            roots: roots,
            sessionID: sessionID,
            parentSessionID: session.parentSessionID,
            rootSessionID: rootSessionID,
            creator: actor,
            provider: Self.providerKind(session.selectedAgent),
            model: session.selectedModelRaw == AgentModel.defaultModel.rawValue ? nil : session.selectedModelRaw,
            visibility: .privateSession,
            transcript: Self.transcriptEntries(legacyItems, actor: actor),
            permissionMode: "workspaceWrite",
            providerSettings: Self.permissionSettings(session.permissionProfile),
            worktrees: worktrees
        ))
        await applyAuthoritySnapshot(snapshot, to: session)
        return snapshot
    }

    func startProviderRun(
        _ session: AgentModeViewModel.TabSession,
        workspace: WorkspaceModel,
        userMessage: String,
        providerPrompt: String
    ) async throws -> RunBindingSnapshot {
        let admitted = try await ensureSession(
            session,
            workspace: workspace,
            excludingCurrentUserMessage: userMessage
        )
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Agent tab has no persistent session identity")
        }
        startObserving(session)
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let payload = Self.presentationPayloadForLatestHumanItem(in: session, matching: userMessage)
        let digest = CanonicalSigning.bodyDigest(Data(providerPrompt.utf8))
        let snapshot = try await authority.startEmbeddedProviderRun(
            sessionID: sessionID,
            actor: actor,
            userMessage: userMessage,
            providerPrompt: providerPrompt,
            presentationPayload: payload,
            resumeMode: admitted.activeRun?.providerSessionID == nil ? .auto : .resume,
            idempotencyKey: "macos-run:\(UUID().uuidString)",
            requestDigest: digest
        )
        await applyAuthoritySnapshot(snapshot, to: session)
        guard let binding = snapshot.activeBinding else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Authority did not publish a provider run binding")
        }
        return binding
    }

    func steerProviderRun(
        _ session: AgentModeViewModel.TabSession,
        text: String
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionID = session.activeAgentSessionID,
              let binding = session.authorityRunBinding
        else {
            throw ServiceAPIError(code: .notFound, message: "No authoritative provider run is active")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let snapshot = try await authority.steerEmbeddedProviderRun(
            sessionID: sessionID,
            text: text,
            targetTurnEpoch: binding.turnEpoch,
            actor: actor,
            idempotencyKey: "macos-steer:\(UUID().uuidString)",
            requestDigest: CanonicalSigning.bodyDigest(Data(text.utf8))
        )
        await applyAuthoritySnapshot(snapshot, to: session)
        return snapshot
    }

    func cancelProviderRun(
        _ session: AgentModeViewModel.TabSession
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionID = session.activeAgentSessionID,
              let binding = session.authorityRunBinding
        else {
            throw ServiceAPIError(code: .notFound, message: "No authoritative provider run is active")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let snapshot = try await authority.cancelEmbeddedProviderRun(
            sessionID: sessionID,
            binding: binding,
            actor: actor,
            idempotencyKey: "macos-cancel:\(UUID().uuidString)",
            requestDigest: CanonicalSigning.bodyDigest(Data(binding.runID.uuidString.utf8))
        )
        await applyAuthoritySnapshot(snapshot, to: session)
        return snapshot
    }

    func updatePermissions(
        _ session: AgentModeViewModel.TabSession
    ) async throws -> ExecutionPermissionSnapshot {
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .notFound, message: "Session is not bound")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let current = try await authority.permissionSnapshot(sessionID: sessionID)
        let snapshot = try await authority.updatePermissions(
            sessionID: sessionID,
            expectedRevision: current?.revision ?? 0,
            mode: "workspaceWrite",
            providerSettings: Self.permissionSettings(session.permissionProfile),
            actor: actor
        )
        session.applyAuthorityPermissions(snapshot)
        return snapshot
    }

    func answerInteraction(
        _ session: AgentModeViewModel.TabSession,
        interaction: InteractionSnapshot,
        payload: Data
    ) async throws -> InteractionSnapshot {
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .notFound, message: "Session is not bound")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let answered = try await authority.answerInteraction(
            sessionID: sessionID,
            interactionID: interaction.interactionID,
            expectedRevision: interaction.revision,
            payload: payload,
            actor: actor,
            idempotencyKey: "macos-interaction:\(interaction.interactionID.uuidString):r\(interaction.revision)",
            requestDigest: CanonicalSigning.bodyDigest(payload)
        )
        try await applyAuthoritySnapshot(
            authority.authoritySessionSnapshot(sessionID: sessionID),
            to: session
        )
        return answered
    }

    func replaceWorktrees(
        _ session: AgentModeViewModel.TabSession,
        workspace: WorkspaceModel,
        bindings: [AgentSessionWorktreeBinding]
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .notFound, message: "Session is not bound")
        }
        let roots = Dictionary(uniqueKeysWithValues: workspace.repoPaths.map { path in
            (path, Self.stableUUID(namespace: workspace.id, value: path))
        })
        let desired = try bindings.map { binding -> WorktreeBindingSnapshot in
            guard let rootID = roots[binding.logicalRootPath] else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Worktree logical root is not in the active workspace")
            }
            return Self.worktreeSnapshot(
                binding,
                sessionID: sessionID,
                projectID: workspace.id,
                rootID: rootID,
                revision: 0
            )
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let snapshot = try await authority.replaceEmbeddedWorktrees(
            sessionID: sessionID,
            desired: desired,
            actor: actor
        )
        await applyAuthoritySnapshot(snapshot, to: session)
        return snapshot
    }

    func startObserving(_ session: AgentModeViewModel.TabSession) {
        guard session.authorityProjectionTask == nil,
              let sessionID = session.activeAgentSessionID
        else { return }
        session.authorityProjectionTask = Task { @MainActor [weak session] in
            guard let session else { return }
            do {
                let authority = try await AppAgentAuthorityComposition.shared.authority()
                var snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
                await self.applyAuthoritySnapshot(snapshot, to: session)
                let stream = try await authority.subscribe(after: snapshot.session.cursor)
                for try await event in stream {
                    try Task.checkCancellation()
                    guard event.sessionID == sessionID else { continue }
                    snapshot = try await authority.authoritySessionSnapshot(sessionID: sessionID)
                    await self.applyAuthoritySnapshot(snapshot, to: session)
                }
            } catch is CancellationError {
                return
            } catch {
                session.recordAuthorityFailure(error)
            }
        }
    }

    func reloadAuthoritativeSnapshot(
        _ session: AgentModeViewModel.TabSession,
        after error: Error
    ) async {
        session.recordAuthorityFailure(error)
        guard let sessionID = session.activeAgentSessionID else { return }
        do {
            let authority = try await AppAgentAuthorityComposition.shared.authority()
            try await applyAuthoritySnapshot(
                authority.authoritySessionSnapshot(sessionID: sessionID),
                to: session
            )
        } catch {
            session.recordAuthorityFailure(error)
        }
    }

    /// Applies the UI projection and independently wakes direct-MCP waiters
    /// from the exact same durable snapshot. The continuation store receives no
    /// mutation closure and cannot influence lifecycle settlement.
    private func applyAuthoritySnapshot(
        _ snapshot: AuthoritySessionSnapshot,
        to session: AgentModeViewModel.TabSession
    ) async {
        session.applyAuthoritySnapshot(snapshot)
        guard var context = session.mcpControlContext else { return }
        let priorEpoch = context.currentEpoch
        let transition: AgentRunEpochTransitionKind = if priorEpoch == nil {
            .initial
        } else if let binding = snapshot.activeBinding,
                  priorEpoch?.id != Self.epochID(binding)
        {
            .relatedFollowUp
        } else {
            priorEpoch?.transitionKind ?? .initial
        }
        guard let cursor = await AgentRunSessionStore.observeAuthoritySnapshot(
            Self.mcpSnapshot(snapshot, tabID: session.tabID),
            registration: context.registration,
            activationID: context.activationID,
            binding: snapshot.activeBinding,
            transitionKind: transition
        ) else { return }
        context.currentEpoch = cursor.epoch
        context.preparedEpoch = cursor.epoch
        context.pendingEpochTransition = nil
        session.mcpControlContext = context
    }

    private static func mcpSnapshot(
        _ snapshot: AuthoritySessionSnapshot,
        tabID: UUID
    ) -> AgentRunMCPSnapshot {
        let pending = snapshot.interactions.first(where: { $0.state == .pending })
        let interaction = pending.map(mcpInteraction)
        let status: AgentRunMCPSnapshot.Status = switch snapshot.session.state {
        case .waiting: .waitingForInput
        case .completed: .completed
        case .failed, .interrupted: .failed
        case .canceled: .cancelled
        case .idle, .preparing, .running, .archived: .running
        }
        let latestAssistant = snapshot.session.transcript.last(where: {
            $0.kind == .assistant
        })?.content
        let failureReason: AgentRunMCPSnapshot.FailureReason? = switch status {
        case .cancelled: .cancelled
        case .failed: .agentError
        default: nil
        }
        return AgentRunMCPSnapshot(
            sessionID: snapshot.session.sessionID,
            runID: snapshot.activeRun?.runID ?? snapshot.activeBinding?.runID,
            tabID: tabID,
            sessionName: nil,
            agentRaw: snapshot.session.provider.rawValue,
            agentDisplayName: snapshot.session.provider.rawValue,
            modelRaw: snapshot.session.model,
            reasoningEffortRaw: nil,
            status: status,
            statusText: snapshot.activeRun?.endReason,
            latestAssistantPreview: latestAssistant,
            interaction: interaction,
            transcriptItemCount: snapshot.session.transcript.count,
            updatedAt: snapshot.session.transcript.last?.timestamp
                ?? snapshot.activeRun?.endedAt
                ?? snapshot.activeRun?.startedAt
                ?? Date(),
            parentSessionID: snapshot.session.parentSessionID,
            failureReason: failureReason,
            worktreeBindings: snapshot.worktrees.map { binding in
                AgentRunMCPSnapshot.WorktreeBinding(
                    id: binding.bindingID.uuidString,
                    repositoryID: binding.projectID.uuidString,
                    repoKey: binding.projectID.uuidString,
                    logicalRootPath: binding.physicalPath,
                    logicalRootName: nil,
                    worktreeID: binding.bindingID.uuidString,
                    worktreeRootPath: binding.physicalPath,
                    worktreeName: binding.branch,
                    branch: binding.branch,
                    head: binding.baseRef,
                    visualLabel: nil,
                    visualColorHex: nil,
                    boundAt: snapshot.session.transcript.first?.timestamp ?? Date(),
                    source: "durable_authority",
                    unavailable: binding.ownershipState != .active
                )
            },
            activeWorktreeMerges: []
        )
    }

    private static func mcpInteraction(_ value: InteractionSnapshot) -> AgentRunMCPSnapshot.Interaction {
        let object = (try? JSONSerialization.jsonObject(with: value.payload)) as? [String: Any]
        let prompt = object?["prompt"] as? String
        let choices = object?["choices"] as? [String] ?? []
        return AgentRunMCPSnapshot.Interaction(
            id: value.interactionID,
            kind: value.kind == .question ? .question : .approval,
            responseType: value.kind == .question ? .text : .decision,
            title: nil,
            prompt: prompt,
            context: nil,
            allowsMultiple: false,
            options: choices.map { .init(label: $0) },
            fields: [],
            details: []
        )
    }

    private static func providerKind(_ value: AgentProviderKind) -> ProviderKind {
        switch value {
        case .codexExec: .codex
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible: .claudeCompatible
        case .openCode: .openCodeACP
        case .cursor: .cursorACP
        }
    }

    private static func permissionSettings(_ profile: AgentProviderPermissionProfile) -> [String: String] {
        switch profile {
        case .userConfigured:
            ["macos.profile": "userConfigured"]
        case .mcpSafeDefaults:
            ["macos.profile": "mcpSafeDefaults"]
        case let .providerOverride(level):
            ["macos.profile": "providerOverride", "macos.permissionLevel": String(describing: level)]
        }
    }

    private static func transcriptEntries(
        _ items: [AgentChatItem],
        actor: ExternalActor
    ) -> [TranscriptEntry] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return items.map { item in
            let kind: TranscriptEntry.Kind = switch item.kind {
            case .user: .human
            case .assistant, .assistantInline: .assistant
            case .thinking: .reasoning
            case .toolCall, .toolResult: .tool
            case .system, .error: .system
            }
            return TranscriptEntry(
                entryID: item.id,
                sessionSequence: Int64(item.sequenceIndex + 1),
                kind: kind,
                content: item.text,
                actor: item.kind == .user ? actor : nil,
                timestamp: item.timestamp,
                presentationPayload: try? encoder.encode(item)
            )
        }
    }

    private static func presentationPayloadForLatestHumanItem(
        in session: AgentModeViewModel.TabSession,
        matching message: String
    ) -> Data? {
        guard let item = authoritativeItems(session).last(where: {
            $0.kind == .user && $0.text == message
        }) else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(item)
    }

    private static func authoritativeItems(
        _ session: AgentModeViewModel.TabSession
    ) -> [AgentChatItem] {
        var rowsByID: [UUID: AgentChatItem] = [:]
        for item in AgentTranscriptIO.flattenFullTranscript(session.transcript) {
            rowsByID[item.id] = item
        }
        for item in session.items {
            rowsByID[item.id] = item
        }
        return rowsByID.values.sorted {
            if $0.sequenceIndex == $1.sequenceIndex {
                if $0.timestamp == $1.timestamp {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.timestamp < $1.timestamp
            }
            return $0.sequenceIndex < $1.sequenceIndex
        }
    }

    private static func worktreeSnapshot(
        _ binding: AgentSessionWorktreeBinding,
        sessionID: UUID,
        projectID: UUID,
        rootID: UUID,
        revision: Int64
    ) -> WorktreeBindingSnapshot {
        WorktreeBindingSnapshot(
            bindingID: stableUUID(namespace: sessionID, value: binding.id),
            projectID: projectID,
            rootID: rootID,
            sessionID: sessionID,
            baseRef: binding.head ?? "HEAD",
            branch: binding.branch ?? "detached",
            physicalPath: binding.worktreeRootPath,
            ownershipState: .active,
            mergeState: .clean,
            revision: revision
        )
    }

    private nonisolated static func stableUUID(namespace: UUID, value: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace.uuidString):\(value)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated static func epochID(_ binding: RunBindingSnapshot) -> UUID {
        stableUUID(
            namespace: binding.runID,
            value: "generation:\(binding.generation):turn:\(binding.turnEpoch)"
        )
    }
}
