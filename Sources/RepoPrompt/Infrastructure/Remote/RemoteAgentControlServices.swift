import Foundation
import MCP
import RepoPromptRemoteProtocol

enum RemoteAgentControlServiceError: LocalizedError {
    case unsupportedProtocol(Int)
    case invalidWorkspaceID
    case workspaceNotFound
    case workspaceNotOpen
    case sessionIDRequired
    case sessionNotFound
    case interactionIDRequired
    case invalidInteractionID
    case messageRequired
    case contextBuilderUnavailable
    case commandRejected(String)
    case partialSuccess(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(version):
            "Unsupported remote protocol version \(version)."
        case .invalidWorkspaceID:
            "A valid workspace ID is required."
        case .workspaceNotFound:
            "The requested workspace was not found."
        case .workspaceNotOpen:
            "The requested workspace is saved but is not open in a desktop window."
        case .sessionIDRequired:
            "A session ID is required for this command."
        case .sessionNotFound:
            "The requested session is not available."
        case .interactionIDRequired:
            "An interaction ID is required for this command."
        case .invalidInteractionID:
            "The interaction ID is invalid or no longer pending."
        case .messageRequired:
            "A non-empty message is required."
        case .contextBuilderUnavailable:
            "Context Builder is not available in the active desktop window."
        case let .commandRejected(message):
            message
        case let .partialSuccess(message):
            message
        }
    }
}

enum RemoteMutationFailureDisposition: Equatable, Sendable {
    case rollbackProvisionalSession
    case preserveExistingSession
}

enum RemoteMutationFailurePolicy {
    static let mutationOperations: [RemoteCommandOperation] = [
        .startRun,
        .followUp,
        .steer,
        .respond,
        .cancel,
        .resume,
        .contextBuilder
    ]

    static func disposition(for operation: RemoteCommandOperation) -> RemoteMutationFailureDisposition {
        switch operation {
        case .startRun:
            .rollbackProvisionalSession
        case .followUp, .steer, .respond, .cancel, .resume, .contextBuilder:
            .preserveExistingSession
        case .registerNotifications:
            .preserveExistingSession
        }
    }
}

enum RemoteWorkspaceActivationDecision: Equatable, Sendable {
    case reuseExistingWindow
    case openNewWindow
    case workspaceNotFound
}

enum RemoteWorkspaceActivationPlanner {
    static func decision(
        workspaceExists: Bool,
        reusableWindowExists: Bool
    ) -> RemoteWorkspaceActivationDecision {
        if reusableWindowExists { return .reuseExistingWindow }
        if workspaceExists { return .openNewWindow }
        return .workspaceNotFound
    }
}

@MainActor
protocol RemoteAgentControlService: AnyObject {
    func execute(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse
}

/// Direct in-process adapter for the Remote gateway. It intentionally calls
/// the same typed Agent Mode control surface used by the desktop's MCP adapter,
/// without creating an MCP request, socket connection, or serialized tool call.
@MainActor
final class WindowRemoteAgentControlService: RemoteAgentControlService {
    private weak var windowStatesManager: WindowStatesManager?

    init(windowStatesManager: WindowStatesManager) {
        self.windowStatesManager = windowStatesManager
    }

    func execute(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        guard RemoteProtocol.supports(request.protocolVersion) else {
            throw RemoteAgentControlServiceError.unsupportedProtocol(request.protocolVersion)
        }

        switch request.operation {
        case .startRun:
            return try await start(request)
        case .followUp, .steer, .resume:
            return try await continueRun(request)
        case .respond:
            return try await respond(request)
        case .cancel:
            return try await cancel(request)
        case .contextBuilder:
            return try await contextBuilder(request)
        case .registerNotifications:
            throw RemoteAgentControlServiceError.commandRejected(
                "Notification registration must be handled by the Remote gateway."
            )
        }
    }

    private func start(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let workspaceID = try parseWorkspaceID(request.workspaceID)
        let context = try await activateWorkspace(workspaceID)
        let message = try requiredMessage(request.message)
        let effectiveMessage: String
        if let workflowID = request.workflowID {
            guard let workflow = AgentWorkflowStore.shared.resolveWorkflowReference(workflowID) else {
                throw RemoteAgentControlServiceError.commandRejected(
                    "The requested workflow is no longer available on the Mac."
                )
            }
            effectiveMessage = workflow.wrapUserText(message)
        } else {
            effectiveMessage = message
        }
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Remote run"
        )

