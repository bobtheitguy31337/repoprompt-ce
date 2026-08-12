# RepoPrompt CE desktop ↔ web portal settings parity audit

**Audit date:** 2026-08-11
**Desktop source:** this checkout's vanilla macOS Settings implementation
**Portal source:** `RepoPromptServiceHTTP/Resources/Portal` plus the shared-server DTO/runtime implementations

## Executive summary

The desktop Settings sidebar has **24 canonical destinations** in six groups:

- Agent Mode: 6
- General: 5
- MCP Server: 4
- Models & Providers: 4
- Workspaces: 2
- Prompting: 3

`Copy Presets` and `Chat Presets` remain enum/deep-link aliases, but are intentionally not separate sidebar rows; both resolve to the canonical `Workflow Presets` destination.

The web portal currently exposes **16 destinations**: every Agent Mode, MCP Server, Models & Providers, and Workspaces destination. It intentionally omits General and Prompting because most of those controls operate a local macOS app/window, local keyboard registration, Sparkle, local prompt packaging, or the built-in desktop chat UI.

Before this parity pass, many portal controls merely wrote strings to `PortalDesktopSettingKey` without any runtime consumer. That made the portal look more complete than it was. This pass applies four rules:

1. **Runtime-backed:** editable only when the Linux runtime consumes the value.
2. **Live projection:** read-only when the server can truthfully expose current state/catalogs but not mutate them.
3. **Explicit boundary:** show the exact desktop controls and why they are unavailable when the destination is useful context on web.
4. **Intentional omission:** do not add desktop chrome that has no sensible browser/server meaning.

The largest corrected UX defect is CLI Providers. Unconfigured Claude Code, OpenCode, and Cursor now use the desktop mental model—one **Connect** action—rather than generic secret fields and single-option authentication dropdowns. Codex's working managed flow is unchanged. A real **Check recommendations to optimize your setup → Check Now** path now opens an assessment based on connected CLI providers and the desktop recommendation priority.

## Status legend

| Status | Meaning |
|---|---|
| **Editable** | Portal mutation is consumed by the shared Linux runtime. |
| **Live read-only** | Portal displays canonical live service state, but no safe mutation API exists. |
| **Boundary shown** | Portal documents the desktop control map and current missing authority; no inert input is rendered. |
| **Intentionally omitted** | Local desktop/window behavior is not useful on the shared web service. |
| **Gap** | Useful server/web behavior still needs a real domain API/runtime consumer. |

## Canonical navigation map

| Group | Desktop destination | Portal | Current result |
|---|---|---:|---|
| Agent Mode | Overview | Yes | Mixed editable/live/boundary |
| Agent Mode | CLI Providers | Yes | Editable; major parity correction in this pass |
| Agent Mode | Agent Models | Yes | Live assessment + provider defaults; role-routing mutation is a gap |
| Agent Mode | Agent Permissions | Yes | Direct permissions editable; sub-agent policy is a gap |
| Agent Mode | Agent Workflows | Yes | Live catalog; authoring/ordering is a gap |
| Agent Mode | Context Builder | Yes | Boundary shown; settings authority is a gap |
| General | Appearance | No | Intentionally omitted |
| General | Updates | No | Intentionally omitted |
| General | Keyboard Shortcuts | No | Intentionally omitted |
| General | Advanced | No | Mixed: several server-applicable controls are gaps; local utilities omitted |
| General | Telemetry | No | Intentionally omitted from user portal; deployment/privacy policy owns server telemetry |
| MCP Server | MCP Server | Yes | Live status; per-window/process/install controls omitted or gaps |
| MCP Server | Tools | Yes | Full canonical live catalog; per-window toggles are a gap |
| MCP Server | Workspace Approvals | Yes | Boundary shown; desktop semantics corrected |
| MCP Server | Model Presets | Yes | Boundary shown; CRUD authority is a gap |
| Models & Providers | API Providers | Yes | Only deployed runtime definitions render; broad desktop catalog is a gap |
| Models & Providers | OpenRouter | Yes | Boundary shown; provider runtime is a gap |
| Models & Providers | Custom API | Yes | Boundary shown; validator/runtime is a gap |
| Models & Providers | Model Config | Yes | Live model catalog; override authority is a gap |
| Workspaces | Manage Workspaces | Yes | Live projects; local workspace CRUD intentionally omitted/server CRUD is a gap |
| Workspaces | Manage Presets | Yes | Correct semantics shown; selection-preset API is a gap |
| Prompting | Chat Settings | No | Intentionally omitted from Agent portal; some model/preset concepts overlap with real gaps above |
| Prompting | Workflow Presets | No | Desktop Copy/Chat packaging; intentionally omitted until a server packaging workflow exists |
| Prompting | Copy Prompt Order | No | Desktop prompt packaging; intentionally omitted |

---

# Detailed destination audit

## 1. Agent Mode → Overview

**Desktop source:** `AgentModeGeneralSettingsView.swift`

### Desktop control inventory

- Canonical deep-link summary rows for:
  - Oracle Model → Agent Models
  - Context Builder Agent → Agent Models
  - Sub-Agent Role Defaults → Agent Models
  - Context Builder Settings → Context Builder
  - CLI Providers → CLI Providers
  - Agent Permissions → Agent Permissions
- CLI status for Claude Code, Codex, OpenCode, and Cursor.
- **Agent Chats:** `Show chats created by MCP tools`.
- **Provider Conversation Cleanup:** `Archive` or `Delete` remote provider conversations when a local Agent Mode session is deleted.
- **Handoff Instructions:** multiline app-wide text, external-change conflict warning, Save, and Clear Saved Instructions.

