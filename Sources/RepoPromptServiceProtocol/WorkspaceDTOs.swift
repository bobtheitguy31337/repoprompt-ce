import Foundation

public struct LogicalSelectionEntry: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case full, slices, codeMap = "codemap_only" }
    public let rootID: UUID
    public let logicalPath: String
    public let mode: Mode
    public let ranges: [ClosedRange<Int>]

    public init(rootID: UUID, logicalPath: String, mode: Mode, ranges: [ClosedRange<Int>] = []) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.mode = mode
        self.ranges = ranges
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case mode
        case ranges
    }
}

public struct SelectionSnapshot: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let entries: [LogicalSelectionEntry]
    public let revision: Int64
    public let bindingRevision: Int64

    public init(sessionID: UUID, entries: [LogicalSelectionEntry], revision: Int64, bindingRevision: Int64 = 1) {
        self.sessionID = sessionID
        self.entries = entries
        self.revision = revision
        self.bindingRevision = bindingRevision
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case entries
        case revision
        case bindingRevision
    }
}

public struct SessionContextSnapshot: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let prompt: String
    public let selectionRevision: Int64
    public let contextRevision: Int64

    public init(
        sessionID: UUID,
        prompt: String,
        selectionRevision: Int64,
        contextRevision: Int64
    ) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.selectionRevision = selectionRevision
        self.contextRevision = contextRevision
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case prompt
        case selectionRevision
        case contextRevision
    }
}

public struct ToolInvocationSnapshot: Codable, Hashable, Sendable {
    public let invocationID: UUID
    public let toolName: String
    public let state: String
    public let argumentDigest: String
    public let resultDigest: String?
    public let errorCode: ServiceErrorCode?

    public init(invocationID: UUID, toolName: String, state: String, argumentDigest: String, resultDigest: String? = nil, errorCode: ServiceErrorCode? = nil) {
        self.invocationID = invocationID
        self.toolName = toolName
        self.state = state
        self.argumentDigest = argumentDigest
        self.resultDigest = resultDigest
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case invocationID = "invocationId"
        case toolName
        case state
        case argumentDigest
        case resultDigest
        case errorCode
    }
}

public struct ProjectSelectionTemplateSnapshot: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let entries: [LogicalSelectionEntry]
    public let revision: Int64

    public init(projectID: UUID, entries: [LogicalSelectionEntry], revision: Int64) {
        self.projectID = projectID
        self.entries = entries
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
        case entries
        case revision
    }
}

public struct ProjectSelectionTemplateMutationInput: Codable, Sendable {
    public let entries: [LogicalSelectionEntry]
    public let expectedRevision: Int64

    public init(entries: [LogicalSelectionEntry], expectedRevision: Int64) {
        self.entries = entries
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case expectedRevision
    }
}

public struct SelectionMutationInput: Codable, Sendable {
    public let entries: [LogicalSelectionEntry]
    public let expectedRevision: Int64

    public init(entries: [LogicalSelectionEntry], expectedRevision: Int64) {
        self.entries = entries
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case expectedRevision
    }
}

public struct SelectionRemovalInput: Codable, Sendable {
    public let rootID: UUID
    public let logicalPaths: Set<String>
    public let expectedRevision: Int64

    public init(rootID: UUID, logicalPaths: Set<String>, expectedRevision: Int64) {
        self.rootID = rootID
        self.logicalPaths = logicalPaths
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPaths
        case expectedRevision
    }
}

public struct ExecutionPermissionSnapshot: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let mode: String
    public let providerSettings: [String: String]
    public let revision: Int64
    public let updatedActor: ExternalActor

    public init(sessionID: UUID, mode: String, providerSettings: [String: String], revision: Int64, updatedActor: ExternalActor) {
        self.sessionID = sessionID
        self.mode = mode
        self.providerSettings = providerSettings
        self.revision = revision
        self.updatedActor = updatedActor
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case mode
        case providerSettings
        case revision
        case updatedActor
    }
}

public struct ExecutionPermissionUpdateInput: Codable, Sendable {
    public let expectedRevision: Int64
    public let mode: String
    public let providerSettings: [String: String]

    public init(expectedRevision: Int64, mode: String, providerSettings: [String: String]) {
        self.expectedRevision = expectedRevision
        self.mode = mode
        self.providerSettings = providerSettings
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
        case mode
        case providerSettings
    }
}

