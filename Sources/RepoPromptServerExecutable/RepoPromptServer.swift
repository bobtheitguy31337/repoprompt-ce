import Foundation
import RepoPromptHeadlessRuntime
import RepoPromptServiceHTTP
import RepoPromptServicePersistence

@main
struct RepoPromptServer {
    static func main() async throws {
        do {
            if CommandLine.arguments.dropFirst().first == "import-json" {
                try await importJSON(arguments: Array(CommandLine.arguments.dropFirst(2)))
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
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: database).deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .file(database))
        do {
            let report = try await LegacySessionJSONImporter.run(source: URL(fileURLWithPath: source), store: store, projectRoot: root)
            try await store.close(clean: true)
            FileHandle.standardOutput.write(try JSONEncoder.serviceEncoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            try? await store.close(clean: false)
            throw error
        }
    }
}