### Portal comparison

- **Live read-only:** canonical deep links and current main CLI connection status.
- **Editable:** shared server fallback execution mode (`Read Only`, `Workspace Write`, `Full Access`) because the runtime consumes it for new sessions.
- **Boundary shown:** Agent Chats visibility, provider cleanup, and titlebar handoff behavior are desktop window/session features. The prior portal fields for cleanup and handoff persisted values but did not drive the server runtime, so they are no longer editable.

### Remaining gap

If the portal gains its own handoff action or server-owned conversation deletion policy, those need dedicated revisioned APIs rather than reusing desktop preference strings.

## 2. Agent Mode → CLI Providers

**Desktop source:** `CLIProvidersSettingsView.swift`, `APISettingsViewModel.swift`

### Shared desktop structure

Provider order is canonical:

1. Codex
2. Claude Code
3. Claude Code–Compatible Backends
   - CC Zai / GLM
   - CC Moonshot / Kimi
   - CC Custom
4. OpenCode
5. Cursor

The desktop displays this banner after any main CLI provider is connected:

> CLI providers connected. Check recommendations to optimize your setup.

The action opens the recommendation/Agent Models flow.

### Recommendation banner

- **Desktop:** visible after Claude, Codex, OpenCode, or Cursor connects; launches recommendations.
- **Portal now:** visible only when one of those main providers has a valid connected record. **Check Now** routes to a live Agent Models assessment.
- **Methodical behavior match:** OpenCode still triggers the banner, as it does on desktop, but an OpenCode-only setup receives an explicit “no desktop recommendation target” result because the desktop `ProviderStatusSnapshot`/candidate chains do not assign OpenCode to Oracle, Context Builder, or role defaults.
- **Gap:** the portal can calculate recommendations but cannot apply Oracle/Context Builder/role routing because that shared authority does not yet exist.

### Codex CLI

Desktop controls/flow:

- Managed packaged Codex executable.
- Connect using ChatGPT/device-code flow.
- Device-code verification panel and polling.
- Account, plan, and authentication summary.
- KYC/identity-verification notice and link.
- Test Connection.
- Sign Out with active-session safety behavior.
- Connection trace export on failure.
- Direct permission/runtime controls after connection.

Portal result:

- **Editable and intentionally preserved:** the existing working managed Codex flow, API-key alternative where advertised, account projection, Test Connection, Sign Out, KYC notice, provider defaults, and direct permissions.
- **Desktop-only:** Downloads trace export and macOS executable repair guidance.
- **Non-regression rule:** this parity work does not replace Codex's device/auth flow with the mounted-account mechanism used by the other CLIs.

### Claude Code CLI

Desktop disconnected state:

- One **Connect** button.
- No authentication-method dropdown.
- No generic API-key input for the main Claude Code account.
- Failure guidance includes running `claude login` in the terminal.
- Compatible backends remain independent and use their own keys when the Claude binary is installed.

Desktop connected state:

- Test Connection.
- Sign Out.
- Direct Permission Level.
- Claude tools:
  - Bash
  - RepoPrompt Only (Strict MCP)
  - Lazy Tool Loading
- Advanced **Sys Prompt Packaging**:
  - Replace System Prompt
  - User Message (No Native)
  - User Message (Keep Native)

Portal result after this pass:

- **Corrected:** disconnected main Claude Code shows exactly one **Connect** action, no secret field, no generic authentication cards, and no single-option dropdown.
- **Security model:** Connect validates the operator-provisioned, read-only mounted Claude CLI home. Browser requests contain no credential material; each run still copies the mounted home into a mode-0700 ephemeral home.
- **Authentication validation:** the service runs the packaged `claude auth status --json` with `CLAUDE_CONFIG_DIR` bound to the dedicated mount, clears ambient Anthropic and Claude OAuth credential variables for the probe, consumes only the `loggedIn` boolean, and never returns or persists CLI stdout/account metadata. A mounted-but-logged-out account is rejected with `claude login` guidance.
- **Connected controls:** Mounted CLI login summary, Test Connection with a fresh sanitized auth-status check, Disconnect without modifying operator-managed login files, and all runtime-backed direct permission/tool controls.
- **Live read-only:** Sys Prompt Packaging displays the server runtime's fixed behavior, **User Message (Keep Native)**. The other two desktop choices are documented but not editable because the headless Claude runtime does not consume a packaging preference.

Remaining Claude gaps:

- Desktop's manual Connect sends a minimal provider request after authorization; the portal's sanitized status check proves current CLI authorization but leaves model/network execution to session launch. Add a no-tools runtime round-trip only if pre-connection model availability is worth the extra provider request.
- Add a server prompt-delivery policy only if all three desktop packaging modes are implemented by `ClaudeNativeProviderRuntime`.

### Claude Code–Compatible Backends

Desktop common prerequisite:

- Claude binary must exist.
- A Claude/Anthropic account login is not required.
- Each backend uses its own API key.
- Test Backend routes a minimal message through the configured backend.

#### CC Zai / GLM

Desktop controls:

- Shared Z.AI API key card, validate/save/delete, and note that it is the same secret as API Providers.
- Claude slot → backend model IDs for Haiku, Sonnet, and Opus.
- Advanced display name, base URL, auth header, Reset to defaults.
- Claude model behavior uses slot mapping.

Portal:

- **Editable:** write-only credential connection and runtime-backed display/base/auth/slot settings.
- **Corrected progressive disclosure:** key and Backend Behavior first; preset internals under Advanced rather than a generic authentication-method selector.

