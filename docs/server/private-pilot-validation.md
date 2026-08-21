# Private-pilot validation evidence

Baseline: audited PR5 head `ff46a97c06c0a6e0d8f902f8023c9004b6211594` on `server-upstream/06-private-pilot-20260819`.

This evidence covers the cumulative PR6 private-pilot/security/operations slice. It does not constitute security, operations, release-owner, custody, or pilot approval. Those external gates remain **PENDING — NOT APPROVED FOR PILOT DISTRIBUTION**.

## Coordinated local evidence

All Swift builds and tests below ran through Conductor without launching or stopping the visible macOS app.

| Boundary | Result | Conductor ticket |
| --- | --- | --- |
| RepoPromptServer product build | PASS | `efd4167e-8c8b-43a4-89df-9f6e1a7b2d34` |
| Portable runtime package tests | PASS | `256127d5-a183-48f0-ab5d-d1d879575e0f` |
| Root `RepoPrompt` product build | PASS | `dde35f5a-12f3-4b2f-adae-d3da03cb1416` |
| Root `repoprompt-mcp` product build | PASS | `602898ce-6830-49d8-8e77-874213c6b494` |
| SwiftFormat + SwiftLint strict | PASS | `a167ca8f-c39e-416c-97c8-4d01a19128e2` |
| Schema V9 fresh/V8 migration | PASS | `934909e8-3b6d-4593-9f2f-4338c6e82c74` |
| Migration fault/cancel/SIGKILL boundaries through V9 | PASS | `870b4175-c514-422b-aa59-9704e195506e` |
| Durable throttle/password/session security | PASS | `ccb98dbe-661c-481d-8b12-0cfd6e680922` |
| Trusted proxy/direct TLS policy | PASS | `fb70addc-a2ab-4bfa-8f45-184a2579b8c0` |
| Portal account/operations assets and topology configuration | PASS | `910c8d18-ac99-495f-a492-56098b4b4426`, `3e34509b-c921-4d85-9fb2-7318d9772567` |
| Portal setup/login regression | PASS | `d3aa8634-40c2-46fd-8096-42a0a747c90a` |
| Backup create/verify/restore core and receipt hash | PASS | `9026973b-afa6-4b38-9868-009b7063e8d7` |
| Backup custody/operational receipt projection | PASS | `98159f96-9c20-4bb8-81bf-d078883f06aa` |
| Offline password reset/session revoke recovery | PASS | `f5f2d159-bf7c-47b0-9bcd-ace9273ef8a4` |
| Authority maintenance lease and schema behavior | PASS | `0ed17f80-069c-4e0a-ab8f-8a113104611f` |
| Shutdown monotonic deadline coverage | PASS | `64a0bc4f-b966-4419-9016-446c3467d5ed` |
| Headless socket shutdown | PASS | `11633512-9744-4a27-98fc-19479c22c01e` |
| Historical V6 normalization compatibility | PASS, two explicit external rollback probes skipped by contract | `46e90e06-d418-4d69-af8e-4491a3ce8aaa` |
| Frozen V6 programs through immutable V7 normalization and latest V9 | PASS | `246ccbff-f4fe-4e8b-aa5f-221472ea8479` |
| Provider/settings fresh-store schema regressions | PASS | `c2ba81e7-708d-45d7-a359-3507f80b3f99`, `01bfe6ad-6c84-48d6-a45d-fe04d0c32dbf` |

Additional local checks passed:

- `node --check Packages/RepoPromptServer/Sources/RepoPromptServiceHTTP/Resources/Portal/portal.js`
- `git diff --check`
- `make guardrails` (SwiftPM emitted read-only user-cache warnings; every repository guardrail completed successfully)
- non-publishing workflow and Dockerfile label inspection

## Independent-audit correction evidence

The release-blocking corrections were applied additively on top of published PR head `3369db78efa825bf33c4384b287c985f2d5a289b`. This rerun does not replace or waive any external gate.

