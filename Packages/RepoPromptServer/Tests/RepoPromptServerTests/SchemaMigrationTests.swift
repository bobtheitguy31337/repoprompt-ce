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
    func testV7StatementAndLedgerFaultsRollBackAndReopenAtV6() async throws {
        for injectedPoint in [
            PersistenceFaultPoint.afterMigrationStatement,
            .beforeMigrationLedgerInsert,
            .afterMigrationLedgerInsert,
        ] {
            let root = try StoreMigrationTestSupport.temporaryDirectory(injectedPoint.rawValue)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
            try await StoreMigrationTestSupport.makeV6Store(at: databaseURL)
            var store = try await SQLiteServiceStore.openForMaintenance(
                storage: .file(databaseURL.path),
                faultInjector: PersistenceFaultInjector { point in
                    if point == injectedPoint { throw InjectedMigrationFailure() }
                }
            )
            let source = try await store.migrationSourceEvidence()
            do {
                _ = try await store.migrateToLatest(
                    verifiedBackup: VerifiedMigrationBackup(
                        source: source,
                        archiveSHA256: String(repeating: "a", count: 64),
                        manifestSHA256: String(repeating: "b", count: 64),
                        verifierFingerprint: String(repeating: "c", count: 64)
                    ),
                    namespaceKind: "server",
                    databaseIdentityDigest: String(repeating: "d", count: 64)
                )
                XCTFail("Expected injected migration failure at \(injectedPoint.rawValue)")
            } catch is InjectedMigrationFailure {}
            let metadata = try await store.metadata()
            XCTAssertEqual(metadata.schemaVersion, 6)
            let database = await store.database
            let v7Ledger = try await database.query("SELECT version FROM schema_migrations WHERE version=7").first
            XCTAssertNil(v7Ledger)
            let v7Tables = try await database.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schema_compatibility_audit','authority_namespace_identity')"
            )
            XCTAssertTrue(v7Tables.isEmpty)
            try await store.close(clean: false)

            store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
            let reopenedMetadata = try await store.metadata()
            XCTAssertEqual(reopenedMetadata.schemaVersion, 6)
            try await store.close(clean: false)
        }
    }
}

private struct InjectedMigrationFailure: Error {}
