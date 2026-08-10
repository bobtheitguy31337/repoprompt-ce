import Foundation
import RepoPromptServiceHTTP

@main
struct RepoPromptServer {
    static func main() async throws {
        do {
            try await RepoPromptServerRunner.run(configuration: .environment())
        } catch {
            FileHandle.standardError.write(Data("RepoPromptServer failed: \(error)\n".utf8))
            throw error
        }
    }
}
