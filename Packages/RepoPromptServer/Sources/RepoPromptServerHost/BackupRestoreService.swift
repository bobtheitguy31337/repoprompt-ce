import Crypto
import Foundation
import RepoPromptRuntimeModel
import RepoPromptServicePersistence

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum BackupAssetDisposition: String, Codable, Sendable {
    case included
    case externalRequired
    case externalOptional
}

public struct BackupAssetRoot: Sendable, Equatable {
    public let logicalID: String
    public let url: URL

    public init(logicalID: String, url: URL) {
        self.logicalID = logicalID
        self.url = url
    }
}

public struct BackupExternalAsset: Codable, Equatable, Sendable {
    public let logicalID: String
    public let disposition: BackupAssetDisposition
    public let expectedVersion: String?
    public let expectedSHA256: String

    public init(
        logicalID: String,
        disposition: BackupAssetDisposition,
        expectedVersion: String? = nil,
        expectedSHA256: String
    ) {
        self.logicalID = logicalID
        self.disposition = disposition
        self.expectedVersion = expectedVersion
        self.expectedSHA256 = expectedSHA256
    }
}

public struct BackupAssetManifestEntry: Codable, Equatable, Sendable {
    public let logicalID: String
    public let archivePath: String
    public let disposition: BackupAssetDisposition
    public let byteCount: Int64
    public let mode: UInt16
    public let sha256: String
    public let expectedVersion: String?
}

public struct BackupManifestV1: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let createdAt: Date
    public let toolVersion: String
    public let toolDigest: String
    public let namespaceKind: String
    public let databaseIdentityDigest: String
    public let source: MigrationSourceEvidence
    public let recipientFingerprints: [String]
    public let assets: [BackupAssetManifestEntry]
}

public struct BackupVerificationRecord: Codable, Equatable, Sendable {
    public let verifiedAt: Date
    public let verifierFingerprint: String
    public let maintenanceToolVersion: String
    public let maintenanceToolDigest: String
}

public struct BackupSidecarV1: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let archiveSHA256: String
    public let manifestSHA256: String
    public let manifestVersion: Int
    public let source: MigrationSourceEvidence
    public let recipientFingerprints: [String]
    public let createdAt: Date
    public let toolVersion: String
    public let toolDigest: String
    public var verification: BackupVerificationRecord?
}

public struct VerifiedBackupArchive: Sendable {
    public let manifest: BackupManifestV1
    public let sidecar: BackupSidecarV1
    public let plaintextEntries: [String: Data]

    public var migrationEvidence: VerifiedMigrationBackup {
        VerifiedMigrationBackup(
            source: manifest.source,
            archiveSHA256: sidecar.archiveSHA256,
            manifestSHA256: sidecar.manifestSHA256,
            verifierFingerprint: sidecar.verification?.verifierFingerprint ?? ""
        )
    }
}

public struct BackupCreateRequest: Sendable {
    public let outputURL: URL
    public let recipientsFileURL: URL
    public let roots: [BackupAssetRoot]
    public let externalAssets: [BackupExternalAsset]
    public let namespaceKind: String
    public let databaseIdentityDigest: String

    public init(
        outputURL: URL,
        recipientsFileURL: URL,
        roots: [BackupAssetRoot],
        externalAssets: [BackupExternalAsset] = [],
        namespaceKind: String,
        databaseIdentityDigest: String
    ) {
        self.outputURL = outputURL
        self.recipientsFileURL = recipientsFileURL
        self.roots = roots
        self.externalAssets = externalAssets
        self.namespaceKind = namespaceKind
        self.databaseIdentityDigest = databaseIdentityDigest
    }
}

public struct BackupRestoreRequest: Sendable {
    public let archiveURL: URL
    public let identityFileURL: URL
    public let targetRootURL: URL
    public let targetNamespaceKind: String
    public let targetDatabaseIdentityDigest: String
    public let observedExternalAssets: [String: String]