#### CC Moonshot / Kimi

Desktop controls:

- Kimi API key save/delete and provider-console link.
- Explicit `No --model flag` behavior; backend manages model selection and no Claude effort level is passed.
- Advanced display name, base URL, auth header, Reset to defaults.

Portal:

- **Editable:** write-only Kimi credential and runtime-backed backend settings.
- **Corrected:** explicitly presents backend-managed model selection and does not show a meaningless model dropdown.

#### CC Custom

Desktop controls:

- Enable custom backend.
- Display name.
- Base URL.
- Auth header: `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`.
- Write-only secret lifecycle.
- Model behavior: No model flag or Claude slot mappings.
- Haiku/Sonnet/Opus mapping when slot mode is selected.

Portal:

- **Settings editable only where runtime-safe.**
- **Credential gap:** the shared service intentionally withholds a custom-endpoint credential form until a safe endpoint validator is configured, preventing an operator-controlled URL from turning validation into unrestricted SSRF.

### OpenCode CLI / ACP

Desktop disconnected state:

- One **Connect** button.
- Guidance: `opencode auth login`.
- No generic secret input or one-option dropdown.

Desktop Connect behavior:

- ACP model-discovery preflight.
- Connected state starts model polling.
- Test Connection, Sign Out, trace export, direct ACP Session Mode.

Portal result:

- **Corrected:** one mounted-account Connect action and no credential inputs/dropdowns.
- **Editable:** connection record, Test Connection with ACP initialization preflight, Disconnect, provider defaults, direct ACP Session Mode.
- **Live runtime behavior:** Connect is rejected unless the packaged runtime can complete its credential-backed ACP initialization preflight; subsequent model/session behavior remains owned by the provider runtime.
- **Desktop-only:** trace export and local terminal login UX.

### Cursor CLI / ACP

Desktop disconnected state:

- One **Connect** button.
- Uses Auto model fallback.
- May use `CURSOR_API_KEY` / `CURSOR_AUTH_TOKEN` or Cursor login when prompted.

Desktop Connect behavior:

- ACP model-discovery preflight with Auto fallback.
- Test Connection, Sign Out, trace export, direct ACP Auto-Approve mode.

Portal result:

- **Corrected:** one mounted-account Connect action and no credential inputs/dropdowns.
- **Editable:** connection record, Test Connection with ACP initialization preflight, Disconnect, provider defaults, direct ACP Auto-Approve mode.
- **Live runtime behavior:** Connect is rejected unless the packaged runtime can complete its credential-backed ACP initialization preflight.
- **Desktop-only:** trace export and interactive local-login handling.

## 3. Agent Mode → Agent Models

**Desktop source:** `AgentModelsSettingsView.swift`, recommendation view models/services

### Desktop control inventory

- Scope card:
  - Use global settings
  - Use workspace overrides
  - Copy global settings to workspace
  - Copy workspace settings to global with destructive confirmation
- Recommendation state:
  - Recommended setup available
  - Preview changed Oracle / Context Builder / role-default assignments
  - Apply Recommended Setup
  - Up-to-date state
- Oracle Model picker, current model, recommended model, individual Apply.
- Context Builder Agent + Model combined picker, recommended assignment, individual Apply, Connect in CLI Providers empty state.
- Sub-Agent Role Defaults:
  - Explore
  - Engineer
  - Pair
  - Design
  - Per-role recommended/current/pinned state
  - Reset All to Recommended
- `Hide non-role models from MCP agents` discovery filter.
- Advanced:
  - Keep Built-in Chat Model synced with Oracle Model
  - Built-in Chat Model override when sync is off
- Related link: Oracle Model Presets.

### Portal comparison

- **Live assessment:** connection availability is evaluated against the actual desktop recommendation profile version `202_608`, not against each provider's current default model.
- **Oracle chain:** Codex GPT-5.6 Sol High → OpenAI API when available → Claude Opus.
- **Context Builder chain:** Codex GPT-5.6 Sol Low → Claude Sonnet → Cursor Composer 2.
- **Explore chain:** Codex Sol Low → Claude Sonnet High → Claude Haiku → CC Zai Haiku slot → Kimi → Custom compatible → legacy Codex mini targets → Cursor Auto.
- **Engineer chain:** Codex Sol Medium → Claude Sonnet → CC Zai Sonnet slot → Kimi → Custom compatible → Cursor Composer 2.
- **Pair chain:** Codex Sol High → Claude Opus → CC Zai Opus slot → Kimi → Custom compatible → Cursor Composer 2.
- **Design chain:** Claude Opus → CC Zai Opus slot → Kimi → Custom compatible → Cursor Composer 2 → Codex Sol Medium.
- **Availability nuances preserved:** OpenCode is not a desktop recommendation target. Compatible backends participate only as enabled, valid role fallbacks and only when Codex, Claude Code, or Cursor makes the desktop role recommender eligible. When the service has not advertised the desktop's exact model/effort target (for example Cursor Composer 2 while the service exposes only Auto), the portal marks that row informational instead of pretending it is configurable.
- **Editable:** each provider's runtime-backed default model/reasoning/speed/service-tier settings remain available under Provider Defaults.
- **Boundary shown:** global/workspace routing, Oracle model, Context Builder agent/model, role defaults, discovery filtering, sync, and built-in chat model are not persisted because no shared Agent Models profile authority consumes them.
- **Corrected:** the portal no longer presents inert model dropdowns as if they configured Oracle or roles.

### Gap

Create a server-owned, revisioned Agent Models profile service with global/project scope, recommendation application, role-label routing, and runtime consumption. Only then make the assessment actionable.

