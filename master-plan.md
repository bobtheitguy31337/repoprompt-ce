# RepoPrompt Remote — Master Plan

Status: paired read/control, explicit detail, encrypted notification,
diagnostics, relay implementation, and iOS release configuration are present in
the two agreed repositories; mutation failure coverage is complete, while
provider credentials/deployment and Android FCM registration remain
release/deferred work.

Last updated: 2026-07-21

This document is the working plan for the separate mobile repository and its
corresponding RepoPrompt CE desktop changes.

## 1. Mission

Build a trusted mobile remote-control surface for RepoPrompt Community Edition.

The phone supervises and controls RepoPrompt agents while the Mac remains the
only runtime and authoritative owner of:

- Agent execution and provider processes
- Provider credentials
- Repository and filesystem access
- Workspace, context, worktree, window, and tab state
- Agent Mode and Context Builder configuration
- Session persistence, transcripts, and history
- Permission enforcement

The phone must never run agents locally or access repository files outside
RepoPrompt desktop services. Agents continue running normally if the phone
disconnects.

## 2. Product scope

### First release includes

- One Mac and one paired phone
- iOS client first; protocol remains platform-neutral for a future Android client
- LAN-only commands and transcript traffic
- Bonjour/DNS-SD discovery with direct-address QR fallback
- Short-lived QR pairing and device-scoped credential
- All saved RepoPrompt workspaces, including closed workspaces
- Automatic desktop workspace/window/tab activation by immutable workspace ID
- Agent Mode built-in and custom workflows
- Context Builder plan, review, question, and configured flows
- Live and historical conversations
- Parent/child agent relationships
- Questions, approvals, follow-ups, steering, cancellation, and resume
- Configurable mobile authority and temporary elevation
- Text-only run creation
- Desktop-default context and worktree behavior
- APNs/FCM wake notifications for “Agent needs you” and related attention

### Deferred

- Mobile code editor
- Mobile file selection or context curation
- Image/file attachments
- Workflow creation or editing
- Worktree selection, merge, or cleanup UI
- Multiple phones or multiple desktops
- WAN command transport
- Phone-hosted agents
- Offline mutation queues

## 3. Architectural decisions

### Desktop is the authority

Mobile is a client of typed RepoPrompt control services. It is not a generic
MCP client and must not infer authoritative state from miscellaneous MCP calls.

The long-term call path is:

```text
iOS / Android app
    │
    │ Bonjour + QR pairing
    │ HTTPS JSON commands and snapshots
    │ resumable event stream
    ▼
RepoPrompt Remote Gateway
    │
    ├── pairing and device authentication
    ├── desktop-enforced authorization
    ├── snapshot projection
    ├── event sequencing and replay
    ├── workspace/window/tab resolution
    └── notification relay envelope producer
    ▼
shared typed RepoPrompt control services
    ▼
existing RepoPrompt Agent Mode, Context Builder, workspace, and history state
```

The existing Unix-socket MCP transport remains a separate transport and is not
the phone protocol.

### Shared typed services

The desktop implementation should extract or formalize these services beneath
MCP and UI-specific adapters:

- `AgentControlService`
- `AgentCatalogService`
- `WorkflowCatalogService`
- `SessionQueryService`
- `TranscriptQueryService`
- `WorkspaceCatalogService`
- `WorkspaceActivationService`
- `ContextBuilderService`
- `HistoryQueryService`
- `RemoteStateProjectionService`

MCP, Remote, CLI, and Coordinator Mode should reuse these services rather than
reimplementing agent lifecycle or workspace routing.

### Transport

The mobile protocol is RepoPrompt-specific and versioned:

```text
/remote/v1/pair
/remote/v1/snapshot
/remote/v1/events
/remote/v1/workspaces
/remote/v1/sessions
/remote/v1/agents
/remote/v1/workflows
/remote/v1/context-builder
/remote/v1/commands
```

Use HTTPS JSON for commands, catalogs, history, and snapshots. Use WebSocket or
SSE for resumable live events. Maintain a bounded replay buffer and fall back to
a complete snapshot when a mobile cursor is too old.

### Pairing and credentials

The first release supports exactly one desktop and one paired phone.

Pairing flow:

1. User opens RepoPrompt Settings → Remote.
2. RepoPrompt enables local discovery and displays a short-lived QR code.
3. The phone scans the QR code and verifies desktop identity.
4. The desktop issues a device-scoped credential.
5. The phone stores the credential in iOS Keychain or Android Keystore.
6. Re-pairing invalidates the previous credential.

The QR code may contain protocol version, desktop instance ID, Bonjour identity,
LAN fallback address, certificate/public-key fingerprint, one-time pairing
secret, and expiration. It must never contain a long-lived bearer credential.

### Authorization

The desktop evaluates authorization for every command. Mobile controls may be
hidden for usability, but hidden controls are not an authorization boundary.

| Level | Allowed behavior |
| --- | --- |
| Observe | Read sessions, transcripts, history, and status |
| Respond | Answer questions, approve lower-risk interactions, send follow-ups |
| Control | Start, steer, cancel, resume, workflows, and Context Builder |
| Danger | Destructive, unrestricted, cleanup, or high-risk operations |

Temporary elevation must support once, session-scoped, limited-duration,
persistent, and explicit Danger mode behavior.

Secret inputs use secure entry. Their values must not appear in snapshots,
events, history, search indexes, logs, or push-notification payloads.

### Notifications

Push is only a wake-up and routing mechanism. It is not the command path or
authoritative data source.

```text
RepoPrompt desktop
    │ opaque encrypted event
    ▼
minimal APNs/FCM relay
    ▼
paired phone
    │ reconnects over LAN
    ▼
authoritative desktop snapshot/event state
```

The relay receives routing metadata and encrypted bytes only. Notifications must
support agent input, approval required, completed, and failed categories without
including secrets, raw prompts, repository paths, commands, or transcripts in
plaintext.

## 4. Current repository state

### Desktop repository

Path: `/Users/jared/Projects/repoprompt-ce`

GitHub remote:

- `origin`: `https://github.com/bobtheitguy31337/repoprompt-ce.git`

The fork has been created and the local checkout uses it as the only desktop
repository remote.

Current branch: `codex/remote-control-foundation`, currently at `1aa0e3b6`
with the Remote implementation changes in the working tree.

Implemented foundation:

- [x] `RemoteProtocol` version and `/remote/v1` path
- [x] Codable/Sendable remote snapshot DTOs
- [x] Desktop, connection, workspace, session, attention, workflow, and agent summaries
- [x] Ordered authority levels and session-scoped temporary grants
- [x] Typed remote event envelope and event types
- [x] Batch event coalescing for high-cardinality fleet projections
- [x] Actor-backed bounded event replay buffer
- [x] Duplicate event-ID suppression
- [x] Snapshot fallback when the replay cursor is too old
- [x] Secret-safe interaction summary shape
- [x] Focused shared-target test target
- [x] Architecture/security notes in `docs/architecture/remote-control.md`
- [x] Typed workspace/session projection services and a complete fixture snapshot
- [x] Opt-in LAN HTTPS gateway with TLS identity pinning metadata
- [x] One-device pairing, Keychain credential storage, rotation, and revocation
- [x] `/remote/v1/pair`, `/remote/v1/snapshot`, and bounded `/events`
- [x] Remote settings UI with enablement, QR regeneration, authority default, and revocation

Files added or changed in the current implementation:

- `Packages/RepoPromptRemoteProtocol/`
- `Sources/RepoPromptShared/RemoteProtocolExports.swift`
- `Sources/RepoPrompt/Infrastructure/Remote/`
- `Sources/RepoPrompt/Features/Settings/Views/RemoteSettingsView.swift`
- `Tests/RepoPromptTests/Remote/`
- `Package.swift`
- `docs/architecture/remote-control.md`

Implemented command/read slice:

- Remote command endpoints
- Live coarse event publication from agent/workspace state
- Paged history and transcript reads
- Live workflow/agent catalogs and selected workflow starts
- Context Builder clarify, question, plan, and review commands
- Launch-at-login setting and active-run sleep assertion
- Catalog and diagnostics endpoints
- Explicit transcript detail expansion with redaction
- Encrypted notification envelopes, APNs registration relay contract, and
  attention-category delivery hooks
- Bounded event coalescing for large fleet snapshot-poll batches

Not implemented yet:

- External APNs/FCM provider credentials and relay deployment (release
  infrastructure, intentionally not committed here)

### Mobile repository

Path: `/Users/jared/Projects/repoprompt-remote`

Current branch: `main`

Current commit: `c83020e`; the implementation changes below are in the working
tree.

Implemented foundation:

- [x] XcodeGen project definition
- [x] iOS 17 SwiftUI application shell
- [x] Pairing entry screen
- [x] Fleet screen
- [x] Projects screen
- [x] History screen
- [x] Remote permissions screen
- [x] Connection-state model
- [x] Simulator build with signing disabled
- [x] QR camera scanning
- [x] Bonjour discovery and QR direct-address fallback
- [x] TLS certificate pinning and URLSession client
- [x] iOS Keychain credential storage
- [x] Snapshot reducer and cursor-based event replay
- [x] Snapshot-required recovery after an old event cursor
- [x] Provider-neutral APNs/FCM relay implementation under `relay/`

The mobile client now uses the production pairing/client path. It renders saved
workspace/session/history/transcript data and can issue the first control
commands through the desktop authority boundary. The current desktop gateway
closes each bounded SSE response after replaying available events. History
search, paged transcript loading, workflow selection, and resume controls are
wired to the same authoritative command/read paths. A Context Builder sheet
supports clarify, question, plan, and review flows through the same command
boundary.

Not implemented yet:

- Provider credentials and deployment (release infrastructure)
- Android FCM registration (deferred; the relay contract already accepts FCM)

### GitHub/repository state

The mobile repository is configured with the intended GitHub remote:

`https://github.com/bobtheitguy31337/repoprompt-remote.git`

The desktop checkout uses only the agreed fork:

```sh
origin   https://github.com/bobtheitguy31337/repoprompt-ce.git
```

Publishing remains a separate deliberate step after the implementation is
review-ready. Do not rewrite history or force-push without explicit approval.

## 5. Master implementation roadmap

### Phase 0 — Repository and protocol ownership

Goal: make the two-repository boundary explicit and buildable.

- [x] Create/configure the GitHub remote for `repoprompt-remote`.
- [x] Decide where the shared Foundation protocol package is versioned: it lives
      under `Packages/RepoPromptRemoteProtocol/` in `repoprompt-remote`.
- [x] Extract the Remote DTOs into a small platform-neutral Swift package
      consumed by desktop and mobile. Desktop uses a local path dependency while
      the package is developed; a tagged remote dependency is release work.
- [x] Add CI for the iOS simulator build and protocol tests.
- [x] Add a compatibility policy: both peers accept only the declared supported
      range (`RemoteProtocol.minimumSupportedVersion...currentVersion`); a
      future incompatible contract gets a new versioned path.

Exit criteria: both repositories build in CI, and the mobile app does not own a
second incompatible copy of the Remote protocol.

### Phase 1 — Shared desktop control services

Goal: expose existing RepoPrompt behavior through typed application services.

- [x] Inventory current Agent Mode lifecycle, interaction, transcript, workflow,
      Context Builder, workspace, window, tab, and history owners.
- [x] Define service protocols and DTO boundaries below the UI/MCP adapters.
- [x] Implement workspace catalog over saved non-ephemeral workspaces, not only open ones.
- [x] Implement workspace activation using immutable workspace ID.
- [x] Reuse an existing window when possible.
- [x] Open a new window and wait for readiness when no window exists.
- [x] Resolve/create the appropriate compose tab automatically.
- [x] Project existing Agent Mode status into `RemoteSessionSummary`.
- [x] Project parent/child session relationships and attention items.
- [x] Add focused tests for restart/reconnect projection, cancellation,
      waiting-for-input, and workspace-not-open cases.

Exit criteria: a typed in-process service can produce an authoritative remote
snapshot without going through serialized MCP requests.

### Phase 2 — Desktop Remote Gateway

Goal: complete the first real end-to-end vertical slice.

- [x] Add opt-in Remote settings section.
- [x] Add one-device pairing state and device management UI.
- [x] Implement local HTTPS/TLS listener without modifying Unix-socket MCP.
- [x] Implement Bonjour advertisement and QR direct-address fallback.
- [x] Store/rotate/revoke the device credential securely.
- [x] Verify desktop identity during pairing and reconnect.
- [x] Enforce paired-device authorization on every read endpoint and recheck
      authority at the command boundary.
