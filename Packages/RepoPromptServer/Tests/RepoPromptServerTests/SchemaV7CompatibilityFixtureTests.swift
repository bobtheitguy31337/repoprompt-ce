import Foundation
import XCTest
@testable import RepoPromptServicePersistence

final class SchemaV7CompatibilityFixtureTests: XCTestCase {
    func testEveryFrozenV6DigestPreservesLedgerAndRecordsExactNormalization() async throws {
        for digest in StoreMigrationTestSupport.knownV6Digests {
            let root = try StoreMigrationTestSupport.temporaryDirectory(digest)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
            try await StoreMigrationTestSupport.makeV6Store(at: databaseURL, digest: digest)
            let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
            let projectID = UUID()
            let legacyJSON = #"{"goblinUserId":"u1","selection":"goblin-explicit-selection"}"#
            _ = try await store.database.query(
                "INSERT INTO projects(project_id,schema_version,name,creator_json,lifecycle_state,revision,snapshot_json,created_at,updated_at) VALUES(?,1,'goblinUserId',?,'active',1,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)",
                [.text(projectID.uuidString), .text(legacyJSON), .text(legacyJSON)]
            )
            let legacySessionID = UUID().uuidString
            if digest != SchemaV6.digest {
                _ = try await store.database.query(
                    "INSERT INTO sessions(session_id,project_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at) VALUES(?,?,?,1,'fixture','active','fake','private',0,0,1,'{}',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)",
                    [.text(legacySessionID), .text(projectID.uuidString), .text(legacySessionID)]
                )
                _ = try await store.database.query(
                    "INSERT INTO collaboration_metadata(session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json,goblin_acknowledgement_json,updated_at) VALUES(?,1,'private',0,'fixture',1,1,1,NULL,'{\"accepted\":true}',CURRENT_TIMESTAMP)",
                    [.text(legacySessionID)]
                )
            }
            let source = try await store.migrationSourceEvidence()
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
            let preserved = try await store.database.query("SELECT digest FROM schema_migrations WHERE version=6").first?.column("digest")?.string
            XCTAssertEqual(preserved, digest)
            let audit = try await store.database.query(
                "SELECT observed_digest,normalization_id,schema_shape_digest FROM schema_compatibility_audit"
            ).first
            XCTAssertEqual(audit?.column("observed_digest")?.string, digest)
            XCTAssertEqual(audit?.column("normalization_id")?.string, SchemaV7.normalizationID(for: digest))
            XCTAssertEqual(audit?.column("schema_shape_digest")?.string, SchemaV7.finalV6ShapeDigest)
            let normalizedProject = try await store.database.query(
                "SELECT name,creator_json,snapshot_json FROM projects WHERE project_id=?",
                [.text(projectID.uuidString)]
            ).first
            XCTAssertEqual(normalizedProject?.column("name")?.string, "goblinUserId")
            if digest == SchemaV6.digest {
                XCTAssertEqual(normalizedProject?.column("creator_json")?.string, legacyJSON)
                XCTAssertEqual(normalizedProject?.column("snapshot_json")?.string, legacyJSON)
            } else {
                XCTAssertEqual(
                    normalizedProject?.column("creator_json")?.string,
                    #"{"userId":"u1","selection":"explicit-selection"}"#
                )
                XCTAssertEqual(
                    normalizedProject?.column("snapshot_json")?.string,
                    #"{"userId":"u1","selection":"explicit-selection"}"#
                )
            }
            if digest != SchemaV6.digest {
                let collaboration = try await store.database.query(
                    "SELECT collaboration_acknowledgement_json FROM collaboration_metadata WHERE session_id=?",
                    [.text(legacySessionID)]
                ).first
                XCTAssertEqual(
                    collaboration?.column("collaboration_acknowledgement_json")?.string,
                    "{\"accepted\":true}"
                )
                let columns = Set(try await store.database.query("PRAGMA table_info(collaboration_metadata)")
                    .compactMap { $0.column("name")?.string })
                XCTAssertFalse(columns.contains("goblin_acknowledgement_json"))
            }
            let metadata = try await store.metadata()
            XCTAssertEqual(metadata.schemaVersion, 7)
            try await store.close(clean: false)
        }
    }

    func testV7OwnsOnlyTwoNewTables() {
        XCTAssertEqual(
            Set(SchemaV7.normalizationPlans.keys),
            SchemaV7.knownPrototypeV6Digests.union([SchemaV6.legacyCanonicalDigest, SchemaV6.canonicalDigest])
        )
        XCTAssertEqual(SchemaV7.knownPrototypeV6Digests.count, 7)
        XCTAssertEqual(SchemaV7.statements.count, 2)
        XCTAssertTrue(SchemaV7.statements[0].contains("schema_compatibility_audit"))
        XCTAssertTrue(SchemaV7.statements[1].contains("authority_namespace_identity"))
        XCTAssertFalse(SchemaV7.statements.joined().contains("outbox"))
        XCTAssertFalse(SchemaV7.statements.joined().contains("rate_limit"))
        XCTAssertFalse(SchemaV7.statements.joined().contains("backup_receipt"))
    }
}
