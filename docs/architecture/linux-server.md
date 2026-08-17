# RepoPrompt Linux Server Authority

Status: operator-only standalone boot (2026-08-17). The 2026-08-09 E0–E6 extraction remains the architectural baseline.

`RepoPromptServer` is a non-UI Swift executable and the only writer for one server state database. The executable parses environment configuration and delegates to `RepoPromptServerRunner`; domain and transport logic do not live in the executable target. Chat collaboration is an optional HMAC adapter. First-run operator password login is enough to serve `/portal`. Mutual TLS remains optional for production.

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
- Concurrent projects keep distinct tool authorities, worktrees, selection templates, and project-filtered events. Tree/search/file and worktree lookup fail closed on a foreign root or binding ID instead of falling back to another active project.
- `SessionAuthority` serializes commands and retains generation, turn-epoch, connection-generation, and exactly-once terminal gates.
- `LocalFilesystemAuthority` resolves symlinks and verifies every logical path remains inside an authorized root.
- External commands are root-session only. Child creation remains an internal runtime operation.
- `ProviderRegistry` accepts executable paths only from immutable service configuration. `ProviderProcessSupervisor` signals only identities that still match recorded process evidence.

## Persistence

`RepoPromptServicePersistence` uses SQLiteNIO 1.13.0. Startup enables foreign keys, WAL, `synchronous=FULL`, and a five-second busy timeout, applies checksum-addressed schema migrations through **schema v6**, and runs `PRAGMA quick_check` before readiness.

The v1 migration creates the complete E4 table inventory: service metadata, projects and roots, templates and selections, sessions/agents/runs, worktrees, workflows, process families/members, interactions, execution permissions, contexts/transcripts/events, artifacts/owned resources, snapshots, idempotency, nonces, audit, and migrations. Project/session snapshots, transcript rows, canonical events, and idempotency results publish in one `BEGIN IMMEDIATE` transaction. Global sequence allocation is store-scoped. Restore activation assigns a fresh `store_id` and records provenance.

## Internal service

- Mutual TLS 1.3 listener: `0.0.0.0:9443` by default.
- Content-free loopback health listener: `127.0.0.1:9080`.
- Roles encode as `app`, `sync`, and `repoprompt-operator`. First-run portal login is an operator password. Mutual TLS and integration HMAC files are optional; omit them for a local password-mode boot.
- Requests use canonical method/path/timestamp/nonce/body/decision/key-ID HMAC input.
- Nonces persist before dispatch and reject replay.
- Human operations require a separately signed, operation/request/target-bound authorization decision with a maximum 30-second lifetime. When that decision is present, Linux binds it (operation, actor, target, digest, expiry, and collaboration revisions) and does not re-evaluate local creator/controller/steering eligibility. Standalone portal, operator MCP, and unsigned in-process callers still use local host policy.
- Agent Models persist as a global profile plus optional per-project envelopes. The project key is the Linux multi-user substitute for Desktop’s window workspace. Inheritance still matches Desktop: inherit uses the global profile even when a leftover project snapshot exists; switching to override materializes from that leftover or from global; global writes store `inheritGlobal` rather than `projectOverride`; and copy is bidirectional (`copy-global` and `copy-project`).
- SSE subscribes before replay, drains durable pages to a captured watermark, deduplicates the bounded live buffer by global sequence, and emits signed application-framed events; lagging subscribers are disconnected with a reconnect cursor.
- Cursor namespace changes or replay-floor violations return the stable `cursor_expired` contract.
- Thin-client composer surfaces stay on the internal API: `catalog/composer-suggestions`, project `composer-attachments` stage/resolve/preview/delete, and turn/start `attachmentIds` / `taggedFiles` / `resolvedSuggestionTokens`. A chat host forwards those instead of owning a leftover composer store.

Provider and Git credentials are not accepted through HTTP and are never stored in the service database. Secret values are loaded from files; the executable does not print them.

Provider executable settings define the server-side catalog, not execution enablement. `REPOPROMPT_ENABLED_PROVIDERS` is the closed comma-separated allowlist of catalogued provider IDs (`codex`, `claudeCompatible`, `openCodeACP`, and `cursorACP`); unset or empty means no provider is enabled. Only allowlisted providers are preflighted for readiness and accepted for runs; disabled provider controllers perform startup cleanup only. Credential-home presence or contents never enable a provider implicitly, while catalogued disabled providers remain visible as unavailable and reject execution with `provider_unavailable`.

