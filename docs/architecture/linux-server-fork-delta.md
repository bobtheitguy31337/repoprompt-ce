# Linux Server Upstream Absorption and Fork Delta Ledger

Observed: 2026-08-09 20:13 America/Los_Angeles (2026-08-10 03:13 UTC)

## Clean starting state and isolation

- Existing checkout: `/Users/jared/Projects/repoprompt-ce`
- Existing branch/HEAD: `remote-foundation` at `963c5c40b07976b3acd27bb2549a51f9eeae278e`
- Starting status: clean; tracking `origin/remote-foundation`, reported 1176 commits behind after refresh.
- Integration worktree: `/private/tmp/repoprompt-ce-linux-server`
- Integration branch: `codex/linux-server-e0-e6`
- Verified canonical base: `upstream/main` at `f7b647d67e9c0b9ac61c8db76f784f1fa01e4198`
- Fork main: `origin/main` at `21016c5d6f38acf7be63547fefc6c5e8f49e1af2`
- Fork remote-foundation ref: `origin/remote-foundation` at `925063e3a112508ca49f5f8eb950d2d528d5e7a7`
- Existing checkout and its unrelated worktrees were not modified.

## Upstream PR absorption

| PR | Exact head | State observed through GitHub | Disposition |
|---|---|---|---|
| #677 | `ee85d7d26f9a2718ee8b06211d2a49f07e510a21` | merged 2026-08-03, merge `d18ee531c463e4050c74527bd9f4d1a756638e65` | received through upstream base |
| #748 | `b6ffc151894c4565ca64c0aeab93e38ae14f9300` | merged 2026-08-09, merge `1c41f62cd4841b26fa76bec9a9758be570180382` | received through upstream base |
| #760 | `f0decc98531597d82f8ef664e9428bc45f0d83d8` | open, changes requested, hosted checks green | not absorbed; review gate is unresolved |
| #761 | `a4cf19b0e6d32be103b127cd354c70016973cf36` | open, review required, hosted checks green | not absorbed; no approved exact head |
| #775 | `f799acb46d8abd7bc83d26cc901e7ea67492de09` | draft; Linux native/container checks green; style and app shards failing | not cherry-picked wholesale; dependency versions, server-only manifest boundary, and POSIX direction were independently ported |
| #776 | `af3d32c2500384cd3a01a2a96dd83c29a7bd506d` | merged 2026-08-09, merge `1063908da74db58d9a998e58ffffec861297ea85` | received through upstream base |

## The 19 remote-foundation commits

`git rev-list --count upstream/main..remote-foundation` returned 19. `git cherry -v upstream/main remote-foundation` marked all 18 non-merge commits `+` (no patch-equivalent upstream commit); `bf76e033` is the remaining merge commit and has no stable patch ID. Therefore all 19 are classified **fork-only**, not already-upstream.

The sequence is `1aa0e3b6`, `a1581ef8`, `0299bb11`, `05f3018c`, `85df080b`, `f060da55`, `1a881c83`, merge `bf76e033`, `4f7c7a87`, `8ea15383`, `de44a8c0`, `3e21d83`, `8be91993`, `0c15b660`, `78d39964`, `eafe0d04`, `c68b462b`, `e7fdb1bb`, and `963c5c40`.

These commits implement the separate Mac-authoritative Remote/Iroh product line. They remain preserved on the untouched `remote-foundation` branch and were not replayed into the Linux-server branch because doing so would mix unrelated UI/pairing/Iroh changes into the server authority and create a second review surface. Removal/replay condition: a later dedicated Remote integration branch must range-diff them against its then-current upstream base and intentionally select that product work.

## Live sandbox observation

Read-only SSH inspection at 2026-08-10T03:12:57Z found:

- App healthy for 6 hours at server SHA `5023b3a329c856b98453b3f5a9d29cfa548b1a70` / ops SHA `5b028767ec66ea787f89ac0832795c3048d21f94`.
- Mongo healthy for 7 days; proxy/media/Jitsi/Coturn healthy for 3 days.
- 33 GiB free on `/` (79 GiB filesystem, 58% used).
- Images 8.285 GB; volumes 3.052 GB; BuildKit cache 10.31 GB with 7.601 GB reclaimable.
- No RepoPrompt service is deployed yet. No host mutation was performed.

These are evidence, not deployment guarantees; E14 must reinspect immediately before building/deploying.

## Fork-only implementation delta

| Delta | Rationale | Upstream/removal condition |
|---|---|---|
| Server-only SwiftPM graph and `RepoPromptServer` product | Linux must not resolve AppKit/SwiftUI/Sparkle/bridging dependencies | upstream once target ownership stabilizes; remove local delta after equivalent upstream server product lands |
| `RepoPromptServiceProtocol` | stable DTO/event/error/signing contract for Goblin integration | generally upstreamable, excluding Goblin naming in actor envelope |
| `RepoPromptAgentRuntimeCore` / `RepoPromptWorkspaceRuntimeCore` | portable authority seams and deterministic ports | converge with upstream `RepoPromptDomainRuntime`; remove duplicates after macOS and MCP cutover |
| `RepoPromptServicePersistence` | SQLiteNIO schema, migrations, events, idempotency, nonces, restore namespace | upstreamable server substrate |
| `RepoPromptHeadlessRuntime` | exact-ID project/session authority and provider/process supervision | replace any overlapping types with upstream extracted runtime as it lands |
| `RepoPromptServiceHTTP` / executable | Hummingbird TLS/HMAC/SSE/product service | server product delta; Goblin route-role policy stays fork-local |
| Ubuntu CI and `Dockerfile.server` | canonical Linux validation and image | upstreamable once release policy approves Linux artifacts |

## Current contract deviations / blockers

1. The macOS app and `repoprompt-mcp` have not yet been converted to adapters over `RepoPromptHeadlessAuthority`; current server core is an additive boundary, not the final single-authority cutover.
2. Existing `AgentModeRunService`, full transcript normalization, Context Builder, Oracle, Git/CodeMap, workflow, and worktree implementations are not yet moved into the new portable targets. Versioned routes are registered and fail closed with `capability_missing` where their backing service is absent.
3. Provider registry/cancellation contracts and `/proc` parsing exist, but real Codex/Claude/OpenCode/Cursor launch adapters, subreaper activation, persisted process-family reconciliation, late-fork scans, and provider smoke are still incomplete.
4. Event rows are persisted before transport signing; SSE applies the directional signature. Canonical at-rest event signatures and archive/checkpoint retention remain incomplete.
5. The image pins Swift 6.2.4 and uses the shared operations UID/GID contract `65532:65532`, but does not yet bundle pinned provider binaries. It expects immutable executable paths and credential homes to be supplied by the deployment image/build extension.
6. TLS requires a client chain from the configured CA and HMAC roles are closed, but certificate SAN/EKU-to-role mapping is not yet enforced independently of the directional HMAC key.
7. Readiness currently covers startup migration/integrity/configuration and quiesce state; enabled-provider preflight, writable-volume capacity, and per-project degradation reporting are not yet complete.
8. The 19 Remote/Iroh commits were preserved but not replayed for the scope reason above.

Goblin siblings can rely on protocol v1 DTO/error names, store-scoped `storeId:sequence` cursors, TLS/HMAC header names, role separation, loopback health ports, and the implemented project/session/snapshot/event routes. They must treat `capability_missing` as expected for the incomplete tool/provider routes until the convergence work above lands.

## Local validation constraints

The local Docker client was present but no Docker daemon socket was available, so the canonical image could not be executed locally. The exact `swift:6.2.4-noble` and `swift:6.2.4-noble-slim` tags were verified in the official registry, and the checked-in Ubuntu image job performs the build plus `65532:65532` metadata assertion. No live host build was attempted.
