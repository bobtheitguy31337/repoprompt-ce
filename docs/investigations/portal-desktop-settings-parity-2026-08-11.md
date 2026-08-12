# RepoPrompt CE desktop ↔ web portal settings parity audit

**Audit date:** 2026-08-11
**Final implementation audit:** 2026-08-12 correction against `origin/sandbox`
**Desktop source:** this checkout's vanilla macOS Settings implementation
**Portal source:** `RepoPromptServiceHTTP/Resources/Portal` plus typed shared-server DTO, persistence, HTTP, and runtime authorities

## Final classification rules

| Classification | Meaning |
|---|---|
| **Editable** | An authenticated revisioned mutation changes a value consumed by the shared Linux runtime or by immediate browser rendering. |
| **Live read-only** | The portal projects canonical runtime state/catalog data without inventing a mutation authority. |
| **Boundary shown** | The portal explains a desktop, deployment, trusted-client, filesystem, network, or privacy boundary and renders no `input`, `select`, or `textarea` for that boundary. |
| **Intentionally omitted** | The desktop feature has no meaningful Agent Mode web equivalent and receives no portal destination or control. |

The portal never treats legacy `[String:String]` compatibility values as authorities for typed domains. Editable controls use typed snapshots, optimistic concurrency, authenticated/CSRF-protected HTTP routes, project/root confinement, and digest-only mutation attribution. Credential values remain write-only and outside settings documents.

Every portal settings mutation uses one persistent accessible feedback contract in the settings header: `Saving…`, `Saved`, or an actionable `Save failed: … Review the setting and try again.` state. This status survives route re-rendering and remains separate from the provider catalog's `Updated …` freshness timestamp. The contract covers typed settings, retained legacy runtime settings, provider preferences/configuration/enablement, workflows, model/selection presets, and browser-local appearance.

## Preserved deployed P0 contract

- **Editable:** Codex retains its managed packaged-runtime authentication, device-code flow, advertised API-key alternative, account projection, Test Connection, Sign Out, KYC notice, provider defaults, and direct permissions.
- **Editable:** disconnected Claude Code, OpenCode, and Cursor each render one mounted-account **Connect** action.
- **Boundary shown:** those three disconnected mounted-account cards contain no password field, credential form, or authentication-method selector.
- **Editable:** Claude Code Connect posts only `{ "authenticationMethod": "providerSpecific" }`; OpenCode/Cursor use their completed provider-specific mounted-runtime contracts.
- **Live read-only:** connected mounted accounts show sanitized mounted-login state; Test Connection revalidates the mounted runtime; Disconnect never claims to mutate credential files.
- **Editable:** Claude-compatible Zai, Kimi, and custom backend forms retain write-only credentials and runtime-backed display/base/header/model behavior.
- **Live read-only:** the recommendation banner still says **Check recommendations to optimize your setup** and **Check Now** opens Agent Models.
- **Live read-only + Editable:** recommendations are server-rendered from profile `202_608`; exact rows can be applied to revisioned Agent Models profiles.
- **Live read-only:** OpenCode can trigger the banner but is never invented as an Oracle, Context Builder, or role target.
- **Live read-only:** MCP Tools renders the canonical 27-tool `MCPDomainToolCatalog` and client-side search, with no fake admission checkboxes.
- **Editable:** all runtime-backed direct Codex, Claude, OpenCode, and Cursor permission controls remain present.
- **Security:** mounted external accounts never accept browser credentials or create vault references.

## Canonical 24-destination map

