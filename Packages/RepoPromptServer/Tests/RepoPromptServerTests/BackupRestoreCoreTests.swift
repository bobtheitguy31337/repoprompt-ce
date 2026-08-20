import Foundation
import RepoPromptRuntimeModel
import XCTest
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

final class BackupRestoreCoreTests: XCTestCase {
    func testCreateVerifyAndSameKindRestorePreserveCompleteManifest() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let databaseURL = state.appendingPathComponent("repoprompt.sqlite")
        try Data("hidden durable material".utf8).write(
            to: state.appendingPathComponent(".event-signing-material")
        )
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        let service = StoreMigrationTestSupport.backupService()
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "failed-verify-recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "failed-verify-identity-\(UUID().uuidString).txt"
        )
        let archive = root.appendingPathComponent("backup.tar.age")
        let sourceDigest = String(repeating: "1", count: 64)
        let sidecar = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: state)],
                namespaceKind: "server",
                databaseIdentityDigest: sourceDigest
            ),
            store: store
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertNil(sidecar.verification)

        let verified = try await service.verify(archiveURL: archive, identityFileURL: identity)
        let currentEvidence = try await store.migrationSourceEvidence()
        XCTAssertEqual(verified.manifest.source, currentEvidence)
        XCTAssertEqual(
            verified.manifest.assets.filter { $0.disposition == .included }.map(\.archivePath),
            [".event-signing-material", "repoprompt.sqlite"]
        )
        XCTAssertNotNil(verified.sidecar.verification)

        let target = root.appendingPathComponent("restored", isDirectory: true)
        let targetDigest = String(repeating: "2", count: 64)
        _ = try await service.prepareRestore(
            .init(
                archiveURL: archive,
                identityFileURL: identity,
                targetRootURL: target,
                targetNamespaceKind: "server",
                targetDatabaseIdentityDigest: targetDigest
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("repoprompt.sqlite")),
            try Data(contentsOf: databaseURL)
        )
        let request = try JSONDecoder().decode(
            RestoreNamespaceRequestV1.self,
            from: Data(contentsOf: target.appendingPathComponent("restore-request.json"))
        )
        XCTAssertEqual(request.sourceDatabaseIdentityDigest, sourceDigest)
        XCTAssertEqual(request.targetDatabaseIdentityDigest, targetDigest)
        XCTAssertEqual(request.sourceNamespaceKind, request.targetNamespaceKind)
        try await store.close(clean: false)
    }

    func testFailedEncryptLeavesNoArchiveOrSidecar() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]
        )
        let archive = root.deletingLastPathComponent().appendingPathComponent("failed-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService(
            envelope: FailingBackupEnvelope(failEncrypt: true)
        )
        do {
            _ = try await service.create(
                request: .init(
                    outputURL: archive,
                    recipientsFileURL: recipients,
                    roots: [.init(logicalID: "", url: root)],
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "1", count: 64)
                ),
                store: store
            )
            XCTFail("Expected encryption failure")
        } catch is FailingBackupEnvelope.Failure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackupRestoreService.sidecarURL(for: archive).path))
        try await store.close(clean: false)
    }

    func testBackupRefusesInventoryWithoutCheckpointedDatabase() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not the database".utf8).write(to: unrelated.appendingPathComponent("asset"))
        let store = try await SQLiteServiceStore.open(
            storage: .file(state.appendingPathComponent("repoprompt.sqlite").path)
        )
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]
        )
        let archive = root.appendingPathComponent("incomplete.tar.age")
        do {
            _ = try await StoreMigrationTestSupport.backupService().create(
                request: .init(
                    outputURL: archive,
                    recipientsFileURL: recipients,
                    roots: [.init(logicalID: "", url: unrelated)],
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "1", count: 64)
                ),
                store: store
            )
            XCTFail("Expected incomplete durable inventory refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        try await store.close(clean: false)
    }

    func testCorruptArchiveAndCrossKindRestoreAreRefusedWithoutTargetMutation() async throws {
        let fixture = try await makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var bytes = try Data(contentsOf: fixture.archive)
        bytes[0] ^= 0xff
        try bytes.write(to: fixture.archive)
        do {
            _ = try await fixture.service.verify(archiveURL: fixture.archive, identityFileURL: fixture.identity)
            XCTFail("Expected checksum refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
        }

        // Recreate a valid archive, then prove kind refusal occurs before the
        // empty target is created or populated.
        try? FileManager.default.removeItem(at: fixture.archive)
        try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: fixture.archive))
        _ = try await fixture.service.create(request: fixture.request, store: fixture.store)
        let target = fixture.root.appendingPathComponent("wrong-kind")
        do {
            _ = try await fixture.service.prepareRestore(
                .init(
                    archiveURL: fixture.archive,
                    identityFileURL: fixture.identity,
                    targetRootURL: target,
                    targetNamespaceKind: "directHeadless",
                    targetDatabaseIdentityDigest: String(repeating: "2", count: 64)
                )
            )
            XCTFail("Expected cross-kind refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try await fixture.store.close(clean: false)
    }

    func testVerifiedBackupGatesLeaseBoundV6Migration() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try StoreMigrationTestSupport.namespace(root: root)
        try await StoreMigrationTestSupport.makeV6Store(at: URL(fileURLWithPath: namespace.databasePath))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "identity-\(UUID().uuidString).txt"
        )
        defer {
            try? FileManager.default.removeItem(at: recipients)
            try? FileManager.default.removeItem(at: identity)
        }
        let archive = root.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService()
        let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
        _ = try await session.createBackup(
            service: service,
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: root)],
                namespaceKind: "server",
                databaseIdentityDigest: namespace.namespaceID
            )
        )
        let migrated = try await session.migrate(
            service: service,
            verifiedBackup: archive,
            identityFileURL: identity
        )
        XCTAssertEqual(migrated.schemaVersion, 7)
        let observation = await session.observation()
        XCTAssertTrue(observation.phases.contains(.migrating))
        try await session.close(clean: true)
    }

    func testFailedIdentityVerificationLeavesPendingStoreUntouched() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "source-mismatch-recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "source-mismatch-identity-\(UUID().uuidString).txt"
        )
        let archive = root.deletingLastPathComponent()
            .appendingPathComponent("failed-verify-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: recipients)
            try? FileManager.default.removeItem(at: identity)
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService(
            envelope: FailingBackupEnvelope(failEncrypt: false)
        )
        _ = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: root)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        do {
            _ = try await service.verify(archiveURL: archive, identityFileURL: identity)
            XCTFail("Expected identity-backed decrypt failure")
        } catch is FailingBackupEnvelope.Failure {}
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        try await store.close(clean: false)
    }

    func testMigrationRechecksVerifiedSourceAndPreservesChangedV6Store() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root.deletingLastPathComponent(),
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"],
            name: "source-mismatch-recipients-\(UUID().uuidString).txt"
        )
        let identity = try StoreMigrationTestSupport.identityFile(
            in: root.deletingLastPathComponent(),
            name: "source-mismatch-identity-\(UUID().uuidString).txt"
        )
        let archive = root.deletingLastPathComponent()
            .appendingPathComponent("source-mismatch-\(UUID().uuidString).tar.age")
        defer {
            try? FileManager.default.removeItem(at: recipients)
            try? FileManager.default.removeItem(at: identity)
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: BackupRestoreService.sidecarURL(for: archive))
        }
        let service = StoreMigrationTestSupport.backupService()
        _ = try await service.create(
            request: .init(
                outputURL: archive,
                recipientsFileURL: recipients,
                roots: [.init(logicalID: "", url: root)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        let verified = try await service.verify(archiveURL: archive, identityFileURL: identity)
        _ = try await store.database.query(
            "UPDATE service_metadata SET next_global_sequence=next_global_sequence+1 WHERE fixed_id=1"
        )
        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: verified.migrationEvidence,
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            )
            XCTFail("Expected source-evidence mismatch")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
        }
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        XCTAssertEqual(metadata.nextGlobalSequence, 2)
        try await store.close(clean: false)
    }

    func testRestoreIdentityRebindRollsBackBeforeCommitAndReplaysAfterCommit() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let injector = PersistenceFaultInjector { point in
            if point == .beforeTransactionCommit { throw InjectedRestoreFailure() }
        }
        var store = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            faultInjector: injector,
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        let prior = try await store.metadata().storeID
        do {
            _ = try await store.activateRestoredNamespace(
                from: prior,
                backupSequence: 0,
                manifestDigest: String(repeating: "a", count: 64),
                sourceNamespaceKind: "server",
                sourceDatabaseIdentityDigest: sourceDigest,
                targetNamespaceKind: "server",
                targetDatabaseIdentityDigest: targetDigest,
                activationToken: Data(repeating: 7, count: 32),
                instanceID: UUID()
            )
            XCTFail("Expected interruption before restore commit")
        } catch is InjectedRestoreFailure {}
        let rolledBackMetadata = try await store.metadata()
        XCTAssertEqual(rolledBackMetadata.storeID, prior)
        let rolledBackIdentity = try await store.database.query(
            "SELECT database_identity_digest FROM authority_namespace_identity WHERE fixed_id=1"
        ).first?.column("database_identity_digest")?.string
        XCTAssertEqual(rolledBackIdentity, sourceDigest)
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        let fresh = try await store.activateRestoredNamespace(
            from: prior,
            backupSequence: 0,
            manifestDigest: String(repeating: "a", count: 64),
            sourceNamespaceKind: "server",
            sourceDatabaseIdentityDigest: sourceDigest,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest,
            activationToken: Data(repeating: 7, count: 32),
            instanceID: UUID()
        )
        let replayed = try await store.activateRestoredNamespace(
            from: prior,
            backupSequence: 0,
            manifestDigest: String(repeating: "a", count: 64),
            sourceNamespaceKind: "server",
            sourceDatabaseIdentityDigest: sourceDigest,
            targetNamespaceKind: "server",
            targetDatabaseIdentityDigest: targetDigest,
            activationToken: Data(repeating: 7, count: 32),
            instanceID: UUID()
        )
        XCTAssertNotEqual(fresh, prior)
        XCTAssertEqual(replayed, fresh)
        try await store.close(clean: false)
    }

    private func makeBackupFixture() async throws -> (
        root: URL,
        archive: URL,
        identity: URL,
        service: BackupRestoreService,
        store: SQLiteServiceStore,
        request: BackupCreateRequest
    ) {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .file(state.appendingPathComponent("repoprompt.sqlite").path))
        let recipients = try StoreMigrationTestSupport.recipientsFile(
            in: root,
            values: ["age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"]
        )
        let identity = try StoreMigrationTestSupport.identityFile(in: root)
        let archive = root.appendingPathComponent("backup.tar.age")
        let service = StoreMigrationTestSupport.backupService()
        let request = BackupCreateRequest(
            outputURL: archive,
            recipientsFileURL: recipients,
            roots: [.init(logicalID: "", url: state)],
            namespaceKind: "server",
            databaseIdentityDigest: String(repeating: "1", count: 64)
        )
        _ = try await service.create(request: request, store: store)
        return (root, archive, identity, service, store, request)
    }
}