`REPOPROMPT_ENABLED_DIRECT_PROVIDERS` is the matching closed allowlist for direct HTTPS adapters (`openAIAPI`, `anthropicAPI`, `openRouter`, `customOpenAICompatible`, `gemini`, `azure`, `deepseek`, `fireworks`, `xAI`, `groq`, `zAI`, `ollama`). Unset or empty admits none. Deployment admission and the per-provider enabled bit stay Linux extensions; they do not replace Desktop’s key/URL fail-closed contract.

Direct-provider egress stays a public-HTTPS SSRF gate: custom/OpenAI/Azure URLs must be `https` on 443 to a public hostname, and every resolved address must be public. Desktop’s local URLs (Ollama default `http://localhost:11434`, custom or OpenAI loopback bases) persist, but execute remains fail-closed unless the operator sets `REPOPROMPT_ALLOW_LOCAL_PROVIDER_URLS=1`. That escape unlocks only `localhost` / `127.0.0.0/8` / `::1` (HTTP or HTTPS, any port). RFC1918, link-local, metadata, and DNS answers that are not entirely loopback stay rejected. TLS verification is not relaxed.

Project tree/search live-read `AdvancedServerSettings` with Desktop ignore mapping: `.gitignore` always loads, `respectRepoIgnore` gates `.repo_ignore` only, `respectCursorIgnore` gates `.cursorignore`, and missing `showEmptyFolders` is off. App-wide `globalIgnoreDefaults` persist on the same document (empty disables). Nested ignore files follow `respectNestedIgnoreFiles`. `followSymbolicLinks` remains the inverse of Desktop `skipSymlinks` (default false = skip).

`codeMapsGloballyDisabled` is the Desktop disable flag (missing → false, maps on). `codeMapsEnabled` remains the inverse for existing portal/API. When disabled, copy/chat usage remaps to `.none` without mutating presets, existing `.codeMap` selection entries package as full files, generate/`get_code_structure` fail closed with `codemaps_disabled`, and selection demote is rejected.

`historyIdleThresholdMinutes` matches Desktop: missing → **10**, persist clamps **0–1440**, and omitted MCP `idle_threshold_minutes` uses that stored default. Explicit overrides outside 0–1440 fail closed (no clamp). `history` `time` and `list_sessions` count consecutive transcript gaps **≤** the threshold and add **0** for longer idle gaps.

MCP `app_settings` get/set for `file_system.*`, `code_maps.globally_disabled`, `ui.appearance_mode` / `ui.font_scale` / `ui.show_tooltips` / `ui.enable_keyboard_shortcuts`, plus the already-wired packaging/temperature keys, write the same advanced document. `file_system.skip_symlinks` stays the inverse of `followSymbolicLinks`. Headless appearance apply is a no-op; persist still round-trips for thin clients. Font scale allowlist is Desktop’s 14 / 16 / 18. Portal Advanced live-reads/writes those same fields (history idle 0–1440, global ignore defaults, app appearance). The Portal Appearance cookie stays browser-local chrome and is not a substitute for the engine keys.

Agent Models scope is a Linux multi-user extension keyed by **project**, not a Desktop window workspace. Inherit/override still matches Desktop: `inheritGlobal` tracks the global profile while keeping any leftover project snapshot; `projectOverride` uses the project snapshot and, when that snapshot is missing, copies global. Copy is bidirectional (`copy-global` and `copy-project`) with dual revision fences. Global writes store `inheritGlobal` rather than `projectOverride`.

## Image contract

`Dockerfile.server` builds only `RepoPromptServer`, runs it as fixed UID/GID 65532, includes `tini` and `curl`, and retains image metadata for both fixed ports: `9443/tcp` is the mTLS internal API and `9080/tcp` is the loopback-only health listener used by the image probe. OCI labels use `io.repoprompt.*` (`schema-version=6`). Deployments must not publish 9080. Compose must still set read-only root, dropped capabilities, no-new-privileges, resource/PID/log bounds, persistent state/project/worktree/cache volumes, internal networks, and runtime secret mounts.

## Validation

```sh
make dev-server-build
make dev-server-test
docker build -f Dockerfile.server .
```

Ubuntu 24.04 runs the same build and focused tests in `.github/workflows/linux-server.yml`.