## 4. Agent Mode → Agent Permissions

**Desktop source:** `AgentPermissionsSettingsView.swift`, `AgentDirectProviderPermissionsView.swift`, `AgentSubagentPolicySettingsView.swift`, shared provider permission controls

### Desktop control inventory

Scope picker:

- Direct Agents
- Sub-Agents

Direct Agents:

- Codex:
  - Permission Level: Read Only, Default Permission, Auto Review, Full Access
  - Bash
  - Search
  - Goals
  - Reasoning Summaries
  - Local Memories
  - Configured MCP-server toggles; RepoPrompt is required
- Claude:
  - Permission Level: Require Approval, Auto-Approve Edits, Auto, Full Access
  - Bash
  - RepoPrompt Only (Strict MCP)
  - Lazy Tool Loading
- OpenCode:
  - ACP Session Mode: Managed Default or Full Access
- Cursor:
  - ACP Auto-Approve: Managed Default or Full Access

Sub-Agents:

- Safe Managed (recommended), with effective per-provider preview.
- Inherit Provider Settings, including Full Access warning.
- Custom per-provider modes for Codex, Claude, OpenCode, and Cursor.

### Portal comparison

- **Editable:** shared fallback execution mode and all direct-provider controls actually mapped into provider execution policies.
- **Live/read-only:** RepoPrompt is shown as the required Codex MCP server. The portal does not invent toggles for an unexposed isolated Codex MCP-server catalog.
- **Boundary shown:** Safe Managed / Inherit / Custom sub-agent policy. Existing persisted keys are not exposed because the server sub-agent launcher does not consume them.
- **Added regression coverage:** the DOM contract asserts all four provider sections and every runtime-backed direct control are present.

### Gap

Expose one server-owned sub-agent permission resolver and make launch admission consume it before reintroducing the three policy choices.

## 5. Agent Mode → Agent Workflows

**Desktop source:** `AgentModeWorkflowsSettingsView.swift`, `AgentWorkflowStore`

### Desktop control inventory

- Include Session Cleanup Guidance toggle.
- Featured workflows:
  - add
  - remove
  - move earlier/later
- Built-in workflows:
  - Visible toggle
  - feature/unfeature through featured list
  - Clone
- Custom workflows:
  - New markdown file
  - Reload
  - Open Folder
  - Reveal
  - Clone
  - Delete with confirmation
- Clear separation from Copy/Chat Workflow Presets.

### Portal comparison

- **Live read-only:** the exact workflow catalog advertised in bootstrap, including enabled/disabled status.
- **Boundary shown:** file-backed authoring, featured ordering, built-in visibility/clone, cleanup-guidance mutation, and custom CRUD.
- **Corrected:** the portal no longer stores a second inert JSON workflow registry.

### Gap

Add a server workflow repository with safe path confinement, revisioning, validation, and runtime reload before exposing CRUD.

## 6. Agent Mode → Context Builder

**Desktop source:** `ContextBuilderSettingsView.swift`

### Desktop control inventory

About:

- Context Builder Agent is a read-only summary linking to Agent Models.

Shared Settings:

- Context Budget: 10k–200k, 5k steps, default 160k.
- Prompt Enhancement: Rewrite, Augment, Preserve.
- Question Timeout: 30 sec, 1 min, 2 min, 5 min.

UI Runs:

- Allow Clarifying Questions.
- Follow-up Analysis.
- Analysis Budget: 40k–200k when follow-up is enabled.
- Oracle model summary/link.
- Custom Instructions prompt collection management.

MCP Runs:

- Allow Clarifying Questions.
- Warning that the user must watch RepoPrompt and respond before timeout.

### Portal comparison

- **Corrected:** no duplicate Context Builder agent/model picker; Agent Models remains canonical.
- **Boundary shown:** every desktop value/range and UI-vs-MCP distinction above.
- **No inert controls:** none of these values is editable because the shared Context Builder execution path does not consume `PortalDesktopSettingKey` values.

### Gap

Add a revisioned Context Builder settings domain service used by UI-originated and MCP-originated runs, including prompt-collection storage and question timeout propagation.

## 7. MCP Server → MCP Server

**Desktop source:** `MCPSettingsView.swift`

### Desktop control inventory

- Per-window MCP tools enabled switch.
- Auto-Start.
- Status Dashboard.
- Force Stop Listener.
- Running/listener/tool status and active tool count.
- Oracle Model Presets:
  - Manage
  - Use presets for MCP
  - hidden-by-wizard recovery
  - count/current-model fallback
- Context Builder agent/model read-only summary linking to Agent Models.
- Quick Setup installers:
  - Cursor
  - VS Code
  - Codex CLI
  - OpenCode
  - Claude Desktop
  - Claude Code per-project
- Skills install/update/uninstall:
  - shared/global and per-project `.agents/skills`
  - Claude Code `.claude/commands`
  - isolated RepoPrompt Codex prompts
- CLI tool installers.
- JSON Configuration copy surface.
- Server/client error details, troubleshooting, dismiss.

### Portal comparison

- **Live:** service online state, canonical tool count/link, and `context_builder` route summary.
- **Intentionally service-managed:** start/stop, force stop, and auto-start. A shared deployment is not a per-browser window listener.
- **Desktop-only:** local client installers, CLI installers, skills filesystem modification, JSON snippet for local apps, Downloads/Finder-oriented actions.
- **Gap:** safe server-side model-preset authority and connection diagnostics suitable for administrators.

## 8. MCP Server → Tools