| Group | Desktop destination | Portal result | Final classification |
|---|---|---|---|
| Agent Mode | Overview | Canonical navigation plus live provider/session status and runtime-backed fallback execution mode | **Editable + Live read-only + Boundary shown** |
| Agent Mode | CLI Providers | Complete deployed CLI/mounted-account/backend management | **Editable + Live read-only + Boundary shown** |
| Agent Mode | Agent Models | Typed global/project six-target routing, pins, discovery filter, server recommendations, provider defaults | **Editable + Live read-only + Boundary shown** |
| Agent Mode | Agent Permissions | Direct permissions plus typed Safe Managed/Inherit/Custom sub-agent policy | **Editable** |
| Agent Mode | Agent Workflows | Stable `rp-*` IDs/commands with desktop built-in display names, server-native definitions, visibility, feature order, clone, reload, cleanup guidance | **Editable + Boundary shown** |
| Agent Mode | Context Builder | Typed defaults/prompts plus the MCP-backed Allow Clarifying Questions control | **Editable** |
| General | Appearance | Browser-native theme and text density; desktop component controls documented | **Editable + Boundary shown** |
| General | Updates | Immutable CI/CD deployment owns server revisions | **Intentionally omitted** |
| General | Keyboard Shortcuts | Browser/global shortcut design not copied from macOS registrar | **Intentionally omitted** |
| General | Advanced | Canonical scanner, Code Maps, and history settings; local utilities documented | **Editable + Boundary shown** |
| General | Telemetry | Deployment/privacy policy owns server observability | **Intentionally omitted** |
| MCP Server | MCP Server | Shared process/catalog status; lifecycle/installers remain deployment/desktop owned | **Live read-only + Boundary shown** |
| MCP Server | Tools | Canonical 27-tool catalog and search | **Live read-only** |
| MCP Server | Workspace Approvals | Exact four desktop trusted-client workspace operations documented | **Boundary shown** |
| MCP Server | Model Presets | Typed ordered chat/plan/review model preset repository | **Editable** |
| Models & Providers | API Providers | Completed OpenAI/Anthropic direct runtime plus input-free unsupported-provider boundaries selected from live catalog truth | **Editable + Boundary shown** |
| Models & Providers | OpenRouter | Complete fixed-host configuration/vault/catalog/runtime plus a deployment-disabled input-free destination | **Editable + Boundary shown** |
| Models & Providers | Custom API | Hardened public HTTPS/443 pinned-address runtime plus a deployment-disabled input-free destination | **Editable + Boundary shown** |
| Models & Providers | Model Config | Sanitized provider model catalogs and option families | **Live read-only + Boundary shown** |
| Workspaces | Manage Workspaces | Operator-provisioned confined server projects | **Live read-only + Boundary shown** |
| Workspaces | Manage Presets | Named project selection capture/apply/rename/reorder/delete | **Editable** |
| Prompting | Chat Settings | Agent portal has no desktop built-in Chat surface | **Intentionally omitted** |
| Prompting | Workflow Presets | Desktop Copy/Chat packaging presets are not Agent Workflows | **Intentionally omitted** |
| Prompting | Copy Prompt Order | Desktop Copy/built-in Chat packaging only | **Intentionally omitted** |

`Copy Presets` and `Chat Presets` remain desktop deep-link aliases of `Workflow Presets`; they are not extra canonical destinations.

---

# Detailed final destination audit

## 1. Agent Mode → Overview

- **Live read-only:** deep links to Agent Models, Context Builder, CLI Providers, Agent Permissions, and Agent Workflows; current CLI status and workflow count.
- **Editable:** shared fallback execution mode (`Read Only`, `Workspace Write`, `Full Access`) consumed by new sessions where provider-specific policy does not override it.
- **Boundary shown:** desktop Agent Chats visibility, local conversation cleanup, titlebar handoff instructions, and local window behavior have no shared-server consumer. No inert field is rendered.

## 2. Agent Mode → CLI Providers

### Recommendation entry point

- **Live read-only:** the desktop wording and Check Now action are preserved.
- **Live read-only:** profile version is exactly `202_608` and comes from `ServerSettingsService`, not duplicated JavaScript candidate chains.
- **Editable:** exact recommendation targets apply through global/project Agent Models revision fences.
- **Live read-only:** unavailable/inexact rows remain explicit; OpenCode is not assigned.

### Codex

- **Editable:** managed auth/device code, advertised API key, Test Connection, Sign Out, provider defaults, permission level, Bash, Search, Goals, Reasoning Summaries, Local Memories, and runtime-supported MCP server state.
- **Live read-only:** account/authentication/KYC/runtime health projections.
- **Boundary shown:** desktop trace export and local executable repair.

### Claude Code