    public init(
        archiveURL: URL,
        identityFileURL: URL,
        targetRootURL: URL,
        targetNamespaceKind: String,
        targetDatabaseIdentityDigest: String,
        observedExternalAssets: [String: String] = [:]
    ) {
        self.archiveURL = archiveURL
        self.identityFileURL = identityFileURL
        self.targetRootURL = targetRootURL
        self.targetNamespaceKind = targetNamespaceKind
        self.targetDatabaseIdentityDigest = targetDatabaseIdentityDigest
        self.observedExternalAssets = observedExternalAssets
    }
}

public protocol BackupEnvelopeEncrypting: Sendable {
    func encrypt(plaintext: URL, recipientsFile: URL, ciphertext: URL) async throws
    func decrypt(ciphertext: URL, identityFile: URL, plaintext: URL) async throws
}

public struct AgeRuntimeConfiguration: Sendable {
    public let executableURL: URL
    public let expectedExecutableSHA256: String

    public init(executableURL: URL, expectedExecutableSHA256: String) {
        self.executableURL = executableURL
        self.expectedExecutableSHA256 = expectedExecutableSHA256
    }

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let executable = environment["REPOPROMPT_AGE_EXECUTABLE"] ?? "/usr/local/libexec/repoprompt/age"
        let checksum: String
        if let configured = environment["REPOPROMPT_AGE_SHA256"] {
            checksum = configured
        } else {
            let checksumURL = URL(fileURLWithPath: executable + ".sha256")
            guard let value = try? String(contentsOf: checksumURL, encoding: .utf8)
                .split(whereSeparator: { $0.isWhitespace }).first
            else {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "Pinned age checksum is not configured"
                )
            }
            checksum = String(value)
        }
        return .init(executableURL: URL(fileURLWithPath: executable), expectedExecutableSHA256: checksum)
    }
}

public struct AgeBackupEnvelope: BackupEnvelopeEncrypting {
    public let configuration: AgeRuntimeConfiguration

    public init(configuration: AgeRuntimeConfiguration) throws {
        let data = try Data(contentsOf: configuration.executableURL, options: [.mappedIfSafe])
        let observed = BackupCryptography.sha256(data)
        guard observed == configuration.expectedExecutableSHA256.lowercased(),
              observed.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else {
            throw ServiceAPIError(
                code: .dependencyUnavailable,
                message: "Pinned age executable checksum mismatch"
            )
        }
        self.configuration = configuration
    }

    public func encrypt(plaintext: URL, recipientsFile: URL, ciphertext: URL) async throws {
        try await run([
            "--encrypt",
            "--recipients-file", recipientsFile.path,
            "--output", ciphertext.path,
            plaintext.path,
        ])
    }

    public func decrypt(ciphertext: URL, identityFile: URL, plaintext: URL) async throws {
        try BackupFileSafety.requireIdentityFile(identityFile)
        try await run([
            "--decrypt",
            "--identity", identityFile.path,
            "--output", plaintext.path,
            ciphertext.path,
        ])
    }

    private func run(_ arguments: [String]) async throws {
        let executableURL = configuration.executableURL
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "age envelope operation failed with exit status \(process.terminationStatus)",
                    retryable: false
                )
            }
        }.value
    }
}

