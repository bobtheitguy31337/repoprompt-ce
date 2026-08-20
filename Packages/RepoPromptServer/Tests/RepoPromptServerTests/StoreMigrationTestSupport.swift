import Crypto
import Foundation
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

enum StoreMigrationTestSupport {
    static let knownV6Digests = [
        "repoprompt-service-schema-v6-typed-mcp-show-model-presets",
        "repoprompt-service-schema-v6-typed-mcp-disabled-tools",
        "repoprompt-service-schema-v6-typed-workspace-approvals",
        "repoprompt-service-schema-v6-typed-direct-agent-permissions",
        "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit",
        "repoprompt-service-schema-v6-agent-composer-semantic-acceptance",
        "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance",
    ]

    static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-pr4-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Constructs a genuine historical V6 database from the immutable V1–V5
    /// programs and the DDL that belonged to the selected prototype label. It
    /// deliberately never opens a V7 store and relabels it as history.
    static func makeV6Store(at databaseURL: URL, digest: String = knownV6Digests[0]) async throws {
        guard knownV6Digests.contains(digest) else {
            // Unknown-digest refusal tests still need a structurally authentic
            // V6 store; use the oldest DDL shape while preserving the bad label.
            return try await makeV6Store(at: databaseURL, ledgerDigest: digest, fixtureDigest: knownV6Digests[4])
        }
        try await makeV6Store(at: databaseURL, ledgerDigest: digest, fixtureDigest: digest)
    }

