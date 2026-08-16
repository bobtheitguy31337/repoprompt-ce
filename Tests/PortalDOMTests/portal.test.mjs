import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(testDirectory, "../..");
const portalDirectory = resolve(
  repositoryRoot,
  "Sources/RepoPromptServiceHTTP/Resources/Portal",
);
const htmlSource = readFileSync(resolve(portalDirectory, "index.html"), "utf8");
const scriptSource = readFileSync(
  resolve(portalDirectory, "portal.js"),
  "utf8",
);

const projectOneID = "10000000-0000-0000-0000-000000000010";
const projectTwoID = "10000000-0000-0000-0000-000000000020";
const sessionOneID = "20000000-0000-0000-0000-000000000010";
const sessionTwoID = "20000000-0000-0000-0000-000000000020";

function sessionFixture(overrides = {}) {
  return {
    sessionId: sessionOneID,
    projectId: projectOneID,
    parentSessionId: null,
    title: "Implement provider portal",
    provider: "codex",
    model: "model-a",
    state: "idle",
    revision: 3,
    runGeneration: 1,
    lastActivityAt: "2026-08-10T20:00:00Z",
    ...overrides,
  };
}

function toolCatalog() {
  const applicationTools = [
    "app_settings",
    "bind_context",
    "manage_workspaces",
  ];
  const windowTools = [
    "manage_selection",
    "file_actions",
    "get_code_structure",
    "get_file_tree",
    "read_file",
    "file_search",
    "workspace_context",
    "prompt",
    "apply_edits",
    "oracle_utils",
    "ask_oracle",
    "oracle_send",
    "oracle_chat_log",
    "git",
    "manage_worktree",
    "context_builder",
    "ask_user",
    "agent_explore",
    "agent_run",
    "agent_manage",
    "share_thoughts",
    "set_status",
    "wait_for_next_user_instruction",
    "history",
  ];
  return [...applicationTools, ...windowTools].map((name) => ({
    name,
    scope: applicationTools.includes(name) ? "application" : "window",
    capability: name.includes("file") ? "file_read" : "agent_external_control",
    admissionClass: name === "file_search" ? "file_search" : "control",
  }));
}

function bootstrapFixture(overrides = {}) {
  return {
    projects: [
      {
        projectId: projectOneID,
        name: "Sandbox Workspace",
        state: "active",
        rootNames: ["RepoPrompt"],
      },
    ],
    sessions: [],
    workflows: [],
    tools: toolCatalog(),
    ...overrides,
  };
}

function transcriptPageFixture(session = sessionFixture(), items = []) {
  return {
    session,
    items,
    hasMoreBefore: false,
    hasMoreAfter: false,
    earliestSequence: items[0]?.sessionSequence ?? null,
    latestSequence: items.at(-1)?.sessionSequence ?? null,
  };
}

function model(id, overrides = {}) {
  return {
    id,
    displayName: id === "model-a" ? "Model A" : "Model B",
    description: "Fixture model",
    isProviderDefault: id === "model-a",
    reasoningEfforts: ["low", "medium", "high"],
    speedModes: [],
    serviceTiers: ["fast", "priority"],
    ...overrides,
  };
}

function providerFixture({
  providerID = "codex",
  displayName = "Codex",
  category = "cliProvider",
  deploymentAllowed = true,
  authenticationMethods = [
    "apiKey",
    "enterpriseAccessToken",
    "browserOAuth",
    "deviceCodeBeta",
  ],
  authFlows = [
    {
      kind: "browserOAuth",
      displayName: "Login with ChatGPT",
      startable: false,
      detail: "Browser login is not available on this server.",
    },
    {
      kind: "deviceCodeBeta",
      displayName: "Use device code instead",
      startable: true,
      detail:
        "Uses your Codex subscription. RepoPrompt CE keeps this sign-in separate from ~/.codex.",
    },
  ],
  supportsSpeedMode = false,
  models = [model("model-a"), model("model-b")],
  connection = null,
  preference = {},
  authentication = {},
  preflight = {},
} = {}) {
  const enabled = deploymentAllowed && category === "cliProvider";
  return {
    providerID,
    displayName,
    category,
    summary: `${displayName} fixture provider`,
    deploymentAllowed,
    runtimePreflightVerified: deploymentAllowed,
    effectiveEnabled: Boolean(enabled && connection?.testState === "valid"),
    preference: {
      providerID,
      enabled,
      defaultModel: models[0]?.id || null,
      reasoningEffort: models[0] ? "medium" : null,
      speedMode: null,
      serviceTier: models[0] ? "fast" : null,
      revision: 1,
      ...preference,
    },
    cli:
      category === "cliProvider"
        ? {
            installed: true,
            healthy: true,
            version: "1.2.3",
            expectedVersion: "1.2.3",
            detail: null,
          }
        : null,
    authentication: {
      state: connection ? "authenticated" : "notConfigured",
      authenticated: Boolean(connection),
      method: connection?.authenticationMethod || null,
      accountLabel: connection?.accountLabel || null,
      expiresAt: connection?.expiresAt || null,
      detail: connection
        ? "Authenticated"
        : "Provision credentials on the server",
      ...authentication,
    },
    connection,
    preflight: {
      ready: Boolean(enabled && connection?.testState === "valid"),
      reason: enabled ? "missingCredential" : "disabled",
      detail: enabled
        ? "Provider credential is not configured"
        : "Provider is disabled",
      ...preflight,
    },
    capabilities: {
      supportsModelSelection: true,
      supportsReasoningEffort: true,
      supportsSpeedMode,
      supportsServiceTier: true,
      authenticationMethods,
      authFlows,
    },
    models,
  };
}

function connectionFixture(overrides = {}) {
  return {
    connectionID: "10000000-0000-0000-0000-000000000001",
    providerID: "codex",
    authenticationMethod: "apiKey",
    state: "connected",
    accountLabel: "sandbox team",
    expiresAt: null,
    lastTestedAt: "2026-08-10T20:00:00Z",
    testState: "valid",
    detail: "Credential accepted",
    keyHelperConfigured: false,
    workloadIdentityConfigured: false,
    createdAt: "2026-08-09T20:00:00Z",
    updatedAt: "2026-08-10T20:00:00Z",
    revision: 2,
    ...overrides,
  };
}

function providerCatalog() {
  return [
    providerFixture(),
    providerFixture({
      providerID: "claudeCompatible",
      displayName: "Claude Code",
      authenticationMethods: ["providerSpecific", "apiKey"],
      authFlows: [
        {
          kind: "externalProvisioning",
          displayName: "Server credential provisioning",
          startable: false,
          detail: "Provision credentials on the server.",
        },
      ],
    }),
    providerFixture({
      providerID: "claudeGLM",
      displayName: "CC Zai",
      authenticationMethods: ["authToken"],
      authFlows: [],
      models: [model("glm-4.5-air"), model("glm-4.7"), model("glm-5.2[1m]")],
      preference: { enabled: false },
    }),
    providerFixture({
      providerID: "claudeKimi",
      displayName: "CC Moonshot",
      authenticationMethods: ["apiKey"],
      authFlows: [],
      models: [model("kimi-code")],
      preference: { enabled: false },
    }),
    providerFixture({
      providerID: "claudeCustom",
      displayName: "CC Custom",
      authenticationMethods: [],
      authFlows: [],
      models: [model("custom-claude-compatible")],
      preference: { enabled: false },
    }),
    providerFixture({
      providerID: "openCodeACP",
      displayName: "OpenCode",
      authenticationMethods: ["providerSpecific"],
      authFlows: [
        {
          kind: "externalProvisioning",
          displayName: "Server credential provisioning",
          startable: false,
          detail: "Complete authentication in the isolated account.",
        },
      ],
      models: [],
      preference: {
        defaultModel: null,
        reasoningEffort: null,
        serviceTier: null,
      },
    }),
    providerFixture({
      providerID: "cursorACP",
      displayName: "Cursor",
      authenticationMethods: ["browserLogin"],
      authFlows: [
        {
          kind: "externalProvisioning",
          displayName: "Server credential provisioning",
          startable: false,
          detail: "Complete browser login in the isolated account.",
        },
      ],
      models: [
        model("auto", {
          displayName: "Auto",
          reasoningEfforts: [],
          serviceTiers: [],
        }),
      ],
      preference: {
        defaultModel: "auto",
        reasoningEffort: null,
        serviceTier: null,
      },
    }),
    providerFixture({
      providerID: "xAI",
      displayName: "xAI",
      category: "apiProvider",
      deploymentAllowed: false,
      authenticationMethods: ["apiKey"],
      authFlows: [
        {
          kind: "externalProvisioning",
          displayName: "Server credential provisioning",
          startable: false,
          detail: "Provision credentials on the server.",
        },
      ],
      models: [],
      preference: {
        enabled: false,
        defaultModel: null,
        reasoningEffort: null,
        serviceTier: null,
      },
      preflight: {
        ready: false,
        reason: "deploymentDisabled",
        detail: "Portable runtime is pending",
      },
    }),
  ];
}

function desktopSettingsFixture(overrides = {}) {
  return {
    schemaVersion: 1,
    revision: 0,
    updatedAt: "1970-01-01T00:00:00Z",
    values: {
      providerConversationCleanupAction: "archive",
      agentSessionHandoffInstructions: "",
      oracleModel: "",
      contextBuilderAgent: "codexExec",
      contextBuilderModel: "",
      exploreRoleModel: "",
      engineerRoleModel: "",
      pairRoleModel: "",
      designRoleModel: "",
      restrictAgentDiscoveryToRoles: "false",
      codexPermissionLevel: "autoReview",
      codexBashEnabled: "true",
      codexSearchEnabled: "true",
      codexGoalsEnabled: "true",
      codexReasoningSummariesEnabled: "false",
      codexMemoriesEnabled: "false",
      codexEnabledMCPServers: '["RepoPromptCE"]',
      claudePermissionLevel: "requireApproval",
      claudeBashEnabled: "true",
      claudeStrictMCPEnabled: "true",
      claudeToolSearchEnabled: "true",
      claudeGLMDisplayName: "CC Zai",
      claudeGLMBaseURL: "https://api.z.ai/api/anthropic",
      claudeGLMAuthHeader: "anthropicAuthToken",
      claudeGLMHaikuModel: "glm-4.5-air",
      claudeGLMSonnetModel: "glm-5.2[1m]",
      claudeGLMOpusModel: "glm-5.2[1m]",
      claudeKimiDisplayName: "CC Moonshot",
      claudeKimiBaseURL: "https://api.kimi.com/coding/",
      claudeKimiAuthHeader: "anthropicAPIKey",
      claudeCustomDisplayName: "CC Custom",
      claudeCustomBaseURL: "",
      claudeCustomAuthHeader: "anthropicAPIKey",
      claudeCustomModelBehavior: "noModel",
      claudeCustomHaikuModel: "",
      claudeCustomSonnetModel: "",
      claudeCustomOpusModel: "",
      openCodePermissionLevel: "managedDefault",
      cursorPermissionLevel: "managedDefault",
      subagentPolicy: "safeManaged",
      subagentCodexPermissionLevel: "autoReview",
      subagentClaudePermissionLevel: "requireApproval",
      includeWorkflowCleanupGuidance: "true",
      featuredWorkflows:
        '["build","investigate","oracleExport","orchestrate","optimize","deepPlan"]',
      customWorkflows: "[]",
      contextBuilderBudget: "160000",
      contextBuilderEnhancementMode: "fullRewrite",
      contextBuilderQuestionTimeout: "60",
      contextBuilderUIClarifyingQuestions: "true",
      contextBuilderFollowUpAnalysis: "false",
      contextBuilderAnalysisBudget: "32000",
      contextBuilderMCPClarifyingQuestions: "false",
      contextBuilderCustomInstructions: "",
      mcpToolsEnabled: "true",
      mcpUseModelPresets: "false",
      mcpDisabledTools: "[]",
      workspaceApprovalsGlobal: "false",
      workspaceApprovalOperations: "[]",
      modelPresets: "[]",
      openRouterIncludeDefaults: "true",
      openRouterUseCustomSettings: "false",
      openRouterMaxTokens: "0",
      customProviderIncludeContentType: "true",
      modelOverrides: "[]",
      defaultWorktreeMode: "isolated",
      worktreeBaseRef: "",
      removeCompletedWorktrees: "false",
      serverDefaultExecutionMode: "workspaceWrite",
      ...overrides,
    },
  };
}