- **Editable:** one mounted-account Connect, Test Connection, Disconnect, default model/options, permission level, Bash, Strict MCP, and Lazy Tool Loading.
- **Live read-only:** fixed system-prompt packaging is `User Message (Keep Native)`.
- **Boundary shown:** terminal login, trace export, `Replace System Prompt`, and `User Message (No Native)` have no headless runtime setting.

### Claude-compatible backends

- **Editable:** CC Zai display/base/auth header and Haiku/Sonnet/Opus mapping; CC Moonshot display/base/auth and backend-managed no-model behavior; CC Custom display/base/auth and no-model or slot mapping.
- **Editable:** write-only backend credentials only where the provider advertises a completed validator.
- **Boundary shown:** no authentication selector is invented where one method is authoritative.

### OpenCode and Cursor

- **Editable:** one mounted-account Connect, ACP preflight Test Connection, Disconnect, provider defaults, and direct ACP permission behavior.
- **Live read-only:** model discovery / Auto fallback from the live runtime.
- **Boundary shown:** trace export and interactive local login.

## 3. Agent Mode → Agent Models

- **Editable:** global profile and active-project `inheritGlobal` / `projectOverride` mode.
- **Editable:** Copy Global to Project uses both observed revisions.
- **Editable:** Oracle, Context Builder, Explore, Engineer, Pair, and Design exact provider/model/effort targets.
- **Editable:** per-target pinned state.
- **Editable:** `Hide non-role models from MCP agents` drives model discovery filtering.
- **Editable:** Apply Recommended Setup updates exact unpinned targets only.
- **Live read-only:** recommendation availability/detail is computed server-side from live provider/model catalogs.
- **Runtime consumption:** root sessions, Oracle, Context Builder, all four role launches, and model discovery resolve the typed profile before launch.
- **Boundary shown:** built-in Chat synchronization/override remains desktop-only because the headless service has no built-in Chat consumer.
- **P0:** provider default cards remain runtime-backed and explicit-provider session selection retains precedence.

## 4. Agent Mode → Agent Permissions

### Direct Agents

- **Editable:** shared fallback execution mode.
- **Editable:** all Codex/Claude/OpenCode/Cursor controls listed in the preserved P0 contract.
- **Live read-only:** RepoPrompt is shown as required where the runtime requires it.

### Sub-Agents

- **Editable:** Safe Managed, Inherit Provider Settings, and Custom.
- **Editable:** custom Codex `Read Only`, `Default Permission`, `Auto Review`, `Full Access`.
- **Editable:** custom Claude `Require Approval`, `Auto-Approve Edits`, `Auto`, `Full Access`.
- **Editable:** custom OpenCode/Cursor `Managed Default`, `Full Access`.
- **Security warning:** Inherit and custom Full Access display an explicit delegated-agent warning.
- **Runtime consumption:** every child launch resolves this authority before the frozen execution-permission snapshot is created; missing/corrupt settings fail closed to Safe Managed.

## 5. Agent Mode → Agent Workflows

- **Editable:** Include Session Cleanup Guidance, create custom markdown, update custom definition/name/enabled/visible/featured state, clone built-in/custom, delete custom, show/hide, feature/unfeature, move featured earlier/later, and Reload & Revalidate.
- **Desktop-faithful projection:** stable IDs and commands remain `rp-*`, while built-ins display exactly `Plan & Build`, `Review`, `Refactor`, `Investigate`, `ChatGPT Export`, `Orchestrate`, `Optimize`, `Deep Plan`, and `Reminder`. Clone defaults and portal/server summaries use these display names; no built-in `rp-*` value is exposed as a user-facing name.
- **Security:** definitions are SQLite-owned, path-free, bounded, parsed/validated, secret-screened, and revisioned. Built-ins cannot be overwritten or deleted.
- **Runtime consumption:** visible enabled definitions drive discovery; cleanup guidance is appended during workflow prompt assembly.
- **Fail-closed durable-association boundary:** sessions do not persist a workflow association. Hidden workflows are excluded from new discovery and cannot be recovered through an alleged running-session association. Hiding therefore fails closed; the workflow must be re-enabled before a new run.
- **Boundary shown:** Open Folder and Reveal are desktop local-filesystem actions and render no browser controls.

