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

    static func makeV6Store(at databaseURL: URL, digest: String = knownV6Digests[0]) async throws {
        let store = try await SQLiteServiceStore.open(storage: .file(databaseURL.path))
        _ = try await store.database.query("UPDATE service_metadata SET schema_version=6 WHERE fixed_id=1")
        _ = try await store.database.query("DELETE FROM schema_migrations WHERE version=7")
        _ = try await store.database.query("UPDATE schema_migrations SET digest=? WHERE version=6", [.text(digest)])
        _ = try await store.database.query("DROP TABLE schema_compatibility_audit")
        _ = try await store.database.query("DROP TABLE authority_namespace_identity")
        try await store.close(clean: false)
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

    static func identityFile(in root: URL, name: String = "identity.txt") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("AGE-SECRET-KEY-1TESTONLY\n".utf8).write(to: url)
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
}