public struct GoblinCollaborationAcknowledgement: Codable, Hashable, Sendable {
    public let decisionID: UUID
    public let acknowledgedPolicyRevision: Int64
    public let acknowledgedControllerRevision: Int64
    public let acknowledgedMembershipRevision: Int64
    public let resultingPolicyRevision: Int64
    public let resultingControllerRevision: Int64
    public let resultingMembershipRevision: Int64
    public let requestID: UUID
    public let correlationID: UUID

    public init(
        decisionID: UUID,
        acknowledgedPolicyRevision: Int64,
        acknowledgedControllerRevision: Int64,
        acknowledgedMembershipRevision: Int64,
        resultingPolicyRevision: Int64,
        resultingControllerRevision: Int64,
        resultingMembershipRevision: Int64,
        requestID: UUID,
        correlationID: UUID
    ) {
        self.decisionID = decisionID
        self.acknowledgedPolicyRevision = acknowledgedPolicyRevision
        self.acknowledgedControllerRevision = acknowledgedControllerRevision
        self.acknowledgedMembershipRevision = acknowledgedMembershipRevision
        self.resultingPolicyRevision = resultingPolicyRevision
        self.resultingControllerRevision = resultingControllerRevision
        self.resultingMembershipRevision = resultingMembershipRevision
        self.requestID = requestID
        self.correlationID = correlationID
    }

    private enum CodingKeys: String, CodingKey {
        case decisionID = "decisionId"
        case acknowledgedPolicyRevision
        case acknowledgedControllerRevision
        case acknowledgedMembershipRevision
        case resultingPolicyRevision
        case resultingControllerRevision
        case resultingMembershipRevision
        case requestID = "requestId"
        case correlationID = "correlationId"
    }
}

public struct CollaborationMetadataSnapshot: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let visibility: Visibility
    public let collaborativeSteeringEnabled: Bool
    public let controllerUserID: String
    public let policyRevision: Int64
    public let controllerRevision: Int64
    public let membershipRevision: Int64
    public let goblinAcknowledgement: GoblinCollaborationAcknowledgement?

    public init(sessionID: UUID, visibility: Visibility, collaborativeSteeringEnabled: Bool, controllerUserID: String, policyRevision: Int64, controllerRevision: Int64, membershipRevision: Int64, goblinAcknowledgement: GoblinCollaborationAcknowledgement? = nil) {
        self.sessionID = sessionID
        self.visibility = visibility
        self.collaborativeSteeringEnabled = collaborativeSteeringEnabled
        self.controllerUserID = controllerUserID
        self.policyRevision = policyRevision
        self.controllerRevision = controllerRevision
        self.membershipRevision = membershipRevision
        self.goblinAcknowledgement = goblinAcknowledgement
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case visibility
        case collaborativeSteeringEnabled
        case controllerUserID = "controllerUserId"
        case policyRevision
        case controllerRevision
        case membershipRevision
        case goblinAcknowledgement
    }
}

public struct InteractionAnswerInput: Codable, Sendable {
    public let interactionID: UUID
    public let expectedRevision: Int64
    public let payload: Data

    public init(interactionID: UUID, expectedRevision: Int64, payload: Data) {
        self.interactionID = interactionID
        self.expectedRevision = expectedRevision
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case interactionID = "interactionId"
        case expectedRevision
        case payload
    }
}

public struct WorktreeBindingSnapshot: Codable, Hashable, Sendable {
    public enum OwnershipState: String, Codable, Sendable { case reserved, active, released, failed }
    public enum MergeState: String, Codable, Sendable { case clean, dirty, conflicted, merged }
    public let bindingID: UUID
    public let projectID: UUID
    public let rootID: UUID
    public let sessionID: UUID?
    public let baseRef: String
    public let branch: String
    public let physicalPath: String
    public let ownershipState: OwnershipState
    public let mergeState: MergeState
    public let revision: Int64

    public init(bindingID: UUID, projectID: UUID, rootID: UUID, sessionID: UUID?, baseRef: String, branch: String, physicalPath: String, ownershipState: OwnershipState, mergeState: MergeState, revision: Int64) {
        self.bindingID = bindingID
        self.projectID = projectID
        self.rootID = rootID
        self.sessionID = sessionID
        self.baseRef = baseRef
        self.branch = branch
        self.physicalPath = physicalPath
        self.ownershipState = ownershipState
        self.mergeState = mergeState
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case projectID = "projectId"
        case rootID = "rootId"
        case sessionID = "sessionId"
        case baseRef
        case branch
        case physicalPath
        case ownershipState
        case mergeState
        case revision
    }
}