## Known extraction boundary

This baseline establishes the reusable target, persistence, protocol, supervision, and service boundaries. The existing macOS `AgentModeViewModel` and direct-headless MCP implementation have not yet been cut over to these targets; see the fork-delta ledger for the explicit remaining convergence work.

Collaboration eligibility for signed HTTP callers is owned by the authorization decision. Linux binds the decision to the operation, request digest, actor, target, expiry, and collaboration revisions (or the exact next revisions for `setSessionVisibility` / `setCollaborativeSteering`). A verified decision is not re-checked against stored creator/controller/steering flags. Unsigned callers (portal operator mTLS, MCP, in-process tests) still use local host policy: session creators own visibility and steering writes, the current controller owns other mutations, and `sendFollowup` / `submitTurn` / `steerSession` may be performed by non-controllers only when the session is collaborative and collaborative steering is enabled. `buildContext` stays a view operation. HMAC identities encode as `app` / `sync` / `repoprompt-operator`.


# RepoPrompt Server web portal

The standalone portal is a RepoPrompt-owned operator surface served by
`RepoPromptServer` at `/portal` on the existing operator-mTLS listener. It is
independently usable. Chat integration can use API, SSO, or deep links
without becoming the portal's UI or orchestration authority.

## Desktop-to-web product map

The macOS application remains the product and visual source of truth. This
first server slice maps the following surfaces rather than introducing a
generic administration dashboard:

| Portal surface | Desktop source | Ported hierarchy/treatment |
| --- | --- | --- |
| Window shell and toolbar | `AgentModeView.swift`, `ContentViewToolbarContent.swift` | Compact title bar; sessions, transcript, and runtime-context regions; toolbar control groups |
| Workspace entry | `WorkspaceLandingView.swift`, `ManageWorkspacesView.swift` | Recent-workspace language, translucent cards, 16/20/32 spacing, 16-point outer radius |
| Agent sessions | `AgentSessionsSidebarView.swift`, `AgentModeDetailWithSidebarView.swift` | Search, dated session groups, workspace roots, transcript-centered detail |
| Empty transcript | `AgentEmptyStateViews.swift` | “What are we building?” and the RepoPrompt workflow cards |
| Tool activity | `ToolCardContainer.swift`, `CompressedToolGroupCard.swift` | Dense 12-point tool cards, status tint, compressed grouped rows |
| Composer | `ComposerChrome.swift` | Rounded input chrome and attached model/context controls |
| Settings navigation | `SettingsView.swift` | Fixed searchable sidebar and detail pane in canonical order: Agent Mode, General, MCP, Models & Providers/API, Workspaces, Copy & Chat |
| Provider cards | `CLIProvidersSettingsView.swift` | Collapsible Codex, Claude Code, OpenCode, and Cursor cards with compact connection capsules |
| Model defaults | `AgentModelsSettingsView.swift`, `AIModelDropDown.swift` | One server-owned model/default source, grouped providers, unavailable states, capability-gated controls |

The CSS spacing scale is deliberately limited to 4, 6, 8, 10, 12, 16, 20,
24, and 32 pixels. Typography follows `FontPreset.swift`: system-rounded body
faces at 14/16/18-point bases and a platform monospace stack for code. Status,
transcript, user-bubble, reasoning, and tool colors are semantic ports of
`BubbleColors.swift`, including light and dark appearances.

## Asset and platform substitution ledger

| Desktop material | Web result | Reason |
| --- | --- | --- |
| `AppResources/AppIcon.icns` | `Resources/Portal/repoprompt-icon.png` (1024×1024) | Export of the repository artwork, not an approximation |
| SF Symbols | Small hand-authored semantic line SVGs in `portal.js` | SF Symbols are platform assets and are not claimed as portable. Equivalents preserve glyph meaning, 16-pixel sizing, rounded line caps, and approximately 1.75-point visual weight. No third-party icon package is used. |
| SwiftUI/macOS materials | `backdrop-filter` translucent surfaces plus semantic opaque fallbacks | Preserves native-material depth without depending on AppKit |
| Apple system-rounded/monospace | `ui-rounded`/system and `ui-monospace` stacks | Faithful web-native fallback when the platform fonts are unavailable |

No screenshots or generated imitation artwork are part of this port.

## Runtime and browser contract