- [x] Implement `/pair`, `/snapshot`, bounded `/events`, `/history`, and
      `/transcript`.
- [x] Publish coarse fleet events from live agent/workspace changes; reserve
      detailed streaming for the viewed conversation.
- [x] Add connection diagnostics and bounded error responses.

Exit criteria: a real paired iPhone can reconnect to a running Mac and render
Fleet, Projects, and persisted session state from a complete authoritative
snapshot.

### Phase 3 — Mobile client

Goal: replace the shell with a reliable remote viewer.

- [x] Implement QR scanning.
- [x] Implement Bonjour discovery and QR direct-address fallback.
- [x] Store the device credential in iOS Keychain.
- [x] Verify the desktop certificate identity by SHA-256 pinning.
- [x] Implement URLSession HTTPS client.
- [x] Implement snapshot reducer and in-memory event cursor handling.
- [x] Replay events after reconnect and request snapshot fallback when required.
- [x] Implement workspace list, session list, history search, and transcript read.
- [x] Add live connection/reconnect/error state to the UI.

Exit criteria: killing/restarting the app, changing networks, or restarting the
Mac never causes the phone to display stale state as authoritative.

### Phase 4 — First mutation and control loop

Goal: prove desktop-enforced control with one complete mutation path.

- [x] Implement `start Agent Mode run` by workspace ID.
- [x] Resolve closed workspace activation automatically.
- [x] Return session ID and live status to mobile.
- [x] Enforce Control authority at the desktop command boundary.
- [x] Add text follow-up.
- [x] Add answer-question and lower-risk approval flows.
- [x] Add secure secret-input submission with no persistence/logging.
- [x] Add steer, cancel, and resume.

Exit criteria: mobile can start and control a real Agent Mode run while the Mac
remains the only execution environment, including phone disconnect/reconnect.

### Phase 5 — Context Builder and full conversation operations

- [x] Add Context Builder plan/review/question/configured flows.
- [x] Add built-in and custom workflow catalogs.
- [x] Add full historical transcript loading with paged mobile continuation.
- [x] Add sanitized tool cards with explicit Show details and redaction.
- [x] Add raw commands, tool arguments, results, reasoning, file/worktree, and
      approval details only behind explicit detail expansion.
- [x] Add parent/child agent navigation and hierarchy visualization.
- [x] Add merge/conflict and worktree summaries without mobile worktree editing.

Exit criteria: the mobile conversation view covers the agreed operational level
of desktop Agent Mode without duplicating desktop lifecycle logic.

### Phase 6 — Notifications and desktop availability

- [x] Add APNs registration for iOS; reserve FCM registration for Android later.
- [x] Implement encrypted notification envelopes.
- [x] Support input, approval, completion, and failure notification categories.
- [x] Deep-link notifications to a session and resync over LAN.
- [x] Add launch-at-login setting.
- [x] Add active-run sleep assertion only while agents are active or waiting for
      input.
- [x] Add network-change, desktop-restart, credential-revocation, and
      notification diagnostics.

Exit criteria: a suspended phone receives a safe attention notification and
opens the authoritative session after reconnecting to the Mac.

### Phase 7 — Hardening and release readiness

- [x] Threat model pairing, TLS identity, credential rotation, and push relay.
- [x] Test replay gaps, duplicate events, stale cursors, and snapshot fallback.
- [x] Test one-device enforcement and revocation through the desktop credential authority.
- [x] Test cancellation and partial-success behavior for every mutation.
- [x] Test workspace activation when windows/tabs are absent or closing.
- [x] Load-test fleet projection and event coalescing with many sessions.
- [x] Add protocol compatibility tests across supported versions.
- [x] Add macOS and iOS release packaging/signing configuration.
- [x] Prepare user-facing setup, diagnostics, and security documentation.

## 6. API and state contract

### Snapshot

`RemoteSnapshot` contains:

```text
RemoteSnapshot
├── protocolVersion
├── desktop
├── connection
├── authorization
├── workspaces[]
├── sessions[]
├── attentionItems[]
├── workflowCatalog[]
├── agentCatalog[]
└── eventCursor
```