public struct WorktreeCreateInput: Codable, Sendable {
    public let rootID: UUID
    public let baseRef: String
    public let branch: String

    public init(rootID: UUID, baseRef: String, branch: String) {
        self.rootID = rootID
        self.baseRef = baseRef
        self.branch = branch
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case baseRef
        case branch
    }
}

public struct WorktreeMergeInput: Codable, Sendable {
    public let bindingID: UUID
    public let strategy: String
    public let expectedRevision: Int64

    public init(bindingID: UUID, strategy: String, expectedRevision: Int64) {
        self.bindingID = bindingID
        self.strategy = strategy
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case strategy
        case expectedRevision
    }
}

public struct WorktreeBindInput: Codable, Sendable {
    public let bindingID: UUID
    public let expectedRevision: Int64
    public let expectedSelectionBindingRevision: Int64

    public init(bindingID: UUID, expectedRevision: Int64, expectedSelectionBindingRevision: Int64) {
        self.bindingID = bindingID
        self.expectedRevision = expectedRevision
        self.expectedSelectionBindingRevision = expectedSelectionBindingRevision
    }

    private enum CodingKeys: String, CodingKey {
        case bindingID = "bindingId"
        case expectedRevision
        case expectedSelectionBindingRevision
    }
}

public struct CollaborationMetadataInput: Codable, Sendable {
    public let expectedPolicyRevision: Int64
    public let expectedControllerRevision: Int64?
    public let expectedMembershipRevision: Int64?
    public let visibility: Visibility
    public let collaborativeSteeringEnabled: Bool
    public let controllerUserID: String

    public init(expectedPolicyRevision: Int64, expectedControllerRevision: Int64? = nil, expectedMembershipRevision: Int64? = nil, visibility: Visibility, collaborativeSteeringEnabled: Bool, controllerUserID: String) {
        self.expectedPolicyRevision = expectedPolicyRevision
        self.expectedControllerRevision = expectedControllerRevision
        self.expectedMembershipRevision = expectedMembershipRevision
        self.visibility = visibility
        self.collaborativeSteeringEnabled = collaborativeSteeringEnabled
        self.controllerUserID = controllerUserID
    }

    private enum CodingKeys: String, CodingKey {
        case expectedPolicyRevision
        case expectedControllerRevision
        case expectedMembershipRevision
        case visibility
        case collaborativeSteeringEnabled
        case controllerUserID = "controllerUserId"
    }
}

public struct ArtifactSnapshot: Codable, Hashable, Sendable {
    public let artifactID: UUID
    public let projectID: UUID
    public let sessionID: UUID?
    public let kind: String
    public let logicalName: String
    public let contentDigest: String
    public let size: Int64
    public let createdCursor: ServiceCursor
    public let retentionState: String

    public init(artifactID: UUID, projectID: UUID, sessionID: UUID?, kind: String, logicalName: String, contentDigest: String, size: Int64, createdCursor: ServiceCursor, retentionState: String = "active") {
        self.artifactID = artifactID
        self.projectID = projectID
        self.sessionID = sessionID
        self.kind = kind
        self.logicalName = logicalName
        self.contentDigest = contentDigest
        self.size = size
        self.createdCursor = createdCursor
        self.retentionState = retentionState
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID = "artifactId"
        case projectID = "projectId"
        case sessionID = "sessionId"
        case kind
        case logicalName
        case contentDigest
        case size
        case createdCursor
        case retentionState
    }
}

public struct WorkflowSnapshot: Codable, Hashable, Sendable {
    public let workflowID: String
    public let source: String
    public let name: String
    public let definition: String
    public let contentDigest: String
    public let enabled: Bool

    public init(workflowID: String, source: String, name: String, definition: String, contentDigest: String, enabled: Bool) {
        self.workflowID = workflowID
        self.source = source
        self.name = name
        self.definition = definition
        self.contentDigest = contentDigest
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case source
        case name
        case definition
        case contentDigest
        case enabled
    }
}

