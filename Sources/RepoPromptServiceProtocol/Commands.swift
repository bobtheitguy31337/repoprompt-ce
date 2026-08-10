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

    private enum CodingKeys: String, CodingKey {
        case name
        case roots
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

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
        case name
        case roots
    }
}

public struct RemoveProjectInput: Codable, Sendable {
    public let expectedRevision: Int64
    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
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

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case parentSessionID = "parentSessionId"
        case provider
        case model
        case visibility
        case initialPrompt
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
    case abortConflictedMerge(bindingID: UUID, leaseID: UUID, expectedRevision: Int64)
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
        case .abortConflictedMerge: "abortConflictedMerge"
        case .archiveSession: "archiveSession"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case operation, providerResumeMode, text, expectedSessionRevision, targetTurnEpoch, expectedGeneration
        case expectedRunID = "expectedRunId"
        case sourceRunID = "sourceRunId"
        case fromTranscriptEntryID = "fromTranscriptEntryId"
        case interactionID = "interactionId"
        case expectedRevision, payload, executionMode, providerSettings, expectedPolicyRevision, visibility, collaborativeSteeringEnabled
        case controllerUserID = "controllerUserId"
        case mode, operations, expectedSelectionRevision, include, instructions, budget, prompt, contextMode, baseRef, branchName, strategy
        case chatID = "chatId"
        case rootID = "rootId"
        case bindingID = "bindingId"
        case leaseID = "leaseId"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try values.decode(String.self, forKey: .operation)
        switch operation {
        case "resumeSession": self = try .resumeSession(expectedRunID: values.decodeIfPresent(UUID.self, forKey: .expectedRunID), providerResumeMode: values.decode(String.self, forKey: .providerResumeMode))
        case "sendFollowup": self = try .sendFollowup(text: values.decode(String.self, forKey: .text), expectedSessionRevision: values.decode(Int64.self, forKey: .expectedSessionRevision))
        case "steerSession": self = try .steerSession(text: values.decode(String.self, forKey: .text), targetTurnEpoch: values.decode(Int64.self, forKey: .targetTurnEpoch))
        case "cancelSession": self = try .cancelSession(expectedRunID: values.decodeIfPresent(UUID.self, forKey: .expectedRunID), expectedGeneration: values.decode(Int64.self, forKey: .expectedGeneration))
        case "retrySession": self = try .retrySession(sourceRunID: values.decode(UUID.self, forKey: .sourceRunID), fromTranscriptEntryID: values.decodeIfPresent(UUID.self, forKey: .fromTranscriptEntryID))
        case "answerInteraction": self = try .answerInteraction(interactionID: values.decode(UUID.self, forKey: .interactionID), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision), payload: values.decode(Data.self, forKey: .payload))
        case "updateExecutionPermissions": self = try .updateExecutionPermissions(expectedRevision: values.decode(Int64.self, forKey: .expectedRevision), executionMode: values.decode(String.self, forKey: .executionMode), providerSettings: values.decode([String: String].self, forKey: .providerSettings))
        case "setSessionVisibility": self = try .setSessionVisibility(expectedPolicyRevision: values.decode(Int64.self, forKey: .expectedPolicyRevision), visibility: values.decode(Visibility.self, forKey: .visibility), collaborativeSteeringEnabled: values.decode(Bool.self, forKey: .collaborativeSteeringEnabled), controllerUserID: values.decode(String.self, forKey: .controllerUserID))
        case "updateSelection": self = try .updateSelection(mode: values.decode(String.self, forKey: .mode), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision), operations: values.decode([String].self, forKey: .operations))
        case "buildContext": self = try .buildContext(expectedSelectionRevision: values.decode(Int64.self, forKey: .expectedSelectionRevision), include: values.decode([String].self, forKey: .include))
        case "runContextBuilder": self = try .runContextBuilder(expectedSelectionRevision: values.decode(Int64.self, forKey: .expectedSelectionRevision), instructions: values.decode(String.self, forKey: .instructions), budget: values.decode(Int.self, forKey: .budget))
        case "askOracle": self = try .askOracle(chatID: values.decodeIfPresent(UUID.self, forKey: .chatID), prompt: values.decode(String.self, forKey: .prompt), contextMode: values.decode(String.self, forKey: .contextMode))
        case "createWorktree": self = try .createWorktree(rootID: values.decode(UUID.self, forKey: .rootID), baseRef: values.decode(String.self, forKey: .baseRef), branchName: values.decode(String.self, forKey: .branchName))
        case "bindWorktree": self = try .bindWorktree(bindingID: values.decode(UUID.self, forKey: .bindingID), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        case "mergeWorktree": self = try .mergeWorktree(bindingID: values.decode(UUID.self, forKey: .bindingID), strategy: values.decode(String.self, forKey: .strategy), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        case "abortConflictedMerge": self = try .abortConflictedMerge(bindingID: values.decode(UUID.self, forKey: .bindingID), leaseID: values.decode(UUID.self, forKey: .leaseID), expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        case "archiveSession": self = try .archiveSession(expectedRevision: values.decode(Int64.self, forKey: .expectedRevision))
        default: throw DecodingError.dataCorruptedError(forKey: .operation, in: values, debugDescription: "Unsupported v1 session operation")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(operation, forKey: .operation)
        switch self {
        case let .resumeSession(expectedRunID, providerResumeMode): try values.encodeIfPresent(expectedRunID, forKey: .expectedRunID); try values.encode(providerResumeMode, forKey: .providerResumeMode)
        case let .sendFollowup(text, revision): try values.encode(text, forKey: .text); try values.encode(revision, forKey: .expectedSessionRevision)
        case let .steerSession(text, epoch): try values.encode(text, forKey: .text); try values.encode(epoch, forKey: .targetTurnEpoch)
        case let .cancelSession(runID, generation): try values.encodeIfPresent(runID, forKey: .expectedRunID); try values.encode(generation, forKey: .expectedGeneration)
        case let .retrySession(runID, entryID): try values.encode(runID, forKey: .sourceRunID); try values.encodeIfPresent(entryID, forKey: .fromTranscriptEntryID)
        case let .answerInteraction(id, revision, payload): try values.encode(id, forKey: .interactionID); try values.encode(revision, forKey: .expectedRevision); try values.encode(payload, forKey: .payload)
        case let .updateExecutionPermissions(revision, mode, settings): try values.encode(revision, forKey: .expectedRevision); try values.encode(mode, forKey: .executionMode); try values.encode(settings, forKey: .providerSettings)
        case let .setSessionVisibility(revision, visibility, steering, controller): try values.encode(revision, forKey: .expectedPolicyRevision); try values.encode(visibility, forKey: .visibility); try values.encode(steering, forKey: .collaborativeSteeringEnabled); try values.encode(controller, forKey: .controllerUserID)
        case let .updateSelection(mode, revision, operations): try values.encode(mode, forKey: .mode); try values.encode(revision, forKey: .expectedRevision); try values.encode(operations, forKey: .operations)
        case let .buildContext(revision, include): try values.encode(revision, forKey: .expectedSelectionRevision); try values.encode(include, forKey: .include)
        case let .runContextBuilder(revision, instructions, budget): try values.encode(revision, forKey: .expectedSelectionRevision); try values.encode(instructions, forKey: .instructions); try values.encode(budget, forKey: .budget)
        case let .askOracle(chatID, prompt, mode): try values.encodeIfPresent(chatID, forKey: .chatID); try values.encode(prompt, forKey: .prompt); try values.encode(mode, forKey: .contextMode)
        case let .createWorktree(rootID, baseRef, branch): try values.encode(rootID, forKey: .rootID); try values.encode(baseRef, forKey: .baseRef); try values.encode(branch, forKey: .branchName)
        case let .bindWorktree(id, revision): try values.encode(id, forKey: .bindingID); try values.encode(revision, forKey: .expectedRevision)
        case let .mergeWorktree(id, strategy, revision): try values.encode(id, forKey: .bindingID); try values.encode(strategy, forKey: .strategy); try values.encode(revision, forKey: .expectedRevision)
        case let .abortConflictedMerge(bindingID, leaseID, revision): try values.encode(bindingID, forKey: .bindingID); try values.encode(leaseID, forKey: .leaseID); try values.encode(revision, forKey: .expectedRevision)
        case let .archiveSession(revision): try values.encode(revision, forKey: .expectedRevision)
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

    private enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case sessionID = "sessionId"
        case operation
        case acceptedCursor
        case status
    }
}