Portal pages load without a client certificate. APIs require either an
operator password session or a client certificate mapped to
`repoprompt-operator` / `app`. First-run setup creates the operator password
on `/portal/`. Operator mTLS remains optional for production:
settings and agent surfaces do not require a chat peer, integration HMAC, or a
reverse proxy. Browser code never receives an internal HMAC key or client
certificate. The browser is a thin renderer over Swift-owned
services and does not persist application state in local or session storage
beyond the HttpOnly operator session cookie. Assets and API
URLs are path-relative so a same-origin gateway can preserve the complete
RepoPrompt-owned HTML/CSS/JavaScript surface beneath `/portal/`. Mutations
additionally require an exact HTTPS
same-origin match against the request authority, same-origin Fetch Metadata
when supplied, JSON content, and the portal's non-secret custom CSRF header;
cross-origin forms cannot create provider or auth-flow mutations. All HTML,
JSON, and error metadata is served with `private, no-store`.

Current endpoints:

- `GET /portal/api/v1/bootstrap` — sanitized project, session, and workflow
  navigation summaries. Project root paths and transcript bodies are omitted.
- `GET /portal/api/v1/provider-settings` — browser-safe provider status,
  executable health/version, model catalogs, and capabilities.
- `PATCH /portal/api/v1/provider-settings/:id` — revisioned replacement of
  non-secret enabled/default/effort/speed/tier preferences.
- `GET` / `PATCH /portal/api/v1/provider-settings/:id/direct-configuration` —
  revisioned non-secret `DirectProviderConfiguration` (URL, tokens, allowlist,
  headers, API version). Credentials stay on the connection APIs.
- `POST /portal/api/v1/provider-settings/:id/auth-flows` — narrow server-side
  auth-flow seam. A device code, if an adapter is installed later, is returned
  only in the initiating operator response with `no-store` and is held only in
  transient DOM.

Provider secrets, access and refresh tokens, API keys, credential files, key
helper output, raw CLI logs or version-probe text, and raw provider
authentication endpoints are not
represented by the DTOs, SQLite schema, events, transcripts, URLs, or browser
persistence. Authentication status can be supplied through an explicitly
sanitized server-side status document; its path and source contents are never
returned.

Optional absolute-path inputs are
`REPOPROMPT_{CODEX,CLAUDE,OPENCODE,CURSOR,XAI}_AUTH_STATUS_FILE` and
`REPOPROMPT_{CODEX,CLAUDE,OPENCODE,CURSOR,XAI}_MODEL_CATALOG_FILE`. Auth status
documents accept authenticated/method/expiry fields. Free-form account labels
and detail text are ignored even if present, and the browser receives only a
fixed status summary;
model documents accept only the browser-safe catalog DTO. They are projections
generated by trusted server provisioning, never provider credential files or
raw provider responses.

Provider homes remain isolated through the native runtime configuration:
Codex uses a separate `CODEX_HOME`, Claude Code uses a separate
`CLAUDE_CONFIG_DIR`, and ACP providers retain their isolated process homes.
OpenCode models and optional variants/effort/tier are admitted only from the
sanitized capability catalog; the portal does not proxy OpenCode auth. Direct
API providers, including xAI, persist non-secret configuration through
`DirectProviderConfiguration`; API keys stay in the vault and connection APIs.
Deployment configuration is an immutable provider ceiling. Effective admission
requires deployment permission, the operator's revisioned enablement, and a
successful runtime preflight; the browser displays those states separately.
`REPOPROMPT_ENABLED_PROVIDERS` defines that ceiling, so a portal operator may
disable and later re-enable an allowed provider but cannot activate a runtime
the deployment did not approve.

## Deliberate first-slice boundaries

- Native browser OAuth/device-flow coordinators are seams, not mock flows; the
  UI describes unavailable flows until a server adapter is installed.
- Codex defaults and ACP model selection are applied by the Swift provider
  dispatcher. Claude effort is passed through its isolated environment.
- Claude fast-mode wiring and live provider model discovery remain open.
- Project/workspace creation, live transcript streaming, context selection,
  workflow execution, MCP settings, and the remaining settings detail pages are
  represented in navigation but are not yet editable.

The next executable slice is the transcript vertical: session selection and
creation, replay plus live event streaming, desktop-fidelity transcript/tool
groups, composer submission, and runtime-context inspection, all backed by the
existing Swift authority and event stream.
