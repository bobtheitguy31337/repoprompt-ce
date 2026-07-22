# Remote control architecture

RepoPrompt Remote is a RepoPrompt-specific control protocol for a paired mobile
client. It is not a network version of the existing Unix-socket MCP transport.

## Shared contract

The contract lives in the Foundation-only Swift package at
`Packages/RepoPromptRemoteProtocol/` in the `repoprompt-remote` repository. The
desktop target consumes it through the local development dependency declared in
`Package.swift` and re-exports it from
`Sources/RepoPromptShared/RemoteProtocolExports.swift`. This keeps the same
types available to the macOS gateway, iOS client, future Android client, and
protocol tests without importing the desktop UI or MCP implementation.

`RemoteSnapshot` is the authoritative fleet projection sent after pairing and
on reconnect. It contains desktop and connection state, authorization, all saved
workspaces, live or persisted sessions, attention items, workflow and agent
catalogs, and the last event cursor.

`RemoteEvent` is a versioned, RepoPrompt-specific event envelope. Every event
has a desktop instance ID, monotonic sequence number, event ID, timestamp, event
type, and optional workspace/session scope. The event payload is typed and does
not provide a generic MCP or arbitrary JSON escape hatch.

`RemoteEventReplayBuffer` is a bounded actor-owned buffer. A reconnect requests
events after the mobile cursor. If the cursor is older than the retained range,
the gateway must return a complete snapshot before resuming live events. Event
IDs are deduplicated so retries cannot apply the same event twice.

The current wire surface includes:

- `POST /remote/v1/pair`
- `GET /remote/v1/snapshot`
- `GET /remote/v1/events?after=<cursor>`
- `GET /remote/v1/workspaces`
- `GET /remote/v1/sessions`
- `GET /remote/v1/agents`
- `GET /remote/v1/workflows`
- `GET /remote/v1/diagnostics`
- `GET /remote/v1/history?q=<query>&limit=<n>`
- `GET /remote/v1/transcript?session_id=<id>&after=<sequence>&limit=<n>&details=1`
- `POST /remote/v1/commands`
- `POST /remote/v1/context-builder`

The gateway emits coarse workspace, session, run-state, interaction, and
authorization/catalog events from the same authoritative projection used for
snapshots. Transcript rows are paged separately so the fleet stream stays
bounded. Tool arguments/results, reasoning, file/worktree key paths, process
metadata, and approval-adjacent details are only returned when the client
explicitly requests `details=1`; common credential fields are redacted before
returning them.

## Authorization

The desktop remains the authorization boundary. `RemoteAuthorizationState`
models the default device authority and an optional temporary/session-scoped
grant. Mobile controls may be hidden or disabled for usability, but the desktop
must evaluate the required authority again when it executes each command.

The levels are intentionally ordered:

| Level | Meaning |
| --- | --- |
| `observe` | Read state, transcripts, and history |
| `respond` | Answer questions, approve lower-risk interactions, send follow-ups |
| `control` | Start, steer, cancel, resume, workflows, and Context Builder |
| `danger` | High-risk, destructive, unrestricted, or cleanup actions |

Secret interactions are represented by `RemoteInteractionSummary` only as a
pending secure-entry prompt. No answer value is present in a snapshot, event,
history record, search index, or push payload. The command endpoint accepts the
secret as a one-shot request body and excludes it from its response and all
remote projections.

## Gateway boundary

The desktop implementation now lives below the app/UI layer in
`Sources/RepoPrompt/Infrastructure/Remote`:

```text
RemoteGatewayController
  ├── pairing and device credential store
  ├── desktop-enforced authorization
  ├── snapshot projection
  ├── HTTPS JSON snapshot/catalog/history/transcript/diagnostics endpoints
  ├── HTTPS JSON command endpoint
  ├── resumable event stream and replay buffer
  └── encrypted notification envelope + configurable relay client
        │
        ▼
shared typed RepoPrompt control services
        │
        ▼
existing Agent Mode, Context Builder, workspace, and history services
```

The gateway does not call MCP providers through serialized tool requests. It
uses `RemoteSnapshotBuilder`, `WindowRemoteReadService`, and
`WindowRemoteAgentControlService` to call typed application services directly.
The command boundary rechecks authorization before dispatching Agent Mode
start, follow-up, steer, response, cancel, and resume operations.