function typedSettingsFixtures(providers, bootstrap) {
  const codex = providers.find((provider) => provider.providerID === "codex");
  const sol = codex?.models?.find((entry) =>
    `${entry.id} ${entry.displayName}`.toLowerCase().includes("gpt-5.6 sol"),
  );
  const recommendationTarget = (effort) =>
    sol && sol.reasoningEfforts.includes(effort)
      ? {
          providerID: "codex",
          modelID: sol.id,
          reasoningEffort: effort,
          pinned: false,
        }
      : null;
  const recommendations = [
    ["oracle", "high"],
    ["contextBuilder", "low"],
    ["explore", "low"],
    ["engineer", "medium"],
    ["pair", "high"],
    ["design", "medium"],
  ].map(([target, effort]) => {
    const recommendedTarget = recommendationTarget(effort);
    return {
      target,
      recommendedTarget,
      availability: recommendedTarget ? "exact" : "unavailable",
      detail: recommendedTarget
        ? "Exact profile 202_608 target is advertised"
        : "No recommendation provider is advertised",
    };
  });
  const emptyProfile = {
    oracle: null,
    contextBuilder: null,
    explore: null,
    engineer: null,
    pair: null,
    design: null,
    restrictDiscoveryToRoleModels: false,
  };
  const contextProfile = {
    budget: 160000,
    enhancementMode: "rewrite",
    questionTimeoutSeconds: 60,
    portalClarifyingQuestions: true,
    mcpClarifyingQuestions: false,
    followUpAnalysis: "disabled",
    followUpBudget: 40000,
  };
  return {
    agentModels: {
      globalProfile: emptyProfile,
      globalRevision: 0,
      projectID: projectOneID,
      projectMode: "inheritGlobal",
      projectProfile: null,
      projectRevision: 0,
      effectiveProfile: emptyProfile,
      recommendationProfileVersion: "202_608",
      recommendations,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    directAgentPermissions: {
      settings: {
        codex: {
          sandboxMode: "workspace-write",
          approvalPolicy: "on-request",
          approvalReviewer: "auto-review",
          bashEnabled: true,
        },
        claude: {
          permissionMode: "default",
          bashEnabled: true,
          mcpStrictModeEnabled: true,
        },
        openCode: { permissionLevel: "managedDefault" },
        cursor: { permissionLevel: "managedDefault" },
      },
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    subagentPermissions: {
      settings: {
        policy: "safeManaged",
        codex: "autoReview",
        claude: "requireApproval",
        openCode: "managedDefault",
        cursor: "managedDefault",
      },
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    contextBuilder: {
      globalProfile: contextProfile,
      globalRevision: 0,
      projectID: projectOneID,
      projectMode: "inheritGlobal",
      projectProfile: null,
      projectRevision: 0,
      effectiveProfile: contextProfile,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    modelPresets: {
      presets: [],
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    advanced: {
      settings: {
        respectRepoIgnore: true,
        respectCursorIgnore: true,
        respectNestedIgnoreFiles: true,
        followSymbolicLinks: false,
        showEmptyFolders: true,
        codeMapsEnabled: true,
        historyIdleThresholdMinutes: 5,
      },
      revision: 0,
      scannerPolicyGeneration: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    workspaceApprovals: {
      settings: {
        autoApproveAll: false,
        autoApproveOperations: [],
        clientPolicies: {
          "cursor-family": {
            clientID: "cursor-family",
            allowedOperations: ["create_workspace"],
            createdAt: "1970-01-01T00:00:00Z",
            lastUsedAt: null,
          },
        },
      },
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    mcpDisabledTools: {
      settings: { disabledTools: [] },
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    showModelPresets: {
      settings: { showModelPresets: false },
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    selectionPresets: {
      projectID: projectOneID,
      presets: [],
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    workflows: {
      workflows: (bootstrap.workflows || []).map((workflow) => ({
        workflowID: workflow.workflowID,
        source: workflow.source || "builtin",
        name: workflow.name,
        definition:
          workflow.definition ||
          `# ${workflow.name}\n\n## Purpose\nFixture workflow.\n\n## Instructions\n- Work safely.`,
        contentDigest: "fixture-digest",
        enabled: workflow.enabled,
        visible: workflow.visible ?? true,
        featuredOrder: workflow.featuredOrder ?? null,
        rowRevision: workflow.rowRevision || 1,
      })),
      includeSessionCleanupGuidance: true,
      revision: 0,
      updatedAt: "1970-01-01T00:00:00Z",
    },
    selection: {
      sessionId: sessionOneID,
      entries: [],
      revision: 1,
      bindingRevision: 1,
    },
    directConfigurations: {},
  };
}

function directConfigurationFixture(providerID, overrides = {}) {
  return {
    providerID,
    baseURL:
      providerID === "customOpenAICompatible"
        ? "https://models.example/v1"
        : null,
    preferredModel: null,
    maximumOutputTokens: 4096,
    customHeaders: {},
    contentTypePolicy: "applicationJSON",
    revision: 1,
    updatedAt: "2026-08-11T20:00:00Z",
    ...overrides,
  };
}

function jsonResponse(body, status = 200) {
  const encoded = JSON.stringify(body);
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get(name) {
        return name.toLowerCase() === "content-type"
          ? "application/json; charset=utf-8"
          : null;
      },
    },
    async text() {
      return encoded;
    },
  };
}

function emptyResponse(status = 204) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    async text() {
      return "";
    },
  };
}

async function settle() {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 0));
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 0));
}

async function waitFor(predicate, message = "condition was not reached") {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await settle();
  }
  assert.fail(message);
}

async function createHarness({
  hash = "#settings/cli-providers",
  providers = providerCatalog(),
  bootstrap = bootstrapFixture(),
  desktopSettings = desktopSettingsFixture(),
  typedSettings = null,
  handler,
} = {}) {
  const dom = new JSDOM(htmlSource, {
    url: `https://server.example/portal/${hash}`,
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const calls = [];
  const context = {
    providers,
    bootstrap,
    desktopSettings,
    typedSettings: typedSettings || typedSettingsFixtures(providers, bootstrap),
  };

  window.__REPOPROMPT_PORTAL_TEST_HOOK__ = true;
  window.fetch = async (path, options = {}) => {
    const call = {
      path: String(path),
      method: (options.method || "GET").toUpperCase(),
      body: options.body || null,
      headers: options.headers || {},
    };
    calls.push(call);
    if (handler) {
      const handled = await handler(call, context);
      if (handled) return handled;
    }
    if (call.path === "api/v1/bootstrap") {
      return jsonResponse(context.bootstrap);
    }
    if (call.path === "api/v1/desktop-settings" && call.method === "GET") {
      return jsonResponse(context.desktopSettings);
    }
    if (call.path === "api/v1/desktop-settings" && call.method === "PATCH") {
      const payload = JSON.parse(call.body);
      context.desktopSettings = {
        ...context.desktopSettings,
        revision: context.desktopSettings.revision + 1,
        updatedAt: "2026-08-11T20:00:00Z",
        values: { ...context.desktopSettings.values, ...payload.changes },
      };
      return jsonResponse(context.desktopSettings);
    }
    if (
      call.path === "api/v1/settings/agent-models" ||
      /^api\/v1\/projects\/[^/]+\/settings\/agent-models$/.test(call.path)
    ) {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        const project = call.path.includes("/projects/");
        context.typedSettings.agentModels = {
          ...context.typedSettings.agentModels,
          ...(project
            ? {
                projectMode: payload.mode,
                projectProfile: payload.profile,
                projectRevision:
                  context.typedSettings.agentModels.projectRevision + 1,
                effectiveProfile:
                  payload.mode === "projectOverride"
                    ? payload.profile
                    : context.typedSettings.agentModels.globalProfile,
              }
            : {
                globalProfile: payload.profile,
                globalRevision:
                  context.typedSettings.agentModels.globalRevision + 1,
                effectiveProfile: payload.profile,
              }),
        };
      }
      return jsonResponse(context.typedSettings.agentModels);
    }
    if (call.path.includes("settings/agent-models/copy-global")) {
      context.typedSettings.agentModels = {
        ...context.typedSettings.agentModels,
        projectMode: "projectOverride",
        projectProfile: context.typedSettings.agentModels.globalProfile,
        effectiveProfile: context.typedSettings.agentModels.globalProfile,
        projectRevision: context.typedSettings.agentModels.projectRevision + 1,
      };
      return jsonResponse(context.typedSettings.agentModels);
    }
    if (call.path.includes("settings/agent-models/apply-recommendations")) {
      return jsonResponse(context.typedSettings.agentModels);
    }
    if (call.path === "api/v1/settings/direct-agent-permissions") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.directAgentPermissions = {
          ...context.typedSettings.directAgentPermissions,
          settings: payload.settings,
          revision: context.typedSettings.directAgentPermissions.revision + 1,
        };
      }
      return jsonResponse(context.typedSettings.directAgentPermissions);
    }
    if (call.path === "api/v1/settings/subagent-permissions") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.subagentPermissions = {
          ...context.typedSettings.subagentPermissions,
          settings: payload.settings,
          revision: context.typedSettings.subagentPermissions.revision + 1,
        };
      }
      return jsonResponse(context.typedSettings.subagentPermissions);
    }
    if (
      call.path === "api/v1/settings/context-builder" ||
      /^api\/v1\/projects\/[^/]+\/settings\/context-builder$/.test(call.path)
    ) {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        const project = call.path.includes("/projects/");
        context.typedSettings.contextBuilder = {
          ...context.typedSettings.contextBuilder,
          ...(project
            ? {
                projectMode: payload.mode,
                projectProfile: payload.profile,
                projectRevision:
                  context.typedSettings.contextBuilder.projectRevision + 1,
                effectiveProfile:
                  payload.mode === "projectOverride"
                    ? payload.profile
                    : context.typedSettings.contextBuilder.globalProfile,
              }
            : {
                globalProfile: payload.profile,
                globalRevision:
                  context.typedSettings.contextBuilder.globalRevision + 1,
                effectiveProfile: payload.profile,
              }),
        };
      }
      return jsonResponse(context.typedSettings.contextBuilder);
    }
    if (call.path.includes("settings/context-builder/copy-global")) {
      context.typedSettings.contextBuilder = {
        ...context.typedSettings.contextBuilder,
        projectMode: "projectOverride",
        projectProfile: context.typedSettings.contextBuilder.globalProfile,
        effectiveProfile: context.typedSettings.contextBuilder.globalProfile,
        projectRevision:
          context.typedSettings.contextBuilder.projectRevision + 1,
      };
      return jsonResponse(context.typedSettings.contextBuilder);
    }
    if (call.path === "api/v1/settings/model-presets") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.modelPresets = {
          ...context.typedSettings.modelPresets,
          presets: payload.presets,
          revision: context.typedSettings.modelPresets.revision + 1,
        };
      }
      return jsonResponse(context.typedSettings.modelPresets);
    }
    if (call.path === "api/v1/settings/advanced") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.advanced = {
          ...context.typedSettings.advanced,
          settings: payload.settings,
          revision: context.typedSettings.advanced.revision + 1,
          scannerPolicyGeneration:
            context.typedSettings.advanced.scannerPolicyGeneration + 1,
        };
      }
      return jsonResponse(context.typedSettings.advanced);
    }
    if (call.path === "api/v1/settings/workspace-approvals") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.workspaceApprovals = {
          ...context.typedSettings.workspaceApprovals,
          settings: payload.settings,
          revision: context.typedSettings.workspaceApprovals.revision + 1,
        };
      }
      return jsonResponse(context.typedSettings.workspaceApprovals);
    }
    if (call.path === "api/v1/settings/mcp-disabled-tools") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.mcpDisabledTools = {
          ...context.typedSettings.mcpDisabledTools,
          settings: payload.settings,
          revision: context.typedSettings.mcpDisabledTools.revision + 1,
        };
      }
      return jsonResponse(context.typedSettings.mcpDisabledTools);
    }
    if (call.path === "api/v1/settings/show-model-presets") {
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.showModelPresets = {
          ...context.typedSettings.showModelPresets,
          settings: payload.settings,
          revision: context.typedSettings.showModelPresets.revision + 1,
        };
      }
      return jsonResponse(context.typedSettings.showModelPresets);
    }
    if (/^api\/v1\/projects\/[^/]+\/selection-presets$/.test(call.path)) {
      return jsonResponse(context.typedSettings.selectionPresets);
    }
    if (/^api\/v1\/projects\/[^/]+\/selection-presets\/.+$/.test(call.path)) {
      if (call.path.endsWith("/apply")) {
        return jsonResponse({
          ...context.typedSettings.selection,
          revision: context.typedSettings.selection.revision + 1,
        });
      }
      return jsonResponse(context.typedSettings.selectionPresets);
    }
    if (call.path === "api/v1/workflows") {
      return jsonResponse(context.typedSettings.workflows);
    }
    if (/^api\/v1\/workflows(?:\/|$)/.test(call.path)) {
      return jsonResponse(context.typedSettings.workflows);
    }
    const selectionMatch = call.path.match(
      /^api\/v1\/sessions\/([^/]+)\/selection$/,
    );
    if (selectionMatch && call.method === "GET") {
      return jsonResponse({
        ...context.typedSettings.selection,
        sessionId: decodeURIComponent(selectionMatch[1]),
      });
    }
    const directConfigurationMatch = call.path.match(
      /^api\/v1\/provider-settings\/([^/]+)\/direct-configuration$/,
    );
    if (directConfigurationMatch) {
      const providerID = decodeURIComponent(directConfigurationMatch[1]);
      const current =
        context.typedSettings.directConfigurations[providerID] ||
        directConfigurationFixture(providerID);
      if (call.method === "PATCH") {
        const payload = JSON.parse(call.body);
        context.typedSettings.directConfigurations[providerID] = {
          providerID,
          ...payload,
          revision: current.revision + 1,
          updatedAt: "2026-08-11T21:00:00Z",
        };
      } else {
        context.typedSettings.directConfigurations[providerID] = current;
      }
      return jsonResponse(
        context.typedSettings.directConfigurations[providerID],
      );
    }
    if (
      call.path.startsWith("api/v1/provider-settings") &&
      call.method === "GET"
    ) {
      return jsonResponse({
        providers: context.providers,
        generatedAt: "2026-08-10T20:00:00Z",
      });
    }
    const preferenceMatch = call.path.match(
      /^api\/v1\/provider-settings\/([^/]+)\/(enable|disable)$/,
    );
    if (preferenceMatch && call.method === "POST") {
      const provider = context.providers.find(
        (item) => item.providerID === decodeURIComponent(preferenceMatch[1]),
      );
      provider.preference = {
        ...provider.preference,
        enabled: preferenceMatch[2] === "enable",
        revision: provider.preference.revision + 1,
      };
      return jsonResponse(provider);
    }
    const connectMatch = call.path.match(
      /^api\/v1\/provider-settings\/([^/]+)\/connect$/,
    );
    if (connectMatch && call.method === "POST") {
      const provider = context.providers.find(
        (item) => item.providerID === decodeURIComponent(connectMatch[1]),
      );
      const payload = JSON.parse(call.body);
      provider.connection = connectionFixture({
        providerID: provider.providerID,
        authenticationMethod: payload.authenticationMethod,
        accountLabel: null,
        detail: "External credential source is mounted",
      });
      provider.authentication = {
        ...provider.authentication,
        state: "authenticated",
        authenticated: true,
        method: payload.authenticationMethod,
        detail: "Authenticated",
      };
      provider.preflight = {
        ready: true,
        reason: "ready",
        detail: "Provider is ready",
      };
      provider.effectiveEnabled = provider.preference.enabled;
      return jsonResponse(provider);
    }
    throw new Error(`Unexpected request: ${call.method} ${call.path}`);
  };

  window.eval(scriptSource);
  await window.RepoPromptPortalTest.whenIdle();
  await settle();

  return {
    dom,
    window,
    document: window.document,
    calls,
    context,
    async close() {
      await window.RepoPromptPortalTest.whenIdle();
      await settle();
      dom.window.close();
    },
  };
}

