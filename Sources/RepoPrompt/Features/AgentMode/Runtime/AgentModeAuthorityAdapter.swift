import CryptoKit
import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

/// Thin macOS adapter over `RepoPromptHeadlessAuthority`.
///
/// Provider controllers and SwiftUI retain presentation mechanics, but durable
/// identity, lifecycle fencing, transcript, permissions, interactions and
/// worktree ownership always cross this boundary before MCP waiters are woken.
@MainActor
final class AgentModeAuthorityAdapter {
    static let shared = AgentModeAuthorityAdapter()

    private let actor = ExternalActor(
        goblinUserID: "macos-local-user",
        username: NSUserName(),
        displayName: NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    )

    private init() {}

    func ensureSession(
        _ session: AgentModeViewModel.TabSession,
        workspace: WorkspaceModel
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Agent tab has no persistent session identity")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let rootSessionID: UUID = if let parentSessionID = session.parentSessionID,
                                     let parent = try? await authority.authoritySessionSnapshot(sessionID: parentSessionID)
        {
            parent.session.rootSessionID
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
            return WorktreeBindingSnapshot(
                bindingID: Self.stableUUID(namespace: sessionID, value: binding.id),
                projectID: workspace.id,
                rootID: rootID,
                sessionID: sessionID,
                baseRef: binding.head ?? "HEAD",
                branch: binding.branch ?? "detached",
                physicalPath: binding.worktreeRootPath,
                ownershipState: .active,
                mergeState: .clean,
                revision: 1
            )
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
            transcript: Self.transcriptEntries(Self.authoritativeItems(session), actor: actor),
            permissionMode: "workspaceWrite",
            providerSettings: Self.permissionSettings(session.permissionProfile),
            worktrees: worktrees
        ))
        session.applyAuthorityTranscript(snapshot.session.transcript)
        return snapshot
    }

    func beginRun(
        _ session: AgentModeViewModel.TabSession,
        workspace: WorkspaceModel
    ) async throws -> RunBindingSnapshot {
        _ = try await ensureSession(session, workspace: workspace)
        guard let sessionID = session.activeAgentSessionID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Agent tab has no persistent session identity")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let generation = AppDomainRuntimeComposition.shared.runtime.identity.lifecycleGeneration
        let snapshot = try await authority.beginEmbeddedRun(
            sessionID: sessionID,
            actor: actor,
            connectionGeneration: Int64(clamping: generation),
            providerSessionID: session.providerSessionID,
            preferredRunID: session.runID
        )
        guard let binding = snapshot.activeBinding else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Authority did not publish the embedded run binding")
        }
        return binding
    }

    func synchronizeTranscript(_ session: AgentModeViewModel.TabSession) async {
        guard let sessionID = session.activeAgentSessionID,
              let binding = session.authorityRunBinding
        else { return }
        do {
            let authority = try await AppAgentAuthorityComposition.shared.authority()
            let snapshot = try await authority.synchronizeEmbeddedTranscript(
                sessionID: sessionID,
                binding: binding,
                entries: Self.transcriptEntries(Self.authoritativeItems(session), actor: actor)
            )
            session.applyAuthorityTranscript(snapshot.session.transcript)
        } catch {
            // A rejected or stale local mutation is rolled back to the
            // authority rather than remaining visible as a second truth.
            if let authority = try? await AppAgentAuthorityComposition.shared.authority(),
               let snapshot = try? await authority.authoritySessionSnapshot(sessionID: sessionID)
            {
                session.applyAuthorityTranscript(snapshot.session.transcript)
            }
        }
    }

    func settle(
        _ session: AgentModeViewModel.TabSession,
        terminalState: AgentSessionRunState,
        expectedRunID: UUID?
    ) async throws -> AuthoritySessionSnapshot {
        guard let sessionID = session.activeAgentSessionID,
              let binding = session.authorityRunBinding,
              expectedRunID == nil || expectedRunID == binding.runID
        else {
            throw ServiceAPIError(code: .staleRevision, message: "Terminal publication is not bound to the authority run")
        }
        let authority = try await AppAgentAuthorityComposition.shared.authority()
        let transcriptSnapshot = try await authority.synchronizeEmbeddedTranscript(
            sessionID: sessionID,
            binding: binding,
            entries: Self.transcriptEntries(Self.authoritativeItems(session), actor: actor)
        )
        session.applyAuthorityTranscript(transcriptSnapshot.session.transcript)
        let outcome: EmbeddedRunTerminalOutcome = switch terminalState {
        case .completed: .completed
        case .cancelled: .canceled
        case .failed: .failed
        case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval: .interrupted
        }
        return try await authority.settleEmbeddedRun(
            sessionID: sessionID,
            binding: binding,
            outcome: outcome,
            providerSessionID: session.providerSessionID
        )
    }

    func synchronizePermissions(
        _ session: AgentModeViewModel.TabSession
    ) async {
        guard let sessionID = session.activeAgentSessionID else { return }
        do {
            let authority = try await AppAgentAuthorityComposition.shared.authority()
            try await authority.synchronizeEmbeddedPermissions(
                sessionID: sessionID,
                mode: "workspaceWrite",
                providerSettings: Self.permissionSettings(session.permissionProfile),
                actor: actor
            )
        } catch {
            // Session admission at run start is the authoritative retry path.
        }
    }

    func synchronizeInteractions(_ session: AgentModeViewModel.TabSession) async {
        guard let sessionID = session.activeAgentSessionID else { return }
        let runID = session.authorityRunBinding?.runID
        var interactions: [InteractionSnapshot] = []
        if let pending = session.pendingAskUser {
            interactions.append(Self.interaction(
                id: pending.id,
                runID: runID,
                kind: .question,
                payload: [
                    "type": "ask_user",
                    "title": pending.interaction.title ?? "Question",
                    "context": pending.interaction.context ?? "",
                    "question_count": pending.interaction.questions.count
                ]
            ))
        }
        if let pending = session.pendingUserInputRequest {
            interactions.append(Self.interaction(
                id: pending.id,
                runID: runID,
                kind: .question,
                payload: [
                    "type": "request_user_input",
                    "method": pending.method,
                    "question_count": pending.questions.count
                ]
            ))
        }
        if let pending = session.pendingMCPElicitationRequest {
            interactions.append(Self.interaction(
                id: pending.id,
                runID: runID,
                kind: .question,
                payload: [
                    "type": "mcp_elicitation",
                    "title": pending.title,
                    "message": pending.message ?? pending.prompt ?? ""
                ]
            ))
        }
        if let pending = session.pendingApproval {
            interactions.append(Self.interaction(
                id: pending.id,
                runID: runID,
                kind: .approval,
                payload: [
                    "type": "approval",
                    "method": pending.method,
                    "reason": pending.reason ?? ""
                ]
            ))
        }
        if let pending = session.pendingPermissionsRequest {
            interactions.append(Self.interaction(
                id: pending.id,
                runID: runID,
                kind: .approval,
                payload: [
                    "type": "permissions",
                    "method": pending.method,
                    "cwd": pending.cwd,
                    "permissions": pending.permissionsJSON
                ]
            ))
        }
        do {
            let authority = try await AppAgentAuthorityComposition.shared.authority()
            _ = try await authority.synchronizeEmbeddedInteractions(
                sessionID: sessionID,
                interactions: interactions,
                actor: actor
            )
        } catch {
            // The next presentation mutation or terminal drain retries against
            // the exact authority binding.
        }
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

    private static func interaction(
        id: UUID,
        runID: UUID?,
        kind: InteractionSnapshot.Kind,
        payload object: [String: Any]
    ) -> InteractionSnapshot {
        let payload = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return InteractionSnapshot(
            interactionID: id,
            runID: runID,
            kind: kind,
            state: .pending,
            payload: payload,
            revision: 1,
            expiresAt: nil
        )
    }

    private static func stableUUID(namespace: UUID, value: String) -> UUID {
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

    static func epochID(_ binding: RunBindingSnapshot) -> UUID {
        stableUUID(
            namespace: binding.runID,
            value: "generation:\(binding.generation):turn:\(binding.turnEpoch)"
        )
    }
}
