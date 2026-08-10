import Foundation
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
            try await RepoPromptServerRunner.run(configuration: .environment())
        } catch {
            FileHandle.standardError.write(Data("RepoPromptServer failed: \(error)\n".utf8))
            throw error
        }
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