public actor BackupRestoreService {
    public static let sidecarSuffix = ".sidecar.json"
    public static let manifestArchivePath = "repoprompt-backup-manifest-v1.json"

    private let envelope: any BackupEnvelopeEncrypting
    private let toolVersion: String
    private let toolDigest: String

    public init(
        envelope: any BackupEnvelopeEncrypting,
        toolVersion: String,
        toolDigest: String
    ) {
        self.envelope = envelope
        self.toolVersion = toolVersion
        self.toolDigest = toolDigest
    }

    public func create(
        request: BackupCreateRequest,
        store: SQLiteServiceStore
    ) async throws -> BackupSidecarV1 {
        guard request.outputURL.pathExtension == "age" else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup output must use the .age extension")
        }
        guard !FileManager.default.fileExists(atPath: request.outputURL.path),
              !FileManager.default.fileExists(atPath: Self.sidecarURL(for: request.outputURL).path)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup output already exists")
        }
        let source = try await store.migrationSourceEvidence()
        let recipients = try Self.recipientFingerprints(request.recipientsFileURL)
        guard !recipients.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Recipients file contains no supported recipients")
        }
        let inventory = try Self.inventory(request.roots, externalAssets: request.externalAssets)
        guard inventory.entries.contains(where: {
            $0.disposition == .included && $0.sha256 == source.sqliteSHA256
        }) else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Backup inventory does not contain the checkpointed source database"
            )
        }
        var manifest = BackupManifestV1(
            formatVersion: 1,
            createdAt: Date(),
            toolVersion: toolVersion,
            toolDigest: toolDigest,
            namespaceKind: request.namespaceKind,
            databaseIdentityDigest: request.databaseIdentityDigest,
            source: source,
            recipientFingerprints: recipients,
            assets: inventory.entries
        )
        // Canonical ordering is part of format v1.
        manifest = BackupManifestV1(
            formatVersion: manifest.formatVersion,
            createdAt: manifest.createdAt,
            toolVersion: manifest.toolVersion,
            toolDigest: manifest.toolDigest,
            namespaceKind: manifest.namespaceKind,
            databaseIdentityDigest: manifest.databaseIdentityDigest,
            source: manifest.source,
            recipientFingerprints: manifest.recipientFingerprints.sorted(),
            assets: manifest.assets.sorted { $0.archivePath < $1.archivePath }
        )
        let manifestData = try Self.encoder.encode(manifest)
        let workspace = try BackupFileSafety.temporaryWorkspace(near: request.outputURL)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plaintext = workspace.appendingPathComponent("archive.tar")
        let ciphertext = request.outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(request.outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        var archiveEntries = inventory.data
        archiveEntries[Self.manifestArchivePath] = (.init(data: manifestData, mode: 0o600))
        try UStarArchive.write(entries: archiveEntries, to: plaintext)
        try BackupFileSafety.protectFile(plaintext)
        // Verify the plaintext archive before encryption.
        let decoded = try UStarArchive.read(from: plaintext)
        try Self.verifyEntries(decoded, manifest: manifest, manifestData: manifestData)
        do {
            try await envelope.encrypt(
                plaintext: plaintext,
                recipientsFile: request.recipientsFileURL,
                ciphertext: ciphertext
            )
            try BackupFileSafety.protectAndSync(ciphertext)
            try BackupFileSafety.atomicPublish(ciphertext, to: request.outputURL)
            let archiveSHA256 = try BackupCryptography.sha256(request.outputURL)
            let sidecar = BackupSidecarV1(
                formatVersion: 1,
                archiveSHA256: archiveSHA256,
                manifestSHA256: BackupCryptography.sha256(manifestData),
                manifestVersion: 1,
                source: source,
                recipientFingerprints: recipients.sorted(),
                createdAt: manifest.createdAt,
                toolVersion: toolVersion,
                toolDigest: toolDigest,
                verification: nil
            )
            try BackupFileSafety.writeAtomic(
                Self.encoder.encode(sidecar),
                to: Self.sidecarURL(for: request.outputURL),
                mode: 0o600
            )
            return sidecar
        } catch {
            try? FileManager.default.removeItem(at: ciphertext)
            try? FileManager.default.removeItem(at: request.outputURL)
            try? FileManager.default.removeItem(at: Self.sidecarURL(for: request.outputURL))
            throw error
        }
    }

    public func verify(
        archiveURL: URL,
        identityFileURL: URL,
        updateSidecar: Bool = true
    ) async throws -> VerifiedBackupArchive {
        let sidecarURL = Self.sidecarURL(for: archiveURL)
        let sidecarData = try Data(contentsOf: sidecarURL)
        var sidecar = try Self.decoder.decode(BackupSidecarV1.self, from: sidecarData)
        guard sidecar.formatVersion == 1,
              sidecar.manifestVersion == 1,
              try BackupCryptography.sha256(archiveURL) == sidecar.archiveSHA256
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup archive or sidecar checksum mismatch")
        }
        let workspace = try BackupFileSafety.temporaryWorkspace(near: archiveURL)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plaintext = workspace.appendingPathComponent("verified.tar")
        try BackupFileSafety.requireIdentityFile(identityFileURL)
        try await envelope.decrypt(ciphertext: archiveURL, identityFile: identityFileURL, plaintext: plaintext)
        try BackupFileSafety.protectFile(plaintext)
        let entries = try UStarArchive.read(from: plaintext)
        guard let manifestEntry = entries[Self.manifestArchivePath] else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup manifest is missing")
        }
        let manifestData = manifestEntry.data
        guard BackupCryptography.sha256(manifestData) == sidecar.manifestSHA256 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup manifest checksum mismatch")
        }
        let manifest = try Self.decoder.decode(BackupManifestV1.self, from: manifestData)
        guard manifest.formatVersion == 1,
              manifest.source == sidecar.source,
              manifest.recipientFingerprints.sorted() == sidecar.recipientFingerprints.sorted(),
              manifest.createdAt == sidecar.createdAt,
              manifest.toolVersion == sidecar.toolVersion,
              manifest.toolDigest == sidecar.toolDigest
        else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup manifest and sidecar disagree")
        }
        try Self.verifyEntries(entries, manifest: manifest, manifestData: manifestData)
        let verifierFingerprint = BackupCryptography.sha256(Data(
            "identity-verified-v1\u{0}\(sidecar.archiveSHA256)\u{0}\(sidecar.manifestSHA256)\u{0}\(toolDigest)".utf8
        ))
        sidecar.verification = BackupVerificationRecord(
            verifiedAt: Date(),
            verifierFingerprint: verifierFingerprint,
            maintenanceToolVersion: toolVersion,
            maintenanceToolDigest: toolDigest
        )
        if updateSidecar {
            try BackupFileSafety.writeAtomic(try Self.encoder.encode(sidecar), to: sidecarURL, mode: 0o600)
        }
        return VerifiedBackupArchive(manifest: manifest, sidecar: sidecar, plaintextEntries: entries.mapValues(\.data))
    }

    public func prepareRestore(_ request: BackupRestoreRequest) async throws -> BackupManifestV1 {
        let verified = try await verify(
            archiveURL: request.archiveURL,
            identityFileURL: request.identityFileURL
        )
        guard verified.manifest.namespaceKind == request.targetNamespaceKind else {
            throw ServiceAPIError(
                code: .namespacePurposeMismatch,
                message: "Cross-kind backup restore is not supported"
            )
        }
        guard verified.manifest.databaseIdentityDigest != request.targetDatabaseIdentityDigest else {
            throw ServiceAPIError(
                code: .namespacePurposeMismatch,
                message: "Restore target reuses the archived source database identity"
            )
        }
        for asset in verified.manifest.assets where asset.disposition != .included {
            let observed = request.observedExternalAssets[asset.logicalID]
            if asset.disposition == .externalRequired, observed != asset.sha256 {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "Required external restore dependency is missing or mismatched: \(asset.logicalID)"
                )
            }
            if let observed, observed != asset.sha256 {
                throw ServiceAPIError(
                    code: .dependencyUnavailable,
                    message: "External restore dependency checksum mismatch: \(asset.logicalID)"
                )
            }
        }

        let target = request.targetRootURL.standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            let children = try FileManager.default.contentsOfDirectory(atPath: target.path)
            guard children.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Restore target must be empty")
            }
        }
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        for asset in verified.manifest.assets where asset.disposition == .included {
            guard let data = verified.plaintextEntries[asset.archivePath] else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup asset is missing during restore")
            }
            let destination = try BackupFileSafety.safeDestination(root: staging, relativePath: asset.archivePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: destination, options: .withoutOverwriting)
            guard chmod(destination.path, mode_t(asset.mode)) == 0 else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to restore asset permissions")
            }
        }
        let restoreRequest = RestoreNamespaceRequestV1(
            schemaVersion: 1,
            acknowledged: true,
            sourceNamespaceKind: verified.manifest.namespaceKind,
            sourceDatabaseIdentityDigest: verified.manifest.databaseIdentityDigest,
            targetNamespaceKind: request.targetNamespaceKind,
            targetDatabaseIdentityDigest: request.targetDatabaseIdentityDigest,
            restoredFromStoreID: verified.manifest.source.storeID,
            backupSequence: verified.manifest.source.nextGlobalSequence,
            backupCreatedAt: Self.formatDate(verified.manifest.createdAt),
            backupManifestSHA256: verified.sidecar.manifestSHA256
        )
        try BackupFileSafety.writeAtomic(
            try Self.encoder.encode(restoreRequest),
            to: staging.appendingPathComponent("restore-request.json"),
            mode: 0o600
        )
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: staging, to: target)
        published = true
        try BackupFileSafety.syncDirectory(target.deletingLastPathComponent())
        return verified.manifest
    }

    public static func sidecarURL(for archiveURL: URL) -> URL {
        URL(fileURLWithPath: archiveURL.path + sidecarSuffix)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func recipientFingerprints(_ url: URL) throws -> [String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline).compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            let type = value.hasPrefix("age1pq1") ? "hybrid" : (value.hasPrefix("age1") ? "x25519" : "unsupported")
            guard type != "unsupported" else { return nil }
            return "\(type):\(BackupCryptography.sha256(Data(value.utf8)))"
        }
    }

    private struct Inventory {
        let entries: [BackupAssetManifestEntry]
        let data: [String: UStarEntry]
    }

    private static func inventory(
        _ roots: [BackupAssetRoot],
        externalAssets: [BackupExternalAsset]
    ) throws -> Inventory {
        guard !roots.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup asset inventory is empty")
        }
        var entries: [BackupAssetManifestEntry] = []
        var archiveData: [String: UStarEntry] = [:]
        for root in roots {
            let canonicalRoot = root.url.standardizedFileURL.resolvingSymlinksInPath()
            guard let enumerator = FileManager.default.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to inventory backup root: \(root.logicalID)")
            }
            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent.hasSuffix(".authority.lock")
                    || url.lastPathComponent.hasSuffix(".authority-owner.json")
                    || url.lastPathComponent.hasSuffix(".authority-purpose.json")
                    || url.lastPathComponent.hasSuffix("-wal")
                    || url.lastPathComponent.hasSuffix("-shm")
                {
                    continue
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let resolved = url.resolvingSymlinksInPath()
                    guard resolved.path == canonicalRoot.path || resolved.path.hasPrefix(canonicalRoot.path + "/") else {
                        throw ServiceAPIError(code: .invalidRequest, message: "Backup inventory contains an escaping symlink")
                    }
                    throw ServiceAPIError(code: .invalidRequest, message: "Backup format v1 does not archive symlink nodes")
                }
                guard values.isRegularFile == true else { continue }
                let canonicalFile = url.standardizedFileURL.resolvingSymlinksInPath()
                guard canonicalFile.path.hasPrefix(canonicalRoot.path + "/") else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Backup inventory path escapes its canonical root")
                }
                let relative = String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
                let archivePath = root.logicalID.isEmpty ? relative : root.logicalID + "/" + relative
                try BackupFileSafety.validateArchivePath(archivePath)
                guard archiveData[archivePath] == nil else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Duplicate backup archive path")
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let mode = UInt16(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600) & 0o777)
                entries.append(.init(
                    logicalID: root.logicalID,
                    archivePath: archivePath,
                    disposition: .included,
                    byteCount: Int64(data.count),
                    mode: mode,
                    sha256: BackupCryptography.sha256(data),
                    expectedVersion: nil
                ))
                archiveData[archivePath] = UStarEntry(data: data, mode: mode)
            }
        }
        for external in externalAssets {
            guard external.disposition != .included else {
                throw ServiceAPIError(code: .invalidRequest, message: "External assets cannot be classified as included")
            }
            entries.append(.init(
                logicalID: external.logicalID,
                archivePath: "external/\(external.logicalID)",
                disposition: external.disposition,
                byteCount: 0,
                mode: 0,
                sha256: external.expectedSHA256,
                expectedVersion: external.expectedVersion
            ))
        }
        return Inventory(entries: entries, data: archiveData)
    }

    private static func verifyEntries(
        _ entries: [String: UStarEntry],
        manifest: BackupManifestV1,
        manifestData: Data
    ) throws {
        guard entries[manifestArchivePath]?.data == manifestData else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup manifest entry changed during archive encoding")
        }
        let expectedIncluded = Set(manifest.assets.filter { $0.disposition == .included }.map(\.archivePath))
            .union([manifestArchivePath])
        guard Set(entries.keys) == expectedIncluded else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup archive contains missing or unmanifested entries")
        }
        for asset in manifest.assets where asset.disposition == .included {
            guard let entry = entries[asset.archivePath],
                  entry.data.count == asset.byteCount,
                  BackupCryptography.sha256(entry.data) == asset.sha256
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup asset checksum mismatch: \(asset.archivePath)")
            }
        }
    }
}

