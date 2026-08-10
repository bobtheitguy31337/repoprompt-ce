import Foundation
import RepoPromptServiceProtocol

public struct OwnedResourceReconciliationReport: Codable, Hashable, Sendable {
    public let inspected: Int
    public let transitioned: Int
    public let deleted: Int
    public let quarantined: Int
    public let failed: Int
    public let observedAt: Date

    public init(inspected: Int, transitioned: Int, deleted: Int, quarantined: Int, failed: Int, observedAt: Date) {
        self.inspected = inspected
        self.transitioned = transitioned
        self.deleted = deleted
        self.quarantined = quarantined
        self.failed = failed
        self.observedAt = observedAt
    }
}

public actor OwnedResourceReconciliationService {
    private let repository: any OwnedResourceRepository
    private let artifactRoot: String
    private let worktreeRoot: String
    private let providerHomeRoot: String?
    private let runner: any WorkspaceCommandRunning
    private let gitExecutable: String

    public init(
        repository: any OwnedResourceRepository,
        artifactRoot: String,
        worktreeRoot: String,
        providerHomeRoot: String? = nil,
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner(),
        gitExecutable: String = "/usr/bin/git"
    ) {
        self.repository = repository
        self.artifactRoot = URL(fileURLWithPath: artifactRoot).standardizedFileURL.path
        self.worktreeRoot = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.path
        self.providerHomeRoot = providerHomeRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.runner = runner
        self.gitExecutable = gitExecutable
    }

    public func reconcile(now: Date = Date()) async -> OwnedResourceReconciliationReport {
        await reconcile(now: now, recoverInterruptedPreparations: false)
    }

    public func reconcileStartup(now: Date = Date()) async -> OwnedResourceReconciliationReport {
        await reconcile(now: now, recoverInterruptedPreparations: true)
    }

    private func reconcile(
        now: Date,
        recoverInterruptedPreparations: Bool
    ) async -> OwnedResourceReconciliationReport {
        var transitioned = 0
        var deleted = 0
        var quarantined = 0
        var failed = 0
        let records: [OwnedResourceRecord]
        do {
            records = try await repository.ownedResources(states: nil)
        } catch {
            return .init(inspected: 0, transitioned: 0, deleted: 0, quarantined: 0, failed: 1, observedAt: now)
        }
        for record in records where record.lifecycleState != .deleted && record.lifecycleState != .failed {
            do {
                let next = try await reconcile(
                    record,
                    now: now,
                    recoverInterruptedPreparation: recoverInterruptedPreparations
                )
                guard next != record.lifecycleState else { continue }
                _ = try await repository.transitionOwnedResource(
                    resourceID: record.resourceID,
                    expectedStates: [record.lifecycleState],
                    to: next,
                    observedBytes: observedSize(at: record.internalPathIdentity),
                    contentDigest: observedDigest(for: record),
                    cleanupError: next == .quarantined || next == .corrupt ? "resource_reconciliation_required" : nil
                )
                transitioned += 1
                if next == .deleted { deleted += 1 }
                if next == .quarantined || next == .corrupt || next == .missing { quarantined += 1 }
            } catch {
                failed += 1
                _ = try? await repository.transitionOwnedResource(
                    resourceID: record.resourceID,
                    expectedStates: [record.lifecycleState],
                    to: .quarantined,
                    observedBytes: observedSize(at: record.internalPathIdentity),
                    contentDigest: nil,
                    cleanupError: "resource_reconciliation_failed"
                )
            }
        }
        let leases = (try? await repository.worktreeMergeLeases(nonterminalOnly: true)) ?? []
        for lease in leases where lease.expiresAt <= now && lease.state != .conflicted {
            do {
                _ = try await repository.transitionWorktreeMergeLease(
                    leaseID: lease.leaseID,
                    expectedStates: [lease.state],
                    to: .conflicted,
                    conflictArtifactPath: lease.conflictArtifactPath,
                    errorCode: "merge_lease_expired"
                )
                transitioned += 1
                quarantined += 1
            } catch {
                failed += 1
            }
        }
        return .init(inspected: records.count + leases.count, transitioned: transitioned, deleted: deleted, quarantined: quarantined, failed: failed, observedAt: now)
    }

    private func reconcile(
        _ record: OwnedResourceRecord,
        now: Date,
        recoverInterruptedPreparation: Bool
    ) async throws -> OwnedResourceLifecycleState {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: record.internalPathIdentity)
        switch record.lifecycleState {
        case .preparing:
            if exists {
                if record.kind == .artifact, artifactMatches(record) { return .prepared }
                if record.kind == .worktree, try await worktreeMatches(record) { return .prepared }
                if isProviderHomeResource(record), providerResourceIsSafe(record) { return .prepared }
                return .quarantined
            }
            if recoverInterruptedPreparation || record.retentionDeadline.map({ $0 <= now }) == true { return .failed }
            return .preparing
        case .prepared, .cleanupPending, .quarantined:
            guard recoverInterruptedPreparation || record.retentionDeadline.map({ $0 <= now }) == true else { return record.lifecycleState }
            guard exists else { return .deleted }
            if record.kind == .artifact {
                try removeArtifact(record)
                return .deleted
            }
            if record.kind == .worktree {
                return try await removeAbandonedWorktree(record) ? .deleted : .quarantined
            }
            if isProviderHomeResource(record) {
                try removeProviderResource(record)
                return .deleted
            }
            return record.lifecycleState
        case .active:
            guard exists else { return .missing }
            if record.kind == .artifact, !artifactMatches(record) { return .corrupt }
            if record.kind == .worktree, try await !worktreeMatches(record) { return .corrupt }
            return .active
        case .missing, .corrupt, .conflicted:
            return record.lifecycleState
        case .released:
            guard record.retentionDeadline.map({ $0 <= now }) == true else { return .released }
            return exists ? .quarantined : .deleted
        case .deleted, .failed:
            return record.lifecycleState
        }
    }

    private func artifactMatches(_ record: OwnedResourceRecord) -> Bool {
        guard isContained(record.internalPathIdentity, root: artifactRoot),
              !isSymbolicLink(record.internalPathIdentity),
              let data = try? Data(contentsOf: URL(fileURLWithPath: record.internalPathIdentity), options: [.mappedIfSafe])
        else { return false }
        return (record.observedBytes == nil || record.observedBytes == Int64(data.count))
            && (record.contentDigest == nil || record.contentDigest == CanonicalSigning.bodyDigest(data))
    }

    private func worktreeMatches(_ record: OwnedResourceRecord) async throws -> Bool {
        guard isContained(record.internalPathIdentity, root: worktreeRoot), !isSymbolicLink(record.internalPathIdentity) else { return false }
        let top = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", record.internalPathIdentity, "rev-parse", "--show-toplevel"],
            workingDirectory: record.internalPathIdentity,
            maximumBytes: 65536
        )
        return URL(fileURLWithPath: top.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path == record.internalPathIdentity
    }

    private func isProviderHomeResource(_ record: OwnedResourceRecord) -> Bool {
        record.kind == .providerHome || record.kind == .providerCredentialCopy
    }

    private func providerResourceIsSafe(_ record: OwnedResourceRecord) -> Bool {
        guard let providerHomeRoot else { return false }
        return isContained(record.internalPathIdentity, root: providerHomeRoot)
            && !isSymbolicLink(record.internalPathIdentity)
    }

    private func removeProviderResource(_ record: OwnedResourceRecord) throws {
        guard providerResourceIsSafe(record) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Provider-home cleanup path is unsafe")
        }
        try FileManager.default.removeItem(atPath: record.internalPathIdentity)
        try DurableFilesystem.fsyncDirectory(URL(fileURLWithPath: record.internalPathIdentity).deletingLastPathComponent().path)
    }

    private func removeArtifact(_ record: OwnedResourceRecord) throws {
        guard isContained(record.internalPathIdentity, root: artifactRoot), !isSymbolicLink(record.internalPathIdentity) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Artifact cleanup path is unsafe")
        }
        try FileManager.default.removeItem(atPath: record.internalPathIdentity)
        try DurableFilesystem.fsyncDirectory(URL(fileURLWithPath: record.internalPathIdentity).deletingLastPathComponent().path)
    }

    private func removeAbandonedWorktree(_ record: OwnedResourceRecord) async throws -> Bool {
        guard isContained(record.internalPathIdentity, root: worktreeRoot),
              !isSymbolicLink(record.internalPathIdentity),
              let sourceRoot = record.metadata["sourceRoot"]
        else { return false }
        let status = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", record.internalPathIdentity, "status", "--porcelain"],
            workingDirectory: record.internalPathIdentity,
            maximumBytes: 65536
        )
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        _ = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", sourceRoot, "worktree", "remove", record.internalPathIdentity],
            workingDirectory: sourceRoot,
            maximumBytes: 65536
        )
        _ = try await runner.run(
            executable: gitExecutable,
            arguments: ["-C", sourceRoot, "worktree", "prune"],
            workingDirectory: sourceRoot,
            maximumBytes: 65536
        )
        return !FileManager.default.fileExists(atPath: record.internalPathIdentity)
    }

    private func isContained(_ path: String, root: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standardized.hasPrefix(prefix) && standardized != root
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func observedSize(at path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
    }

    private func observedDigest(for record: OwnedResourceRecord) -> String? {
        guard record.kind == .artifact,
              let data = try? Data(contentsOf: URL(fileURLWithPath: record.internalPathIdentity), options: [.mappedIfSafe])
        else { return record.contentDigest }
        return CanonicalSigning.bodyDigest(data)
    }
}
