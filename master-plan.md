# RepoPrompt Remote — Master Plan

Status: foundation established; read-only end-to-end vertical slice is next.

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

GitHub topology:

- `origin`: `https://github.com/bobtheitguy31337/repoprompt-ce.git` — your fork
- `upstream`: `https://github.com/repoprompt/repoprompt-ce.git` — canonical source

The fork has been created and the local checkout has been configured with this
topology. The fork has push access for the connected account.

Current branch: `codex/remote-control-foundation`, based on upstream `main` at
`80d2e4c`. At the time of the latest fetch, `upstream/main` was `c82143ce`, so
this feature branch needs an explicit update/rebase decision before publishing.

Implemented foundation:

- [x] `RemoteProtocol` version and `/remote/v1` path
- [x] Codable/Sendable remote snapshot DTOs
- [x] Desktop, connection, workspace, session, attention, workflow, and agent summaries
- [x] Ordered authority levels and session-scoped temporary grants
- [x] Typed remote event envelope and event types
- [x] Actor-backed bounded event replay buffer
- [x] Duplicate event-ID suppression
- [x] Snapshot fallback when the replay cursor is too old
- [x] Secret-safe interaction summary shape
- [x] Focused shared-target test target
- [x] Architecture/security notes in `docs/architecture/remote-control.md`

Files added or changed:

- `Sources/RepoPromptShared/Remote/RemoteModels.swift`
- `Sources/RepoPromptShared/Remote/RemoteEventReplayBuffer.swift`
- `Tests/RepoPromptSharedTests/RemoteContractTests.swift`
- `Package.swift`
- `docs/architecture/remote-control.md`

Not implemented yet:

- Remote settings UI
- Opt-in listener or HTTPS/TLS gateway
- Bonjour advertising
- QR pairing and credential storage/rotation
- Desktop remote authorization enforcement
- Snapshot projection from live RepoPrompt state
- Workspace activation by immutable workspace ID
- Remote command endpoints
- Live event publication from agent/workspace state
- Transcript detail endpoint/stream
- Push relay integration
- Launch-at-login and active-run sleep prevention

### Mobile repository

Path: `/Users/jared/Projects/repoprompt-remote`

Current branch: `main`

Current commit: `719986c` — `Initialize RepoPrompt Remote iOS shell`

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

The pairing flow currently uses a clearly marked simulated-pairing action. No
production network behavior is implied by the shell.

Not implemented yet:

- QR camera scanning
- Bonjour discovery
- TLS identity verification/pinning
- Keychain credential storage
- Snapshot fetching and decoding
- Event cursor persistence and replay
- Real fleet/session/project/history data
- Remote command client
- Push notification registration and deep links

### GitHub/repository state

The mobile repository is currently local and has no configured Git remote. Add
the intended GitHub remote before publishing or opening a pull request.

The desktop checkout is now configured as a fork-based contribution checkout:

```sh
origin   https://github.com/bobtheitguy31337/repoprompt-ce.git
upstream https://github.com/repoprompt/repoprompt-ce.git
```

Publishing remains a separate deliberate step after the implementation is
review-ready. Before publishing, decide whether to rebase this branch onto the
newer `upstream/main`; do not rewrite history or force-push without explicit
approval.

## 5. Master implementation roadmap

### Phase 0 — Repository and protocol ownership

Goal: make the two-repository boundary explicit and buildable.

- [ ] Create/configure the GitHub remote for `repoprompt-remote`.
- [ ] Decide where the shared Foundation protocol package is versioned.
- [ ] Preferred direction: extract the Remote DTOs into a small versioned,
      platform-neutral Swift package consumed by desktop and mobile.
- [ ] Add CI for the iOS simulator build and protocol tests.
- [ ] Add a compatibility policy for protocol versions and minimum app versions.

Exit criteria: both repositories build in CI, and the mobile app does not own a
second incompatible copy of the Remote protocol.

### Phase 1 — Shared desktop control services

Goal: expose existing RepoPrompt behavior through typed application services.

- [ ] Inventory current Agent Mode lifecycle, interaction, transcript, workflow,
      Context Builder, workspace, window, tab, and history owners.
- [ ] Define service protocols and DTO boundaries below the UI/MCP adapters.
- [ ] Implement workspace catalog over every saved workspace, not only open ones.
- [ ] Implement workspace activation using immutable workspace ID.
- [ ] Reuse existing window when possible; otherwise open and wait for readiness.
- [ ] Resolve/create the appropriate compose tab automatically.
- [ ] Project existing Agent Mode status into `RemoteSessionSummary`.
- [ ] Project parent/child session relationships and attention items.
- [ ] Add focused tests for restart, cancellation, waiting-for-input, and
      workspace-not-open cases.

Exit criteria: a typed in-process service can produce an authoritative remote
snapshot without going through serialized MCP requests.

### Phase 2 — Desktop read-only Remote Gateway

Goal: complete the first real end-to-end vertical slice.