## 6. Agent Mode → Context Builder

- **Editable:** global/project inheritance and Copy Global to Project.
- **Editable:** Context Budget 10k–200k in 5k steps; Rewrite/Augment/Preserve; 30/60/120/300-second timeout.
- **Editable:** one user-facing **Allow Clarifying Questions** toggle mutates `mcpClarifyingQuestions`. Its copy explains that connected chat agents using RepoPrompt MCP can ask during Context Builder.
- **Compatibility preservation:** `portalClarifyingQuestions` remains in the typed profile for compatibility but is hidden and copied unchanged by portal profile replacement; the portal does not invent a second origin control.
- **Editable:** Disabled/Plan/Review/Question follow-up and 40k–200k follow-up budget.
- **Editable:** ordered named saved prompts with enabled state, bounded names, and bounded instructions.
- **Runtime precedence:** `ContextBuilderInput` optional fields override project, global, and typed defaults for internal/MCP consumers.
- **Runtime consumption:** `.mcp` resolution consumes `mcpClarifyingQuestions`; budget, enhancement, prompts, timeout, follow-up mode/budget, Context Builder Agent route, Oracle follow-up route, frozen-state checks, and final selection/prompt commit remain runtime-backed.
- **Removed boundary:** the portal exposes no Manual Portal Run UI and registers no portal-only `POST /portal/api/v1/sessions/:id/context-builder` route. Internal and MCP Context Builder APIs remain intact. The authenticated session-selection GET remains because named selection presets use it.

## 7. General → Appearance

- **Editable:** Portal Appearance offers `system`, `light`, `dark` and `normal`, `large`, `extraLarge`.
- **Browser-local authority:** a versioned fixed-grammar `rpce_portal_appearance` cookie uses `Path=/portal`, `SameSite=Strict`, and `Secure`. Invalid values normalize to system/normal. No server API call is made.
- **Boundary shown:** Always Collapse File Changes, desktop tooltip/timestamp switches, instruction spell checking, desktop file picker style, and experimental @-mention UI control SwiftUI components absent from the portal.

## 8. General → Updates

- **Intentionally omitted:** Sparkle, update channels, update checks, and install actions mutate a signed macOS app. The server runs immutable CI/CD revisions and browser users cannot mutate binaries.

## 9. General → Keyboard Shortcuts

- **Intentionally omitted:** macOS global shortcut registration cannot be mapped to a browser without a dedicated focus, assistive-technology, and browser-conflict contract. No shortcut recorder or master switch is rendered.

## 10. General → Advanced

- **Editable:** Respect `.repo_ignore`, Respect `.cursorignore`, Respect nested ignore files, Follow symbolic links, Show empty folders, Enable Code Maps, and History Idle Threshold 0–60.
- **Security warning:** ignore/symlink changes can widen scanning and are shown with root-confinement guidance.
- **Runtime consumption:** scanner operations read the policy; the revision is the scanner cache generation; empty folders affect tree output; disabled Code Maps reject generation and suppress admission; omitted history query threshold uses the stored value while explicit query override wins.
- **Boundary shown:** desktop prompt packaging, keyboard shortcut link, `repoprompt://` URL opener, and desktop saved-prompt import/export/reset are input-free local utilities.

## 11. General → Telemetry

- **Intentionally omitted:** server observability/privacy policy is deployment-owned. Ordinary portal users cannot change crash, hang, performance, tracing, or environment-disable policy. Health/readiness remain operational endpoints, not user settings.

## 12. MCP Server → MCP Server

- **Live read-only:** shared service status, canonical tool count, Context Builder route, and typed model-preset ownership.
- **Boundary shown:** per-window enable, auto-start, force stop, listener lifecycle, local client/skills/CLI installers, JSON configuration copy, and local troubleshooting are desktop/deployment responsibilities.

## 13. MCP Server → Tools

- **Live read-only:** all 27 canonical tools, scope, capability, admission class, and browser search.
- **Boundary shown by absence of inputs:** desktop per-window enable/toggle semantics do not map to a multi-user service. Tool admission remains server policy.