        do {
            try await context.agentMode.mcpConfigureSession(
                tabID: target.tabID,
                agentRaw: request.agentID,
                modelRaw: request.modelID,
                reasoningEffortRaw: request.reasoningEffort
            )
            guard let sessionID = target.sessionID else {
                throw RemoteAgentControlServiceError.sessionNotFound
            }
            try await context.agentMode.mcpActivateControlContext(
                forTabID: target.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                taskLabelKind: .pair,
                startPending: true,
                markSessionAsMCPOriginated: true
            )
            _ = try await context.agentMode.mcpDispatchInstruction(
                sessionID: sessionID,
                text: effectiveMessage,
                allowStartingRun: true
            )
            return await response(
                request: request,
                workspaceID: workspaceID,
                sessionID: sessionID,
                context: context
            )
        } catch {
            switch RemoteMutationFailurePolicy.disposition(for: request.operation) {
            case .rollbackProvisionalSession:
                let discarded = await context.agentMode.mcpDiscardSessionTarget(target)
                guard discarded else {
                    throw RemoteAgentControlServiceError.partialSuccess(
                        "The remote run could not start and provisional session cleanup was incomplete."
                    )
                }
            case .preserveExistingSession:
                break
            }
            throw error
        }
    }

    private func continueRun(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        let context = try await contextForSession(sessionID, requestedWorkspaceID: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: false,
            sessionName: nil
        )
        let session = await context.agentMode.ensureSessionReady(tabID: target.tabID)
        let message = try requiredMessage(request.message)
        var activatedForRequest = false
        if session.mcpControlContext?.sessionID != sessionID {
            try await context.agentMode.mcpActivateControlContext(
                forTabID: target.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                taskLabelKind: .pair,
                startPending: false,
                markSessionAsMCPOriginated: true
            )
            activatedForRequest = true
        }
        do {
            _ = try await context.agentMode.mcpDispatchInstruction(
                sessionID: sessionID,
                text: message,
                allowStartingRun: true
            )
        } catch {
            if activatedForRequest {
                await context.agentMode.mcpDeactivateControlContext(
                    sessionID: sessionID,
                    cleanupSessionStore: false
                )
            }
            throw error
        }
        return await response(
            request: request,
            workspaceID: try workspaceID(for: context, fallback: request.workspaceID),
            sessionID: sessionID,
            context: context
        )
    }

    private func respond(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        let interactionID = try requiredInteractionID(request.interactionID)
        let context = try await contextForSession(sessionID, requestedWorkspaceID: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: false,
            sessionName: nil
        )
        let session = await context.agentMode.ensureSessionReady(tabID: target.tabID)
        guard Self.pendingInteractionID(in: session) == interactionID else {
            throw RemoteAgentControlServiceError.invalidInteractionID
        }
        var answers = request.answers
        if let secret = request.secret {
            guard let question = session.pendingUserInputRequest?.questions.first(where: { $0.isSecret }) else {
                throw RemoteAgentControlServiceError.commandRejected(
                    "A secret can only be submitted for a pending secure-entry question."
                )
            }
            // Keep the secret in this one-shot in-memory payload only. It is
            // never placed in text, logs, snapshots, events, or credentials.
            answers[question.id] = [secret]
        }
        var activatedForRequest = false
        if session.mcpControlContext?.sessionID != sessionID {
            try await context.agentMode.mcpActivateControlContext(
                forTabID: target.tabID,
                sessionID: sessionID,
                originatingConnectionID: nil,
                taskLabelKind: .pair,
                startPending: false,
                markSessionAsMCPOriginated: true
            )
            activatedForRequest = true
        }
        let payload = AgentModeViewModel.MCPInteractionResponsePayload(
            text: request.secret == nil ? request.message ?? request.decision : nil,
            skip: request.decision?.lowercased() == "skip",
            explicitSkip: request.decision?.lowercased() == "skip",
            decisionRaw: request.decision,
            amendment: nil,
            answersByQuestionID: answers
        )
        do {
            _ = try await context.agentMode.mcpResolvePendingInteraction(
                sessionID: sessionID,
                interactionID: interactionID,
                payload: payload
            )
        } catch {
            if activatedForRequest {
                await context.agentMode.mcpDeactivateControlContext(
                    sessionID: sessionID,
                    cleanupSessionStore: false
                )
            }
            throw error
        }
        return await response(
            request: request,
            workspaceID: try workspaceID(for: context, fallback: request.workspaceID),
            sessionID: sessionID,
            context: context
        )
    }

