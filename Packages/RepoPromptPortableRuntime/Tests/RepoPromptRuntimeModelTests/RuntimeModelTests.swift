import Foundation
@testable import RepoPromptRuntimeModel
import XCTest

final class RuntimeModelTests: XCTestCase {
    func testIdentifiersRejectEmptyValues() throws {
        XCTAssertThrowsError(try RuntimeOwnerID(validating: "  "))
        XCTAssertThrowsError(try RuntimeResourceID(validating: "\n"))
    }

    func testWorkflowValueUsesNaturalJSONAndPreservesIntegers() throws {
        let value = WorkflowValue.object([
            "integer": .integer(42),
            "number": .number(2.5),
            "enabled": .boolean(true),
            "items": .array([.string("value"), .null])
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(WorkflowValue.self, from: data), value)

        let decoded = try JSONDecoder().decode(WorkflowValue.self, from: Data("42".utf8))
        XCTAssertEqual(decoded, .integer(42))
    }

    func testWorkflowRejectsUnsupportedVersion() {
        XCTAssertThrowsError(try WorkflowDefinition(formatVersion: 2)) { error in
            XCTAssertEqual(error as? RuntimeModelError, .unsupportedWorkflowVersion(2))
        }
    }

    func testWorkflowRejectsNestedNonFiniteNumberAtConstruction() {
        XCTAssertThrowsError(try WorkflowDefinition(payload: .object([
            "nested": .array([.number(.nan)])
        ]))) { error in
            XCTAssertEqual(error as? RuntimeModelError, .invalidNumber)
        }
    }
}
