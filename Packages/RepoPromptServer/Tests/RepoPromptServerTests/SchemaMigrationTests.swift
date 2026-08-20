import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO
import XCTest
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

final class SchemaMigrationTests: XCTestCase {
    func testForwardVersionFailsWithoutMutation() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        _ = try await store.database.query("UPDATE service_metadata SET schema_version=8 WHERE fixed_id=1")
        try await store.close(clean: false)
        let before = try Data(contentsOf: databaseURL)
        do {
            _ = try await SQLiteServiceStore.openForServing(storage: .file(databaseURL.path))
            XCTFail("Expected forward schema refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .forwardSchemaUnsupported)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    }

    func testUnknownV6DigestFailsBeforeMigration() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL, digest: "unknown-v6")
        do {
            _ = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
            XCTFail("Expected digest refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
            XCTAssertTrue(error.message.contains("digest"))
        }
    }

    func testStampedNamespaceKindMismatchIsRefused() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try StoreMigrationTestSupport.namespace(root: root)
        let store = try await SQLiteServiceStore.openForServing(
            storage: .file(namespace.databasePath),
            namespaceKind: "server",
            databaseIdentityDigest: namespace.namespaceID
        )
        try await store.close()
        do {
            _ = try await SQLiteServiceStore.openForServing(
                storage: .file(namespace.databasePath),
                namespaceKind: "directHeadless",
                databaseIdentityDigest: namespace.namespaceID
            )
            XCTFail("Expected namespace kind refusal")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }
    }

    func testBusyMigrationIsRetryableAndPreservesV6() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
        let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let source = try await store.migrationSourceEvidence()
        let blocker = try await SQLiteConnection.open(storage: .file(path: databaseURL.path))
        _ = try await blocker.query("PRAGMA busy_timeout=100")
        _ = try await blocker.query("BEGIN IMMEDIATE")
        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: .init(
                    source: source,
                    archiveSHA256: String(repeating: "a", count: 64),
                    manifestSHA256: String(repeating: "b", count: 64),
                    verifierFingerprint: String(repeating: "c", count: 64)
                ),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            XCTFail("Expected busy migration failure")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .persistenceUnavailable)
            XCTAssertTrue(error.retryable)
        }
        _ = try await blocker.query("ROLLBACK")
        try await blocker.close()
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        let v7Tables = try await store.database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schema_compatibility_audit','authority_namespace_identity')"
        )
        XCTAssertTrue(v7Tables.isEmpty)
        try await store.close(clean: false)
    }

    func testRestoreRequestCannotBypassIdentityWithoutExplicitActivationStartup() async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        let sourceDigest = String(repeating: "1", count: 64)
        let targetDigest = String(repeating: "2", count: 64)
        let source = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: sourceDigest
        )
        try await source.close(clean: false)
        try Data("{}".utf8).write(to: root.appendingPathComponent("restore-request.json"))

        do {
            _ = try await SQLiteServiceStore.openForServing(
                storage: .file(databaseURL.path),
                namespaceKind: "server",
                databaseIdentityDigest: targetDigest
            )
            XCTFail("Ordinary startup accepted a pending restore identity rebind")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .namespacePurposeMismatch)
        }

        let activationOpen = try await SQLiteServiceStore.openForServing(
            storage: .file(databaseURL.path),
            namespaceKind: "server",
            databaseIdentityDigest: targetDigest,
            allowPendingRestoreRebind: true
        )
        try await activationOpen.close(clean: false)
    }
}

final class SQLiteTransactionFaultInjectionTests: XCTestCase {
    func testEveryV7StatementInterruptionAndCancellationBoundaryPreservesBytesAndLedger() async throws {
        let statementCount = try await countHistoricalV7StatementBoundaries()
        XCTAssertGreaterThan(statementCount, SchemaV6.statements.count)
        let boundaries = [(PersistenceFaultPoint.afterTransactionBegin, 1)]
            + (1 ... statementCount).map { (PersistenceFaultPoint.afterMigrationStatement, $0) }
            + [
                (PersistenceFaultPoint.beforeMigrationLedgerInsert, 1),
                (PersistenceFaultPoint.afterMigrationLedgerInsert, 1),
                (PersistenceFaultPoint.beforeTransactionCommit, 1),
            ]

        for cancellation in [false, true] {
            for (point, occurrence) in boundaries {
                try await assertFailedMigrationPreservesV6(
                    point: point,
                    occurrence: occurrence,
                    cancellation: cancellation
                )
            }
        }
    }

    private func countHistoricalV7StatementBoundaries() async throws -> Int {
        let root = try StoreMigrationTestSupport.temporaryDirectory("count-v7-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(
            at: databaseURL,
            digest: StoreMigrationTestSupport.knownV6Digests[4]
        )
        let counter = MigrationFaultCounter(target: nil, occurrence: 0, cancellation: false)
        let store = try await SQLiteServiceStore.openForMaintenance(
            storage: .file(databaseURL.path),
            faultInjector: PersistenceFaultInjector { point in try counter.hit(point) }
        )
        let source = try await store.migrationSourceEvidence()
        _ = try await store.migrateToLatest(
            verifiedBackup: verifiedBackup(source),
            namespaceKind: "server",
            databaseIdentityDigest: String(repeating: "d", count: 64)
        )
        let count = counter.count(for: .afterMigrationStatement)
        try await store.close(clean: false)
        return count
    }

