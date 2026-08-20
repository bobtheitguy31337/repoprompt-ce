#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import RepoPromptServerHost

let HEADLESS_CLI_VERSION = "1.3.0"
let HEADLESS_LAUNCHER_CONTRACT_VERSION = "1"

@main
enum RepoPromptMCPHeadlessBootstrap {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--print-launcher-contract-version" {
            print(HEADLESS_LAUNCHER_CONTRACT_VERSION)
            return
        }
        guard let index = arguments.firstIndex(of: "--launcher-contract-version"),
              arguments.indices.contains(index + 1),
              arguments[index + 1] == HEADLESS_LAUNCHER_CONTRACT_VERSION
        else {
            fputs("RepoPrompt private headless runtime: incompatible or missing launcher contract\n", stderr)
            exit(64)
        }
        do {
            try await RepoPromptDirectHeadlessHostRunner.run()
        } catch {
            fputs("RepoPrompt private headless runtime: \(error)\n", stderr)
            exit(70)
        }
    }
}
