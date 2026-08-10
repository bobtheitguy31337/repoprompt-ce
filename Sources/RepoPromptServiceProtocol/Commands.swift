import Foundation

public struct CreateProjectInput: Codable, Sendable {
    public struct Root: Codable, Sendable {
        public let logicalName: String
        public let path: String
        public let writable: Bool
        public init(logicalName: String, path: String, writable: Bool) {
            self.logicalName = logicalName
            self.path = path
            self.writable = writable
        }
    }

    public let name: String
    public let roots: [Root]
    public init(name: String, roots: [Root]) {
        self.name = name
        self.roots = roots
    }
}

public struct UpdateProjectInput: Codable, Sendable {
    public let expectedRevision: Int64
    public let name: String
    public let roots: [CreateProjectInput.Root]
    public init(expectedRevision: Int64, name: String, roots: [CreateProjectInput.Root]) {
        self.expectedRevision = expectedRevision
        self.name = name
        self.roots = roots
    }
}

public struct RemoveProjectInput: Codable, Sendable {
    public let expectedRevision: Int64
    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }
}

public struct CreateSessionInput: Codable, Sendable {
    public let projectID: UUID
    public let parentSessionID: UUID?
    public let provider: ProviderKind
    public let model: String?
    public let visibility: Visibility
    public let initialPrompt: String?
    public init(projectID: UUID, parentSessionID: UUID? = nil, provider: ProviderKind, model: String? = nil, visibility: Visibility, initialPrompt: String? = nil) {
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.provider = provider
        self.model = model
        self.visibility = visibility
        self.initialPrompt = initialPrompt
    }
}

public enum SessionCommand: Codable, Sendable {
    case resumeSession(expectedRunID: UUID?, providerResumeMode: String)
    case sendFollowup(text: String, expectedSessionRevision: Int64)
    case steerSession(text: String, targetTurnEpoch: Int64)
    case cancelSession(expectedRunID: UUID?, expectedGeneration: Int64)
    case retrySession(sourceRunID: UUID, fromTranscriptEntryID: UUID?)
    case answerInteraction(interactionID: UUID, expectedRevision: Int64, payload: Data)
    case updateExecutionPermissions(expectedRevision: Int64, executionMode: String, providerSettings: [String: String])
    case setSessionVisibility(expectedPolicyRevision: Int64, visibility: Visibility, collaborativeSteeringEnabled: Bool, controllerUserID: String)
    case updateSelection(mode: String, expectedRevision: Int64, operations: [String])
    case buildContext(expectedSelectionRevision: Int64, include: [String])
    case runContextBuilder(expectedSelectionRevision: Int64, instructions: String, budget: Int)
    case askOracle(chatID: UUID?, prompt: String, contextMode: String)
    case createWorktree(rootID: UUID, baseRef: String, branchName: String)
    case bindWorktree(bindingID: UUID, expectedRevision: Int64)
    case mergeWorktree(bindingID: UUID, strategy: String, expectedRevision: Int64)
    case archiveSession(expectedRevision: Int64)

    public var operation: String {
        switch self {
        case .resumeSession: "resumeSession"
        case .sendFollowup: "sendFollowup"
        case .steerSession: "steerSession"
        case .cancelSession: "cancelSession"
        case .retrySession: "retrySession"
        case .answerInteraction: "answerInteraction"
        case .updateExecutionPermissions: "updateExecutionPermissions"
        case .setSessionVisibility: "setSessionVisibility"
        case .updateSelection: "updateSelection"
        case .buildContext: "buildContext"
        case .runContextBuilder: "runContextBuilder"
        case .askOracle: "askOracle"
        case .createWorktree: "createWorktree"
        case .bindWorktree: "bindWorktree"
        case .mergeWorktree: "mergeWorktree"
        case .archiveSession: "archiveSession"
        }
    }
}

public struct CommandReceipt: Codable, Hashable, Sendable {
    public let commandID: UUID
    public let sessionID: UUID
    public let operation: String
    public let acceptedCursor: ServiceCursor
    public let status: String
    public init(commandID: UUID, sessionID: UUID, operation: String, acceptedCursor: ServiceCursor, status: String) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.operation = operation
        self.acceptedCursor = acceptedCursor
        self.status = status
    }
}