**Desktop source:** `MCPToolsSettingsView.swift`; canonical domain list: `MCPDomainToolCatalog.swift`

### Desktop control inventory

- Enable MCP tools for this window.
- Search tools.
- Per-tool availability toggles.
- Empty/disconnected/disabled states.

### Portal comparison

- **Now live and complete:** bootstrap exposes all **27 canonical tools** from `MCPDomainToolCatalog` with name, application/window scope, capability, and admission class.
- **Now searchable:** client-side search updates shown/total count.
- **Corrected:** no fabricated short list and no fake checkboxes.
- **Gap:** a shared-server or per-client tool-admission API. Desktop's per-window toggle cannot be mapped directly to a multi-user service.

## 9. MCP Server → Workspace Approvals

**Desktop source:** `PermissionsSettingsView.swift`, `WorkspaceApprovalTypes.swift`

### Desktop control inventory

- Global `Auto-approve All Operations` high-risk switch.
- Per-operation global auto-approve:
  - Create Workspace
  - Delete Workspace
  - Add Folder
  - Remove Folder
- Trusted Clients:
  - client-specific allowed operations
  - per-operation Revoke
  - remove client policy
  - Reset All
  - last-used information

### Portal comparison

- **Corrected semantics:** this page is not generic file writes, file moves, Git, shell, or worktree permission. Those prior portal labels were wrong.
- **Boundary shown:** exact four desktop operations and trusted-client behavior.
- **Server behavior:** HTTP authorization, project authority, path confinement, operator authentication, and agent interaction approvals are separate controls; the portal does not map them onto desktop local-client trust preferences.

### Gap

Only add this page's controls if shared project CRUD is introduced and has a client-attributed approval manager.

## 10. MCP Server → Model Presets

**Desktop source:** `ModelPresetsSettingsView.swift`, `ModelPresetsSheet.swift`

### Desktop control inventory

- Empty state and Create Default Preset.
- Add Preset.
- Edit and delete existing presets.
- Name with sanitized persisted name preview.
- Model selection.
- Optional description.
- Availability modes:
  - Chat + optional Chat Preset
  - Plan + optional Chat Preset
  - Review + optional Chat Preset
- Recommendation/wizard hidden state and Show Presets recovery.
- Presets are used by `list_models`, `oracle_send`, and `ask_oracle`.

### Portal comparison

- **Boundary shown:** no inputs/count are rendered without a real snapshot/CRUD authority.
- **Corrected:** removed the inert browser-side JSON preset count and controls.

### Gap

Create a durable server model-preset repository and make MCP model resolution consume it.

## 11. Models & Providers → API Providers

**Desktop source:** `APISettingsView.swift`, `APISettingsViewModel.swift`

### Desktop provider inventory

- Anthropic API Key.
- OpenAI API Key.
  - Service Tier: Auto, Default, Flex, Priority.
  - Show service-tier variants in model list.
  - Advanced custom base URL with validation/reset.
- DeepSeek API Key.
- Fireworks AI API Key.
- Grok (xAI) API Key.
- Groq API Key.
- Z.AI API Key, shared with CC Zai.
- Gemini API Key.
- Azure OpenAI:
  - Base URL
  - API Version
  - API Key
  - discovered deployments
  - optional custom deployment
- Ollama / LM Studio:
  - URL
  - validate/model discovery
  - model selection
  - reset defaults
- Common API-key lifecycle:
  - write-only key field
  - validate/save
  - delete
  - fetched model list or custom model selection where supported
- Recommendation banner when supported API keys are valid.
- Secure-storage repair UI.

### Portal comparison

- **Truthful dynamic rendering:** only API-provider definitions both advertised and deployment-allowed are shown.
- **Current packaged state:** no broad direct API runtime is enabled; the disabled xAI definition is not presented as functional.
- **Boundary shown:** full desktop cloud and enterprise/local provider inventory.
- **Security:** no inert key fields are displayed when no portable validator/runtime exists.

### Gaps

- Implement each provider as an explicit server runtime + fixed-host validator + write-only vault contract.
- Add OpenAI service-tier and variant handling only when an OpenAI direct runtime consumes them.
- Azure and local-model access need separate threat models; do not fold them into a generic URL form.

## 12. Models & Providers → OpenRouter

**Desktop source:** `OpenRouterSettingsView.swift`

### Desktop control inventory

- API key, Validate & Fetch, Delete Key.
- Include default OpenRouter models.
- Use Custom Settings.
- Maximum tokens.
- Multiple custom request headers, add/remove.
- Registered model list, add/remove.
- Search fetched models.
- Refresh Model List.
- Limit/empty result messaging.

### Portal comparison

- **Boundary shown:** exact setup and lifecycle, with no editable controls.
- **Gap:** no OpenRouter provider definition, fixed-host credential validator, catalog fetcher, header policy, or execution runtime exists in the service.

## 13. Models & Providers → Custom API

**Desktop source:** `CustomProviderSettingsView.swift`

### Desktop control inventory

- OpenAI-compatible Provider URL.
- API Key.
- Optional preferred model ID / auto-detect.
- Default output max tokens; zero means provider/model default.
- Validate & Save.
- Delete Provider.
- Content-Type header toggle.
- Fetched Available Models search and per-model enablement.

### Portal comparison

- **Boundary shown:** full desktop connection and model lifecycle.
- **Corrected:** no misleading Content-Type-only checkbox or other inert form controls.
- **Gap/security boundary:** an operator-controlled endpoint validator could become SSRF. A web implementation needs URL policy, DNS/IP revalidation, redirect limits, egress restrictions, write-only vault storage, bounded responses, and a portable request runtime.

