import Foundation
import Logging
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptRuntimeModel

public enum AuthorityHostLifecycleState: Sendable, Equatable {
    case idle
    case acquiringLease
    case validatingStore
    case recoveringResources
    case recoveringProviders
    case recoveringAuthority
    case ready
    case draining
    case quiescingProviders
    case checkpointing
    case closing
    case stopped
    case failed(phase: String, diagnosticCode: String)
}

public struct AuthorityHostConfiguration: Sendable {
    public let namespace: AuthorityNamespaceDescriptor
    public let eventSigningKeyID: String?
    public let eventSigningSecret: Data?

    public init(
        namespace: AuthorityNamespaceDescriptor,
        eventSigningKeyID: String? = nil,
        eventSigningSecret: Data? = nil
    ) {
        self.namespace = namespace
        self.eventSigningKeyID = eventSigningKeyID
        self.eventSigningSecret = eventSigningSecret
    }
}

public struct AuthorityHostShutdownBudget: Sendable {
    public let startedAt: ContinuousClock.Instant
    public let deadline: ContinuousClock.Instant

    public init(total: Duration = .seconds(30)) {
        let clock = ContinuousClock()
        startedAt = clock.now
        deadline = startedAt.advanced(by: max(.zero, total))
    }

    public func remaining() -> Duration {
        max(.zero, ContinuousClock().now.duration(to: deadline))
    }

    public func allowance(maximum: Duration) -> Duration {
        min(max(.zero, maximum), remaining())
    }

    public var isExhausted: Bool { remaining() == .zero }
}

public struct AuthorityHostShutdownReport: Sendable, Equatable {
    public let clean: Bool
    public let mutationDrainTimedOut: Bool
    public let childDrainTimedOut: Bool
    public let budgetExhausted: Bool
    public let elapsed: Duration
    public let finalState: AuthorityHostLifecycleState

    public var drainTimedOut: Bool { mutationDrainTimedOut || childDrainTimedOut }
}

public struct AuthorityHostStartupObservation: Sendable, Equatable {
    public let diagnosticCodes: [String]
    public let staleOwnerRecoveries: Int
}

public struct AuthorityHostCapabilities: Sendable {
    public let authority: RepoPromptHeadlessAuthority
    public let store: SQLiteServiceStore
    public let mutationGate: AuthorityMutationGate
}

