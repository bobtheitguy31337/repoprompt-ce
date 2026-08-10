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
}

public struct SelectionMutationInput: Codable, Sendable {
    public let entries: [LogicalSelectionEntry]
    public let expectedRevision: Int64

    public init(entries: [LogicalSelectionEntry], expectedRevision: Int64) {
        self.entries = entries
        self.expectedRevision = expectedRevision
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
}