## 14. Models & Providers → Model Config

**Desktop source:** `ModelOverrideSettingsView.swift`, `ModelOverrideSettings.swift`

### Desktop per-model controls

- Allow Diff Editing.
- Use Streaming.
- Use Responses-API for custom-provider models.
- Temperature 0.0–2.0, model/global fallback display, Reset.
- Provider-grouped disclosure rows and override indicator.

### Portal comparison

- **Live read-only:** every model advertised by provider settings plus reasoning effort, speed mode, and service tier option families.
- **Boundary shown:** exact desktop override controls.
- **Corrected:** OpenAI Service Tier is documented as API Providers behavior rather than misplaced on Model Config.
- **Gap:** model capability/override DTO and request/runtime consumption.

## 15. Workspaces → Manage Workspaces

**Desktop source:** `ManageWorkspacesView.swift`

### Desktop control inventory

- Restore workspaces on launch.
- Global storage location, set/reset.
- Duplicate workspace detection and consolidate flow.
- Existing workspace search/count.
- Switch workspace.
- Rename.
- Hide/show in menus.
- Delete.
- Create workspace:
  - name
  - macOS folder picker
  - one or more folders
  - create and switch

### Portal comparison

- **Live read-only:** operator-provisioned server projects, browser-safe root names, and project state.
- **Intentionally omitted:** macOS folder picker, local window restore, menu visibility, local database/storage location, local duplicate cleanup.
- **Corrected:** removed default worktree controls that were persisted but never consumed. Worktree selection remains a per-session runtime operation.
- **Gap:** authenticated server project CRUD if desired; it must use server filesystem authority, not emulate local NSOpenPanel behavior.

## 16. Workspaces → Manage Presets

**Desktop source:** `ManagePresetsView.swift`

### Desktop control inventory

- Existing selection presets for active workspace.
- Explanation that presets switch selected-file sets.
- Keyboard shortcuts ⌘⌥1 through ⌘⌥9 for first nine presets.
- Reorder.
- Rename.
- Delete.
- Empty/no-active-workspace states.

### Portal comparison

- **Corrected:** this destination is now identified as workspace **file-selection presets**, not Agent Workflows. The previous portal showed the wrong domain data.
- **Boundary shown:** exact list/switch/reorder/rename/delete semantics.
- **Gap:** bootstrap snapshot and CRUD for project-scoped selection presets.

---

# Intentionally omitted desktop destinations

## 17. General → Appearance

**Desktop source:** `AppearanceSettingsView.swift`

Desktop controls:

- Theme: System, Light, Dark.
- Text Size: Normal, Large, Extra Large.
- Always Collapse File Changes.
- Show Tooltips.
- Show dates in message timestamps.
- Enable Spell Checking in Instructions.
- @ File Picker Style: Compact or Expanded.
- Enable @-Mention Menu (Experimental).

Portal disposition:

- **Intentionally omitted.** The portal has its own responsive CSS/theme/accessibility behavior and no desktop transcript/file-change editor or SwiftUI @-mention component. If browser theming becomes a product requirement, build it as portal UI preferences rather than copying macOS control keys.

## 18. General → Updates

**Desktop source:** `LicenseUpdatesSettingsView.swift`

Desktop controls:

- Current/update-available status.
- Check for Updates.
- Install available update.
- Update Channel (including Stable/Tip semantics).
- Automatically check for updates.

Portal disposition:

- **Intentionally omitted.** Sparkle updates a signed macOS app. The server deploys immutable revisions through CI/CD; a browser user must not mutate server binaries.

## 19. General → Keyboard Shortcuts

**Desktop source:** `KeyboardShortcutsSettingsView.swift`

Desktop controls:

- Enable keyboard shortcuts master switch.
- Remappable global shortcut recorder rows grouped into:
  - Agent & layout
  - Workspace & presets
  - Agent session tabs
  - Display
- Includes new chat, sidebar/compose, agent navigation HUDs, workspace save, preset create/switch 1–9, tab create/close/next/previous/parent navigation/focus 1–9, and font-size changes.

Portal disposition:

- **Intentionally omitted.** These register macOS global hotkeys and drive desktop windows. Browser-local shortcuts, if added, need a separate conflict/accessibility design and cannot use the desktop registrar.

## 20. General → Advanced

**Desktop source:** `AdvancedSettingsView.swift`

This is the only omitted destination with a meaningful mixed authority.

### Desktop File System controls

- Respect `.repo_ignore` rules.
- Respect `.cursorignore` rules.
- Respect nested ignore files.
- Follow symbolic links.
- Show empty folders.

Portal disposition: **Gap.** These affect server folder scanning and already overlap with `app_settings` file-system preferences. A future portal page should read/write the canonical app-settings authority—not `PortalDesktopSettingKey`—and must preserve project refresh/invalidation behavior.

### Desktop AI Behavior controls

- Disable Code Maps globally.
- Prompt Packaging:
  - File path display
  - Include datetime in user instructions

Portal disposition:

- **Code Maps:** Gap where server-wide code-map generation exists; wire to canonical code-map policy.
- **Prompt Packaging:** intentionally omitted from Agent Mode portal until the server exposes a copy/built-in-chat packaging workflow. Agent providers assemble context through a different runtime.

### Desktop History control

- Default idle threshold, 0–60 minutes, used by `history` active-time calculations and overrideable per query.

Portal disposition: **Gap.** This is server-applicable and should use the existing settings-backed history policy, not a new portal-only preference.

### Desktop Keyboard shortcut link

