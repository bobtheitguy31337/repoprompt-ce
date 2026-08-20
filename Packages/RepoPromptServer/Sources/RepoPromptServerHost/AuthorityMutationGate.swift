import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// Single host-owned admission fence shared by HTTP, MCP, and private child
/// transports. Draining invalidates every previously issued capability before it
/// waits for already-admitted work.
public actor AuthorityMutationGate: AuthorityMutationAdmitting {
    private var acceptingMutations = true
    private var acceptingSubscriptions = true
    private var inFlightMutations = 0
    private var mutationGenerationValue: UInt64 = 1
    private var readGenerationValue: UInt64 = 1
    private var drainStartedAt: Date?
    private var drainTimedOut = false

    public init() {}

    public func mutationGeneration() -> UInt64 {
        mutationGenerationValue
    }

    public func capability() -> AuthorityMutationCapability {
        AuthorityMutationCapability(generation: mutationGenerationValue, admission: self)
    }

    public func performMutation<Result: Sendable>(
        generation: UInt64,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        guard generation == mutationGenerationValue else {
            throw ServiceAPIError(code: .staleCapability, message: "Authority mutation capability is stale")
        }
        guard acceptingMutations else {
            throw ServiceAPIError(code: .serviceDraining, message: "Service is draining mutations", retryable: true)
        }
        inFlightMutations += 1
        do {
            let result = try await operation()
            inFlightMutations -= 1
            return result
        } catch {
            inFlightMutations -= 1
            throw error
        }
    }

    public func beginDraining(now: Date = Date()) {
        guard acceptingMutations || acceptingSubscriptions else { return }
        acceptingMutations = false
        acceptingSubscriptions = false
        mutationGenerationValue &+= 1
        drainStartedAt = now
    }

    @discardableResult
    public func drain(timeout: Duration = .seconds(15)) async -> AuthorityMutationGateSnapshot {
        beginDraining()
        let clock = ContinuousClock()
        let allowance = max(.zero, timeout)
        let deadline = clock.now.advanced(by: allowance)
        while inFlightMutations > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if inFlightMutations > 0 {
            drainTimedOut = true
        }
        return snapshot()
    }

    /// Invalidates read/subscription capabilities after transport shutdown.
    public func close() {
        acceptingMutations = false
        acceptingSubscriptions = false
        mutationGenerationValue &+= 1
        readGenerationValue &+= 1
    }

    public func snapshot() -> AuthorityMutationGateSnapshot {
        AuthorityMutationGateSnapshot(
            acceptingMutations: acceptingMutations,
            acceptingSubscriptions: acceptingSubscriptions,
            inFlightMutations: inFlightMutations,
            mutationGeneration: mutationGenerationValue,
            readGeneration: readGenerationValue,
            drainStartedAt: drainStartedAt,
            drainTimedOut: drainTimedOut
        )
    }
}