    private func cancel(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        let context = try await contextForSession(sessionID, requestedWorkspaceID: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: false,
            sessionName: nil
        )
        let session = await context.agentMode.ensureSessionReady(tabID: target.tabID)
        guard session.runState.isActive else {
            throw RemoteAgentControlServiceError.commandRejected(
                "The requested session has no active run to cancel."
            )
        }
        let cancelTarget = context.agentMode.makeRunCancelTarget(
            tabID: target.tabID,
            session: session
        )
        guard await context.agentMode.cancelAgentRun(target: cancelTarget) else {
            throw RemoteAgentControlServiceError.commandRejected(
                "The run changed before cancellation could be applied."
            )
        }
        return await response(
            request: request,
            workspaceID: try workspaceID(for: context, fallback: request.workspaceID),
            sessionID: sessionID,
            context: context
        )
    }

    private func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let workspaceID = try parseWorkspaceID(request.workspaceID)
        let context = try await activateWorkspace(workspaceID)
        let instructions = try requiredMessage(request.message)
        let responseType = request.contextBuilderResponseType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard responseType == nil || ["clarify", "question", "plan", "review"].contains(responseType!) else {
            throw RemoteAgentControlServiceError.commandRejected(
                "Unsupported Context Builder response type. Use clarify, question, plan, or review."
            )
        }

        let tool = await context.window.mcpServer.windowMCPTools.first {
            $0.name == MCPWindowToolName.contextBuilder
        }
        guard let tool else { throw RemoteAgentControlServiceError.contextBuilderUnavailable }

        var arguments: [String: Value] = ["instructions": .string(instructions)]
        if let responseType, responseType != "clarify" {
            arguments["response_type"] = .string(responseType)
        }
        if request.contextBuilderExportResponse == true {
            arguments["export_response"] = .bool(true)
        }