- Enable shortcut master toggle and Open Keyboard Shortcuts.

Portal disposition: **Intentionally omitted.**

### Desktop URL Opener

- Canonical `repoprompt://` scheme.
- Examples for opening folders, selecting files and prompt text, focusing/creating ephemeral workspaces, and creating saved prompts.
- Parameters: workspace, files, prompt, focus, ephemeral, persist.
- Copy buttons.

Portal disposition: **Intentionally omitted.** This is local macOS app/deep-link integration; the portal uses HTTPS/hash routing and server project IDs.

### Desktop Saved Prompts utilities

- Export Prompts.
- Import Prompts.
- Reset Prompts.

Portal disposition: **Intentionally omitted** until a server prompt-library domain exists. Browser file upload/download alone would not make desktop prompt storage authoritative.

## 21. General → Telemetry

**Desktop source:** `TelemetrySettingsView.swift`

Desktop controls/content:

- Build/runtime telemetry status banner.
- Share crash reports and diagnostics.
- App hang reports.
- Performance timing and tracing.
- Explicit privacy inventory of collected and never-sent data.
- `REPOPROMPT_TELEMETRY_DISABLED=1` process override.

Portal disposition:

- **Intentionally omitted from ordinary user settings.** Server observability and telemetry are deployment/privacy policy, not per-browser app diagnostics. Any future admin surface must preserve the privacy contract and environment-level disable override.

## 22. Prompting → Chat Settings

**Desktop source:** `ChatSettingsView.swift`

Desktop controls:

- Built-in Chat Model.
- Check Recommendations button.
- Oracle Model Presets:
  - Manage Presets
  - Use Oracle Model Presets for MCP
  - current fallback/count/empty states
- Chat Planning Prompt editor:
  - Save
  - Reset to Default
- Advanced Chat Controls:
  - Chat Edit Mode Prompt / file edit format: None, Diff, Whole
  - model capability fallback
  - Model Temperature 0.0–1.0

Portal disposition:

- **Intentionally omitted as a page.** The portal is Agent Mode, not the desktop built-in Chat UI.
- **Overlapping gaps:** server Oracle Model Presets and Agent Models authority belong on their existing portal destinations; they should not be duplicated under a web Chat page.

## 23. Prompting → Workflow Presets

**Desktop source:** `WorkflowPresetsSettingsView.swift`, `CopyPresetsSettingsView.swift`, `ChatPresetsSettingsView.swift`

Canonical structure:

- One destination with Copy/Chat scope picker.
- Search/filter.
- Show/hide in quick menu.
- Built-in vs modified built-in vs custom labeling.
- Add/New, Clone/Duplicate, Edit, Delete.
- Reset built-in overrides.
- Name, emoji icon, description.

Copy preset payload:

- Include files.
- Include user prompt.
- Project Structure mode.
- Code Maps usage.
- Git Diff: None, Selected, Complete.
- Meta-prompt collection.

Chat preset payload:

- Chat Mode: Chat, Plan, Review.
- Project Structure mode.
- Code Maps usage.
- Git Diff: None, Selected, Complete.
- Meta-prompt collection.
- Optional required model/model preset.

Portal disposition:

- **Intentionally omitted.** These package the desktop Copy and built-in Chat workflows, not Agent Mode provider sessions. Do not confuse them with Agent Workflows or workspace selection presets.

## 24. Prompting → Copy Prompt Order

**Desktop source:** `PromptOrderingSettingsMenu.swift`, `PromptAssemblyBuilder.swift`

Desktop controls:

- Drag/reorder these five prompt sections:
  - File Tree
  - File Contents
  - Git Diff
  - Meta Prompts
  - User Instructions
- Reset to Default.
- Duplicate User Instructions at top.
- Explicit statement that this affects copied prompts and built-in chat packaging and **does not affect Agent Mode**.

Portal disposition:

- **Intentionally omitted.** The portal should not expose this on an Agent Mode settings map unless it later gains the same Copy/Chat packaging feature.

---

# Runtime truth table for portal-exposed settings

## Values currently consumed by shared runtime

- `serverDefaultExecutionMode`
- Codex direct permission/tool controls:
  - permission level
  - Bash
  - Search
  - Goals
  - Reasoning Summaries
  - Local Memories
  - supported MCP-server state where the runtime supplies it
- Claude direct permission/tool controls:
  - permission level
  - Bash
  - Strict MCP
  - Lazy Tool Loading
- OpenCode direct permission level / ACP mode mapping
- Cursor direct permission level / ACP auto-approve mapping
- Claude-compatible backend display/base/auth/model behavior/slot mappings
- Provider default model, reasoning effort, speed mode, and service tier where advertised by that provider/model
- Provider connection/vault/managed-auth state

## Legacy persisted keys not currently exposed as editable portal controls

`PortalDesktopSettingKey` still recognizes several values for backward-compatible persistence even though the current shared runtime does not consume them:

- cleanup and handoff
- Oracle/Context Builder/role model routing
- role discovery filtering
- sub-agent policy and per-provider sub-agent modes
- Agent Workflow cleanup/featured/custom data
- Context Builder settings
- MCP tool/model-preset/approval settings
- OpenRouter and custom-provider decorative options
- model overrides
- default worktree preferences

This compatibility surface should be deprecated or migrated in a later schema change. The important product rule is that the portal no longer renders controls whose only effect is writing these unused strings.

# Prioritized remaining work

## P0 — corrected in this pass