## 14. MCP Server → Workspace Approvals

- **Boundary shown:** exact desktop master switch plus Create Workspace, Delete Workspace, Add Folder, Remove Folder, and trusted-client revoke/reset behavior.
- **Server boundary:** authenticated HTTP/MCP policy, project/root confinement, mutation attribution, and agent interaction approvals are distinct. No generic file/Git/shell/worktree approval controls are invented.
- **Project decision:** projects and filesystem roots are operator-provisioned; portal authentication does not grant arbitrary server path selection.

## 15. MCP Server → Model Presets

- **Editable:** ordered preset CRUD through full replacement, unique names, optional description, exact provider/model/effort target, enabled state, and Chat/Plan/Review availability.
- **Runtime consumption:** list_models discovery and Oracle resolution use enabled presets; missing, disabled, mode-incompatible, and unavailable targets fail explicitly.

## 16. Models & Providers → API Providers

- **Editable:** OpenAI API and Anthropic API expose the complete direct surface for definitions admitted by both `deploymentAllowed` and the runtime registry.
- **Editable:** enable/disable, fixed-host non-secret configuration, preferred model, output-token bound, write-only API-key connect, validated catalog, Test Connection, Disconnect/Revoke, and provider defaults/options.
- **Security:** no returned DTO contains credential or vault reference.
- **Boundary shown:** DeepSeek, Fireworks, xAI, Groq, and Z.AI use the hardened custom OpenAI-compatible runtime where standards-compatible; Gemini is an omitted protocol; Azure OpenAI is an enterprise deployment/identity boundary; Ollama and LM Studio are local-network deployment boundaries.

## 17. Models & Providers → OpenRouter

- **Editable:** the destination owns enable/disable, fixed-host write-only credential lifecycle, preferred model, maximum output tokens, non-secret custom headers, sanitized model catalog, Test Connection, Disconnect/Revoke, and execution.
- **Boundary shown:** the same destination owns the deployment-disabled input-free card; it never renders a partial form.
- **Header security:** Authorization, proxy authorization, cookies, Host, forwarding headers, controls, oversized values, and likely secrets are rejected.
- **Dynamic live truth:** the authenticated catalog chooses the editable complete-runtime rendering or the input-free deployment-boundary rendering. The destination's fixed final classification is **Editable + Boundary shown**.
- **Catalog decision:** curated/fetched model content is owned by the sanitized server catalog; no decorative include-default toggle is persisted outside that contract.

## 18. Models & Providers → Custom API

- **Editable:** the destination owns public HTTPS base URL, write-only API key, preferred model, output-token bound, allowed non-secret headers, fixed JSON content type, catalog, validation, execution, and Disconnect/Revoke.
- **Boundary shown:** the same destination owns the deployment-disabled input-free card; it never renders endpoint or credential placeholders.
- **Security:** HTTPS port 443, no userinfo/fragment, per-request DNS resolution, mixed/private/local/metadata/reserved rejection, pinned address connection with original-host TLS/SNI validation, redirects disabled, bounded headers/body/timeouts/cancellation.
- **Dynamic live truth:** the authenticated catalog chooses the editable hardened-runtime rendering or the input-free deployment-boundary rendering. The destination's fixed final classification is **Editable + Boundary shown**.

## 19. Models & Providers → Model Config

- **Live read-only:** provider-grouped sanitized models, reasoning efforts, speed modes, and service tiers.
- **Boundary shown:** desktop per-model Diff Editing, Streaming, Responses API, and Temperature overrides have no completed shared DTO/runtime authority. OpenAI service tier remains provider settings behavior.

## 20. Workspaces → Manage Workspaces

- **Live read-only:** operator-provisioned project names, safe root names, and lifecycle state.
- **Boundary shown:** local restore, storage location, duplicate consolidation, folder picker, create/add-folder, rename/hide/delete, and local window switching are not portal operations.
- **Threat model:** unrestricted browser path input would bypass canonical-root confinement; no path input is rendered.

## 21. Workspaces → Manage Presets