public struct RestoreNamespaceRequestV1: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let acknowledged: Bool
    public let sourceNamespaceKind: String
    public let sourceDatabaseIdentityDigest: String
    public let targetNamespaceKind: String
    public let targetDatabaseIdentityDigest: String
    public let restoredFromStoreID: UUID
    public let backupSequence: Int64
    public let backupCreatedAt: String
    public let backupManifestSHA256: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case acknowledged
        case sourceNamespaceKind
        case sourceDatabaseIdentityDigest
        case targetNamespaceKind
        case targetDatabaseIdentityDigest
        case restoredFromStoreID = "restoredFromStoreId"
        case backupSequence
        case backupCreatedAt
        case backupManifestSHA256 = "backupManifestSha256"
    }
}

private enum BackupCryptography {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ url: URL) throws -> String {
        sha256(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}

private enum BackupFileSafety {
    static func temporaryWorkspace(near url: URL) throws -> URL {
        let workspace = url.deletingLastPathComponent()
            .appendingPathComponent(".repoprompt-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return workspace
    }

    static func requireIdentityFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isSymbolicLink != true,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "age identity file must be a private regular file")
        }
    }

    static func protectFile(_ url: URL) throws {
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to protect backup temporary file")
        }
    }

    static func protectAndSync(_ url: URL) throws {
        try protectFile(url)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to open backup output") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to sync backup output") }
    }

    static func atomicPublish(_ temporary: URL, to destination: URL) throws {
        guard rename(temporary.path, destination.path) == 0 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to publish backup atomically")
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func writeAtomic(_ data: Data, to destination: URL, mode: UInt16) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            guard chmod(temporary.path, mode_t(mode)) == 0 else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to protect backup metadata")
            }
            try protectAndSync(temporary)
            try atomicPublish(temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to open backup parent directory") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to sync backup parent directory") }
    }

    static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count <= 255
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup archive path is unsafe")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup archive path traversal is forbidden")
        }
    }

    static func safeDestination(root: URL, relativePath: String) throws -> URL {
        try validateArchivePath(relativePath)
        let result = root.appendingPathComponent(relativePath).standardizedFileURL
        guard result.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Restore path escapes target")
        }
        return result
    }
}