Each session summary should include session/workspace/tab identity, parent and
children, session name, workflow, provider/model/reasoning effort, run state,
lifecycle stage, latest meaningful activity, pending interaction, worktree and
merge summaries, failure summary, update time, and live-versus-persisted state.

### Events

Every event includes desktop instance ID, monotonic sequence, event ID,
timestamp, event type, payload version, and optional workspace/session scope.

Important event types:

```text
workspace_opening
workspace_ready
session_created
session_updated
run_started
run_progressed
run_waiting_for_input
run_completed
run_failed
run_cancelled
transcript_items_appended
interaction_created
interaction_resolved
child_session_created
catalog_changed
authorization_changed
```

The phone stores the latest cursor, requests replay after reconnect, deduplicates
by event ID, and requests a full snapshot if replay is unavailable.

## 7. Security invariants

- The Mac authorizes every read and mutation.
- The QR code never contains a long-lived bearer credential.
- Re-pairing invalidates the previous phone credential.
- LAN command/transcript traffic is encrypted and identity-verified.
- Secrets are entered through secure fields and are never persisted or logged.
- Push payloads contain no plaintext secrets, prompts, paths, commands, or raw
  transcript data.
- The relay cannot execute commands and is not an authoritative data source.
- Mobile uses immutable workspace IDs, never filesystem paths, as authority.
- Danger mode is explicit, visible, temporary by default, and desktop-enforced.
- Desktop remains functional and agents continue running without the phone.

## 8. Validation plan

### Shared protocol tests

- Codable round trips for snapshots and events
- Authority ordering and session-scoped grants
- Limited-grant expiration
- Secret interaction has no answer value
- Event sequence monotonicity
- Duplicate event suppression
- Replay window behavior
- Snapshot fallback for stale cursors
- Latest-state event coalescing under a large fleet projection batch

### Desktop tests

- Pairing exchange, expiration, rotation, and revocation
- One-device enforcement
- Authorization at the command boundary
- Workspace ID activation when workspace is closed
- Existing-window reuse and automatic tab resolution
- Event publication/coalescing
- App restart and reconnect behavior
- Cancellation, resume, approval, and question state transitions

### Mobile tests

- QR parsing and identity verification
- Keychain persistence and credential invalidation
- Bonjour/direct-address discovery
- Snapshot reducer and event deduplication
- Replay-to-snapshot fallback
- Network loss, network change, and Mac restart
- Notification deep-link and LAN resync
- Secure input never entering local history or logs

### Integration validation

Use the CE debug app and `rpce-cli-debug` for desktop behavior. Validate the
real app/gateway path after focused unit tests; do not treat a mock transport or
an unrelated product build as evidence for the CE desktop implementation.

## 9. Implementation record

The original Phase 0/Phase 1 coding task is complete in the working trees:

1. ~~Create/configure the desktop fork `bobtheitguy31337/repoprompt-ce` as `origin`.~~ Done.
2. ~~Configure the mobile GitHub remote and CI.~~ Done.
3. Extract the shared Remote contract into a Foundation package. Done locally;
   tagging remains a publishing/release step.
4. Inventory and document the existing Agent Mode/session/workspace owners. Done.
5. Define `WorkspaceCatalogService`, `WorkspaceActivationService`, and
   `RemoteStateProjectionService` protocols. Done.
6. Implement a desktop-only snapshot builder backed by current saved workspace
   and session state. Done.
7. Add a test fixture that produces a complete Fleet snapshot with live,
   waiting, failed, completed, and child sessions. Done.

Provider credentials, relay deployment, package tagging, and Android FCM
registration remain deliberate release/deferred work; they are not required to
change the LAN authority boundary or the iOS client contract.

## 10. Definition of first usable release

The first usable release is complete when a user can:

1. Enable Remote on a Mac.
2. Pair exactly one iPhone securely using the QR code.
3. See every saved workspace and active/persisted Agent Mode session.
4. See live Fleet status and reconnect without stale-state confusion.
5. Open a conversation and answer a question or approval.
6. Start, follow up, steer, cancel, and resume a text-only Agent Mode run.
7. Receive a safe “Agent needs you” notification while the app is suspended.
8. Revoke or re-pair the phone and observe the old credential stop working.

The Mac must remain the sole executor, security boundary, and source of truth
throughout all of these flows.