function change(window, control, value) {
  if (control.type === "checkbox") control.checked = value;
  else control.value = value;
  control.dispatchEvent(new window.Event("change", { bubbles: true }));
}

function submit(window, form) {
  form.dispatchEvent(
    new window.Event("submit", { bubbles: true, cancelable: true }),
  );
}

function click(window, control) {
  control.dispatchEvent(
    new window.MouseEvent("click", { bubbles: true, cancelable: true }),
  );
}

test("filtered Desktop settings hierarchy deep-links, searches, and excludes desktop-only destinations", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { document, window } = harness;

  assert.equal(document.getElementById("home-shell").hidden, true);
  assert.equal(
    document.getElementById("settings-detail-title").textContent,
    "CLI Providers",
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Primary way to add Agent Mode model support/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Claude Code–Compatible Backends/,
  );
  assert.equal(document.querySelectorAll(".desktop-provider-card").length, 8);
  assert.deepEqual(
    [
      ...document.querySelectorAll(
        ".compatible-backend-list [data-provider-id]",
      ),
    ].map((row) => row.dataset.providerId),
    ["claudeGLM", "claudeKimi", "claudeCustom"],
  );

  const navText = document.getElementById("settings-nav").textContent;
  for (const included of [
    "Agent Permissions",
    "Context Builder",
    "MCP Server",
    "Workspace Approvals",
    "Manage Workspaces",
    "Portal Appearance",
    "Advanced",
  ]) {
    assert.match(navText, new RegExp(included));
  }
  for (const excluded of [
    "Keyboard Shortcuts",
    "Updates",
    "Telemetry",
    "Copy Prompt Order",
  ]) {
    assert.doesNotMatch(navText, new RegExp(excluded));
  }

  window.location.hash = "#settings/agent-models";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  assert.equal(
    document.getElementById("settings-detail-title").textContent,
    "Agent Models",
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Recommended Setup/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Provider Defaults/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /agent_manage list_agents/,
  );
  assert.doesNotMatch(
    document.getElementById("settings-content").textContent,
    /Filters list_models discovery/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Unassigned \(fail-closed\)/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Unassigned \(tracks recommendation\)/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Use global settings/,
  );

  const search = document.getElementById("settings-search");
  search.focus();
  search.value = "Context Builder";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(
    document.querySelector('[data-route="context-builder"]').hidden,
    false,
  );
  assert.equal(
    document.querySelector('[data-route="cli-providers"]').hidden,
    true,
  );
  search.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
  );
  assert.equal(search.value, "");

  search.value = "CLI Providers";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  search.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
  );
  await settle();
  assert.equal(window.location.hash, "#settings/cli-providers");

  const skip = document.querySelector('[data-action="skip-content"]');
  click(window, skip);
  assert.equal(
    document.activeElement,
    document.getElementById("settings-main-content"),
  );
});

test("narrow settings navigation uses an accessible focus-trapped drawer", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { document, window } = harness;
  window.matchMedia = () => ({ matches: true });

  const toggle = document.getElementById("settings-drawer-toggle");
  toggle.focus();
  click(window, toggle);
  await settle();
  assert.equal(toggle.getAttribute("aria-expanded"), "true");
  assert.equal(
    document.getElementById("settings-sidebar").getAttribute("aria-modal"),
    "true",
  );
  assert.equal(
    document.activeElement,
    document.getElementById("settings-search"),
  );

  document.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
  );
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  assert.equal(document.activeElement, toggle);
});

test("unconfigured Claude Code, OpenCode, and Cursor use one mounted-account Connect action", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { calls, document, window } = harness;

  for (const providerID of ["claudeCompatible", "openCodeACP", "cursorACP"]) {
    const card = document.querySelector(`[data-provider-id="${providerID}"]`);
    card.open = true;
    const connectButtons = [...card.querySelectorAll("button")].filter(
      (button) => button.textContent.trim() === "Connect",
    );
    assert.equal(
      connectButtons.length,
      1,
      `${providerID} should have one Connect`,
    );
    assert.equal(card.querySelector(".credential-form"), null);
    assert.equal(card.querySelector(".credential-card"), null);
    assert.equal(
      card.querySelector('select[name="authenticationMethod"]'),
      null,
    );
    assert.equal(card.querySelector('input[type="password"]'), null);
  }

  const claude = document.querySelector(
    '[data-provider-id="claudeCompatible"]',
  );
  click(
    window,
    [...claude.querySelectorAll("button")].find(
      (button) => button.textContent.trim() === "Connect",
    ),
  );
  await waitFor(() =>
    document
      .querySelector('[data-provider-id="claudeCompatible"]')
      ?.textContent.includes("Mounted CLI login"),
  );
  const connectCall = calls.find(
    (call) => call.path === "api/v1/provider-settings/claudeCompatible/connect",
  );
  assert.deepEqual(JSON.parse(connectCall.body), {
    authenticationMethod: "providerSpecific",
  });
  const refreshed = document.querySelector(
    '[data-provider-id="claudeCompatible"]',
  );
  refreshed.open = true;
  assert.match(refreshed.textContent, /Mounted CLI login/);
  assert.match(refreshed.textContent, /Disconnect/);
  assert.doesNotMatch(refreshed.textContent, /Authentication method\s*Api Key/);
});