- **Editable:** project-scoped list, capture current session selection, apply to session, rename, reorder, and delete.
- **Concurrency:** capture fences collection and selection revisions; apply fences preset collection and target selection revisions; row edits fence row and collection revisions.
- **Confinement:** logical entries must reference current project roots and valid relative paths.
- **Semantic correction:** these are file-selection presets, not Agent Workflows or prompt presets.
- **Desktop-only detail:** ⌘⌥1…9 shortcut assignment is not copied into the browser.

## 22. Prompting → Chat Settings

- **Intentionally omitted:** the portal is Agent Mode and has no desktop built-in Chat UI. Agent Models and Model Presets remain on their canonical portal pages; planning prompt, edit format, and temperature are not duplicated.

## 23. Prompting → Workflow Presets

- **Intentionally omitted:** Copy/Chat Workflow Presets package desktop Copy and built-in Chat inputs (files, prompt, tree, Code Maps, Git diff, meta prompts, mode, required model). They are not server Agent Workflows.

## 24. Prompting → Copy Prompt Order

- **Intentionally omitted:** File Tree, File Contents, Git Diff, Meta Prompts, User Instructions ordering and duplicate-user-instructions behavior affect desktop copied/built-in Chat prompts and explicitly do not affect Agent Mode.

---

# Typed authenticated HTTP surface

All routes require portal certificate authorization. Mutations additionally require the portal CSRF header and pass authenticated settings/provider attribution.

| Domain | Read | Mutation |
|---|---|---|
| Agent Models global | `GET /portal/api/v1/settings/agent-models` | `PATCH .../agent-models`, `POST .../apply-recommendations` |
| Agent Models project | `GET /portal/api/v1/projects/:id/settings/agent-models` | `PATCH`, `POST .../copy-global`, `POST .../apply-recommendations` |
| Sub-agent permissions | `GET /portal/api/v1/settings/subagent-permissions` | `PATCH` |
| Context Builder global | `GET /portal/api/v1/settings/context-builder` | `PATCH` |
| Context Builder project | `GET /portal/api/v1/projects/:id/settings/context-builder` | `PATCH`, `POST .../copy-global` |
| MCP model presets | `GET /portal/api/v1/settings/model-presets` | `PATCH` |
| Advanced | `GET /portal/api/v1/settings/advanced` | `PATCH` |
| Selection presets | project collection route plus `GET /portal/api/v1/sessions/:id/selection` | create/update/delete/reorder/capture/apply routes |
| Workflows | `GET /portal/api/v1/workflows` | create/update/delete/clone/visibility/reorder/preferences/reload routes |
| Direct provider configuration | `GET /portal/api/v1/provider-settings/:id/direct-configuration` | `PATCH /portal/api/v1/provider-settings/:id/direct-configuration` revisioned full replacement while disconnected |
| Provider connection | provider catalog/connection routes | enable/disable/connect/test/disconnect/revoke |

The client uses per-domain mutation locks. A stale revision reloads only the affected domain before re-rendering.

# Portal mutation DTO and validator audit

The portal mutation producers were compared field-for-field with their Swift request DTOs and final server validators:

| Domain | Exact portal payload and authoritative bounds |
|---|---|
| Agent Models | Global `{expectedRevision, profile}`; project `{expectedRevision, mode, profile}`; copy `{expectedGlobalRevision, expectedProjectRevision}`; recommendations `{expectedRevision}`. A profile has the six routing keys plus `restrictDiscoveryToRoleModels`; each non-null target has `providerID`, optional catalog `modelID`/`reasoningEffort`, and `pinned`. |
| Sub-agent settings | `{expectedRevision, settings}` with exactly `policy`, `codex`, `claude`, `openCode`, and `cursor`; every value comes from its Swift enum. |
| Context Builder | Stored global/project/copy envelopes match the DTOs. Profiles carry budget 10,000–200,000/5,000, timeout 30/60/120/300, follow-up budget 40,000–200,000/5,000, follow-up mode, and at most 100 ordered prompts with 128-byte names and 16-KiB instructions. The sole displayed clarification control writes `mcpClarifyingQuestions`; replacement payloads preserve the hidden `portalClarifyingQuestions` compatibility value unchanged. No portal execution body or route remains. |
| Model presets | `{expectedRevision, presets}`; each preset carries `presetID`, name, nullable description, exact target, non-empty Chat/Plan/Review availability, enabled, and order. The collection cap is 100, name bound 128 bytes, and description bound 1,024 bytes. |
| Advanced | `{expectedRevision, settings}` with the six Boolean scanner/tree/code-map keys and integer `historyIdleThresholdMinutes`; both DOM and client guard use the server's 0–60 bound. |
| Workflows | Create/update/delete/clone/visibility/reorder/preferences/reload envelopes use their distinct revision and row-fence keys. Names are capped at 128 bytes, definitions at 256 KiB, custom count at 200, and the server retains path-free frontmatter/secret validation. |
| Selection presets | Rename preserves entries and sends collection/row fences; reorder sends the ordered UUID list; capture/apply send collection plus live selection fences; delete sends collection/row fences. Names are capped at 256 bytes and project collection count at 100; entries remain server-confined logical selections. |
| Direct providers | `{expectedRevision, baseURL, preferredModel, maximumOutputTokens, customHeaders, contentTypePolicy}` and no credential field. Output tokens use 1–65,536 in DOM and client validation; preferred model is 256 bytes; headers decode as string-to-string only, cap at 16 entries and 8 KiB total, and retain the server's forbidden-name/value/secret checks. |

Browser `maxlength` is an early character-count guard; Swift UTF-8 byte checks, catalog checks, uniqueness checks, revision fences, path/root confinement, secret screening, and provider endpoint policy remain the final authority.

# Legacy compatibility classification

`PortalDesktopSettingKey` remains decodable for rollback and historical V5 documents.

## Still editable through the legacy P0 document

- `serverDefaultExecutionMode`
- Codex direct permission/tool settings
- Claude direct permission/tool settings
- OpenCode direct ACP mode
- Cursor direct ACP approval mode
- Claude-compatible backend non-secret runtime settings

These values are consumed by session/runtime policy.

## Decodable but superseded and non-mutable as authorities

- cleanup and handoff strings
- Oracle/Context Builder/role model routing
- role discovery filtering
- sub-agent policy/modes
- workflow cleanup/featured/custom values
- Context Builder settings/prompts
- MCP preset/tool/approval values
- OpenRouter/custom-provider decorative values
- model overrides
- default worktree preferences

Typed domains start from typed defaults rather than silently activating historical decorative values. The preserved legacy document remains forensic/rollback data.

# Provider truth and security closure

The authenticated live catalog selects a complete editable provider form after definition, deployment allowlist, validator/auth contract, write-only vault lifecycle, sanitized catalog, and execution runtime all agree; otherwise the destination renders its explicit input-free boundary.

- **Editable:** OpenAI API, Anthropic API, OpenRouter, and custom OpenAI-compatible complete runtime surfaces.
- **Boundary shown:** deployment-disabled direct definitions remain input-free in those same destinations.
- **Boundary shown:** Azure OpenAI enterprise identity/private-network policy; Ollama/LM Studio local-network access.
- **Intentionally omitted protocol:** Gemini.
- **Compatibility boundary:** xAI decodes but is never deployment-admitted.
- **Credential rule:** credentials appear only in connection requests and narrow runtime access; settings snapshots, bootstrap, audit rows, errors, catalogs, and DOM state contain no secret or vault reference.

# P1/P2/P3 final closure

## P1

- [x] Agent Models typed authority and all six runtime targets.
- [x] Safe Managed/Inherit/Custom sub-agent authority consumed at child launch.
- [x] Context Builder typed settings, prompts, MCP clarification policy, timeout, and follow-up, with the obsolete portal execution consumer removed.
- [x] MCP model preset repository and Oracle/model discovery consumption.
- [x] Advanced scanner/Code Maps/history authority and runtime consumption.
- [x] Named project selection preset management and runtime apply.

## P2

- [x] OpenAI API, Anthropic API, OpenRouter, and hardened custom direct runtimes exposed only through backend truth.
- [x] Server-native workflow repository and runtime reload/visibility/cleanup behavior.
- [x] Project lifecycle finalized as operator/deployment owned.
- [x] Workspace Approvals finalized as desktop trusted-client policy.
- [x] Azure/local-network providers finalized as deployment boundaries.

