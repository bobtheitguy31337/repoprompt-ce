import Foundation
import XCTest

final class RepoPromptPortableFixtureTests: XCTestCase {
    func testAgentParityFixtureIsSingleAndDecodable() throws {
        let names = [
            "model-normalization",
            "provider-matrix",
            "transcript-presentation",
            "turn-compilation"
        ]
        for name in names {
            let url = try XCTUnwrap(
                Bundle.module.url(
                    forResource: name,
                    withExtension: "json",
                    subdirectory: "AgentParity/v1"
                )
            )
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        }
    }
}