test("connected CLI recommendation Check Now opens a live desktop-style assessment", async (t) => {
  const providers = providerCatalog();
  const connection = connectionFixture({
    authenticationMethod: "deviceCodeBeta",
  });
  providers[0] = providerFixture({
    connection,
    models: [
      model("gpt-5.6-sol", {
        displayName: "GPT-5.6 Sol",
        reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
      }),
    ],
    authentication: {
      authenticated: true,
      state: "authenticated",
      method: "deviceCodeBeta",
      accountLabel: "sandbox team",
    },
  });
  const harness = await createHarness({ providers });
  t.after(() => harness.close());
  const { document, window } = harness;

  assert.match(
    document.querySelector(".recommendation-banner").textContent,
    /Check recommendations to optimize your setup/,
  );
  const check = [...document.querySelectorAll("button")].find(
    (button) => button.textContent.trim() === "Check Now",
  );
  assert.ok(check);
  click(window, check);
  await waitFor(
    () =>
      document.getElementById("settings-detail-title").textContent ===
      "Agent Models",
  );
  const text = document.getElementById("settings-content").textContent;
  assert.match(text, /Recommendation check complete/);
  assert.match(text, /Oracle.*Codex · gpt-5\.6-sol · High/s);
  assert.match(text, /Context Builder.*Codex · gpt-5\.6-sol · Low/s);
  assert.match(text, /Explore.*Codex · gpt-5\.6-sol · Low/s);
  assert.match(text, /Engineer.*Codex · gpt-5\.6-sol · Medium/s);
  assert.match(text, /Pair.*Codex · gpt-5\.6-sol · High/s);
  assert.match(text, /Design.*Codex · gpt-5\.6-sol · Medium/s);
  assert.match(text, /profile 202_608/);
  assert.match(text, /Provider Defaults/);
  assert.match(text, /Save Agent Routes/);
});

test("overview live-reads typed Agent Models assignments", async (t) => {
  const harness = await createHarness({ hash: "#settings/overview" });
  t.after(() => harness.close());
  const text = harness.document.getElementById("settings-content").textContent;
  assert.match(text, /Live routing/);
  assert.match(text, /Live permissions/);
  assert.match(text, /Unconfigured/);
  assert.match(text, /Tracks recommendation/);
  assert.match(text, /Fail-closed when unassigned/);
  assert.match(text, /Workspace Write/);
  assert.match(text, /Safe Managed/);
  assert.match(text, /Require Approval/);
});

test("desktop recommendation assessment explains OpenCode-only connections without inventing role assignments", async (t) => {
  const providers = providerCatalog();
  const connection = connectionFixture({
    providerID: "openCodeACP",
    authenticationMethod: "providerSpecific",
  });
  providers[5] = providerFixture({
    providerID: "openCodeACP",
    displayName: "OpenCode",
    authenticationMethods: ["providerSpecific"],
    authFlows: [],
    models: [],
    connection,
    preference: {
      defaultModel: null,
      reasoningEffort: null,
      serviceTier: null,
    },
    authentication: {
      authenticated: true,
      state: "authenticated",
      method: "providerSpecific",
    },
  });
  const harness = await createHarness({ providers });
  t.after(() => harness.close());
  const { document, window } = harness;

  const check = [...document.querySelectorAll("button")].find(
    (button) => button.textContent.trim() === "Check Now",
  );
  assert.ok(check);
  click(window, check);
  await waitFor(
    () =>
      document.getElementById("settings-detail-title").textContent ===
      "Agent Models",
  );
  const text = document.getElementById("settings-content").textContent;
  assert.match(text, /OpenCode remains a connection signal/);
  assert.match(text, /Unavailable/);
  const assignedRoutes = [
    ...document.querySelectorAll(".typed-route-row select"),
  ].map((select) => select.value);
  assert.equal(assignedRoutes.length, 6);
  assert.ok(assignedRoutes.every((value) => !value.startsWith("openCodeACP|")));
});

test("MCP Tools renders and searches the complete canonical server catalog with live-read toggles", async (t) => {
  const harness = await createHarness({ hash: "#settings/mcp-tools" });
  t.after(() => harness.close());
  const { calls, document, window } = harness;

  assert.equal(document.querySelectorAll(".tool-catalog-row").length, 27);
  const text = document.getElementById("settings-content").textContent;
  for (const name of [
    "app_settings",
    "file_actions",
    "oracle_send",
    "agent_run",
    "history",
  ]) {
    assert.match(text, new RegExp(name));
  }
  assert.equal(
    document.querySelectorAll('.tool-catalog-list input[type="checkbox"]')
      .length,
    27,
  );
  const fileActions = document.querySelector(
    'input[aria-label="file_actions"]',
  );
  change(window, fileActions, false);
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/mcp-disabled-tools",
    ),
  );
  const payload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/mcp-disabled-tools",
    ).body,
  );
  assert.deepEqual(Object.keys(payload).sort(), [
    "expectedRevision",
    "settings",
  ]);
  assert.deepEqual(payload.settings.disabledTools, ["file_actions"]);

  const search = document.querySelector('input[aria-label="Search MCP tools"]');
  search.value = "oracle";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(document.querySelectorAll(".tool-catalog-row").length, 4);
  assert.match(document.querySelector(".tool-count").textContent, /4 of 27/);
});

test("Workspace Approvals and MCP Server live-read the typed MCP workspace authority", async (t) => {
  const harness = await createHarness({ hash: "#settings/workspace-approvals" });
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const text = document.getElementById("settings-content").textContent;

  assert.match(text, /Auto-approve All Operations/);
  assert.match(text, /Create Workspace/);
  assert.match(text, /Trusted Clients/);
  assert.match(text, /cursor-family/);
  assert.doesNotMatch(text, /Not applicable/);
  assert.doesNotMatch(text, /write operations/);
  assert.equal(
    document.querySelectorAll('input[type="checkbox"]').length,
    5,
  );

  const master = document.querySelector(
    'input[aria-label="Auto-approve All Operations"]',
  );
  change(window, master, true);
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/workspace-approvals",
    ),
  );
  const workspacePayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/workspace-approvals",
    ).body,
  );
  assert.equal(workspacePayload.settings.autoApproveAll, true);
  assert.deepEqual(workspacePayload.settings.autoApproveOperations, []);
  assert.equal(
    workspacePayload.settings.clientPolicies["cursor-family"].clientID,
    "cursor-family",
  );

  window.location.hash = "#settings/mcp-server";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  await settle();
  const presets = document.querySelector(
    'input[aria-label="Use Oracle Model Presets for MCP"]',
  );
  assert.equal(presets.checked, false);
  change(window, presets, true);
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/show-model-presets",
    ),
  );
  const presetsPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/show-model-presets",
    ).body,
  );
  assert.deepEqual(presetsPayload, {
    expectedRevision: 0,
    settings: { showModelPresets: true },
  });
});

test("Agent Permissions exposes every runtime-backed desktop direct-provider control", async (t) => {
  const harness = await createHarness({ hash: "#settings/agent-permissions" });
  t.after(() => harness.close());
  const { document } = harness;
  const content = document.getElementById("settings-content");
  const text = content.textContent;

  for (const expected of [
    "Default Execution Mode",
    "Codex Direct Agent",
    "Permission Level",
    "Sandbox",
    "Approval Policy",
    "Approval Reviewer",
    "Core tools",
    "Bash",
    "Search",
    "Goals",
    "Reasoning Summaries",
    "Local Memories",
    "RepoPrompt · Required",
    "Claude Code Direct Agent",
    "RepoPrompt Only (Strict MCP)",
    "Lazy Tool Loading",
    "Sys Prompt Packaging",
    "User Message (Keep Native)",
    "OpenCode Direct Agent",
    "ACP Session Mode",
    "Cursor Direct Agent",
    "ACP Auto-Approve",
    "Safe Managed",
    "Inherit Provider Settings",
    "Custom",
  ]) {
    assert.ok(text.includes(expected), `missing ${expected}`);
  }
  assert.equal(content.querySelectorAll("select").length, 12);
  assert.equal(content.querySelectorAll('input[type="checkbox"]').length, 8);
  assert.match(text, /frozen into every child session/);
});