## P3

- [x] Browser-native theme and text density.
- [x] Browser shortcuts intentionally omitted for accessibility/conflict reasons.
- [x] Telemetry mutation and admin diagnostics intentionally omitted from ordinary settings; deployment/health interfaces remain authoritative.

# Focused acceptance coverage added for Item 5

## HTTP

`SettingsCatalogAuthorityTests.testTypedSettingsDirectConfigurationWorkflowAndPresetHTTPContractsAreAuthenticatedAndRejectPathAuthorityFields` covers the authenticated-route matrix for Agent Models, sub-agent settings, Context Builder settings/copy, retained session-selection read, model presets, Advanced, direct-provider-configuration GET/PATCH, selection presets, and workflows. It also asserts that the portal-only Context Builder POST route returns `404 Not Found` and covers strict workflow path-field rejection. `ServerSettingsFoundationTests.testRuntimeRouteResolutionContextDefaultsPresetsAndDiscovery` proves `.mcp` resolution consumes `mcpClarifyingQuestions` while explicit invocation overrides retain precedence. Provider catalog/connection authorization remains in the existing provider HTTP coverage and is not claimed by this matrix test.

## DOM

`Tests/PortalDOMTests/portal.test.mjs` retains the P0 contracts and adds focused coverage for:

- server-owned Agent Models profile/recommendations and absence of the old JavaScript recommender;
- exact Agent Models project mutation keys/profile shape;
- exact sub-agent mutation keys and Full Access warning;
- exact Advanced mutation keys plus the authoritative 0–60 history bound;
- exact Context Builder settings keys/bounds, a single MCP clarification toggle, hidden portal-field preservation, and absence of Manual Portal Run;
- persistent accessible `Saving…`, `Saved`, and actionable failure feedback that survives route re-rendering without replacing catalog freshness;
- behavioral model-preset add/reorder/delete ordering controls plus exact preset payload keys;
- exact workflow display labels with stable `rp-*` IDs, display-name clone defaults, and no visible built-in `rp-*` names;
- exact workflow visibility and named selection-preset apply fences/keys;
- fail-closed hidden-workflow durable-association explanation;
- deployment-truth-gated direct-provider forms, exact configuration keys, and the authoritative 1–65,536 output-token bound;
- input-free unsupported boundaries;
- browser-local strict versioned appearance cookie;
- canonical 27-tool catalog/search;
- mounted-account and Codex P0 behavior;
- no `localStorage`, no `sessionStorage`, no inline script/style, and sensitive-input disposal.

The coordinated focused test batch, commit, push, deployment, live smoke, and cleanup remain deliberately unexecuted for orchestrator verification, as required by the Item 5 implementation/audit handoff.

# Primary source index

- `Sources/RepoPromptServiceHTTP/RepoPromptHTTPService.swift`
- `Sources/RepoPromptServiceHTTP/Resources/Portal/index.html`
- `Sources/RepoPromptServiceHTTP/Resources/Portal/portal.js`
- `Sources/RepoPromptServiceHTTP/Resources/Portal/portal.css`
- `Sources/RepoPromptHeadlessRuntime/ServerSettingsService.swift`
- `Sources/RepoPromptHeadlessRuntime/RepoPromptHeadlessAuthority.swift`
- `Sources/RepoPromptHeadlessRuntime/WorkflowRepository.swift`
- `Sources/RepoPromptHeadlessRuntime/ProviderSettingsService.swift`
- `Sources/RepoPromptHeadlessRuntime/DirectProviderRuntime.swift`
- `Sources/RepoPromptHeadlessRuntime/ValidatedProviderEgressTransport.swift`
- `Sources/RepoPromptServiceProtocol/*SettingsDTOs.swift`
- `Sources/RepoPromptServicePersistence/SchemaV6.swift`
- `Tests/RepoPromptServerTests/SettingsCatalogAuthorityTests.swift`
- `Tests/PortalDOMTests/portal.test.mjs`