    private static func makeV6Store(
        at databaseURL: URL,
        ledgerDigest: String,
        fixtureDigest: String
    ) async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .file(path: databaseURL.path))
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        do {
            try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
                for statement in SchemaV1.statements + SchemaV1.operatorStatements {
                    _ = try await database.query(statement)
                }
                for legacyColumn in SchemaV1.legacyColumns {
                    let columns = Set(try await database.query("PRAGMA table_info(\(legacyColumn.table))")
                        .compactMap { $0.column("name")?.string })
                    if !columns.contains(legacyColumn.column) {
                        _ = try await database.query(
                            "ALTER TABLE \(legacyColumn.table) ADD COLUMN \(legacyColumn.column) \(legacyColumn.definition)"
                        )
                    }
                }
                _ = try await database.query(
                    "INSERT INTO service_metadata(fixed_id,store_id,schema_version,created_at,last_clean_shutdown,current_boot_epoch,next_global_sequence,replay_floor) VALUES(1,?,1,CURRENT_TIMESTAMP,0,1,1,0)",
                    [.text(UUID().uuidString)]
                )
                try await insertLedger(database, version: 1, digest: SchemaV1.digest)

                for (version, statements, digest) in [
                    (2, SchemaV2.statements + SchemaV2.dataStatements, SchemaV2.digest),
                    (3, SchemaV3.statements, SchemaV3.digest),
                    (4, SchemaV4.statements, SchemaV4.digest),
                    (5, SchemaV5.statements, SchemaV5.digest),
                ] {
                    for statement in statements { _ = try await database.query(statement) }
                    _ = try await database.query(
                        "UPDATE service_metadata SET schema_version=? WHERE fixed_id=1",
                        [.integer(version)]
                    )
                    try await insertLedger(database, version: version, digest: digest)
                }

                for statement in historicalV6Statements(for: fixtureDigest) {
                    _ = try await database.query(statement)
                }
                if fixtureDigest != knownV6Digests[0] {
                    // Earlier prototype stores used the Goblin-era acknowledgement
                    // column. Keeping both source and destination permits explicit
                    // copy-if-nil and source-column removal evidence during V7.
                    _ = try await database.query(
                        "ALTER TABLE collaboration_metadata ADD COLUMN goblin_acknowledgement_json TEXT"
                    )
                }
                _ = try await database.query("UPDATE service_metadata SET schema_version=6 WHERE fixed_id=1")
                try await insertLedger(database, version: 6, digest: ledgerDigest)
            }
            try await database.commitTransaction(transactionID)
        } catch {
            await database.rollbackTransaction(transactionID)
            try? await database.close()
            throw error
        }
        try await database.close()
    }

    private static func insertLedger(
        _ database: SQLiteDatabaseExecutor,
        version: Int,
        digest: String
    ) async throws {
        _ = try await database.query(
            "INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES(?,?,?,?,CURRENT_TIMESTAMP)",
            [.text("v\(version)"), .integer(version), .text("historical fixture v\(version)"), .text(digest)]
        )
    }

    private static func historicalV6Statements(for digest: String) -> [String] {
        let typedBase = Array(SchemaV6.statements[0 ... 1]) + Array(SchemaV6.statements[6 ... 17])
        let composer = Array(SchemaV6.statements[18...])
        switch digest {
        case knownV6Digests[0]:
            return SchemaV6.statements
        case knownV6Digests[1]:
            return SchemaV6.statements.filter { !$0.contains("mcp_show_model_presets") }
        case knownV6Digests[2]:
            return SchemaV6.statements.filter {
                !$0.contains("mcp_disabled_tools") && !$0.contains("mcp_show_model_presets")
            }
        case knownV6Digests[3]:
            return SchemaV6.statements.filter {
                !$0.contains("workspace_approval_settings")
                    && !$0.contains("mcp_disabled_tools")
                    && !$0.contains("mcp_show_model_presets")
            }
        case knownV6Digests[4]:
            return typedBase
        case knownV6Digests[5]:
            return composer
        case knownV6Digests[6]:
            return typedBase + composer
        default:
            return typedBase
        }
    }

    static func namespace(
        root: URL,
        mode: RepoPromptAuthorityServingMode = .server
    ) throws -> AuthorityNamespaceDescriptor {
        try AuthorityNamespaceDescriptor(
            storageRoot: root.path,
            databasePath: root.appendingPathComponent("repoprompt.sqlite").path,
            profile: "test",
            servingMode: mode
        )
    }

    static let defaultRecipient = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    static func identityFile(
        in root: URL,
        name: String = "identity.txt",
        recipient: String = defaultRecipient
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        // CopyingBackupEnvelope is deliberately not cryptography. The fixture
        // stores only a public recipient so unit tests can exercise custody
        // bookkeeping without inventing private-key evidence.
        try Data((recipient + "\n").utf8).write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        return url
    }

    static func recipientsFile(in root: URL, values: [String], name: String = "recipients.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((values.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    static func backupService(envelope: any BackupEnvelopeEncrypting = CopyingBackupEnvelope()) -> BackupRestoreService {
        BackupRestoreService(
            envelope: envelope,
            toolVersion: "RepoPromptServerTests/1",
            toolDigest: String(repeating: "a", count: 64)
        )
    }
}

struct CopyingBackupEnvelope: BackupEnvelopeEncrypting {
    func encrypt(plaintext: URL, recipientsFile _: URL, ciphertext: URL) async throws {
        try FileManager.default.copyItem(at: plaintext, to: ciphertext)
    }

    func decrypt(ciphertext: URL, identityFile _: URL, plaintext: URL) async throws {
        try FileManager.default.copyItem(at: ciphertext, to: plaintext)
    }

    func identityRecipientFingerprint(identityFile: URL) async throws -> String {
        let recipient = try String(contentsOf: identityFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(recipient.utf8)).map { String(format: "%02x", $0) }.joined()
        return "x25519:\(digest)"
    }
}

struct FailingBackupEnvelope: BackupEnvelopeEncrypting {
    enum Failure: Error { case injected }
    let failEncrypt: Bool

    func encrypt(plaintext: URL, recipientsFile _: URL, ciphertext: URL) async throws {
        if failEncrypt { throw Failure.injected }
        try FileManager.default.copyItem(at: plaintext, to: ciphertext)
    }

    func decrypt(ciphertext _: URL, identityFile _: URL, plaintext _: URL) async throws {
        throw Failure.injected
    }

    func identityRecipientFingerprint(identityFile _: URL) async throws -> String {
        throw Failure.injected
    }
}