test("unsupported desktop authorities are explicit and do not expose inert controls", async (t) => {
  const harness = await createHarness({
    bootstrap: bootstrapFixture({
      workflows: [{ workflowID: "build", name: "Build", enabled: true }],
    }),
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  const cases = [
    ["manage-workspaces", /Operator-provisioned here/, /Open Folder/],
    ["openrouter", /Deployment-disabled/, /API key/],
    ["custom-api", /pinned-address egress/, /Preferred Model/],
    ["model-config", /Desktop Per-Model Overrides/, /Temperature slider/],
  ];
  for (const [route, expected, forbidden] of cases) {
    window.location.hash = `#settings/${route}`;
    window.dispatchEvent(new window.HashChangeEvent("hashchange"));
    await settle();
    const content = document.getElementById("settings-content");
    assert.match(content.textContent, expected);
    assert.doesNotMatch(content.textContent, forbidden);
    assert.equal(content.querySelectorAll("input, select, textarea").length, 0);
  }
});

test("typed settings pages mutate revisioned server authorities", async (t) => {
  const harness = await createHarness({ hash: "#settings/agent-models" });
  t.after(() => harness.close());
  const { calls, document, window } = harness;

  assert.match(
    document.getElementById("settings-content").textContent,
    /profile 202_608/,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Save Agent Routes/,
  );
  assert.doesNotMatch(scriptSource, /function agentModelRecommendations/);

  const scope = document.querySelector(
    'select[aria-label="Agent Models scope"]',
  );
  change(window, scope, "projectOverride");
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" && call.path.endsWith("/settings/agent-models"),
    ),
  );
  const agentModelsCall = calls.find(
    (call) =>
      call.method === "PATCH" && call.path.endsWith("/settings/agent-models"),
  );
  const agentModelsPayload = JSON.parse(agentModelsCall.body);
  assert.deepEqual(Object.keys(agentModelsPayload).sort(), [
    "expectedRevision",
    "mode",
    "profile",
  ]);
  assert.deepEqual(Object.keys(agentModelsPayload.profile).sort(), [
    "contextBuilder",
    "design",
    "engineer",
    "explore",
    "oracle",
    "pair",
    "restrictDiscoveryToRoleModels",
  ]);
  assert.equal(agentModelsPayload.mode, "projectOverride");
  await settle();
  const oracleRoute = document.querySelector(
    'select[aria-label="Oracle route"]',
  );
  oracleRoute.value =
    [...oracleRoute.options].find((option) => option.value)?.value || "";
  submit(window, oracleRoute.closest("form"));
  await waitFor(
    () =>
      calls.filter(
        (call) =>
          call.method === "PATCH" &&
          call.path.endsWith("/settings/agent-models"),
      ).length === 2,
  );
  const savedAgentModelsPayload = JSON.parse(
    calls.filter(
      (call) =>
        call.method === "PATCH" && call.path.endsWith("/settings/agent-models"),
    )[1].body,
  );
  assert.deepEqual(Object.keys(savedAgentModelsPayload.profile.oracle).sort(), [
    "modelID",
    "pinned",
    "providerID",
    "reasoningEffort",
  ]);
  assert.equal(savedAgentModelsPayload.profile.oracle.pinned, false);

  window.location.hash = "#settings/agent-permissions";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  await settle();
  const sandbox = document.querySelector('select[aria-label="Sandbox"]');
  change(window, sandbox, "read-only");
  submit(
    window,
    [...document.querySelectorAll("form")].find((form) =>
      form.textContent.includes("Save Direct Agents"),
    ),
  );
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/direct-agent-permissions",
    ),
  );
  const directPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/direct-agent-permissions",
    ).body,
  );
  assert.deepEqual(Object.keys(directPayload).sort(), [
    "expectedRevision",
    "settings",
  ]);
  assert.deepEqual(Object.keys(directPayload.settings).sort(), [
    "claude",
    "codex",
    "cursor",
    "openCode",
  ]);
  assert.deepEqual(Object.keys(directPayload.settings.codex).sort(), [
    "approvalPolicy",
    "approvalReviewer",
    "bashEnabled",
    "sandboxMode",
  ]);
  assert.equal(directPayload.settings.codex.sandboxMode, "read-only");
  assert.equal(directPayload.settings.claude.permissionMode, "default");
  assert.equal(directPayload.settings.claude.mcpStrictModeEnabled, true);

  const policy = document.querySelector(
    'select[aria-label="Sub-agent permission policy"]',
  );
  change(window, policy, "custom");
  assert.match(
    document.getElementById("settings-content").textContent,
    /Full Access can allow delegated agents/,
  );
  submit(
    window,
    [...document.querySelectorAll("form")].find((form) =>
      form.textContent.includes("Save Sub-Agent Policy"),
    ),
  );
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/subagent-permissions",
    ),
  );
  const subagentPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/subagent-permissions",
    ).body,
  );
  assert.deepEqual(Object.keys(subagentPayload).sort(), [
    "expectedRevision",
    "settings",
  ]);
  assert.deepEqual(Object.keys(subagentPayload.settings).sort(), [
    "claude",
    "codex",
    "cursor",
    "openCode",
    "policy",
  ]);
  assert.equal(subagentPayload.settings.policy, "custom");

  window.location.hash = "#settings/advanced";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  await settle();
  assert.match(
    document.getElementById("settings-content").textContent,
    /scanner policy generation 0/,
  );
  const historyThreshold = document.querySelector(
    'input[aria-label="Default history idle threshold"]',
  );
  assert.equal(historyThreshold.min, "0");
  assert.equal(historyThreshold.max, "60");
  assert.equal(historyThreshold.step, "1");
  click(
    window,
    [...document.querySelectorAll("button")].find(
      (button) => button.textContent === "Save Advanced Settings",
    ),
  );
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" && call.path === "api/v1/settings/advanced",
    ),
  );
  const advancedPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" && call.path === "api/v1/settings/advanced",
    ).body,
  );
  assert.deepEqual(Object.keys(advancedPayload).sort(), [
    "expectedRevision",
    "settings",
  ]);
  assert.deepEqual(Object.keys(advancedPayload.settings).sort(), [
    "codeMapsEnabled",
    "followSymbolicLinks",
    "historyIdleThresholdMinutes",
    "respectCursorIgnore",
    "respectNestedIgnoreFiles",
    "respectRepoIgnore",
    "showEmptyFolders",
  ]);
  assert.equal(advancedPayload.settings.historyIdleThresholdMinutes, 5);
});

test("settings save feedback persists across route rerenders and stays separate from catalog freshness", async (t) => {
  let releaseMutation;
  let mutationStarted = false;
  const mutationGate = new Promise((resolvePromise) => {
    releaseMutation = resolvePromise;
  });
  const harness = await createHarness({
    hash: "#settings/advanced",
    handler: async (call, context) => {
      if (call.path === "api/v1/settings/advanced" && call.method === "PATCH") {
        mutationStarted = true;
        await mutationGate;
        return jsonResponse({
          ...context.typedSettings.advanced,
          revision: context.typedSettings.advanced.revision + 1,
        });
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;
  const feedback = document.getElementById("settings-save-status");
  const catalogFreshness = document.getElementById("catalog-freshness");

  click(
    window,
    [...document.querySelectorAll("button")].find(
      (button) => button.textContent === "Save Advanced Settings",
    ),
  );
  await waitFor(() => mutationStarted);
  assert.equal(feedback.textContent, "Saving…");
  assert.equal(feedback.dataset.state, "saving");
  assert.equal(feedback.getAttribute("role"), "status");
  assert.match(catalogFreshness.textContent, /^Updated /);
  window.RepoPromptPortalTest.renderRoute();
  assert.equal(feedback.textContent, "Saving…");

  releaseMutation();
  await window.RepoPromptPortalTest.whenIdle();
  await settle();
  assert.equal(feedback.textContent, "Saved");
  assert.equal(feedback.dataset.state, "saved");
  assert.match(catalogFreshness.textContent, /^Updated /);

  window.location.hash = "#settings/portal-appearance";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  await settle();
  assert.equal(feedback.textContent, "Saved");
  const theme = document.querySelector('select[aria-label="Portal theme"]');
  theme.value = "dark";
  theme.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(feedback.textContent, "Saved");
  assert.equal(feedback.dataset.state, "saved");
});

test("settings save failures remain actionable and accessible after rerender", async (t) => {
  const harness = await createHarness({
    hash: "#settings/agent-permissions",
    handler: async (call) => {
      if (call.path === "api/v1/desktop-settings" && call.method === "PATCH") {
        return jsonResponse(
          {
            message: "The execution mode was rejected.",
            code: "invalidRequest",
          },
          422,
        );
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const mode = document.querySelector(
    'select[aria-label="Default Execution Mode"]',
  );
  mode.value = "fullAccess";
  mode.dispatchEvent(new window.Event("change", { bubbles: true }));
  await waitFor(() =>
    calls.some(
      (call) =>
        call.path === "api/v1/desktop-settings" && call.method === "PATCH",
    ),
  );
  await window.RepoPromptPortalTest.whenIdle();
  await settle();

  const feedback = document.getElementById("settings-save-status");
  assert.equal(feedback.dataset.state, "error");
  assert.equal(feedback.getAttribute("role"), "alert");
  assert.equal(feedback.getAttribute("aria-live"), "assertive");
  assert.match(
    feedback.textContent,
    /Save failed: The execution mode was rejected\. Review the setting and try again\./,
  );
  assert.match(
    document.getElementById("catalog-freshness").textContent,
    /^Updated /,
  );

  window.RepoPromptPortalTest.renderRoute();
  assert.match(feedback.textContent, /^Save failed:/);
});

test("Context Builder preserves typed controls without saved prompt collection or manual portal run", async (t) => {
  const harness = await createHarness({
    hash: "#settings/context-builder",
    bootstrap: bootstrapFixture({ sessions: [sessionFixture()] }),
  });
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const content = document.getElementById("settings-content");

  for (const expected of [
    "Context Budget",
    "Prompt Enhancement",
    "Question Timeout",
    "Allow Clarifying Questions",
    "Follow-up Analysis",
  ]) {
    assert.match(content.textContent, new RegExp(expected));
  }
  assert.match(
    content.textContent,
    /Connected chat agents using RepoPrompt MCP can ask clarifying questions during Context Builder\./,
  );
  assert.doesNotMatch(
    content.textContent,
    /Portal Clarifying Questions|MCP Clarifying Questions|Manual Portal Run|Run Context Builder|Invocation Overrides|Saved Prompt Collection|Add Saved Prompt/,
  );
  assert.equal(
    document.querySelectorAll(".saved-prompt-list, .saved-prompt-row").length,
    0,
  );
  assert.equal(
    document.querySelectorAll('input[aria-label="Allow Clarifying Questions"]')
      .length,
    1,
  );
  const scope = document.querySelector(
    'select[aria-label="Context Builder scope"]',
  );
  assert.deepEqual(
    [...scope.options].map((option) => option.value),
    ["inheritGlobal", "projectOverride"],
  );
  assert.equal(scope.value, "inheritGlobal");
  assert.ok(
    [...document.querySelectorAll("button")].some(
      (button) => button.textContent === "Copy Global to Project",
    ),
  );
  const enhancement = document.querySelector(
    'select[aria-label="Prompt Enhancement"]',
  );
  assert.deepEqual(
    [...enhancement.options].map((option) => option.value),
    ["rewrite", "augment", "preserve"],
  );
  const timeout = document.querySelector(
    'select[aria-label="Question Timeout"]',
  );
  assert.deepEqual(
    [...timeout.options].map((option) => option.value),
    ["30", "60", "120", "300"],
  );
  const followUp = document.querySelector(
    'select[aria-label="Follow-up Analysis"]',
  );
  assert.deepEqual(
    [...followUp.options].map((option) => option.value),
    ["disabled", "plan", "review", "question"],
  );
  const clarifyingQuestions = document.querySelector(
    'input[aria-label="Allow Clarifying Questions"]',
  );
  assert.equal(clarifyingQuestions.checked, false);
  clarifyingQuestions.checked = true;

  const budget = document.querySelector('input[aria-label="Context Budget"]');
  assert.deepEqual(
    [budget.min, budget.max, budget.step],
    ["10000", "200000", "5000"],
  );
  const followUpBudget = document.querySelector(
    'input[aria-label="Follow-up Analysis Budget"]',
  );
  assert.deepEqual(
    [followUpBudget.min, followUpBudget.max, followUpBudget.step],
    ["40000", "200000", "5000"],
  );
  submit(
    window,
    [...document.querySelectorAll("form")].find((form) =>
      form.textContent.includes("Save Context Builder Settings"),
    ),
  );
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/context-builder",
    ),
  );
  const settingsPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/context-builder",
    ).body,
  );
  assert.deepEqual(Object.keys(settingsPayload).sort(), [
    "expectedRevision",
    "profile",
  ]);
  assert.deepEqual(Object.keys(settingsPayload.profile).sort(), [
    "budget",
    "enhancementMode",
    "followUpAnalysis",
    "followUpBudget",
    "mcpClarifyingQuestions",
    "portalClarifyingQuestions",
    "questionTimeoutSeconds",
  ]);
  assert.equal(settingsPayload.profile.mcpClarifyingQuestions, true);
  assert.equal(
    settingsPayload.profile.portalClarifyingQuestions,
    true,
    "the hidden portal compatibility field must be preserved",
  );
  assert.equal("prompts" in settingsPayload.profile, false);
  assert.equal(
    calls.some(
      (call) =>
        call.method === "POST" &&
        /\/sessions\/[^/]+\/context-builder$/.test(call.path),
    ),
    false,
  );
});

test("workflow settings retain rp IDs while showing only desktop built-in names", async (t) => {
  const builtins = [
    ["rp-build", "Plan & Build"],
    ["rp-review", "Review"],
    ["rp-refactor", "Refactor"],
    ["rp-investigate", "Investigate"],
    ["rp-oracle-export", "ChatGPT Export"],
    ["rp-orchestrate", "Orchestrate"],
    ["rp-optimize", "Optimize"],
    ["rp-deep-plan", "Deep Plan"],
    ["rp-reminder", "Reminder"],
  ];
  const bootstrap = bootstrapFixture({
    workflows: builtins.map(([workflowID, name], featuredOrder) => ({
      workflowID,
      name,
      source: "builtin",
      enabled: true,
      visible: true,
      featuredOrder,
      rowRevision: 1,
    })),
  });
  const harness = await createHarness({
    hash: "#settings/agent-workflows",
    bootstrap,
  });
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const names = [
    ...document.querySelectorAll(".workflow-editor-summary strong"),
  ].map((node) => node.textContent);
  assert.deepEqual(
    names,
    builtins.map(([, name]) => name),
  );
  assert.doesNotMatch(
    document.getElementById("settings-content").textContent,
    /\brp-[a-z-]+\b/,
  );

  click(
    window,
    document.querySelector(
      ".workflow-editor-row button.secondary-button:nth-child(2)",
    ),
  );
  await waitFor(() =>
    calls.some(
      (call) =>
        call.path === "api/v1/workflows/rp-build/clone" &&
        call.method === "POST",
    ),
  );
  const clonePayload = JSON.parse(
    calls.find((call) => call.path === "api/v1/workflows/rp-build/clone").body,
  );
  assert.equal(clonePayload.name, "Plan & Build Copy");
  await window.RepoPromptPortalTest.whenIdle();
  assert.equal(
    document.getElementById("settings-save-status").textContent,
    "Saved",
  );
});

test("model presets, workflows, and named selection presets render real management controls", async (t) => {
  const bootstrap = bootstrapFixture({
    sessions: [sessionFixture()],
    workflows: [
      {
        workflowID: "build",
        name: "Build",
        source: "builtin",
        enabled: true,
        visible: true,
        featuredOrder: 0,
        rowRevision: 1,
      },
    ],
  });
  const typed = typedSettingsFixtures(providerCatalog(), bootstrap);
  typed.selectionPresets.presets = [
    {
      presetID: "40000000-0000-0000-0000-000000000010",
      projectID: projectOneID,
      name: "Core Files",
      entries: [],
      order: 0,
      rowRevision: 1,
    },
  ];
  const harness = await createHarness({ bootstrap, typedSettings: typed });
  t.after(() => harness.close());
  const { calls, document, window } = harness;

  for (const [route, expected, control] of [
    ["model-presets", /Oracle Model Presets/, /Add Preset/],
    [
      "agent-workflows",
      /Hidden-workflow lookup fails closed/i,
      /Reload & Revalidate/,
    ],
    ["manage-presets", /Selection Presets/, /Apply to Session/],
  ]) {
    window.location.hash = `#settings/${route}`;
    window.dispatchEvent(new window.HashChangeEvent("hashchange"));
    await settle();
    const content = document.getElementById("settings-content");
    assert.match(content.textContent, expected);
    assert.match(content.textContent, control);
    assert.ok(content.querySelector("input, select, textarea, button"));
  }

  const coreFilesName = document.querySelector(
    'input[aria-label="Preset name for Core Files"]',
  );
  assert.equal(coreFilesName.value, "Core Files");
  assert.equal(coreFilesName.maxLength, 256);
  assert.equal(
    document.querySelector('input[aria-label="New selection preset name"]')
      .maxLength,
    256,
  );
  const applyPreset = [...document.querySelectorAll("button")].find(
    (button) => button.textContent === "Apply to Session",
  );
  click(window, applyPreset);
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "POST" &&
        call.path.endsWith("/selection-presets/apply"),
    ),
  );
  const applyPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "POST" &&
        call.path.endsWith("/selection-presets/apply"),
    ).body,
  );
  assert.deepEqual(Object.keys(applyPayload).sort(), [
    "expectedCollectionRevision",
    "expectedSelectionRevision",
    "presetID",
    "sessionID",
  ]);
  assert.equal(applyPayload.expectedCollectionRevision, 0);
  assert.equal(applyPayload.expectedSelectionRevision, 1);

  window.location.hash = "#settings/agent-workflows";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  await settle();
  assert.equal(
    document.querySelector('input[aria-label="New workflow name"]').maxLength,
    128,
  );
  assert.equal(
    document.querySelector(
      'textarea[aria-label="New workflow markdown definition"]',
    ).maxLength,
    262144,
  );
  click(
    window,
    [...document.querySelectorAll("button")].find(
      (button) => button.textContent === "Hide",
    ),
  );
  await waitFor(() =>
    calls.some(
      (call) => call.method === "PATCH" && call.path.endsWith("/visibility"),
    ),
  );
  const visibilityPayload = JSON.parse(
    calls.find(
      (call) => call.method === "PATCH" && call.path.endsWith("/visibility"),
    ).body,
  );
  assert.deepEqual(Object.keys(visibilityPayload).sort(), [
    "expectedRevision",
    "expectedRowRevision",
    "visible",
  ]);
  assert.deepEqual(visibilityPayload, {
    expectedRevision: 0,
    expectedRowRevision: 1,
    visible: false,
  });
});

