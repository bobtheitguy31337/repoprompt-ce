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
      authenticationMethods: [
        "apiKey",
        "authToken",
        "keyHelper",
        "workloadIdentityFederation",
      ],
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
      authenticationMethods: ["apiKey", "authToken"],
      authFlows: [],
      models: [model("glm-4.5-air"), model("glm-4.7"), model("glm-5.2[1m]")],
      preference: { enabled: false },
    }),
    providerFixture({
      providerID: "claudeKimi",
      displayName: "CC Moonshot",
      authenticationMethods: ["apiKey", "authToken"],
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
      authenticationMethods: ["browserLogin", "apiKey"],
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
      claudeStrictMCPEnabled: "false",
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
      mcpUseModelPresets: "true",
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
  handler,
} = {}) {
  const dom = new JSDOM(htmlSource, {
    url: `https://server.example/portal/${hash}`,
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const calls = [];
  const context = { providers, bootstrap, desktopSettings };

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
    close() {
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
  ]) {
    assert.match(navText, new RegExp(included));
  }
  for (const excluded of [
    "Appearance",
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
    /Oracle Model/,
  );
  assert.doesNotMatch(
    document.getElementById("settings-content").textContent,
    /Provider defaults/,
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

test("compatible backends remain visible and save non-secret Linux runtime settings", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { calls, document, window } = harness;
  const group = document.querySelector(".compatible-provider-card");
  group.open = true;
  const glm = group.querySelector('[data-provider-id="claudeGLM"]');
  glm.open = true;
  assert.match(glm.textContent, /Backend Settings/);
  assert.match(glm.textContent, /Choose a sign-in method/);
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