public struct ProjectTreeRequest: Codable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let maximumDepth: Int
    public let maximumEntries: Int

    public init(rootID: UUID, logicalPath: String = "", maximumDepth: Int = 4, maximumEntries: Int = 5000) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.maximumDepth = maximumDepth
        self.maximumEntries = maximumEntries
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case maximumDepth
        case maximumEntries
    }
}

public struct ProjectRefreshInput: Codable, Sendable {
    public let expectedRevision: Int64

    public init(expectedRevision: Int64) {
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case expectedRevision
    }
}

public struct ProjectTreeEntry: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let isDirectory: Bool
    public let size: Int64?

    public init(rootID: UUID, logicalPath: String, isDirectory: Bool, size: Int64?) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.isDirectory = isDirectory
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case isDirectory
        case size
    }
}

public struct ProjectSearchRequest: Codable, Sendable {
    public let rootID: UUID
    public let query: String
    public let logicalPath: String
    public let useRegex: Bool
    public let maximumResults: Int
    public let maximumFileBytes: Int

    public init(rootID: UUID, query: String, logicalPath: String = "", useRegex: Bool = false, maximumResults: Int = 200, maximumFileBytes: Int = 2_097_152) {
        self.rootID = rootID
        self.query = query
        self.logicalPath = logicalPath
        self.useRegex = useRegex
        self.maximumResults = maximumResults
        self.maximumFileBytes = maximumFileBytes
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case query
        case logicalPath
        case useRegex
        case maximumResults
        case maximumFileBytes
    }
}

public struct ProjectSearchHit: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let line: Int
    public let preview: String

    public init(rootID: UUID, logicalPath: String, line: Int, preview: String) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.line = line
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case line
        case preview
    }
}

public struct ProjectFileRequest: Codable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let startLine: Int?
    public let lineCount: Int?
    public let maximumBytes: Int

    public init(rootID: UUID, logicalPath: String, startLine: Int? = nil, lineCount: Int? = nil, maximumBytes: Int = 2_097_152) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.startLine = startLine
        self.lineCount = lineCount
        self.maximumBytes = maximumBytes
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case startLine
        case lineCount
        case maximumBytes
    }
}

public struct ProjectFileSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let content: String
    public let contentDigest: String
    public let truncated: Bool

    public init(rootID: UUID, logicalPath: String, content: String, contentDigest: String, truncated: Bool) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.content = content
        self.contentDigest = contentDigest
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case content
        case contentDigest
        case truncated
    }
}

public struct ProjectCodeMapRequest: Codable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let maximumBytes: Int

    public init(rootID: UUID, logicalPath: String, maximumBytes: Int = 5_242_880) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.maximumBytes = maximumBytes
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case maximumBytes
    }
}

public struct ProjectCodeMapSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let logicalPath: String
    public let status: String
    public let language: String?
    public let content: String
    public let contentDigest: String

    public init(rootID: UUID, logicalPath: String, status: String, language: String?, content: String, contentDigest: String) {
        self.rootID = rootID
        self.logicalPath = logicalPath
        self.status = status
        self.language = language
        self.content = content
        self.contentDigest = contentDigest
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case logicalPath
        case status
        case language
        case content
        case contentDigest
    }
}

public struct ProjectDiffRequest: Codable, Sendable {
    public let rootID: UUID
    public let comparison: String
    public let logicalPaths: [String]
    public let maximumBytes: Int

    public init(rootID: UUID, comparison: String = "HEAD", logicalPaths: [String] = [], maximumBytes: Int = 2_097_152) {
        self.rootID = rootID
        self.comparison = comparison
        self.logicalPaths = logicalPaths
        self.maximumBytes = maximumBytes
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case comparison
        case logicalPaths
        case maximumBytes
    }
}

public struct ProjectDiffSnapshot: Codable, Hashable, Sendable {
    public let rootID: UUID
    public let comparison: String
    public let patch: String
    public let truncated: Bool
    public let contentDigest: String

    public init(rootID: UUID, comparison: String, patch: String, truncated: Bool, contentDigest: String) {
        self.rootID = rootID
        self.comparison = comparison
        self.patch = patch
        self.truncated = truncated
        self.contentDigest = contentDigest
    }

    private enum CodingKeys: String, CodingKey {
        case rootID = "rootId"
        case comparison
        case patch
        case truncated
        case contentDigest
    }
}