private struct UStarEntry: Sendable {
    let data: Data
    let mode: UInt16
}

private enum UStarArchive {
    private static let blockSize = 512

    static func write(entries: [String: UStarEntry], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for path in entries.keys.sorted() {
            try BackupFileSafety.validateArchivePath(path)
            guard let entry = entries[path] else { continue }
            var header = Data(repeating: 0, count: blockSize)
            try writePath(path, header: &header)
            writeOctal(Int(entry.mode), width: 8, offset: 100, header: &header)
            writeOctal(0, width: 8, offset: 108, header: &header)
            writeOctal(0, width: 8, offset: 116, header: &header)
            writeOctal(entry.data.count, width: 12, offset: 124, header: &header)
            writeOctal(0, width: 12, offset: 136, header: &header)
            header.replaceSubrange(148 ..< 156, with: Data(repeating: 0x20, count: 8))
            header[156] = Character("0").asciiValue!
            header.replaceSubrange(257 ..< 263, with: Data("ustar\0".utf8))
            header.replaceSubrange(263 ..< 265, with: Data("00".utf8))
            let checksum = header.reduce(0) { $0 + Int($1) }
            let checksumText = String(format: "%06o\0 ", checksum)
            header.replaceSubrange(148 ..< 156, with: Data(checksumText.utf8))
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: entry.data)
            let padding = (blockSize - entry.data.count % blockSize) % blockSize
            if padding > 0 { try handle.write(contentsOf: Data(repeating: 0, count: padding)) }
        }
        try handle.write(contentsOf: Data(repeating: 0, count: blockSize * 2))
        try handle.synchronize()
    }

    static func read(from url: URL) throws -> [String: UStarEntry] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var offset = 0
        var entries: [String: UStarEntry] = [:]
        while offset + blockSize <= data.count {
            let header = Data(data[offset ..< offset + blockSize])
            if header.allSatisfy({ $0 == 0 }) { break }
            let storedChecksum = try parseOctal(header, range: 148 ..< 156)
            var checksumHeader = Data(header)
            checksumHeader.replaceSubrange(148 ..< 156, with: Data(repeating: 0x20, count: 8))
            guard checksumHeader.reduce(0, { $0 + Int($1) }) == storedChecksum,
                  header[156] == Character("0").asciiValue || header[156] == 0
            else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup tar header is invalid")
            }
            let name = string(header, range: 0 ..< 100)
            let prefix = string(header, range: 345 ..< 500)
            let path = prefix.isEmpty ? name : prefix + "/" + name
            try BackupFileSafety.validateArchivePath(path)
            guard entries[path] == nil else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup tar contains duplicate paths")
            }
            let size = try parseOctal(header, range: 124 ..< 136)
            let mode = try parseOctal(header, range: 100 ..< 108)
            offset += blockSize
            guard size >= 0, offset + size <= data.count else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup tar entry is truncated")
            }
            entries[path] = UStarEntry(data: Data(data[offset ..< offset + size]), mode: UInt16(mode & 0o777))
            offset += size
            offset += (blockSize - size % blockSize) % blockSize
        }
        return entries
    }

    private static func writePath(_ path: String, header: inout Data) throws {
        let bytes = Array(path.utf8)
        if bytes.count <= 100 {
            header.replaceSubrange(0 ..< bytes.count, with: bytes)
            return
        }
        guard let slash = path.indices.reversed().first(where: { path[$0] == "/" }) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup path exceeds ustar limits")
        }
        let prefix = String(path[..<slash])
        let name = String(path[path.index(after: slash)...])
        guard prefix.utf8.count <= 155, name.utf8.count <= 100 else {
            throw ServiceAPIError(code: .invalidRequest, message: "Backup path exceeds ustar limits")
        }
        header.replaceSubrange(0 ..< name.utf8.count, with: name.utf8)
        header.replaceSubrange(345 ..< 345 + prefix.utf8.count, with: prefix.utf8)
    }

    private static func writeOctal(_ value: Int, width: Int, offset: Int, header: inout Data) {
        let text = String(format: "%0*o\0", width - 1, value)
        header.replaceSubrange(offset ..< offset + width, with: Data(text.utf8))
    }

    private static func parseOctal(_ data: Data, range: Range<Int>) throws -> Int {
        let value = string(data, range: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(value, radix: 8) else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Backup tar numeric field is invalid")
        }
        return parsed
    }

    private static func string(_ data: Data, range: Range<Int>) -> String {
        let bytes = data[range].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
