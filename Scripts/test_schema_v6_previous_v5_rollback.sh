#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <exact-previous-v5-ref> <schema-v6-database-path>" >&2
  exit 64
fi

previous_ref="$1"
database_path="$2"
repository_root="$(git rev-parse --show-toplevel)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-v5-rollback.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

git -C "$repository_root" archive "$previous_ref" | tar -x -C "$temporary_root"
cat > "$temporary_root/Tests/RepoPromptServerTests/PreviousSchemaV5RollbackProbeTests.swift" <<'SWIFT'
import Foundation
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class PreviousSchemaV5RollbackProbeTests: XCTestCase {
    func testExactPreviousSourceOpensReadsAndWritesV6Database() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_SCHEMA_COMPAT_DB"])
        let store = try await SQLiteServiceStore.open(storage: .file(path))
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        let actor = ExternalActor(goblinUserID: "v5-probe", username: "v5-probe", displayName: "V5 Probe")
        let projectID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(projectID: projectID, name: "v5 rollback write", creator: actor, state: .active, roots: [], revision: 1, cursor: cursor)
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
        let persisted = try await store.project(id: projectID)
        XCTAssertEqual(persisted?.name, "v5 rollback write")
        try await store.close()
    }
}
SWIFT

(
  cd "$temporary_root"
  REPOPROMPT_SERVER_ONLY=1 REPOPROMPT_SCHEMA_COMPAT_DB="$database_path" swift test --filter PreviousSchemaV5RollbackProbeTests
)
