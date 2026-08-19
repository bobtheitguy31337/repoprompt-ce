import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptWorkspaceRuntimeCore

public enum HeadlessRuntimeError: Error, Equatable, Sendable {
    case providerRuntimeUnavailable
    case workspaceCapabilitiesUnavailable
}

public actor RepoPromptHeadlessRuntime {
    private let workspace: WorkspaceRuntime
    private let turnRuntime: AgentTurnRuntime?
    private let workspaceCapabilities: WorkspaceCapabilityRuntime?
    private var agents: [RuntimeOwnerID: AgentRuntime] = [:]

    public init(workspace: WorkspaceRuntime = WorkspaceRuntime()) {
        self.workspace = workspace
        turnRuntime = nil
        workspaceCapabilities = nil
    }

    public init(
        workspace: WorkspaceRuntime = WorkspaceRuntime(),
        settingsProvider: any ProviderTurnSettingsProviding,
        provider: any ProviderTurnExecuting,
        filesystem: any WorkspaceFilesystemPort,
        worktrees: any WorkspaceWorktreePort,
        artifacts: any WorkspaceArtifactPort,
        projectSources: any WorkspaceProjectSourcePort,
        clock: any RuntimeClock = SystemRuntimeClock(),
        idGenerator: any RuntimeIDGenerator = SystemRuntimeIDGenerator()
    ) {
        self.workspace = workspace
        turnRuntime = AgentTurnRuntime(
            settingsProvider: settingsProvider,
            provider: provider,
            clock: clock,
            idGenerator: idGenerator
        )
        workspaceCapabilities = WorkspaceCapabilityRuntime(
            authority: workspace,
            filesystem: filesystem,
            worktrees: worktrees,
            artifacts: artifacts,
            projectSources: projectSources
        )
    }

    public func registerOwner(_ ownerID: RuntimeOwnerID) async throws {
        try await workspace.registerOwner(ownerID)
        if agents[ownerID] == nil {
            agents[ownerID] = AgentRuntime(ownerID: ownerID) { [workspace] reference, requestedBy in
                try await workspace.authorize(reference, requestedBy: requestedBy)
            }
        }
    }

    public func removeOwner(_ ownerID: RuntimeOwnerID) async {
        agents.removeValue(forKey: ownerID)
        await workspace.removeOwner(ownerID)
    }

    public func attach(
        _ resourceID: RuntimeResourceID,
        to ownerID: RuntimeOwnerID
    ) async throws -> OwnedResourceReference {
        do {
            return try await workspace.attach(resourceID, to: ownerID)
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    public func detach(
        _ reference: OwnedResourceReference,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws {
        do {
            try await workspace.detach(reference, requestedBy: ownerID)
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    public func validate(_ workflow: WorkflowDefinition, for ownerID: RuntimeOwnerID) async throws {
        guard let agent = agents[ownerID] else {
            throw AuthorityError.ownerUnavailable(ownerID)
        }
        do {
            try await agent.validateAccess(for: workflow)
        } catch let error as AgentRuntimeError {
            switch error {
            case let .resourceUnavailable(reference):
                throw AuthorityError.resourceUnavailable(reference)
            }
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    @discardableResult
    public func execute(_ request: AgentTurnRequest) async throws -> PreparedProviderTurn {
        guard let agent = agents[request.ownerID] else {
            throw AuthorityError.ownerUnavailable(request.ownerID)
        }
        do {
            try await agent.validateAccess(for: request.workflow)
            guard let turnRuntime else {
                throw HeadlessRuntimeError.providerRuntimeUnavailable
            }
            return try await turnRuntime.prepareAndExecute(request)
        } catch let error as AgentRuntimeError {
            switch error {
            case let .resourceUnavailable(reference):
                throw AuthorityError.resourceUnavailable(reference)
            }
        } catch let error as WorkspaceRuntimeError {
            throw Self.authorityError(from: error)
        }
    }

    public func readFile(
        _ reference: OwnedResourceReference,
        path: WorkspaceRelativePath,
        requestedBy ownerID: RuntimeOwnerID
    ) async throws -> WorkspaceFileSnapshot {
        guard let workspaceCapabilities else {
            throw HeadlessRuntimeError.workspaceCapabilitiesUnavailable
        }
        return try await workspaceCapabilities.readFile(reference, path: path, requestedBy: ownerID)
    }

    private nonisolated static func authorityError(from error: WorkspaceRuntimeError) -> AuthorityError {
        switch error {
        case let .ownerUnavailable(ownerID):
            .ownerUnavailable(ownerID)
        case let .resourceUnavailable(reference):
            .resourceUnavailable(reference)
        case let .staleGrant(grant):
            .staleGrant(grant)
        case .generationExhausted:
            .resourceGenerationExhausted
        }
    }
}

public actor InMemoryAuthorityStore: RepoPromptAuthorityStore {
    private let storeID: UUID
    private var authoritySnapshot: AuthoritySnapshot

    public init(storeID: UUID = UUID(), snapshot: AuthoritySnapshot = AuthoritySnapshot()) {
        self.storeID = storeID
        authoritySnapshot = snapshot
    }

    public func loadAuthoritySnapshot() -> AuthoritySnapshot {
        authoritySnapshot
    }

    public func commit(
        _ command: AuthorityTransitionCommand,
        expectedRevision: Int64,
        operationID: UUID
    ) throws -> AuthorityTransitionReceipt {
        guard expectedRevision == authoritySnapshot.revision else {
            throw AuthorityError.revisionConflict(expected: expectedRevision, actual: authoritySnapshot.revision)
        }
        switch command {
        case let .setLifecycle(entityID, state):
            authoritySnapshot.entities[entityID] = state
        case let .remove(entityID):
            authoritySnapshot.entities.removeValue(forKey: entityID)
        }
        authoritySnapshot.revision += 1
        return AuthorityTransitionReceipt(
            operationID: operationID,
            revision: authoritySnapshot.revision,
            cursor: ServiceCursor(storeID: storeID, globalSequence: authoritySnapshot.revision)
        )
    }
}

public actor RepoPromptHeadlessAuthority: RepoPromptAuthorityServing {
    private let store: any RepoPromptAuthorityStore
    private var projection: AuthoritySnapshot

    public init(store: any RepoPromptAuthorityStore) async throws {
        self.store = store
        projection = try await store.loadAuthoritySnapshot()
    }

    public func snapshot() -> AuthoritySnapshot {
        projection
    }

    public func apply(
        _ command: AuthorityTransitionCommand,
        operationID: UUID
    ) async throws -> AuthorityTransitionReceipt {
        let receipt = try await store.commit(
            command,
            expectedRevision: projection.revision,
            operationID: operationID
        )
        switch command {
        case let .setLifecycle(entityID, state):
            projection.entities[entityID] = state
        case let .remove(entityID):
            projection.entities.removeValue(forKey: entityID)
        }
        projection.revision = receipt.revision
        return receipt
    }
}