| Corrected boundary | Result | Conductor ticket |
| --- | --- | --- |
| Setup transaction, concurrent auth reservation, offline reset throttle, restore crash atomicity, required receipt decode, and secret-free audit coverage | PASS, 7 tests | `eec0a05f-8829-4472-85dd-232f504f11f2` |
| Failed V9 migration marker imported into V9 audit on atomic retry | PASS | `dbadcef8-0150-4b88-ab99-3607e9d16f0a` |
| Mandatory setup token and immediate owner-only token-file deletion | PASS | `658b3404-ac3c-454f-b799-551402448cf0` |
| Backup/restore core, including required activation receipts | PASS | `e405d4bf-f05e-44fb-a179-034ff27f5a56` |
| One-time prepared-store activation fence | PASS | `5b2c33d4-108b-4169-8bfb-f8c8d9ab711e` |
| V9 migration, trusted public-origin CSRF, portal security/assets/configuration, stale-owner audit, provider portal, and offline recovery | PASS | `18245715-c32e-4cd9-bd82-0393779a6b47`, `3a05955e-6c09-429f-a90e-1e824d5eb534`, `c8cdbb40-b5f0-410d-a760-d2d83dfbf3fa`, `90ebc4b7-5e03-4651-b44d-b3227e0f6f1e`, `5ffb2837-2b2c-4a73-8575-f0d3e620b135`, `a90814b3-9ca0-4184-8bb4-75ce98b3276f`, `48ee5c2d-b6b6-4eb1-8c77-4caf501b1d2d`, `0ac041a1-12dc-4518-83d6-de7b3e5e1c07` |
| Backup custody/operational audit projection | PASS | `f9a6c96d-45ba-4685-be76-fe4829c075ea` |
| SwiftFormat + SwiftLint strict | PASS | `8f63e2b7-4a85-4df7-bd2a-b32d5e7fbe87` |
| RepoPromptServer product build | PASS | `ac56ef72-190c-4269-ac53-4add6878e6fd` |

Correction checks also passed `node --check`, `git diff --check`, `make guardrails`, and an explicit changed-path guard proving no `SchemaV7.swift`, `SchemaV8.swift`, or frozen fixture was modified.

## Exact limitations

- Full `make dev-server-test` was attempted twice. Ticket `08af6536-4244-4e55-b6c8-94a1e2cd19c3` was canceled after 21 minutes 28 seconds and ticket `36e3d338-02c7-46bf-95a7-2a31deb36ca0` after 5 minutes 12 seconds. Both made progress with no reported assertion failure, then stopped producing output at the same untouched `DirectHeadlessStdioTransportTests` boundary immediately after `testCleanEOFAndTruncatedEOFHaveDistinctTerminalProvenance`. No PR6 source or test file changes that transport suite. Focused touched-boundary suites above completed.
- The post-audit full Server attempt `99c36acb-0244-4fcd-b743-acba14d8bcef` was canceled after 10 minutes 36 seconds at the untouched `DirectHeadlessStdioTransportTests.testBrokenPipeIsBoundedAndDeliveryIsRecordedOnlyAfterPhysicalWrite` stall. It found one expected-count regression caused by the two new fresh-store migration audit rows; that assertion was corrected and its focused rerun passed at `f9a6c96d-45ba-4685-be76-fe4829c075ea`.
- Broad `PersistenceTests` ticket `f9da197d-b3c2-4555-96a9-0da9c0670c17` retained unrelated failures in cursor rejection, terminal archive, and unclean-restart cases; the touched `testRestoreChangesStoreNamespace` passed. Broad `DurabilityOperationsTests` ticket `20c942af-f253-4359-9c3a-af84b7121503` produced no test output for 3 minutes 59 seconds and was canceled; the touched restore activation test passed separately at `5b2c33d4-108b-4169-8bfb-f8c8d9ab711e`.
- Post-audit `pr-ready` passed repository/Conductor selftests and coordinated lint (`0259c16e-6b08-4960-8b29-7e7e9afff882`), then its root-suite ticket `f6fe8797-982d-4ed7-91e6-64ad19b827fe` exposed unrelated failures in `ContextBuilderRunLifecycleTests.testRealConnectionCleanupCannotEraseContextBeforeCommit`, `GitBlobIdentityServiceTests.testCheckoutAttributesConfigFiltersLFSIdentAndEncodingRequireRawBytes`, and `MCPMutationRetryableFailureTests.testCloseTabRepairsBoundNonActiveContextAfterCommit`. The suite continued well beyond those failures, then stopped producing output inside the untouched `WorkspaceRootNamespaceManifestTests` suite immediately after `testReaderFailsTerminallyWhenOpenArtifactIsMutatedOrTruncated`; it was canceled after 22 minutes 57 seconds. No PR6 correction changes those root-test boundaries.
- `make dev-server-container-test` ticket `0c68085e-bfa0-40a2-8f7f-ff0597cef48b` could not start the build because the local Docker daemon/socket was absent. The GitHub workflow performs the canonical non-publishing image build and asserts `io.repoprompt.distribution=private-pilot-non-publishing`; it contains no registry login or push step.
- No visible-app lifecycle or live-provider smoke was used. No distribution or publishing path was enabled.

## External gates

Human security review, human operations/runbook review, release-owner review, backup-custody acceptance, private-pilot approval, and pilot soak/rollback acceptance are external evidence and remain pending. See `private-pilot-custody-record.md`.