- [ ] Add opt-in Remote settings section.
- [ ] Add one-device pairing state and device management UI.
- [ ] Implement local HTTPS/TLS listener without modifying Unix-socket MCP.
- [ ] Implement Bonjour advertisement and QR direct-address fallback.
- [ ] Store/rotate/revoke the device credential securely.
- [ ] Verify desktop identity during pairing and reconnect.
- [ ] Enforce Observe authority on every read endpoint.
- [ ] Implement `/pair`, `/snapshot`, and resumable `/events`.
- [ ] Publish coarse fleet events; reserve detailed streaming for the viewed
      conversation.
- [ ] Add connection diagnostics and bounded error responses.

Exit criteria: a real paired iPhone can reconnect to a running Mac and render
Fleet, Projects, and persisted session state from a complete authoritative
snapshot.

### Phase 3 — Mobile read-only client

Goal: replace the shell with a reliable remote viewer.

- [ ] Implement QR scanning.
- [ ] Implement Bonjour discovery and QR direct-address fallback.
- [ ] Store the device credential in iOS Keychain.
- [ ] Verify the desktop certificate/public-key identity.
- [ ] Implement URLSession HTTPS client.
- [ ] Implement snapshot reducer and event cursor persistence.
- [ ] Replay events after reconnect and request snapshot fallback when required.
- [ ] Implement workspace list, session list, history search, and transcript read.
- [ ] Add live connection/reconnect/error state to the UI.

Exit criteria: killing/restarting the app, changing networks, or restarting the
Mac never causes the phone to display stale state as authoritative.

### Phase 4 — First mutation and control loop

Goal: prove desktop-enforced control with one complete mutation path.

- [ ] Implement `start Agent Mode run` by workspace ID.
- [ ] Resolve closed workspace activation automatically.
- [ ] Return session ID and live status to mobile.
- [ ] Enforce Control authority at the desktop command boundary.
- [ ] Add text follow-up.
- [ ] Add answer-question and lower-risk approval flows.
- [ ] Add secure secret-input submission with no persistence/logging.
- [ ] Add steer, cancel, and resume.

Exit criteria: mobile can start and control a real Agent Mode run while the Mac
remains the only execution environment, including phone disconnect/reconnect.

### Phase 5 — Context Builder and full conversation operations

- [ ] Add Context Builder plan/review/question/configured flows.
- [ ] Add built-in and custom workflow catalogs.
- [ ] Add full historical transcript loading.
- [ ] Add sanitized tool cards with explicit Show details.
- [ ] Add raw commands, tool arguments, results, reasoning, file/worktree, and
      approval details only behind explicit detail expansion.
- [ ] Add parent/child agent navigation and hierarchy visualization.
- [ ] Add merge/conflict and worktree summaries without mobile worktree editing.

Exit criteria: the mobile conversation view covers the agreed operational level
of desktop Agent Mode without duplicating desktop lifecycle logic.

### Phase 6 — Notifications and desktop availability

- [ ] Add APNs registration for iOS and FCM registration for Android later.
- [ ] Implement encrypted notification envelopes.
- [ ] Support input, approval, completion, and failure notification categories.
- [ ] Deep-link notifications to a session and resync over LAN.
- [ ] Add launch-at-login setting.
- [ ] Add active-run sleep assertion only while agents are active or waiting for
      input.
- [ ] Add network-change, desktop-restart, credential-revocation, and
      notification diagnostics.

Exit criteria: a suspended phone receives a safe attention notification and
opens the authoritative session after reconnecting to the Mac.

### Phase 7 — Hardening and release readiness

- [ ] Threat model pairing, TLS identity, credential rotation, and push relay.
- [ ] Test replay gaps, duplicate events, stale cursors, and snapshot fallback.
- [ ] Test one-device enforcement and revocation.
- [ ] Test cancellation and partial-success behavior for every mutation.
- [ ] Test workspace activation when windows/tabs are absent or closing.
- [ ] Load-test fleet projection and event coalescing with many sessions.
- [ ] Add protocol compatibility tests across supported versions.
- [ ] Add macOS and iOS release packaging/signing configuration.
- [ ] Prepare user-facing setup, diagnostics, and security documentation.

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
generic production RepoPrompt app as evidence for CE behavior.

## 9. Immediate next coding task

Implement Phase 0 and the beginning of Phase 1:

1. ~~Create the GitHub fork `bobtheitguy31337/repoprompt-ce`.~~ Done.
2. ~~Configure the desktop checkout with fork `origin` and canonical `upstream`.~~ Done.
3. Configure the mobile GitHub remote and CI.
4. Extract the shared Remote contract into a versioned Foundation package.
5. Inventory and document the existing Agent Mode/session/workspace owners.
6. Define `WorkspaceCatalogService`, `WorkspaceActivationService`, and
   `RemoteStateProjectionService` protocols.
7. Implement a desktop-only snapshot builder backed by current saved workspace
   and session state.
8. Add a test fixture that produces a complete Fleet snapshot with live,
   waiting, failed, completed, and child sessions.

Do not begin push notifications, WAN transport, mobile editing, or broad UI
polish until the read-only paired snapshot and reconnect path is real.

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
