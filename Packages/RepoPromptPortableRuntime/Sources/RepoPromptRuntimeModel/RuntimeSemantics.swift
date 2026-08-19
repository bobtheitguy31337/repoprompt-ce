import Foundation

public enum Visibility: String, Codable, Sendable {
    case privateSession = "private"
    case collaborative
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCompatible
    case openCodeACP
    case cursorACP
    case grokBuildACP
    case headlessAdapter
    case mcp
}

public enum ProviderExecutionMode: String, Codable, CaseIterable, Sendable {
    case readOnly
    case workspaceWrite
    case fullAccess
}

public enum SessionLifecycleState: String, Codable, CaseIterable, Sendable {
    case preparing
    case idle
    case running
    case waiting
    case completed
    case failed
    case canceled
    case interrupted
    case archived
}

public enum ProjectLifecycleState: String, Codable, CaseIterable, Sendable {
    case active
    case degraded
    case archived
}

public struct ProviderModelIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct AuthorityRevisionEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let revision: Int64
    public let updatedAt: Date

    public init(value: Value, revision: Int64, updatedAt: Date) {
        self.value = value
        self.revision = revision
        self.updatedAt = updatedAt
    }
}

public struct AuthoritySnapshot: Codable, Hashable, Sendable {
    public var entities: [String: SessionLifecycleState]
    public var revision: Int64

    public init(entities: [String: SessionLifecycleState] = [:], revision: Int64 = 0) {
        self.entities = entities
        self.revision = revision
    }
}

public enum AuthorityTransitionCommand: Codable, Hashable, Sendable {
    case setLifecycle(entityID: String, state: SessionLifecycleState)
    case remove(entityID: String)
}

public struct AuthorityTransitionReceipt: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let revision: Int64
    public let cursor: ServiceCursor?

    public init(operationID: UUID, revision: Int64, cursor: ServiceCursor? = nil) {
        self.operationID = operationID
        self.revision = revision
        self.cursor = cursor
    }
}

public enum AuthorityReconciliationState: String, Codable, Hashable, Sendable {
    case notRequired
    case required
    case reconciled
}

public struct ProviderExecutionPolicy: Codable, Hashable, Sendable {
    public let mode: ProviderExecutionMode
    public let writableRoots: [String]
    public let providerSettings: [String: String]

    public init(
        mode: ProviderExecutionMode = .workspaceWrite,
        writableRoots: [String] = [],
        providerSettings: [String: String] = [:]
    ) {
        self.mode = mode
        self.writableRoots = writableRoots
        self.providerSettings = providerSettings
    }
}