/// Lifecycle owner shared by the network Server and private direct-headless
/// helper. It deliberately imports no HTTP/TLS/portal modules.
public actor RepoPromptAuthorityHost {
    public nonisolated let instanceID: UUID
    public nonisolated let configuration: AuthorityHostConfiguration
    public nonisolated let mutationGate: AuthorityMutationGate

    private var stateValue: AuthorityHostLifecycleState = .idle
    private var lease: AuthorityNamespaceLease?
    private var storeValue: SQLiteServiceStore?
    private var authorityValue: RepoPromptHeadlessAuthority?
    private var directRuntimeValue: MCPDomainRuntime?
    private var durabilityOperationsValue: DurabilityOperationsService?
    private var startupDiagnosticCodes: [String] = []
    private var staleOwnerRecoveries = 0
    private var shutdownBudget: AuthorityHostShutdownBudget?
    private var shutdownDrainSnapshot: AuthorityMutationGateSnapshot?
    private var lastShutdownReport: AuthorityHostShutdownReport?
    private let logger = Logger(label: "com.repoprompt.ce.authority-host")

    private init(configuration: AuthorityHostConfiguration) {
        self.instanceID = UUID()
        self.configuration = configuration
        self.mutationGate = AuthorityMutationGate()
    }

    public static func start(configuration: AuthorityHostConfiguration) async throws -> RepoPromptAuthorityHost {
        let host = RepoPromptAuthorityHost(configuration: configuration)
        try await host.open()
        return host
    }

    private func open() async throws {
        do {
            stateValue = .acquiringLease
            let acquisition = try AuthorityNamespaceLease.acquire(configuration.namespace)
            lease = acquisition.lease
            if acquisition.recoveredStaleOwner {
                startupDiagnosticCodes.append("stale_owner_recovered")
                staleOwnerRecoveries += 1
                logger.warning(
                    "authority_namespace_stale_owner_recovered",
                    metadata: [
                        "namespace": "\(configuration.namespace.namespaceID)",
                        "mode": "\(configuration.namespace.servingMode.rawValue)"
                    ]
                )
            }
            stateValue = .validatingStore
            let eventSigningKey: PersistenceEventSigningKey? = if let keyID = configuration.eventSigningKeyID,
                                                                  let secret = configuration.eventSigningSecret
            {
                PersistenceEventSigningKey(keyID: keyID, secret: secret)
            } else {
                nil
            }
            storeValue = try await SQLiteServiceStore.openForServing(
                storage: .file(configuration.namespace.databasePath),
                eventSigningKey: eventSigningKey
            )
            stateValue = .recoveringResources
        } catch let error as ServiceAPIError {
            stateValue = .failed(phase: "startup", diagnosticCode: error.code.rawValue)
            lease?.release()
            lease = nil
            throw error
        } catch {
            stateValue = .failed(phase: "startup", diagnosticCode: "authority_start_failed")
            lease?.release()
            lease = nil
            throw error
        }
    }

    public func storeForRecovery() throws -> SQLiteServiceStore {
        guard let storeValue else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority store is unavailable")
        }
        return storeValue
    }

    public func markRecoveringProviders() { stateValue = .recoveringProviders }
    public func markRecoveringAuthority() { stateValue = .recoveringAuthority }

    public func installRecoveredAuthority(
        _ authority: RepoPromptHeadlessAuthority,
        durabilityOperations: DurabilityOperationsService? = nil
    ) {
        authorityValue = authority
        durabilityOperationsValue = durabilityOperations
        stateValue = .ready
    }

    func installDirectHeadlessRuntime(_ runtime: MCPDomainRuntime) throws {
        guard configuration.namespace.servingMode == .directHeadless,
              directRuntimeValue == nil,
              authorityValue == nil
        else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Direct-headless runtime does not match the authority host mode"
            )
        }
        directRuntimeValue = runtime
        stateValue = .ready
    }

    public func capabilities() throws -> AuthorityHostCapabilities {
        guard stateValue == .ready, let authorityValue, let storeValue else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Authority host is not ready")
        }
        return .init(authority: authorityValue, store: storeValue, mutationGate: mutationGate)
    }

    public func lifecycleState() -> AuthorityHostLifecycleState { stateValue }

    public func startupObservation() -> AuthorityHostStartupObservation {
        .init(
            diagnosticCodes: startupDiagnosticCodes,
            staleOwnerRecoveries: staleOwnerRecoveries
        )
    }

    @discardableResult
    public func beginShutdown(using proposedBudget: AuthorityHostShutdownBudget) async -> AuthorityMutationGateSnapshot {
        if let snapshot = shutdownDrainSnapshot { return snapshot }
        let budget = recordShutdownBudget(proposedBudget)
        stateValue = .draining
        let snapshot = await mutationGate.drain(timeout: budget.allowance(maximum: .seconds(15)))
        shutdownDrainSnapshot = snapshot
        return snapshot
    }

    public func shutdown(reason: String, deadline: Duration = .seconds(30)) async -> AuthorityHostShutdownReport {
        await shutdown(
            reason: reason,
            using: AuthorityHostShutdownBudget(total: deadline),
            childDrainTimedOut: false
        )
    }

    public func shutdown(
        reason _: String,
        using proposedBudget: AuthorityHostShutdownBudget,
        childDrainTimedOut: Bool
    ) async -> AuthorityHostShutdownReport {
        if let lastShutdownReport { return lastShutdownReport }
        let budget = recordShutdownBudget(proposedBudget)
        let drain = await beginShutdown(using: budget)
        var clean = !drain.drainTimedOut && !childDrainTimedOut && !budget.isExhausted

        stateValue = .quiescingProviders
        if let authorityValue {
            do {
                try await authorityValue.quiesce()
            } catch {
                clean = false
            }
        }
        if let directRuntimeValue {
            _ = await directRuntimeValue.shutdown()
        }
        if let durabilityOperationsValue {
            await durabilityOperationsValue.stop()
            _ = await durabilityOperationsValue.runOnce()
        }
        if budget.isExhausted { clean = false }

        stateValue = .checkpointing
        if clean, let storeValue {
            do {
                try await storeValue.checkpoint()
            } catch {
                clean = false
            }
        }

        stateValue = .closing
        await mutationGate.close()
        if budget.isExhausted { clean = false }
        if let storeValue {
            do {
                try await storeValue.close(clean: clean)
            } catch {
                clean = false
                try? await storeValue.close(clean: false)
            }
        }
        storeValue = nil
        authorityValue = nil
        directRuntimeValue = nil
        durabilityOperationsValue = nil

        // The namespace lease is deliberately the final owned resource released.
        lease?.release()
        lease = nil
        stateValue = .stopped
        let exhausted = budget.isExhausted
        if exhausted { clean = false }
        let report = AuthorityHostShutdownReport(
            clean: clean,
            mutationDrainTimedOut: drain.drainTimedOut,
            childDrainTimedOut: childDrainTimedOut,
            budgetExhausted: exhausted,
            elapsed: budget.startedAt.duration(to: ContinuousClock().now),
            finalState: .stopped
        )
        lastShutdownReport = report
        return report
    }

    private func recordShutdownBudget(_ proposed: AuthorityHostShutdownBudget) -> AuthorityHostShutdownBudget {
        if let shutdownBudget, shutdownBudget.deadline <= proposed.deadline {
            return shutdownBudget
        }
        shutdownBudget = proposed
        return proposed
    }
}

/// The only serving factory allowed to acquire an authority namespace lease.
/// Executables provide outer transport configuration but never open a store or
/// construct a lease themselves.
public enum RepoPromptAuthorityHostFactory {
    public static func start(
        configuration: AuthorityHostConfiguration
    ) async throws -> RepoPromptAuthorityHost {
        try await RepoPromptAuthorityHost.start(configuration: configuration)
    }

    static func startDirectHeadless(
        configuration: AuthorityHostConfiguration,
        runtime: MCPDomainRuntime
    ) async throws -> RepoPromptAuthorityHost {
        let host = try await start(configuration: configuration)
        do {
            try await runtime.start()
            try await host.installDirectHeadlessRuntime(runtime)
            return host
        } catch {
            _ = await host.shutdown(reason: "direct_headless_start_failed", deadline: .seconds(5))
            throw error
        }
    }
}
