# RepoPrompt Linux Server Authority

Status: implementation baseline for E0-E6 (2026-08-09)

`RepoPromptServer` is a non-UI Swift executable and the only writer for one server state database. The executable parses environment configuration and delegates to `RepoPromptServerRunner`; domain and transport logic do not live in the executable target.

## Target graph

```text
RepoPromptServerExecutable
  -> RepoPromptServiceHTTP
       -> RepoPromptHeadlessRuntime
       -> RepoPromptServicePersistence
       -> RepoPromptServiceProtocol
  -> RepoPromptHeadlessRuntime
       -> RepoPromptAgentRuntimeCore
       -> RepoPromptWorkspaceRuntimeCore
       -> RepoPromptDomainRuntime
       -> RepoPromptServicePersistence

RepoPromptMCPAdapter -> RepoPromptHeadlessRuntime + RepoPromptDomainRuntime
```

Linux, and macOS builds with `REPOPROMPT_SERVER_ONLY=1`, resolve only this graph. The same canonical `RepoPromptDomainRuntime` and `RepoPromptShared` sources used by the app and MCP product are below the server boundary; their crypto, random, locking, and POSIX edges select Crypto/Glibc implementations on Linux. AppKit, SwiftUI, Sparkle, Combine UI, the Objective-C bridging header, and the macOS binary target are absent. The normal macOS graph remains available when that switch is unset.

## Authority and isolation

- `RepoPromptHeadlessAuthority` is actor isolated and routes by persisted project and session UUIDs.
- `ProjectRuntimeSupervisor` owns one `ProjectAuthority` per project. A child session cannot cross the parent's project.
- `SessionAuthority` serializes commands and retains generation, turn-epoch, connection-generation, and exactly-once terminal gates.
- `LocalFilesystemAuthority` resolves symlinks and verifies every logical path remains inside an authorized root.
- External commands are root-session only. Child creation remains an internal runtime operation.
- `ProviderRegistry` accepts executable paths only from immutable service configuration. `ProviderProcessSupervisor` signals only identities that still match recorded process evidence.

## Persistence

`RepoPromptServicePersistence` uses SQLiteNIO 1.13.0. Startup enables foreign keys, WAL, `synchronous=FULL`, and a five-second busy timeout, applies checksum-addressed schema v1, and runs `PRAGMA quick_check` before readiness.

The v1 migration creates the complete E4 table inventory: service metadata, projects and roots, templates and selections, sessions/agents/runs, worktrees, workflows, process families/members, interactions, execution permissions, contexts/transcripts/events, artifacts/owned resources, snapshots, idempotency, nonces, audit, and migrations. Project/session snapshots, transcript rows, canonical events, and idempotency results publish in one `BEGIN IMMEDIATE` transaction. Global sequence allocation is store-scoped. Restore activation assigns a fresh `store_id` and records provenance.

## Internal service

- Mutual TLS 1.3 listener: `0.0.0.0:9443` by default.
- Content-free loopback health listener: `127.0.0.1:9080`.
- Roles are closed: `goblin-app`, `goblin-sync`, and `repoprompt-operator`.
- Requests use canonical method/path/timestamp/nonce/body/decision/key-ID HMAC input.
- Nonces persist before dispatch and reject replay.
- Human operations require a separately signed, operation/request/target-bound Goblin decision with a maximum 30-second lifetime.
- SSE subscribes before replay, drains durable pages to a captured watermark, deduplicates the bounded live buffer by global sequence, and emits signed application-framed events; lagging subscribers are disconnected with a reconnect cursor.
- Cursor namespace changes or replay-floor violations return the stable `cursor_expired` contract.

Provider and Git credentials are not accepted through HTTP and are never stored in the service database. Secret values are loaded from files; the executable does not print them.

## Image contract

`Dockerfile.server` builds only `RepoPromptServer`, runs it as fixed UID/GID 65532, includes `tini` and `curl`, and retains image metadata for both fixed ports: `9443/tcp` is the mTLS internal API and `9080/tcp` is the loopback-only health listener used by the image probe. The `io.degentlemen.repoprompt.port.*` OCI labels make those scopes explicit; deployments must not publish 9080. Compose must still set read-only root, dropped capabilities, no-new-privileges, resource/PID/log bounds, persistent state/project/worktree/cache volumes, internal networks, and runtime secret mounts.

## Validation

```sh
REPOPROMPT_SERVER_ONLY=1 swift build --disable-automatic-resolution --product RepoPromptServer
REPOPROMPT_SERVER_ONLY=1 swift test --disable-automatic-resolution --filter RepoPromptServerTests
docker build -f Dockerfile.server .
```

Ubuntu 24.04 runs the same build and focused tests in `.github/workflows/linux-server.yml`.

## Known extraction boundary

This baseline establishes the reusable target, persistence, protocol, supervision, and service boundaries. The existing macOS `AgentModeViewModel` and direct-headless MCP implementation have not yet been cut over to these targets; see the fork-delta ledger for the explicit remaining convergence work. No Goblin collaboration policy is evaluated here.