public struct ContextBuildInput: Codable, Sendable {
    public let expectedSelectionRevision: Int64
    public let include: [String]

    public init(expectedSelectionRevision: Int64, include: [String]) {
        self.expectedSelectionRevision = expectedSelectionRevision
        self.include = include
    }

    private enum CodingKeys: String, CodingKey {
        case expectedSelectionRevision
        case include
    }
}

public struct ContextBuilderInput: Codable, Sendable {
    public let expectedSelectionRevision: Int64
    public let instructions: String
    public let budget: Int
    public let responseType: String?
    public let allowClarifyingQuestions: Bool

    public init(expectedSelectionRevision: Int64, instructions: String, budget: Int, responseType: String? = nil, allowClarifyingQuestions: Bool = false) {
        self.expectedSelectionRevision = expectedSelectionRevision
        self.instructions = instructions
        self.budget = budget
        self.responseType = responseType
        self.allowClarifyingQuestions = allowClarifyingQuestions
    }

    private enum CodingKeys: String, CodingKey {
        case expectedSelectionRevision, instructions, budget, responseType, allowClarifyingQuestions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        expectedSelectionRevision = try values.decode(Int64.self, forKey: .expectedSelectionRevision)
        instructions = try values.decode(String.self, forKey: .instructions)
        budget = try values.decode(Int.self, forKey: .budget)
        responseType = try values.decodeIfPresent(String.self, forKey: .responseType)
        allowClarifyingQuestions = try values.decodeIfPresent(Bool.self, forKey: .allowClarifyingQuestions) ?? false
    }
}

/// Additive v1 Context Builder result. Selection fields remain flat for
/// compatibility with clients that previously decoded SelectionSnapshot.
public struct ContextBuilderSnapshot: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let entries: [LogicalSelectionEntry]
    public let revision: Int64
    public let bindingRevision: Int64
    public let proposalArtifactID: UUID
    public let response: String?
    public let chatID: UUID?

    public init(selection: SelectionSnapshot, proposalArtifactID: UUID, response: String?, chatID: UUID?) {
        sessionID = selection.sessionID
        entries = selection.entries
        revision = selection.revision
        bindingRevision = selection.bindingRevision
        self.proposalArtifactID = proposalArtifactID
        self.response = response
        self.chatID = chatID
    }

    public var selection: SelectionSnapshot {
        SelectionSnapshot(sessionID: sessionID, entries: entries, revision: revision, bindingRevision: bindingRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case entries
        case revision
        case bindingRevision
        case proposalArtifactID = "proposalArtifactId"
        case response
        case chatID = "chatId"
    }
}

public struct OracleInput: Codable, Sendable {
    public let chatID: UUID?
    public let prompt: String
    public let contextMode: String

    public init(chatID: UUID?, prompt: String, contextMode: String) {
        self.chatID = chatID
        self.prompt = prompt
        self.contextMode = contextMode
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case prompt
        case contextMode
    }
}

public struct OracleSnapshot: Codable, Hashable, Sendable {
    public let chatID: UUID
    public let response: String
    public let artifactID: UUID?
    public let revision: Int64

    public init(chatID: UUID, response: String, artifactID: UUID?, revision: Int64 = 1) {
        self.chatID = chatID
        self.response = response
        self.artifactID = artifactID
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case response
        case artifactID = "artifactId"
        case revision
    }
}

public struct OracleChatTurn: Codable, Hashable, Sendable {
    public let prompt: String
    public let response: String
    public let timestamp: Date

    public init(prompt: String, response: String, timestamp: Date) {
        self.prompt = prompt
        self.response = response
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case response
        case timestamp
    }
}

public struct OracleChatState: Codable, Hashable, Sendable {
    public let chatID: UUID
    public let sessionID: UUID
    public let providerSessionID: String?
    public let turns: [OracleChatTurn]
    public let revision: Int64

    public init(
        chatID: UUID,
        sessionID: UUID,
        providerSessionID: String? = nil,
        turns: [OracleChatTurn],
        revision: Int64
    ) {
        self.chatID = chatID
        self.sessionID = sessionID
        self.providerSessionID = providerSessionID
        self.turns = turns
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case sessionID = "sessionId"
        case providerSessionID = "providerSessionId"
        case turns
        case revision
    }
}