test("model preset add, reorder, and delete keep ordering controls truthful", async (t) => {
  const harness = await createHarness({ hash: "#settings/model-presets" });
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const form = document.querySelector(".typed-settings-form");
  const rowsContainer = form.querySelector(".model-preset-rows");
  const formActions = form.querySelector(".model-preset-actions");
  const add = [...formActions.querySelectorAll("button")].find(
    (button) => button.textContent === "Add Preset",
  );

  assert.ok(rowsContainer.querySelector(".empty-inline"));
  click(window, add);
  assert.equal(rowsContainer.querySelector(".empty-inline"), null);
  assert.equal(rowsContainer.nextElementSibling, formActions);
  let rows = [...rowsContainer.querySelectorAll(".model-preset-row")];
  assert.equal(rows.length, 1);
  assert.equal(
    [...rows[0].querySelectorAll("button")].find(
      (button) => button.textContent === "Move Earlier",
    ).disabled,
    true,
  );
  assert.equal(
    [...rows[0].querySelectorAll("button")].find(
      (button) => button.textContent === "Move Later",
    ).disabled,
    true,
  );
  const firstName = rows[0].querySelector(
    'input[aria-label="Model preset name"]',
  );
  const firstDescription = rows[0].querySelector("textarea");
  assert.equal(firstName.maxLength, 128);
  assert.equal(firstDescription.maxLength, 1024);
  firstName.value = "First";

  click(window, add);
  rows = [...rowsContainer.querySelectorAll(".model-preset-row")];
  rows[1].querySelector('input[aria-label="Model preset name"]').value =
    "Second";
  const firstEarlier = [...rows[0].querySelectorAll("button")].find(
    (button) => button.textContent === "Move Earlier",
  );
  const firstLater = [...rows[0].querySelectorAll("button")].find(
    (button) => button.textContent === "Move Later",
  );
  const secondEarlier = [...rows[1].querySelectorAll("button")].find(
    (button) => button.textContent === "Move Earlier",
  );
  const secondLater = [...rows[1].querySelectorAll("button")].find(
    (button) => button.textContent === "Move Later",
  );
  assert.deepEqual(
    [
      firstEarlier.disabled,
      firstLater.disabled,
      secondEarlier.disabled,
      secondLater.disabled,
    ],
    [true, false, false, true],
  );

  click(window, secondEarlier);
  rows = [...rowsContainer.querySelectorAll(".model-preset-row")];
  assert.deepEqual(
    rows.map(
      (row) => row.querySelector('input[aria-label="Model preset name"]').value,
    ),
    ["Second", "First"],
  );
  assert.deepEqual(
    rows.flatMap((row) => {
      const buttons = [...row.querySelectorAll("button")];
      return [
        buttons.find((button) => button.textContent === "Move Earlier")
          .disabled,
        buttons.find((button) => button.textContent === "Move Later").disabled,
      ];
    }),
    [true, false, false, true],
  );

  click(
    window,
    [...rows[0].querySelectorAll("button")].find(
      (button) => button.textContent === "Delete",
    ),
  );
  assert.equal(document.getElementById("confirm-dialog").hidden, false);
  click(window, document.getElementById("confirm-action-button"));
  await settle();
  rows = [...rowsContainer.querySelectorAll(".model-preset-row")];
  assert.equal(rows.length, 1);
  const remainingButtons = [...rows[0].querySelectorAll("button")];
  assert.equal(
    remainingButtons.find((button) => button.textContent === "Move Earlier")
      .disabled,
    true,
  );
  assert.equal(
    remainingButtons.find((button) => button.textContent === "Move Later")
      .disabled,
    true,
  );

  submit(window, form);
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/model-presets",
    ),
  );
  const payload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/settings/model-presets",
    ).body,
  );
  assert.deepEqual(Object.keys(payload).sort(), [
    "expectedRevision",
    "presets",
  ]);
  assert.equal(payload.presets.length, 1);
  assert.deepEqual(Object.keys(payload.presets[0]).sort(), [
    "availability",
    "description",
    "enabled",
    "name",
    "order",
    "presetID",
    "target",
  ]);
  assert.equal(payload.presets[0].name, "First");
  assert.equal(payload.presets[0].order, 0);
  assert.deepEqual(payload.presets[0].availability.sort(), [
    "chat",
    "plan",
    "review",
  ]);
  assert.deepEqual(Object.keys(payload.presets[0].target).sort(), [
    "modelID",
    "pinned",
    "providerID",
    "reasoningEffort",
  ]);
});

