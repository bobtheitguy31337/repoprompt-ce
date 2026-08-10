import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptHeadlessRuntime
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public struct ReadinessCheck: Codable, Hashable, Sendable {
    public let name: String
    public let ready: Bool
    public let detail: String
}

public struct ProviderReadiness: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let required: Bool
    public let ready: Bool
    public let version: String?
    public let protocolVersion: String?
    public let detail: String
}

public struct RepoPromptReadinessSnapshot: Codable, Sendable {
    public let ready: Bool
    public let checks: [ReadinessCheck]
    public let providers: [ProviderReadiness]
    public let degradedProjectIDs: [UUID]
    public let activeSessionCount: Int
    public let maximumActiveSessions: Int
    public let observedAt: Date
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
    private let minimumFreeBytes: Int64
    private let minimumFreeNodes: Int64
    private let maximumActiveSessions: Int
    private let cacheDuration: TimeInterval
    private var cached: RepoPromptReadinessSnapshot?

    public init(authority: RepoPromptHeadlessAuthority, store: SQLiteServiceStore, volumes: [Volume] = [], requiredProviders: Set<ProviderKind> = [], minimumFreeBytes: Int64 = 268_435_456, minimumFreeNodes: Int64 = 1024, maximumActiveSessions: Int = 64, cacheDuration: TimeInterval = 15) {
        self.authority = authority
        self.store = store
        self.volumes = volumes
        self.requiredProviders = requiredProviders
        self.minimumFreeBytes = minimumFreeBytes
        self.minimumFreeNodes = minimumFreeNodes
        self.maximumActiveSessions = maximumActiveSessions
        self.cacheDuration = cacheDuration
    }

    public func snapshot(forceRefresh: Bool = false) async -> RepoPromptReadinessSnapshot {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.observedAt) < cacheDuration { return cached }
        var checks: [ReadinessCheck] = []
        do {
            let metadata = try await store.metadata()
            checks.append(ReadinessCheck(name: "sqlite", ready: metadata.schemaVersion == 1, detail: metadata.schemaVersion == 1 ? "schema-v1" : "schema-mismatch"))
        } catch {
            checks.append(ReadinessCheck(name: "sqlite", ready: false, detail: "unavailable"))
        }

        let authorityReady = await authority.isReady()
        checks.append(ReadinessCheck(name: "quiesce", ready: authorityReady, detail: authorityReady ? "accepting" : "quiescing"))
        for volume in volumes {
            checks.append(volumeCheck(volume))
        }

        let capabilities = await authority.providerCapabilities(preflight: true)
        let providers = capabilities.map { capability in
            let required = requiredProviders.contains(capability.kind)
            return ProviderReadiness(kind: capability.kind, required: required, ready: !required || capability.enabled, version: capability.version, protocolVersion: capability.protocolVersion, detail: capability.enabled ? "ready" : (capability.reasonUnavailable ?? "disabled"))
        }
        let sessions = await authority.sessionSnapshots()
        let activeStates: Set<SessionLifecycleState> = [.preparing, .running, .waiting]
        let activeSessionCount = sessions.count(where: { activeStates.contains($0.state) })
        let capacityReady = activeSessionCount < maximumActiveSessions
        checks.append(ReadinessCheck(name: "session-capacity", ready: capacityReady, detail: "\(activeSessionCount)/\(maximumActiveSessions)"))
        let projects = await authority.projectSnapshots()
        let degraded = projects.filter { $0.state == .degraded }.map(\.projectID).sorted { $0.uuidString < $1.uuidString }
        let ready = checks.allSatisfy(\.ready) && providers.allSatisfy(\.ready)
        let result = RepoPromptReadinessSnapshot(ready: ready, checks: checks, providers: providers, degradedProjectIDs: degraded, activeSessionCount: activeSessionCount, maximumActiveSessions: maximumActiveSessions, observedAt: Date())
        cached = result
        return result
    }

    private func volumeCheck(_ volume: Volume) -> ReadinessCheck {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: volume.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ReadinessCheck(name: "volume:\(volume.name)", ready: false, detail: "missing")
        }
        let probe = URL(fileURLWithPath: volume.path, isDirectory: true).appendingPathComponent(".repoprompt-readiness-\(UUID().uuidString)")
        do {
            try Data("ready".utf8).write(to: probe, options: [.atomic])
            try manager.removeItem(at: probe)
            let attributes = try manager.attributesOfFileSystem(forPath: volume.path)
            let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let freeNodes = (attributes[.systemFreeNodes] as? NSNumber)?.int64Value ?? minimumFreeNodes
            let ready = freeBytes >= minimumFreeBytes && freeNodes >= minimumFreeNodes
            return ReadinessCheck(name: "volume:\(volume.name)", ready: ready, detail: ready ? "writable" : "capacity-low")
        } catch {
            return ReadinessCheck(name: "volume:\(volume.name)", ready: false, detail: "not-writable")
        }
    }
}

struct RepoPromptDiagnostics: Codable {
    let storeID: UUID
    let schemaVersion: Int
    let nextGlobalSequence: Int64
    let replayFloor: Int64
    let readiness: RepoPromptReadinessSnapshot
}