The gateway is opt-in and LAN-only. Bonjour is used for discovery, while the
pairing QR code also carries a direct-address fallback and desktop certificate
fingerprint. The QR code contains a short-lived, one-time pairing secret, never
a long-lived bearer credential. The desktop stores the generated PKCS#12 TLS
identity and the single paired-device credential in separate Keychain records.

## Delivery order

1. Extract typed control services and implement a snapshot projection from
   existing Agent Mode and workspace state.
2. Add the opt-in desktop listener, pairing, credential rotation, snapshot and
   command endpoints, and replayable event stream.
3. Build the separate iOS client against this shared contract.
4. Add Context Builder/workflow operations and explicit detail expansion on top
   of the established command/read boundaries. Context Builder clarify,
   question, plan, and review flows now use the desktop window-tool service;
   richer raw command/reasoning/file/worktree details are now available only
   through the explicit detail request.
5. Register iOS notification tokens and forward only encrypted, sanitized
   envelopes through a configured APNs/FCM-compatible relay; the phone always
   reconnects to the desktop for authoritative state.

## Current owner inventory

The first typed service seam is implemented in
`Sources/RepoPrompt/Infrastructure/Remote/RemoteControlServices.swift`.
Adapters currently read the following existing owners without routing through
serialized MCP requests:

| Remote concern | Current desktop owner | Adapter boundary |
| --- | --- | --- |
| Saved workspaces and immutable IDs | `WorkspaceManagerViewModel.workspaces` and `WorkspaceModel` | `WorkspaceManagerRemoteCatalogService` |
| Closed/open workspace state | `WindowStatesManager` plus `WorkspaceManagerViewModel` | `WorkspaceManagerRemoteCatalogService` |
| Workspace activation | `WorkspaceManagerViewModel.switchWorkspace(to:saveState:reason:)` | `WorkspaceManagerRemoteActivationService` |
| Compose-tab identity | `WorkspaceModel.composeTabs` and `activeComposeTabID` | workspace DTOs and activation result |
| Live Agent Mode state | `AgentModeViewModel.sessions` and `AgentModeViewModel.TabSession` | `AgentModeRemoteSessionQueryService` |
| Persisted session index | `AgentModeViewModel.sessionIndex` / `AgentWorkspaceSessionIndexStore` | `AgentModeRemoteSessionQueryService` |
| Parent/child relationships | `AgentSessionIndexEntry.parentSessionID` | snapshot builder child projection |
| Context-safe interaction state | `TabSession.pendingAskUser`, `pendingUserInputRequest`, `pendingMCPElicitationRequest`, and `pendingApproval` | `RemoteInteractionSummary` with no answer data |
| Window reuse | `WindowStatesManager.findWindowState(showing:)` | activation result |

`RemoteSnapshotBuilder` is intentionally fed only value-type records. This
keeps path sanitization, run-state normalization, interaction redaction, and
parent/child projection testable without constructing a provider process or a
serialized MCP request. `RemoteSnapshotProjectionTests` provides the fixture
coverage for live, waiting, failed, completed, and child sessions, including a
closed saved workspace.

The current gateway aggregates the saved workspace catalogs and session indexes
from all available desktop windows, exposes the paired snapshot/event/read
surfaces above, and returns `snapshot_required` when a requested cursor is older
than the bounded replay buffer. Built-in and custom workflows are projected
  from `AgentWorkflowStore`; selected workflow starts use the desktop template
  without sending workflow contents to the phone. Launch-at-login and active-run
  sleep prevention are wired into Remote availability settings. Notification
  registration, envelope encryption, attention categories, deep-link routing,
  network monitoring, and gateway diagnostics are implemented; deploying a
provider-backed relay URL remains environment configuration rather than a
desktop runtime dependency.

The security threat model, residual risks, and release gates are maintained in
the companion mobile repository at
`docs/security/remote-threat-model.md`. The two implementation repositories are
the agreed `bobtheitguy31337/repoprompt-ce` desktop fork and
`bobtheitguy31337/repoprompt-remote` mobile repository.