test("direct provider forms appear only for deployment-admitted complete runtimes", async (t) => {
  const providers = providerCatalog();
  providers.push(
    providerFixture({
      providerID: "openAIAPI",
      displayName: "OpenAI API",
      category: "apiProvider",
      deploymentAllowed: true,
      authenticationMethods: ["apiKey"],
      authFlows: [],
      models: [model("gpt-5.6-sol")],
      preference: { enabled: false },
    }),
    providerFixture({
      providerID: "openRouter",
      displayName: "OpenRouter",
      category: "apiProvider",
      deploymentAllowed: true,
      authenticationMethods: ["apiKey"],
      authFlows: [],
      models: [model("openai/gpt-5.6")],
      preference: { enabled: false },
    }),
  );
  const harness = await createHarness({
    hash: "#settings/api-providers",
    providers,
  });
  t.after(() => harness.close());
  const { calls, document, window } = harness;

  const openAI = document.querySelector('[data-provider-id="openAIAPI"]');
  assert.ok(openAI);
  assert.equal(
    document.querySelector('[data-provider-id="anthropicAPI"]'),
    null,
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Save Runtime Configuration/,
  );
  const maximum = openAI.querySelector(
    'input[aria-label="OpenAI API maximum output tokens"]',
  );
  assert.deepEqual(
    [maximum.min, maximum.max, maximum.step],
    ["1", "65536", "1"],
  );
  assert.equal(
    openAI.querySelector('input[aria-label="OpenAI API preferred model"]')
      .maxLength,
    256,
  );
  maximum.value = "65536";
  submit(window, openAI.querySelector(".direct-provider-form"));
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/provider-settings/openAIAPI/direct-configuration",
    ),
  );
  const directPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path === "api/v1/provider-settings/openAIAPI/direct-configuration",
    ).body,
  );
  assert.deepEqual(Object.keys(directPayload).sort(), [
    "baseURL",
    "contentTypePolicy",
    "customHeaders",
    "expectedRevision",
    "maximumOutputTokens",
    "preferredModel",
  ]);
  assert.equal(directPayload.maximumOutputTokens, 65536);
  assert.equal(directPayload.contentTypePolicy, "applicationJSON");
  assert.deepEqual(directPayload.customHeaders, {});
  assert.equal("credential" in directPayload, false);
  await window.RepoPromptPortalTest.whenIdle();
  assert.equal(
    document.getElementById("settings-save-status").textContent,
    "Saved",
  );

  window.location.hash = "#settings/openrouter";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  await settle();
  const openRouter = document.querySelector('[data-provider-id="openRouter"]');
  assert.ok(openRouter);
  assert.match(
    document.getElementById("settings-content").textContent,
    /Custom Headers \(JSON\)/,
  );
  const routerMaximum = openRouter.querySelector(
    'input[aria-label="OpenRouter maximum output tokens"]',
  );
  assert.equal(routerMaximum.max, "65536");
  openRouter.querySelector(
    'textarea[aria-label="OpenRouter custom headers"]',
  ).value = '{"X-Title":"Portal"}';
  submit(window, openRouter.querySelector(".direct-provider-form"));
  await waitFor(() =>
    calls.some(
      (call) =>
        call.method === "PATCH" &&
        call.path ===
          "api/v1/provider-settings/openRouter/direct-configuration",
    ),
  );
  const routerPayload = JSON.parse(
    calls.find(
      (call) =>
        call.method === "PATCH" &&
        call.path ===
          "api/v1/provider-settings/openRouter/direct-configuration",
    ).body,
  );
  assert.deepEqual(routerPayload.customHeaders, { "X-Title": "Portal" });
});

test("portal appearance is browser-local and uses a strict versioned cookie", async (t) => {
  const harness = await createHarness({ hash: "#settings/portal-appearance" });
  t.after(() => harness.close());
  const { document, window } = harness;
  const theme = document.querySelector('select[aria-label="Portal theme"]');
  const density = document.querySelector(
    'select[aria-label="Portal text density"]',
  );
  change(window, theme, "dark");
  change(window, density, "extraLarge");
  assert.equal(document.documentElement.dataset.portalTheme, "dark");
  assert.equal(document.documentElement.dataset.textDensity, "extraLarge");
  assert.match(document.cookie, /rpce_portal_appearance=v1.dark.extraLarge/);
  assert.equal(
    harness.calls.some((call) => call.path.includes("appearance")),
    false,
  );
});

test("compatible backends remain visible and save non-secret Linux runtime settings", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const group = document.querySelector(".compatible-provider-card");
  group.open = true;
  const glm = group.querySelector('[data-provider-id="claudeGLM"]');
  glm.open = true;
  assert.match(glm.textContent, /Backend Behavior/);
  assert.match(glm.textContent, /Z.ai API Key/);
  assert.doesNotMatch(glm.textContent, /Choose a sign-in method/);
  assert.equal(
    glm.querySelector('.secret-form select[name="authenticationMethod"]'),
    null,
  );
  assert.doesNotMatch(glm.textContent, /readiness|availability|vault|DTO/i);

  const form = glm.querySelector(".compatible-backend-form");
  form.querySelector('[name="sonnet"]').value = "glm-4.7";
  submit(window, form);
  await waitFor(
    () => calls.some((call) => call.method === "PATCH"),
    "backend settings PATCH was not sent",
  );
  const patch = calls.find((call) => call.method === "PATCH");
  const payload = JSON.parse(patch.body);
  assert.equal(payload.changes.claudeGLMSonnetModel, "glm-4.7");
  assert.equal(
    payload.changes.claudeGLMBaseURL,
    "https://api.z.ai/api/anthropic",
  );
  assert.equal("credential" in payload.changes, false);
  await waitFor(
    () =>
      calls.filter(
        (call) =>
          call.method === "GET" &&
          call.path.startsWith("api/v1/provider-settings"),
      ).length >= 2,
    "provider catalog did not refresh after saving backend settings",
  );
  await window.RepoPromptPortalTest.whenIdle();
  await settle();

  const refreshedGroup = document.querySelector(".compatible-provider-card");
  refreshedGroup.open = true;
  const custom = refreshedGroup.querySelector(
    '[data-provider-id="claudeCustom"]',
  );
  custom.open = true;
  assert.match(custom.textContent, /safe endpoint validator/i);
  assert.equal(custom.querySelector(".credential-form"), null);
});

test("connected Codex disclosure shows Desktop account and runtime controls without credential forms", async (t) => {
  const connection = connectionFixture({
    authenticationMethod: "deviceCodeBeta",
    accountLabel: "owner@example.com",
  });
  const providers = providerCatalog();
  providers[0] = providerFixture({
    connection,
    authentication: {
      authenticated: true,
      state: "authenticated",
      method: "deviceCodeBeta",
      accountLabel: "owner@example.com",
      planLabel: "Plus",
      authenticationLabel: "Managed ChatGPT",
    },
  });
  const harness = await createHarness({ providers });
  t.after(() => harness.close());
  const { document } = harness;
  const codex = document.querySelector('[data-provider-id="codex"]');
  codex.open = true;
  assert.match(codex.textContent, /Signed in to Codex/);
  assert.match(codex.textContent, /Account\s*owner@example.com/);
  assert.match(codex.textContent, /Plan\s*Plus/);
  assert.match(codex.textContent, /Permissions & Runtime/);
  assert.match(codex.textContent, /Reasoning Summaries/);
  assert.match(codex.textContent, /RepoPrompt · Required/);
  assert.equal(codex.querySelector(".credential-card"), null);
  assert.doesNotMatch(
    codex.textContent,
    /Provider defaults|revision|vault|runtime-ready/i,
  );
});

test("Codex keeps device authorization visible during probe failure and renders API credentials once", async (t) => {
  const providers = providerCatalog();
  providers[0] = providerFixture({
    connection: connectionFixture({
      authenticationMethod: "deviceCodeBeta",
      state: "attention",
      testState: "unavailable",
      detail: "Codex authentication status is temporarily unavailable",
    }),
    authenticationMethods: [
      "apiKey",
      "enterpriseAccessToken",
      "deviceCodeBeta",
    ],
    authFlows: [
      {
        kind: "deviceCodeBeta",
        displayName: "ChatGPT device authorization",
        startable: false,
        detail:
          "Device authorization is temporarily unavailable because RepoPrompt could not verify the Codex runtime. Existing settings are preserved.",
      },
    ],
    authentication: {
      authenticated: false,
      state: "attention",
      method: "deviceCodeBeta",
      detail: "Codex authentication status is temporarily unavailable",
    },
  });
  const harness = await createHarness({ providers });
  t.after(() => harness.close());
  const { document } = harness;
  const codex = document.querySelector('[data-provider-id="codex"]');
  codex.open = true;

  const choices = [...codex.querySelectorAll(".auth-choice")];
  assert.deepEqual(
    choices.map((choice) => choice.dataset.authenticationMethod),
    ["deviceCodeBeta"],
  );
  assert.match(
    choices[0].textContent,
    /ChatGPT device authorization.*temporarily unavailable.*Reconnect/s,
  );
  assert.equal(choices[0].querySelector("button").disabled, true);
  assert.equal(codex.querySelectorAll(".credential-card").length, 1);
  assert.deepEqual(
    [
      ...codex.querySelectorAll(
        '.credential-card select[name="authenticationMethod"] option',
      ),
    ].map((option) => option.value),
    ["apiKey", "enterpriseAccessToken"],
  );
});

test("Desktop setting controls persist through the versioned settings contract", async (t) => {
  const harness = await createHarness({ hash: "#settings/agent-permissions" });
  t.after(() => harness.close());
  const { document, window, calls } = harness;
  const mode = [...document.querySelectorAll("select")].find(
    (select) => select.getAttribute("aria-label") === "Default Execution Mode",
  );
  change(window, mode, "readOnly");
  await window.RepoPromptPortalTest.whenIdle();
  await settle();
  const patch = calls.find(
    (call) =>
      call.path === "api/v1/desktop-settings" && call.method === "PATCH",
  );
  assert.deepEqual(JSON.parse(patch.body), {
    expectedRevision: 0,
    changes: { serverDefaultExecutionMode: "readOnly" },
  });
  assert.equal(
    harness.context.desktopSettings.values.serverDefaultExecutionMode,
    "readOnly",
  );
});

