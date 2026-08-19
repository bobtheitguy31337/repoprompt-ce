# Portable runtime semantic owners

This inventory is the PR 2 review surface for identity-sensitive semantics after
`RepoPromptPortableRuntime` extraction. The portable package owns values shared
between products; Desktop keeps only UI policy and persistence adapters in the
narrow owners that already held them. A catch-all Desktop bridge is prohibited.

| Semantic surface | Canonical portable owner | Desktop/root mapping owner |
| --- | --- | --- |
| Workflow raw IDs, command names, prompt rendering, MCP order, and install order | `Packages/RepoPromptPortableRuntime/Sources/RepoPromptShared/Workflows/**` | `Sources/RepoPrompt/Features/AgentMode/Models/AgentWorkflow.swift` and existing Chat/Prompt/Agent Mode callers adapt definitions for UI only. |
| Provider kinds, execution modes, model raw identifiers used across products | `RepoPromptRuntimeModel` and `RepoPromptAgentRuntimeCore` | `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModel.swift`, `AgentModelCatalog.swift`, `Runtime/Providers/AgentRuntimeProviderService.swift`, `Providers/ClaudeCompatible/ClaudeCompatibleModelCatalogAdapter.swift`, and `ClaudeCompatiblePluginBridge.swift` own Desktop display/recommendation policy and explicit conversions. `AgentModel.portableModelIdentifier` and `AgentProviderKind.portableSettingsID` are the narrow portable projections. |
| Provider controls, turn configuration, and permissions | `RepoPromptAgentRuntimeCore/ProviderTurnConfigurationAdapters.swift` plus typed permission values in `RepoPromptRuntimeModel` | `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/**` owns Desktop `UserDefaults` and secure-permission reads. `AgentProviderBindingModels.swift` performs the typed `ProviderTurnSettingsSnapshot` projection; only that value crosses the seam. |
| App settings persistence and presentation | Portable typed values/defaults only when genuinely cross-product | `GlobalSettingsDocument.swift`, `GlobalSettingsManager.swift`, and existing Settings view-model adapters remain authoritative for Desktop persistence. |
| App-backed MCP session/agent projection | Portable identity/snapshot values only when genuinely shared | `AgentManageMCPToolService.swift` and `AgentRunSessionStore.swift` continue mapping live/persisted Desktop session owners; they never query a headless authority or Server store. |
| Protocol-v1 wire/settings DTOs | Deferred to `Packages/RepoPromptServer/Sources/RepoPromptServiceProtocol/**` in PR 3 | No Desktop owner. Root Desktop and public MCP targets must not import `RepoPromptServiceProtocol`. |

## Executable checks

`Scripts/source_layout_guardrails.sh portable-imports` enforces the prohibited
import set, single compiled workflow catalog, single Agent Parity fixture,
Desktop model/provider definition owners, and absence of Server/headless
authority imports from root products. The full source-layout guard additionally
parses both SwiftPM manifests and verifies the target dependency allowlist.

## Explicit deferrals

- PR 3 introduces the Server wire mappings and concrete Server package consumer.
- PR 5 introduces proposal/application lifecycle transitions and durable outbox
  behavior. PR 2 contains only store-independent commands/receipts plus an
  injected store seam and does not change an existing durable schema.
