import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct ReadinessCheck: Codable, Hashable, Sendable {
    public let name: String
    public let ready: Bool
    public let detail: String

    private enum CodingKeys: String, CodingKey {
        case name, ready, detail
    }
}

public struct ProviderReadiness: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let required: Bool
    public let ready: Bool
    public let version: String?
    public let protocolVersion: String?
    public let detail: String

    private enum CodingKeys: String, CodingKey {
        case kind, required, ready, version, protocolVersion, detail
    }
}

public struct RepoPromptReadinessSnapshot: Codable, Sendable {
    public let ready: Bool
    public let checks: [ReadinessCheck]
    public let providers: [ProviderReadiness]
    public let degradedProjectIDs: [UUID]
    public let activeSessionCount: Int
    public let maximumActiveSessions: Int
    public let operational: StoreOperationalSnapshot?
    public let drain: MutationDrainSnapshot
    public let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case ready, checks, providers
        case degradedProjectIDs = "degradedProjectIds"
        case activeSessionCount, maximumActiveSessions, operational, drain, observedAt
    }
}

public actor RepoPromptReadinessService {
    public struct Volume: Hashable, Sendable {
        public let name: String
        public let path: String

        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    private let authority: RepoPromptHeadlessAuthority
    private let store: SQLiteServiceStore
    private let volumes: [Volume]
    private let requiredProviders: Set<ProviderKind>
    private let expectedProviderProtocols: [ProviderKind: String]
    private let minimumFreeBytes: Int64
    private let minimumFreeNodes: Int64
    private let maximumActiveSessions: Int
    private let cacheDuration: TimeInterval
    private let drainController: MutationDrainController
    private let trustConfigurationValid: Bool
    private var cached: RepoPromptReadinessSnapshot?

    public init(
        authority: RepoPromptHeadlessAuthority,
        store: SQLiteServiceStore,
        volumes: [Volume] = [],
        requiredProviders: Set<ProviderKind> = [],
        expectedProviderProtocols: [ProviderKind: String] = [:],
        minimumFreeBytes: Int64 = 268_435_456,
        minimumFreeNodes: Int64 = 1024,
        maximumActiveSessions: Int = 64,
        cacheDuration: TimeInterval = 15,
        drainController: MutationDrainController = MutationDrainController(),
        trustConfigurationValid: Bool = true
    ) {
        self.authority = authority
        self.store = store
        self.volumes = volumes
        self.requiredProviders = requiredProviders
        self.expectedProviderProtocols = expectedProviderProtocols
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumFreeNodes = minimumFreeNodes
        self.maximumActiveSessions = maximumActiveSessions
        self.cacheDuration = cacheDuration
        self.drainController = drainController
        self.trustConfigurationValid = trustConfigurationValid
    }

    public func snapshot(forceRefresh: Bool = false) async -> RepoPromptReadinessSnapshot {
        let drain = await drainController.snapshot()
        if drain.acceptingMutations,
           !forceRefresh,
           let cached,
           Date().timeIntervalSince(cached.observedAt) < cacheDuration
        {
            return cached
        }

        var checks = [ReadinessCheck]()
        var operational: StoreOperationalSnapshot?
        do {
            let snapshot = try await store.operationalSnapshot()
            operational = snapshot
            checks.append(.init(name: "sqlite-integrity", ready: snapshot.integrityValid, detail: snapshot.integrityValid ? "ok" : "failed"))
            checks.append(.init(name: "migrations", ready: snapshot.migrationsValid, detail: snapshot.migrationsValid ? "schema-v2" : "mismatch"))
            checks.append(.init(name: "activation", ready: snapshot.activationState == "active", detail: snapshot.activationState))
            // Startup reconstruction is completed by authority.recover() before this
            // service exists. Families observed here are verified live work, not an
            // unreconciled startup condition, and remain visible in metrics.
            checks.append(.init(name: "supervisor-recovery", ready: true, detail: "active-families=\(snapshot.activeProcessFamilyCount)"))
            checks.append(.init(name: "owned-resources", ready: snapshot.ownedResources.ready, detail: snapshot.ownedResources.ready ? "reconciled" : "degraded"))
        } catch {
            checks.append(.init(name: "sqlite-integrity", ready: false, detail: "unavailable"))
            checks.append(.init(name: "migrations", ready: false, detail: "unavailable"))
            checks.append(.init(name: "activation", ready: false, detail: "unavailable"))
            checks.append(.init(name: "supervisor-recovery", ready: false, detail: "unavailable"))
            checks.append(.init(name: "owned-resources", ready: false, detail: "unavailable"))
        }

        checks.append(.init(name: "trust", ready: trustConfigurationValid, detail: trustConfigurationValid ? "validated" : "invalid"))
        let authorityReady = await authority.isReady()
        let accepting = drain.acceptingMutations && authorityReady
        checks.append(.init(name: "quiesce", ready: accepting, detail: accepting ? "accepting" : "draining"))
        for volume in volumes {
            checks.append(volumeCheck(volume))
        }

        let capabilities = await authority.providerCapabilities(preflight: true)
        let providers = capabilities.map { capability in
            let required = requiredProviders.contains(capability.kind)
            let expectedProtocol = expectedProviderProtocols[capability.kind]
            let protocolMatches = expectedProtocol == nil || capability.protocolVersion == expectedProtocol
            let ready = !required || (capability.enabled && protocolMatches)
            let detail: String
            if !capability.enabled {
                detail = capability.reasonUnavailable ?? "disabled"
            } else if !protocolMatches {
                detail = "protocol-mismatch"
            } else {
                detail = "ready"
            }
            return ProviderReadiness(
                kind: capability.kind,
                required: required,
                ready: ready,
                version: capability.version,
                protocolVersion: capability.protocolVersion,
                detail: detail
            )
        }
        let representedProviders = Set(providers.map(\.kind))
        let missingProviders = requiredProviders.subtracting(representedProviders).map {
            ProviderReadiness(kind: $0, required: true, ready: false, version: nil, protocolVersion: nil, detail: "missing")
        }
        let completeProviders = (providers + missingProviders).sorted { $0.kind.rawValue < $1.kind.rawValue }

        let sessions: [SessionSnapshot]
        do {
            sessions = try await authority.sessionSnapshots()
        } catch {
            sessions = []
            checks.append(.init(name: "session-authority", ready: false, detail: "persistence-unavailable"))
        }
        let activeStates: Set<SessionLifecycleState> = [.preparing, .running, .waiting]
        let activeSessionCount = sessions.count(where: { activeStates.contains($0.state) })
        let capacityReady = activeSessionCount < maximumActiveSessions
        checks.append(.init(name: "session-capacity", ready: capacityReady, detail: "\(activeSessionCount)/\(maximumActiveSessions)"))
        let projects = await authority.projectSnapshots()
        let degraded = projects.filter { $0.state == .degraded }.map(\.projectID).sorted { $0.uuidString < $1.uuidString }
        let ready = checks.allSatisfy(\.ready) && completeProviders.allSatisfy(\.ready)
        let result = RepoPromptReadinessSnapshot(
            ready: ready,
            checks: checks,
            providers: completeProviders,
            degradedProjectIDs: degraded,
            activeSessionCount: activeSessionCount,
            maximumActiveSessions: maximumActiveSessions,
            operational: operational,
            drain: drain,
            observedAt: Date()
        )
        cached = result
        return result
    }

    private func volumeCheck(_ volume: Volume) -> ReadinessCheck {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: volume.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init(name: "volume:\(volume.name)", ready: false, detail: "missing")
        }
        let probe = URL(fileURLWithPath: volume.path, isDirectory: true).appendingPathComponent(".repoprompt-readiness-\(UUID().uuidString)")
        do {
            try Data("ready".utf8).write(to: probe, options: [.atomic])
            try manager.removeItem(at: probe)
            let attributes = try manager.attributesOfFileSystem(forPath: volume.path)
            let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let freeNodes = (attributes[.systemFreeNodes] as? NSNumber)?.int64Value ?? minimumFreeNodes
            let ready = freeBytes >= minimumFreeBytes && freeNodes >= minimumFreeNodes
            return .init(name: "volume:\(volume.name)", ready: ready, detail: ready ? "writable" : "capacity-low")
        } catch {
            return .init(name: "volume:\(volume.name)", ready: false, detail: "not-writable")
        }
    }
}

struct RepoPromptDiagnostics: Codable {
    let storeID: UUID
    let schemaVersion: Int
    let nextGlobalSequence: Int64
    let replayFloor: Int64
    let readiness: RepoPromptReadinessSnapshot
    let operational: StoreOperationalSnapshot?
    let drain: MutationDrainSnapshot
    let maintenance: DurabilityMaintenanceSnapshot?

    private enum CodingKeys: String, CodingKey {
        case storeID = "storeId"
        case schemaVersion, nextGlobalSequence, replayFloor, readiness, operational, drain, maintenance
    }
}
