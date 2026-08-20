import Crypto
import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptMCPAdapter
import RepoPromptServerHost
import RepoPromptServiceHTTP
import RepoPromptServicePersistence

@main
struct RepoPromptServer {
    static func main() async throws {
        do {
            if CommandLine.arguments.dropFirst().first == "mcp-stdio" {
                try await HeadlessMCPStdioBridge.run()
                return
            }
            if CommandLine.arguments.dropFirst().first == "import-json" {
                try await importJSON(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "backup" {
                try await backup(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "migrate" {
                try await migrate(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "restore" {
                try await restore(arguments: Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "process-family-smoke" {
                try await processFamilySmoke()
                return
            }
            try await RepoPromptServerRunner.run(configuration: .environment())
        } catch {
            FileHandle.standardError.write(Data("RepoPromptServer failed: \(error)\n".utf8))
            throw error
        }
    }

    private static func processFamilySmoke() async throws {
        #if os(Linux)
            let store = try await SQLiteServiceStore.open(storage: .memory)
            do {
                let launchingPort = try PortableProcessSupervisionPort()
                let leader = try await launchingPort.launch(
                    executable: "/bin/sh",
                    arguments: ["-c", "setsid /bin/sh -c 'sleep 30' & wait"],
                    environment: ["PATH": "/usr/local/bin:/usr/bin:/bin"],
                    workingDirectory: "/tmp",
                    helperToken: UUID().uuidString
                )
                let runID = UUID()
                let initial = ProviderProcessSupervisor(processPort: launchingPort, store: store)
                try await initial.register(runID: runID, leader: leader)
                let persistedFamilies = try await store.activeProcessFamilies()
                guard persistedFamilies.count == 1 else {
                    throw ConfigurationError.invalid("process family was not persisted")
                }

                let recoveredPort = try PortableProcessSupervisionPort()
                let recovered = ProviderProcessSupervisor(processPort: recoveredPort, store: store)
                try await recovered.recoverPersistedFamilies(graceScans: 3)
                let remainingFamilies = try await store.activeProcessFamilies()
                guard remainingFamilies.isEmpty else {
                    throw ConfigurationError.invalid("recovered process family was not reaped")
                }
                try await store.close()
                FileHandle.standardOutput.write(Data("RepoPromptServer process-family smoke passed\n".utf8))
            } catch {
                try? await store.close(clean: false)
                throw error
            }
        #else
            throw ConfigurationError.invalid("process-family-smoke is supported only on Linux")
        #endif
    }

    private static func importJSON(arguments: [String]) async throws {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let source = value(after: "--source") else {
            throw ConfigurationError.missing("--source")
        }
        let database = value(after: "--database") ?? ProcessInfo.processInfo.environment["REPOPROMPT_STATE_DB"] ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        let root = value(after: "--project-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let storageRoot = URL(fileURLWithPath: database).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: storageRoot.path,
            databasePath: database,
            profile: ProcessInfo.processInfo.environment["REPOPROMPT_PROFILE"] ?? "default",
            servingMode: .server
        )
        let maintenance = try await AuthorityMaintenanceSession.open(
            configuration: .init(namespace: namespace)
        )
        do {
            let report = try await maintenance.importLegacyJSON(
                source: URL(fileURLWithPath: source),
                projectRoot: root
            )
            try await maintenance.close(clean: true)
            FileHandle.standardOutput.write(try JSONEncoder.serviceEncoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            try? await maintenance.close(clean: false)
            throw error
        }
    }

    private static func backup(arguments: [String]) async throws {
        guard let operation = arguments.first else { throw ConfigurationError.missing("backup create|verify") }
        let options = Array(arguments.dropFirst())
        let service = try backupService()
        switch operation {
        case "create":
            guard let recipients = value(after: "--recipients-file", in: options) else {
                throw ConfigurationError.missing("--recipients-file")
            }
            guard let output = value(after: "--output", in: options) else {
                throw ConfigurationError.missing("--output")
            }
            let namespace = try authorityNamespace(arguments: options)
            let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
            do {
                var roots = [BackupAssetRoot(logicalID: "", url: URL(fileURLWithPath: namespace.storageRoot, isDirectory: true))]
                let environment = ProcessInfo.processInfo.environment
                for (key, logicalID) in [
                    ("REPOPROMPT_ARTIFACT_DIR", "artifacts"),
                    ("REPOPROMPT_PROJECT_DIR", "projects"),
                    ("REPOPROMPT_WORKTREE_DIR", "worktrees"),
                ] {
                    if let path = environment[key], FileManager.default.fileExists(atPath: path) {
                        roots.append(.init(logicalID: logicalID, url: URL(fileURLWithPath: path, isDirectory: true)))
                    }
                }
                let sidecar = try await session.createBackup(
                    service: service,
                    request: BackupCreateRequest(
                        outputURL: URL(fileURLWithPath: output),
                        recipientsFileURL: URL(fileURLWithPath: recipients),
                        roots: roots,
                        namespaceKind: namespace.servingMode.rawValue,
                        databaseIdentityDigest: namespace.namespaceID
                    )
                )
                try await session.close(clean: true)
                try writeJSON(sidecar)
            } catch {
                try? await session.close(clean: false)
                throw error
            }
        case "verify":
            guard let archive = options.first(where: { !$0.hasPrefix("-") }),
                  let identity = value(after: "--identity-file", in: options)
            else {
                throw ConfigurationError.missing("backup verify <archive> --identity-file")
            }
            let verified = try await service.verify(
                archiveURL: URL(fileURLWithPath: archive),
                identityFileURL: URL(fileURLWithPath: identity)
            )
            try writeJSON(verified.sidecar)
        default:
            throw ConfigurationError.invalid("backup operation must be create or verify")
        }
    }

    private static func migrate(arguments: [String]) async throws {
        guard let archive = value(after: "--verified-backup", in: arguments) else {
            throw ConfigurationError.missing("--verified-backup")
        }
        guard let identity = value(after: "--identity-file", in: arguments) else {
            throw ConfigurationError.missing("--identity-file")
        }
        let namespace = try authorityNamespace(arguments: arguments, requireNamespaceKind: true)
        let service = try backupService()
        let session = try await AuthorityMaintenanceSession.open(configuration: .init(namespace: namespace))
        do {
            let evidence = try await session.migrate(
                service: service,
                verifiedBackup: URL(fileURLWithPath: archive),
                identityFileURL: URL(fileURLWithPath: identity)
            )
            try await session.close(clean: true)
            try writeJSON(evidence)
        } catch {
            try? await session.close(clean: false)
            throw error
        }
    }

    private static func restore(arguments: [String]) async throws {
        guard arguments.first == "prepare" else {
            throw ConfigurationError.invalid("restore operation must be prepare")
        }
        let options = Array(arguments.dropFirst())
        guard let archive = options.first(where: { !$0.hasPrefix("-") }),
              let identity = value(after: "--identity-file", in: options),
              let target = value(after: "--target", in: options)
        else {
            throw ConfigurationError.missing("restore prepare <archive> --identity-file --target")
        }
        let kind = try namespaceKind(value(after: "--namespace-kind", in: options) ?? "server")
        let targetURL = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        let namespace = try AuthorityNamespaceDescriptor(
            storageRoot: targetURL.path,
            databasePath: targetURL.appendingPathComponent("repoprompt.sqlite").path,
            profile: ProcessInfo.processInfo.environment["REPOPROMPT_PROFILE"] ?? "default",
            servingMode: kind
        )
        let manifest = try await backupService().prepareRestore(
            BackupRestoreRequest(
                archiveURL: URL(fileURLWithPath: archive),
                identityFileURL: URL(fileURLWithPath: identity),
                targetRootURL: targetURL,
                targetNamespaceKind: kind.rawValue,
                targetDatabaseIdentityDigest: namespace.namespaceID
            )
        )
        try writeJSON(manifest)
    }

    private static func authorityNamespace(
        arguments: [String],
        requireNamespaceKind: Bool = false
    ) throws -> AuthorityNamespaceDescriptor {
        let environment = ProcessInfo.processInfo.environment
        let database = value(after: "--database", in: arguments)
            ?? environment["REPOPROMPT_STATE_DB"]
            ?? "/var/lib/repoprompt/state/repoprompt.sqlite"
        let configuredKind = value(after: "--namespace-kind", in: arguments)
        if requireNamespaceKind, configuredKind == nil {
            throw ConfigurationError.missing("--namespace-kind server|direct-headless")
        }
        let kind = try namespaceKind(configuredKind ?? "server")
        let root = URL(fileURLWithPath: database).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try AuthorityNamespaceDescriptor(
            storageRoot: root.path,
            databasePath: database,
            profile: environment["REPOPROMPT_PROFILE"] ?? "default",
            servingMode: kind
        )
    }

    private static func namespaceKind(_ value: String) throws -> RepoPromptAuthorityServingMode {
        switch value {
        case "server": .server
        case "direct-headless", "directHeadless": .directHeadless
        default: throw ConfigurationError.invalid("namespace kind must be server or direct-headless")
        }
    }

    private static func backupService() throws -> BackupRestoreService {
        let envelope = try AgeBackupEnvelope(configuration: .environment())
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let digest = (try? Data(contentsOf: executable, options: [.mappedIfSafe])).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? String(repeating: "0", count: 64)
        return BackupRestoreService(envelope: envelope, toolVersion: "RepoPromptServer/0.1.0", toolDigest: digest)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