test("project and threaded session navigation render a literal server transcript", async (t) => {
  const child = sessionFixture({
    sessionId: sessionTwoID,
    parentSessionId: sessionOneID,
    title: "Review provider states",
    state: "running",
    lastActivityAt: "2026-08-10T21:00:00Z",
  });
  const root = sessionFixture();
  const malicious = '<img src=x onerror="window.__transcriptExecuted = true">';
  const harness = await createHarness({
    hash: "#home",
    bootstrap: bootstrapFixture({
      projects: [
        ...bootstrapFixture().projects,
        {
          projectId: projectTwoID,
          name: "Desktop Reference",
          state: "active",
          rootNames: ["RepoPromptApp"],
        },
      ],
      sessions: [root, child],
    }),
    handler(call) {
      if (call.path.includes(`/sessions/${sessionTwoID}/transcript`)) {
        return jsonResponse(
          transcriptPageFixture(child, [
            {
              entryId: "30000000-0000-0000-0000-000000000010",
              sessionSequence: 1,
              kind: "human",
              content: malicious,
              timestamp: "2026-08-10T21:00:00Z",
              truncated: false,
            },
            {
              entryId: "30000000-0000-0000-0000-000000000020",
              sessionSequence: 2,
              kind: "assistant",
              content: "I will inspect the live provider capabilities.",
              timestamp: "2026-08-10T21:00:01Z",
              truncated: false,
            },
          ]),
        );
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  assert.equal(
    document.querySelectorAll("#project-list .project-row").length,
    2,
  );
  assert.equal(
    document.querySelectorAll("#session-list .session-row").length,
    2,
  );
  assert.ok(
    document
      .querySelector(`[data-session-id="${sessionTwoID}"]`)
      .classList.contains("depth-1"),
  );
  assert.equal(
    document.getElementById("active-session-title").textContent,
    child.title,
  );
  assert.match(
    document.getElementById("transcript-list").textContent,
    /<img src=x/,
  );
  assert.equal(document.querySelector("#transcript-list img"), null);
  assert.equal(window.__transcriptExecuted, undefined);

  click(window, document.querySelector(`[data-project-id="${projectTwoID}"]`));
  assert.equal(
    document.getElementById("active-workspace-name").textContent,
    "Desktop Reference",
  );
  assert.match(
    document.getElementById("session-list").textContent,
    /No sessions yet/i,
  );
  assert.equal(
    document.getElementById("active-session-title").textContent,
    "New chat",
  );
});

test("switching sessions starts the new transcript request without waiting for a stale request", async (t) => {
  const root = sessionFixture();
  const child = sessionFixture({
    sessionId: sessionTwoID,
    parentSessionId: sessionOneID,
    title: "Child session",
    lastActivityAt: "2026-08-10T19:00:00Z",
  });
  let stallRoot = false;
  let releaseRoot;
  const stalledRootResponse = new Promise((resolvePromise) => {
    releaseRoot = resolvePromise;
  });
  const harness = await createHarness({
    hash: "#home",
    bootstrap: bootstrapFixture({ sessions: [root, child] }),
    handler(call) {
      if (call.path.includes(`/sessions/${sessionOneID}/transcript`)) {
        if (stallRoot) return stalledRootResponse;
        return jsonResponse(
          transcriptPageFixture(root, [
            {
              entryId: "30000000-0000-0000-0000-000000000050",
              sessionSequence: 1,
              kind: "assistant",
              content: "Root transcript",
              timestamp: "2026-08-10T20:00:00Z",
              truncated: false,
            },
          ]),
        );
      }
      if (call.path.includes(`/sessions/${sessionTwoID}/transcript`)) {
        return jsonResponse(
          transcriptPageFixture(child, [
            {
              entryId: "30000000-0000-0000-0000-000000000060",
              sessionSequence: 1,
              kind: "assistant",
              content: "Child transcript",
              timestamp: "2026-08-10T19:00:00Z",
              truncated: false,
            },
          ]),
        );
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  stallRoot = true;
  const staleRequest = window.RepoPromptPortalTest.loadTranscript({
    after: 1,
    silent: true,
  });
  window.RepoPromptPortalTest.selectSession(sessionTwoID);
  await waitFor(
    () =>
      document
        .getElementById("transcript-list")
        .textContent.includes("Child transcript"),
    "new session transcript was blocked by the stale request",
  );

  releaseRoot(
    jsonResponse(
      transcriptPageFixture(root, [
        {
          entryId: "30000000-0000-0000-0000-000000000070",
          sessionSequence: 2,
          kind: "assistant",
          content: "Late root transcript",
          timestamp: "2026-08-10T20:01:00Z",
          truncated: false,
        },
      ]),
    ),
  );
  await staleRequest;
  assert.match(
    document.getElementById("transcript-list").textContent,
    /Child transcript/,
  );
  assert.doesNotMatch(
    document.getElementById("transcript-list").textContent,
    /Late root transcript/,
  );
});

test("composer creates sessions and sends revision-checked follow-ups through portal APIs", async (t) => {
  const connectedProvider = providerFixture({
    connection: connectionFixture(),
  });
  const created = sessionFixture({ title: "Draft the portal" });
  const transcriptItems = [
    {
      entryId: "30000000-0000-0000-0000-000000000030",
      sessionSequence: 1,
      kind: "human",
      content: "Draft the portal",
      timestamp: "2026-08-10T22:00:00Z",
      truncated: false,
    },
  ];
  const harness = await createHarness({
    hash: "#home",
    providers: [connectedProvider],
    handler(call) {
      if (call.path === "api/v1/sessions" && call.method === "POST") {
        return jsonResponse(created, 202);
      }
      if (call.path.includes(`/sessions/${sessionOneID}/messages`)) {
        transcriptItems.push({
          entryId: "30000000-0000-0000-0000-000000000040",
          sessionSequence: 2,
          kind: "human",
          content: "Polish the provider states",
          timestamp: "2026-08-10T22:01:00Z",
          truncated: false,
        });
        return jsonResponse({ accepted: true }, 202);
      }
      if (call.path.includes(`/sessions/${sessionOneID}/transcript`)) {
        return jsonResponse(transcriptPageFixture(created, transcriptItems));
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;
  const composer = document.getElementById("composer-text");

  composer.value = "Draft the portal";
  composer.dispatchEvent(new window.Event("input", { bubbles: true }));
  change(window, document.getElementById("composer-model"), "model-b");
  submit(window, document.getElementById("composer-form"));
  await waitFor(() =>
    harness.calls.some(
      (call) => call.path === "api/v1/sessions" && call.method === "POST",
    ),
  );
  await waitFor(
    () =>
      document.getElementById("active-session-title").textContent ===
      created.title,
  );

  const createCall = harness.calls.find(
    (call) => call.path === "api/v1/sessions" && call.method === "POST",
  );
  const createBody = JSON.parse(createCall.body);
  assert.equal(createBody.projectId, projectOneID);
  assert.equal(createBody.providerId, "codex");
  assert.equal(createBody.model, "model-b");
  assert.equal(createBody.initialPrompt, "Draft the portal");
  assert.match(createBody.operationId, /^[0-9a-f-]{36}$/i);
  assert.equal(createCall.headers["X-RepoPrompt-Portal-CSRF"], "1");

  composer.value = "Polish the provider states";
  composer.dispatchEvent(new window.Event("input", { bubbles: true }));
  submit(window, document.getElementById("composer-form"));
  await waitFor(() =>
    harness.calls.some((call) =>
      call.path.includes(`/sessions/${sessionOneID}/messages`),
    ),
  );
  const messageCall = harness.calls.find((call) =>
    call.path.includes(`/sessions/${sessionOneID}/messages`),
  );
  const messageBody = JSON.parse(messageCall.body);
  assert.equal(messageBody.expectedRevision, 3);
  assert.equal(messageBody.text, "Polish the provider states");
  assert.match(messageBody.operationId, /^[0-9a-f-]{36}$/i);
  assert.equal(messageCall.headers["X-RepoPrompt-Portal-CSRF"], "1");
  await window.RepoPromptPortalTest.whenIdle();
  await settle();
});

test("offline failures are visible and an online event refreshes retained UI", async (t) => {
  let fail = true;
  const harness = await createHarness({
    handler() {
      if (fail) throw new Error("network unavailable");
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  assert.equal(document.getElementById("connection-banner").hidden, false);
  assert.match(
    document.getElementById("connection-banner-text").textContent,
    /offline|unreachable/i,
  );
  assert.equal(
    document.getElementById("service-dot").classList.contains("offline"),
    true,
  );
  assert.match(
    document.getElementById("session-list").textContent,
    /cannot reach/i,
  );

  fail = false;
  window.dispatchEvent(new window.Event("online"));
  await waitFor(() =>
    document.getElementById("service-dot").classList.contains("online"),
  );
  assert.equal(document.getElementById("connection-banner").hidden, true);
  assert.equal(
    document.querySelectorAll("#project-list .project-row").length,
    1,
  );
  assert.match(
    document.getElementById("session-list").textContent,
    /no sessions yet/i,
  );
});

test("every visible interactive element works or is disabled with an explanation", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { document, window } = harness;

  for (const hash of [
    "#home",
    "#settings/overview",
    "#settings/cli-providers",
    "#settings/agent-models",
    "#settings/api-providers",
  ]) {
    window.location.hash = hash;
    window.dispatchEvent(new window.HashChangeEvent("hashchange"));
    await settle();

    for (const button of document.querySelectorAll("button:not([hidden])")) {
      if (button.disabled) {
        assert.ok(
          button.dataset.disabledReason || button.title,
          `disabled button lacks a reason: ${button.textContent || button.id}`,
        );
      } else {
        assert.ok(
          button.dataset.action || button.type === "submit",
          `enabled button lacks an action contract: ${button.textContent || button.id}`,
        );
      }
    }

    for (const control of document.querySelectorAll(
      "input:disabled, select:disabled",
    )) {
      assert.ok(
        control.dataset.disabledReason || control.title,
        `disabled form control lacks a reason: ${control.name || control.id}`,
      );
    }

    for (const anchor of document.querySelectorAll("a:not([hidden])")) {
      const href = anchor.getAttribute("href");
      assert.ok(href && (href.startsWith("#") || href.startsWith("https://")));
    }

    for (const summary of document.querySelectorAll("details > summary")) {
      assert.ok(summary.parentElement.matches("details"));
    }
  }
});

test("portal assets retain security, API, loading, and no-placeholder contracts", () => {
  for (const term of [
    "Projects",
    "Sessions",
    "Ask RepoPrompt anything",
    "Models &amp; Providers",
    "Server Portal",
  ]) {
    assert.ok(
      htmlSource.includes(term),
      `missing portal hierarchy term: ${term}`,
    );
  }
  for (const deadPlaceholder of [
    "Session creation arrives",
    "APIs do not exist yet",
    "Provider and model settings",
  ]) {
    assert.equal(htmlSource.includes(deadPlaceholder), false);
  }
  for (const forbidden of [
    "localStorage",
    "sessionStorage",
    "console.",
    "style.",
  ]) {
    assert.equal(
      scriptSource.includes(forbidden),
      false,
      `forbidden browser behavior: ${forbidden}`,
    );
  }
  for (const endpoint of [
    'api("api/v1/bootstrap")',
    'api("api/v1/sessions"',
    "/transcript?",
    "/messages",
    "api/v1/provider-settings/",
    "/connect",
    "/auth-flows",
    "api/v1/provider-auth-flows/",
  ]) {
    assert.ok(
      scriptSource.includes(endpoint),
      `missing endpoint contract: ${endpoint}`,
    );
  }
  for (const operation of ["test", "disconnect", "revoke"]) {
    assert.ok(
      scriptSource.includes(
        `${operation}: "${operation === "test" ? "Testing…" : operation === "disconnect" ? "Disconnecting…" : "Revoking…"}"`,
      ),
      `missing lifecycle operation: ${operation}`,
    );
  }
  assert.ok(scriptSource.includes("flow.userCode"));
  assert.ok(scriptSource.includes("disposeSensitiveInputs"));
  assert.equal(scriptSource.includes('api("/portal/'), false);
  assert.ok(htmlSource.includes('href="assets/portal.css"'));
  assert.ok(htmlSource.includes('src="assets/portal.js"'));
});