        let value = try await tool(arguments)
        guard let object = value.objectValue else {
            throw RemoteAgentControlServiceError.commandRejected("Context Builder returned an invalid result.")
        }
        let result = RemoteContextBuilderResult(
            tabID: object["context_id"]?.stringValue ?? "",
            status: object["status"]?.stringValue ?? "completed",
            prompt: object["prompt"]?.stringValue ?? "",
            fileCount: object["file_count"]?.intValue ?? 0,
            totalTokens: object["total_tokens"]?.intValue ?? 0,
            responseType: object["response_type"]?.stringValue,
            plan: object["plan"]?.objectValue?["response"]?.stringValue,
            review: object["review"]?.objectValue?["response"]?.stringValue,
            followUpHint: object["follow_up_hint"]?.stringValue
        )
        return RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: workspaceID.uuidString,
            message: "Context Builder completed.",
            contextBuilderResult: result
        )
    }

    private func activateWorkspace(_ workspaceID: UUID) async throws -> WindowContext {
        guard let manager = windowStatesManager else {
            throw RemoteAgentControlServiceError.workspaceNotOpen
        }
        let window = manager.allWindows.first(where: {
            !$0.isClosing && $0.workspaceManager.workspace(withID: workspaceID) != nil
        })
        let workspaceExists = manager.allWindows.contains {
            $0.workspaceManager.workspace(withID: workspaceID) != nil
        }
        switch RemoteWorkspaceActivationPlanner.decision(
            workspaceExists: workspaceExists,
            reusableWindowExists: window != nil
        ) {
        case .reuseExistingWindow:
            guard let window, let workspace = window.workspaceManager.workspace(withID: workspaceID) else {
                throw RemoteAgentControlServiceError.workspaceNotFound
            }
            if window.workspaceManager.activeWorkspaceID != workspaceID {
                let result = await window.workspaceManager.switchWorkspace(to: workspace, saveState: true, reason: "remote_command")
                guard result.didSwitch || window.workspaceManager.activeWorkspaceID == workspaceID else {
                    throw RemoteAgentControlServiceError.commandRejected(
                        result.message ?? "The workspace could not be activated."
                    )
                }
            }
            return WindowContext(window: window)
        case .openNewWindow:
            do {
            let newWindow = try await manager.openNewMainWindow()
            await newWindow.workspaceManager.awaitInitialized()
            guard let workspace = newWindow.workspaceManager.workspace(withID: workspaceID) else {
                throw RemoteAgentControlServiceError.workspaceNotFound
            }
            let result = await newWindow.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: true)
            guard result.didSwitch || newWindow.workspaceManager.activeWorkspaceID == workspaceID else {
                throw RemoteAgentControlServiceError.commandRejected(
                    result.message ?? "The workspace could not be activated in the new window."
                )
            }
            return WindowContext(window: newWindow)
            } catch let error as RemoteAgentControlServiceError {
                throw error
            } catch {
                throw RemoteAgentControlServiceError.commandRejected(
                    "The desktop could not open a window for the saved workspace."
                )
            }
        case .workspaceNotFound:
            throw RemoteAgentControlServiceError.workspaceNotFound
        }
    }

    private func contextForSession(
        _ sessionID: UUID,
        requestedWorkspaceID: String?
    ) async throws -> WindowContext {
        if let requestedWorkspaceID, let workspaceID = UUID(uuidString: requestedWorkspaceID) {
            let context = try await activateWorkspace(workspaceID)
            if context.agentMode.sessionIndex[sessionID] != nil
                || context.agentMode.sessions.values.contains(where: { $0.activeAgentSessionID == sessionID })
            {
                return context
            }
        }
        guard let manager = windowStatesManager else {
            throw RemoteAgentControlServiceError.sessionNotFound
        }
        for window in manager.allWindows where !window.isClosing {
            if window.agentModeViewModel.sessionIndex[sessionID] != nil
                || window.agentModeViewModel.sessions.values.contains(where: { $0.activeAgentSessionID == sessionID })
            {
                return WindowContext(window: window)
            }
        }
        throw RemoteAgentControlServiceError.sessionNotFound
    }

    private func response(
        request: RemoteCommandRequest,
        workspaceID: UUID,
        sessionID: UUID,
        context: WindowContext
    ) async -> RemoteCommandResponse {
        let state = await AgentModeRemoteSessionQueryService(
            agentMode: context.agentMode,
            workspaceManager: context.workspaceManager
        ).remoteSessions().first(where: { $0.sessionID == sessionID })?.runState
        return RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: workspaceID.uuidString,
            sessionID: sessionID,
            runState: state,
            message: "Remote command accepted."
        )
    }

    private func parseWorkspaceID(_ raw: String?) throws -> UUID {
        guard let raw, let workspaceID = UUID(uuidString: raw) else {
            throw RemoteAgentControlServiceError.invalidWorkspaceID
        }
        return workspaceID
    }

    private func workspaceID(for context: WindowContext, fallback: String?) throws -> UUID {
        if let fallback, let workspaceID = UUID(uuidString: fallback) {
            return workspaceID
        }
        guard let workspaceID = context.workspaceManager.activeWorkspaceID else {
            throw RemoteAgentControlServiceError.workspaceNotFound
        }
        return workspaceID
    }

    private func requiredSessionID(_ sessionID: UUID?) throws -> UUID {
        guard let sessionID else { throw RemoteAgentControlServiceError.sessionIDRequired }
        return sessionID
    }

    private func requiredInteractionID(_ interactionID: UUID?) throws -> UUID {
        guard let interactionID else { throw RemoteAgentControlServiceError.interactionIDRequired }
        return interactionID
    }

    private static func pendingInteractionID(in session: AgentModeViewModel.TabSession) -> UUID? {
        if let pending = session.pendingAskUser { return pending.id }
        if let pending = session.pendingUserInputRequest { return pending.id }
        if let pending = session.pendingMCPElicitationRequest { return pending.id }
        return session.pendingApproval?.id
    }

    private func requiredMessage(_ message: String?) throws -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw RemoteAgentControlServiceError.messageRequired }
        return trimmed
    }

    private struct WindowContext {
        let window: WindowState

        var agentMode: AgentModeViewModel { window.agentModeViewModel }
        var workspaceManager: WorkspaceManagerViewModel { window.workspaceManager }
    }
}