final class BackupRecipientRotationTests: XCTestCase {
    func testRotationIsAdditiveAndProducesNewRecipientFingerprintSet() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .file(state.appendingPathComponent("repoprompt.sqlite").path))
        let old = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
        let new = "age1pppppppppppppppppppppppppppppppppppppppppppppppppppp"
        let firstRecipients = try StoreMigrationTestSupport.recipientsFile(in: root, values: [old], name: "old.txt")
        let rotatedRecipients = try StoreMigrationTestSupport.recipientsFile(in: root, values: [old, new], name: "rotated.txt")
        let service = StoreMigrationTestSupport.backupService()
        let firstArchive = root.appendingPathComponent("first.tar.age")
        let rotatedArchive = root.appendingPathComponent("rotated.tar.age")
        let first = try await service.create(
            request: .init(
                outputURL: firstArchive,
                recipientsFileURL: firstRecipients,
                roots: [.init(logicalID: "", url: state)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        let rotated = try await service.create(
            request: .init(
                outputURL: rotatedArchive,
                recipientsFileURL: rotatedRecipients,
                roots: [.init(logicalID: "", url: state)],
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "1", count: 64)
            ),
            store: store
        )
        XCTAssertEqual(first.recipientFingerprints.count, 1)
        XCTAssertEqual(rotated.recipientFingerprints.count, 2)
        XCTAssertTrue(Set(first.recipientFingerprints).isSubset(of: Set(rotated.recipientFingerprints)))
        try await store.close(clean: false)
    }
}

private struct InjectedRestoreFailure: Error {}
