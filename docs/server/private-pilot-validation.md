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

## Exact limitations

- Full `make dev-server-test` was attempted twice. Ticket `08af6536-4244-4e55-b6c8-94a1e2cd19c3` was canceled after 21 minutes 28 seconds and ticket `36e3d338-02c7-46bf-95a7-2a31deb36ca0` after 5 minutes 12 seconds. Both made progress with no reported assertion failure, then stopped producing output at the same untouched `DirectHeadlessStdioTransportTests` boundary immediately after `testCleanEOFAndTruncatedEOFHaveDistinctTerminalProvenance`. No PR6 source or test file changes that transport suite. Focused touched-boundary suites above completed.
- `make dev-server-container-test` ticket `0c68085e-bfa0-40a2-8f7f-ff0597cef48b` could not start the build because the local Docker daemon/socket was absent. The GitHub workflow performs the canonical non-publishing image build and asserts `io.repoprompt.distribution=private-pilot-non-publishing`; it contains no registry login or push step.
- No visible-app lifecycle or live-provider smoke was used. No distribution or publishing path was enabled.

## External gates

Human security review, human operations/runbook review, release-owner review, backup-custody acceptance, private-pilot approval, and pilot soak/rollback acceptance are external evidence and remain pending. See `private-pilot-custody-record.md`.