- Restore functional CLI recommendation entry point.
- Replace Claude/OpenCode/Cursor generic authentication inputs with one desktop-style Connect action.
- Preserve the working Codex managed flow.
- Expose the canonical 27-tool catalog and real search.
- Correct Manage Presets and Workspace Approvals domain semantics.
- Remove inert model/workflow/Context Builder/MCP/provider controls from the UI.
- Show all runtime-backed direct provider permissions.

## P1 — highest-value real parity gaps

1. **Agent Models profile authority:** global/project scope, recommendation apply, Oracle, Context Builder, four roles, discovery filter, built-in-chat sync if applicable.
2. **Sub-agent permission authority:** Safe Managed / Inherit / Custom consumed by actual launches.
3. **Context Builder settings authority:** budgets, enhancement, timeout, UI/MCP clarify behavior, follow-up analysis, prompt library.
4. **MCP model presets:** durable CRUD and model resolution.
5. **Canonical server app-settings bridge for Advanced:** file scanning, code maps, and history threshold.
6. **Workspace selection preset snapshot/CRUD.**

## P2 — provider/runtime expansion

- OpenRouter runtime.
- Custom OpenAI-compatible runtime with SSRF-safe validation.
- Explicit direct API provider runtimes (Anthropic/OpenAI/etc.).
- Server project CRUD plus client-attributed workspace approvals, if the portal is intended to own project lifecycle.
- Workflow authoring repository.

## P3 — optional browser-native preferences

- Portal theme/text density.
- Browser keyboard shortcuts.
- Portal telemetry/admin diagnostics.

These should be designed for the web surface rather than copied mechanically from macOS settings.

# Regression/acceptance contract

The focused acceptance suite for this slice must prove:

- Unconfigured Claude, OpenCode, and Cursor each render exactly one Connect button and no credential form/password/auth-method select.
- Claude Connect posts only `{ "authenticationMethod": "providerSpecific" }`.
- Connected external accounts show mounted-login state, Test Connection, and Disconnect without claiming to mutate credential files.
- Connected CLI banner contains `Check recommendations to optimize your setup` and Check Now opens the live Agent Models assessment.
- The assessment matches desktop profile `202_608` model/effort candidate chains rather than repeating one provider default for every role.
- OpenCode-only connections get an explicit no-target result rather than invented Oracle/role assignments.
- Codex's existing connection controls still render and behave.
- Claude-compatible backend forms retain write-only secret handling and runtime-backed settings.
- Agent Permissions exposes every direct provider control listed in this audit.
- MCP Tools renders all 27 canonical entries and search works without fake checkboxes.
- Unsupported authorities render no input/select/textarea controls.
- Bootstrap serialization includes the canonical tool catalog.
- Mounted external account connections never create vault references or accept raw browser credentials.
- A mounted-but-logged-out Claude account is rejected, while OpenCode/Cursor require successful ACP initialization preflight.

# Primary source index

Desktop navigation/source map:

- `Sources/RepoPrompt/Features/Settings/Views/SettingsView.swift`

Desktop destination implementations:

- `AgentModeGeneralSettingsView.swift`
- `CLIProvidersSettingsView.swift`
- `AgentModelsSettingsView.swift`
- `AgentPermissionsSettingsView.swift`
- `AgentDirectProviderPermissionsView.swift`
- `AgentSubagentPolicySettingsView.swift`
- `AgentProviderPermissionControlsComponents.swift`
- `AgentModeWorkflowsSettingsView.swift`
- `Sources/RepoPrompt/Features/ContextBuilder/Views/ContextBuilderSettingsView.swift`
- `MCPSettingsView.swift`
- `MCPToolsSettingsView.swift`
- `PermissionsSettingsView.swift`
- `ModelPresetsSettingsView.swift`
- `ModelPresetsSheet.swift`
- `APISettingsView.swift`
- `OpenRouterSettingsView.swift`
- `CustomProviderSettingsView.swift`
- `ModelOverrideSettingsView.swift`
- `Sources/RepoPrompt/Features/Workspaces/Views/ManageWorkspacesView.swift`
- `Sources/RepoPrompt/Features/Workspaces/Views/ManagePresetsView.swift`
- `General/AppearanceSettingsView.swift`
- `General/LicenseUpdatesSettingsView.swift`
- `KeyboardShortcutsSettingsView.swift`
- `AdvancedSettingsView.swift`
- `General/TelemetrySettingsView.swift`
- `ChatSettingsView.swift`
- `WorkflowPresetsSettingsView.swift`
- `CopyPresetsSettingsView.swift`
- `ChatPresetsSettingsView.swift`
- `PromptOrderingSettingsMenu.swift`

Portal/runtime sources:

- `Sources/RepoPromptServiceHTTP/Resources/Portal/index.html`
- `Sources/RepoPromptServiceHTTP/Resources/Portal/portal.js`
- `Sources/RepoPromptServiceHTTP/Resources/Portal/portal.css`
- `Sources/RepoPromptServiceProtocol/PortalSessionDTOs.swift`
- `Sources/RepoPromptServiceProtocol/PortalDesktopSettingsDTOs.swift`
- `Sources/RepoPromptServiceHTTP/RepoPromptHTTPService.swift`
- `Sources/RepoPromptHeadlessRuntime/ProviderSettingsService.swift`
- `Sources/RepoPromptHeadlessRuntime/ProviderConnectionRuntime.swift`
- `Sources/RepoPromptHeadlessRuntime/NativeProviderRuntimes.swift`
- `Sources/RepoPromptDomainRuntime/MCPDomainToolCatalog.swift`
- `Tests/PortalDOMTests/portal.test.mjs`
- `Tests/RepoPromptServerTests/ProviderManagementBackendTests.swift`