    private func assertFailedMigrationPreservesV6(
        point: PersistenceFaultPoint,
        occurrence: Int,
        cancellation: Bool
    ) async throws {
        let root = try StoreMigrationTestSupport.temporaryDirectory("\(point.rawValue)-\(occurrence)-\(cancellation)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
        try await StoreMigrationTestSupport.makeV6Store(
            at: databaseURL,
            digest: StoreMigrationTestSupport.knownV6Digests[4]
        )
        let counter = MigrationFaultCounter(target: point, occurrence: occurrence, cancellation: cancellation)
        var store = try await SQLiteServiceStore.openForMaintenance(
            storage: .file(databaseURL.path),
            faultInjector: PersistenceFaultInjector { hit in try counter.hit(hit) }
        )
        let source = try await store.migrationSourceEvidence()
        let database = await store.database
        let ledgerBefore = try await ledgerEvidence(database)
        let bytesBefore = try Data(contentsOf: databaseURL)

        do {
            _ = try await store.migrateToLatest(
                verifiedBackup: verifiedBackup(source),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            XCTFail("expected fault at \(point.rawValue)#\(occurrence)")
        } catch is InjectedMigrationFailure {
            XCTAssertFalse(cancellation)
        } catch is CancellationError {
            XCTAssertTrue(cancellation)
        }

        let bytesAfter = try Data(contentsOf: databaseURL)
        let ledgerAfter = try await ledgerEvidence(database)
        let metadataAfter = try await store.metadata()
        let v7Ledger = try await database.query("SELECT version FROM schema_migrations WHERE version=7").first
        let v7Tables = try await database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schema_compatibility_audit','authority_namespace_identity')"
        )
        XCTAssertEqual(bytesAfter, bytesBefore)
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        XCTAssertEqual(metadataAfter.schemaVersion, 6)
        XCTAssertNil(v7Ledger)
        XCTAssertTrue(v7Tables.isEmpty)
        try await store.close(clean: false)

        store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
        let reopenedMetadata = try await store.metadata()
        let reopenedDatabase = await store.database
        let reopenedLedger = try await ledgerEvidence(reopenedDatabase)
        XCTAssertEqual(reopenedMetadata.schemaVersion, 6)
        XCTAssertEqual(reopenedLedger, ledgerBefore)
        try await store.close(clean: false)
    }

    private func ledgerEvidence(_ database: SQLiteDatabaseExecutor) async throws -> [String] {
        try await database.query("SELECT version,digest FROM schema_migrations ORDER BY version").map {
            "\($0.column("version")?.integer ?? -1):\($0.column("digest")?.string ?? "")"
        }
    }

    private func verifiedBackup(_ source: MigrationSourceEvidence) -> VerifiedMigrationBackup {
        VerifiedMigrationBackup(
            source: source,
            archiveSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            verifierFingerprint: String(repeating: "c", count: 64)
        )
    }

    func testCanonicalMigrationDigestsMatchCheckedInPrograms() {
        let migrations: [(version: Int, frozen: String, computed: String)] = [
            (SchemaV1.version, SchemaV1.canonicalDigest, SchemaV1.definition.computedDigest),
            (SchemaV2.version, SchemaV2.canonicalDigest, SchemaV2.definition.computedDigest),
            (SchemaV3.version, SchemaV3.canonicalDigest, SchemaV3.definition.computedDigest),
            (SchemaV4.version, SchemaV4.canonicalDigest, SchemaV4.definition.computedDigest),
            (SchemaV5.version, SchemaV5.canonicalDigest, SchemaV5.definition.computedDigest),
            (SchemaV6.version, SchemaV6.canonicalDigest, SchemaV6.definition.computedDigest),
            (SchemaV7.version, SchemaV7.canonicalDigest, SchemaV7.definition.computedDigest),
        ]
        XCTAssertEqual(migrations.map(\.version), Array(1 ... 7))
        for migration in migrations {
            XCTAssertEqual(
                migration.computed,
                migration.frozen,
                "migration V\(migration.version) is immutable; append a new version instead of changing its program"
            )
        }
    }
}

private struct InjectedMigrationFailure: Error {}

private final class MigrationFaultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let target: PersistenceFaultPoint?
    private let occurrence: Int
    private let cancellation: Bool
    private var counts: [String: Int] = [:]

    init(target: PersistenceFaultPoint?, occurrence: Int, cancellation: Bool) {
        self.target = target
        self.occurrence = occurrence
        self.cancellation = cancellation
    }

    func hit(_ point: PersistenceFaultPoint) throws {
        lock.lock()
        let count = counts[point.rawValue, default: 0] + 1
        counts[point.rawValue] = count
        let shouldFail = point == target && count == occurrence
        lock.unlock()
        if shouldFail {
            if cancellation { throw CancellationError() }
            throw InjectedMigrationFailure()
        }
    }

    func count(for point: PersistenceFaultPoint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[point.rawValue, default: 0]
    }
}
