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
const cssSource = readFileSync(resolve(portalDirectory, "portal.css"), "utf8");

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
      displayName: "Browser OAuth",
      startable: false,
      detail: "OAuth adapter is not installed.",
    },
    {
      kind: "deviceCodeBeta",
      displayName: "Device auth (beta)",
      startable: true,
      detail: "Authorize this device with the provider.",
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
  handler,
} = {}) {
  const dom = new JSDOM(htmlSource, {
    url: `https://server.example/portal/${hash}`,
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const { window } = dom;
  const calls = [];
  const context = { providers };

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
      return jsonResponse({
        projects: [{ name: "Sandbox Workspace", rootNames: ["RepoPrompt"] }],
        sessions: [],
        workflows: [],
      });
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

test("deep links, settings search, keyboard clearing, and unavailable explanations work", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { document, window } = harness;

  assert.equal(document.getElementById("home-shell").hidden, true);
  assert.equal(document.getElementById("settings-shell").hidden, false);
  assert.equal(
    document.getElementById("settings-detail-title").textContent,
    "CLI Providers",
  );
  assert.equal(document.querySelectorAll("[data-provider-id]").length, 4);
  assert.equal(
    document
      .querySelector('[data-route="cli-providers"]')
      .getAttribute("aria-current"),
    "page",
  );

  window.location.hash = "#settings/agent-models";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  assert.equal(
    document.getElementById("settings-detail-title").textContent,
    "Agent Models",
  );
  assert.match(
    document.getElementById("settings-content").textContent,
    /Fast mode/,
  );

  window.location.hash = "#settings/not-a-real-page";
  window.dispatchEvent(new window.HashChangeEvent("hashchange"));
  assert.equal(
    document.getElementById("settings-detail-title").textContent,
    "Overview",
  );

  const search = document.getElementById("settings-search");
  search.focus();
  search.value = "API Providers";
  search.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(
    document.querySelector('[data-route="api-providers"]').hidden,
    false,
  );
  assert.equal(
    document.querySelector('[data-route="cli-providers"]').hidden,
    true,
  );
  assert.equal(document.getElementById("clear-settings-search").hidden, false);

  search.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
  );
  assert.equal(search.value, "");
  assert.equal(
    document.querySelector('[data-route="cli-providers"]').hidden,
    false,
  );

  for (const unavailable of document.querySelectorAll(".unavailable-nav-row")) {
    assert.equal(unavailable.getAttribute("aria-disabled"), "true");
    assert.ok(unavailable.dataset.unavailableReason);
  }

  const skip = document.querySelector('[data-action="skip-content"]');
  click(window, skip);
  assert.equal(document.activeElement, document.getElementById("main-content"));
});

test("provider enable, model, effort, fast-mode, and tier controls submit the full revision", async (t) => {
  const fixture = providerFixture({
    supportsSpeedMode: true,
    models: [
      model("model-a", { speedModes: ["standard"], serviceTiers: ["fast"] }),
      model("model-b", {
        speedModes: ["standard", "fast"],
        serviceTiers: ["fast", "priority"],
      }),
    ],
  });
  let patchBody = null;
  const harness = await createHarness({
    providers: [fixture],
    handler(call) {
      if (call.method === "PATCH") {
        patchBody = JSON.parse(call.body);
        return jsonResponse({
          ...fixture,
          preference: {
            ...fixture.preference,
            ...patchBody,
            providerID: fixture.providerID,
            revision: 2,
          },
        });
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;
  const form = document.querySelector('[data-provider-settings="codex"]');
  const save = form.querySelector('[data-action="save-provider-settings"]');

  assert.equal(save.disabled, true);
  assert.match(save.title, /change a setting/i);
  change(window, form.elements.defaultModel, "model-b");
  change(window, form.elements.reasoningEffort, "high");
  change(window, form.elements.speedMode, "fast");
  change(window, form.elements.serviceTier, "priority");
  change(window, form.elements.enabled, false);
  assert.equal(save.disabled, false);

  submit(window, form);
  await waitFor(() => patchBody !== null, "preference PATCH was not sent");
  await settle();

  assert.deepEqual(patchBody, {
    expectedRevision: 1,
    enabled: false,
    defaultModel: "model-b",
    reasoningEffort: "high",
    speedMode: "fast",
    serviceTier: "priority",
  });
  assert.equal(
    harness.calls.find((call) => call.method === "PATCH").headers[
      "X-RepoPrompt-Portal-CSRF"
    ],
    "1",
  );
  assert.match(
    document.getElementById("toast-region").textContent,
    /settings saved/i,
  );
});

test("direct authentication fields are capability-gated for every supported family", async (t) => {
  const harness = await createHarness();
  t.after(() => harness.close());
  const { document, window } = harness;

  const codex = document.querySelector('[data-provider-connect="codex"]');
  assert.deepEqual(
    [...codex.elements.authenticationMethod.options].map(
      (option) => option.value,
    ),
    ["apiKey", "enterpriseAccessToken"],
  );
  assert.ok(codex.elements.credential);
  change(window, codex.elements.authenticationMethod, "enterpriseAccessToken");
  assert.equal(codex.elements.credential.type, "password");
  assert.equal(codex.elements.credential.dataset.sensitive, "true");

  const claude = document.querySelector(
    '[data-provider-connect="claudeCompatible"]',
  );
  assert.deepEqual(
    [...claude.elements.authenticationMethod.options].map(
      (option) => option.value,
    ),
    ["apiKey", "authToken", "keyHelper", "workloadIdentityFederation"],
  );
  change(window, claude.elements.authenticationMethod, "authToken");
  assert.ok(claude.elements.credential);
  change(window, claude.elements.authenticationMethod, "keyHelper");
  assert.ok(claude.elements.keyHelperCommand);
  assert.equal(claude.elements.keyHelperCommand.dataset.sensitive, "true");
  change(
    window,
    claude.elements.authenticationMethod,
    "workloadIdentityFederation",
  );
  assert.ok(claude.elements.workloadIdentityProvider);
  assert.ok(claude.elements.workloadIdentityServiceAccount);
  assert.equal(claude.querySelector('[name="credential"]'), null);

  const openCode = document.querySelector(
    '[data-provider-connect="openCodeACP"]',
  );
  assert.deepEqual(
    [...openCode.elements.authenticationMethod.options].map(
      (option) => option.value,
    ),
    ["providerSpecific"],
  );
  assert.equal(openCode.querySelector("[data-sensitive]"), null);
  assert.match(openCode.textContent, /No raw credential is proxied/);

  const cursor = document.querySelector('[data-provider-connect="cursorACP"]');
  assert.deepEqual(
    [...cursor.elements.authenticationMethod.options].map(
      (option) => option.value,
    ),
    ["apiKey"],
  );
  assert.match(
    document.querySelector('[data-provider-id="cursorACP"]').textContent,
    /Browser login requires a provider flow/,
  );

  for (const unavailable of document.querySelectorAll(
    '[data-action="start-auth-flow"]:disabled',
  )) {
    assert.ok(
      unavailable.dataset.disabledReason,
      `missing disabled reason for ${unavailable.textContent}`,
    );
  }
});

test("write-only credential inputs are disposed after both success and failure", async (t) => {
  const fixture = providerFixture({
    authenticationMethods: ["apiKey"],
    authFlows: [],
  });
  let attempts = 0;
  const harness = await createHarness({
    providers: [fixture],
    handler(call) {
      if (call.path.endsWith("/connect")) {
        attempts += 1;
        if (attempts === 1) {
          const connected = connectionFixture({
            testState: "notTested",
            state: "attention",
          });
          return jsonResponse(
            providerFixture({
              authenticationMethods: ["apiKey"],
              authFlows: [],
              connection: connected,
              authentication: {
                state: "attention",
                authenticated: false,
                method: "apiKey",
                accountLabel: "sandbox team",
                detail: "Credential stored; validation is required",
              },
            }),
            201,
          );
        }
        return jsonResponse(
          {
            code: "invalidRequest",
            message: "The test value was rejected",
            retryable: false,
          },
          422,
        );
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  const firstForm = document.querySelector('[data-provider-connect="codex"]');
  const firstSecret = firstForm.elements.credential;
  firstSecret.value = "not-a-real-value";
  submit(window, firstForm);
  await waitFor(() => attempts === 1);
  await settle();
  assert.equal(firstSecret.value, "");

  const secondForm = document.querySelector('[data-provider-connect="codex"]');
  const secondSecret = secondForm.elements.credential;
  secondSecret.value = "another-fake-value";
  submit(window, secondForm);
  await waitFor(() => attempts === 2);
  await waitFor(() => secondForm.querySelector(".inline-message.error"));
  assert.equal(secondSecret.value, "");
  assert.match(
    secondForm.querySelector(".inline-message.error").textContent,
    /fields were cleared/i,
  );
  assert.equal(secondForm.querySelector('[type="submit"]').disabled, false);

  const connectCalls = harness.calls.filter((call) =>
    call.path.endsWith("/connect"),
  );
  assert.equal(connectCalls.length, 2);
  for (const call of connectCalls) {
    assert.equal(call.headers["X-RepoPrompt-Portal-CSRF"], "1");
    assert.equal(call.headers["Content-Type"], "application/json");
  }
});

test("device auth state machine starts, polls to completion, refreshes, and cancels", async (t) => {
  let fixture = providerFixture({
    authenticationMethods: ["deviceCodeBeta"],
    authFlows: [
      {
        kind: "deviceCodeBeta",
        displayName: "Device auth (beta)",
        startable: true,
        detail: "Authorize this device.",
      },
    ],
  });
  let starts = 0;
  let polls = 0;
  let cancels = 0;
  const harness = await createHarness({
    providers: [fixture],
    handler(call, context) {
      if (call.path.endsWith("/auth-flows") && call.method === "POST") {
        starts += 1;
        return jsonResponse(
          {
            flowID: `20000000-0000-0000-0000-00000000000${starts}`,
            providerID: "codex",
            kind: "deviceCodeBeta",
            state: "pending",
            userCode: "ABCD-EFGH",
            verificationURL: "https://provider.example/device",
            expiresAt: "2026-08-10T21:00:00Z",
            detail: "Awaiting authorization",
          },
          202,
        );
      }
      if (
        call.path.startsWith("api/v1/provider-auth-flows/") &&
        call.method === "GET"
      ) {
        polls += 1;
        fixture = providerFixture({
          authenticationMethods: ["deviceCodeBeta"],
          authFlows: fixture.capabilities.authFlows,
          connection: connectionFixture({
            authenticationMethod: "deviceCodeBeta",
          }),
          authentication: {
            state: "authenticated",
            authenticated: true,
            method: "deviceCodeBeta",
            accountLabel: "device account",
            detail: "Authenticated",
          },
          preflight: {
            ready: true,
            reason: "ready",
            detail: "Provider is ready",
          },
        });
        context.providers = [fixture];
        return jsonResponse({
          flowID: "20000000-0000-0000-0000-000000000001",
          providerID: "codex",
          kind: "deviceCodeBeta",
          state: "completed",
          userCode: null,
          verificationURL: null,
          expiresAt: "2026-08-10T21:00:00Z",
          detail: "Authorization completed",
        });
      }
      if (
        call.path.startsWith("api/v1/provider-auth-flows/") &&
        call.method === "DELETE"
      ) {
        cancels += 1;
        return emptyResponse();
      }
      return null;
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  click(
    window,
    document.querySelector('[data-action="start-auth-flow"]:not(:disabled)'),
  );
  await waitFor(() => document.querySelector(".device-panel"));
  assert.equal(document.querySelector(".device-code").textContent, "ABCD-EFGH");
  assert.equal(
    document.querySelector(".verification-link").rel,
    "noopener noreferrer",
  );
  assert.equal(
    harness.calls.find((call) => call.path.endsWith("/auth-flows")).body,
    '{"kind":"deviceCodeBeta"}',
  );

  await window.RepoPromptPortalTest.pollActiveFlow(true);
  await settle();
  assert.equal(polls, 1);
  assert.equal(document.querySelector(".device-panel"), null);
  assert.match(
    document.querySelector('[data-provider-id="codex"]').textContent,
    /Authenticated/,
  );
  assert.equal(window.RepoPromptPortalTest.state.activeFlow, null);

  click(
    window,
    document.querySelector('[data-action="start-auth-flow"]:not(:disabled)'),
  );
  await waitFor(() => document.querySelector(".device-panel"));
  click(window, document.querySelector('[data-action="cancel-auth-flow"]'));
  await waitFor(() => cancels === 1);
  await waitFor(() => window.RepoPromptPortalTest.state.activeFlow === null);
  const cancelCall = harness.calls.find(
    (call) =>
      call.method === "DELETE" &&
      call.path.startsWith("api/v1/provider-auth-flows/"),
  );
  assert.equal(cancelCall.headers["X-RepoPrompt-Portal-CSRF"], "1");
});

test("connection test, disconnect, revoke, confirmation, and Escape are wired", async (t) => {
  const connected = connectionFixture();
  const fixture = providerFixture({ connection: connected });
  const operations = [];
  const harness = await createHarness({
    providers: [fixture],
    handler(call) {
      const operation = ["test", "disconnect", "revoke"].find((name) =>
        call.path.endsWith(`/${name}`),
      );
      if (!operation) return null;
      operations.push(operation);
      if (operation === "test") {
        return jsonResponse(
          providerFixture({
            connection: connectionFixture({
              revision: 3,
              detail: "Credential accepted again",
            }),
          }),
        );
      }
      return jsonResponse(
        providerFixture({
          connection: null,
          authentication: {
            state: "notConfigured",
            authenticated: false,
            method: null,
            accountLabel: null,
            detail: "Provision credentials on the server",
          },
          preflight: {
            ready: false,
            reason: "missingCredential",
            detail: "Provider credential is not configured",
          },
        }),
      );
    },
  });
  t.after(() => harness.close());
  const { document, window } = harness;

  click(window, document.querySelector('[data-action="test-connection"]'));
  await waitFor(() => operations.includes("test"));
  await waitFor(() =>
    /accepted again/i.test(
      document.querySelector(".connection-panel").textContent,
    ),
  );

  const disconnect = document.querySelector(
    '[data-action="request-disconnect"]',
  );
  disconnect.focus();
  click(window, disconnect);
  await waitFor(() => !document.getElementById("confirm-dialog").hidden);
  document.dispatchEvent(
    new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
  );
  assert.equal(document.getElementById("confirm-dialog").hidden, true);
  assert.equal(document.activeElement, disconnect);
  assert.deepEqual(operations, ["test"]);

  click(window, disconnect);
  await waitFor(() => !document.getElementById("confirm-dialog").hidden);
  click(window, document.getElementById("confirm-action-button"));
  await waitFor(() => operations.includes("disconnect"));
  assert.equal(document.querySelector(".connection-panel"), null);
  const disconnectCall = harness.calls.find((call) =>
    call.path.endsWith("/disconnect"),
  );
  assert.equal(disconnectCall.body, "{}");
  assert.equal(disconnectCall.headers["X-RepoPrompt-Portal-CSRF"], "1");

  const revokeFixture = providerFixture({ connection: connectionFixture() });
  const revokeHarness = await createHarness({
    providers: [revokeFixture],
    handler(call) {
      if (!call.path.endsWith("/revoke")) return null;
      return jsonResponse(providerFixture({ connection: null }));
    },
  });
  t.after(() => revokeHarness.close());
  click(
    revokeHarness.window,
    revokeHarness.document.querySelector('[data-action="request-revoke"]'),
  );
  await waitFor(
    () => !revokeHarness.document.getElementById("confirm-dialog").hidden,
  );
  click(
    revokeHarness.window,
    revokeHarness.document.getElementById("confirm-action-button"),
  );
  await waitFor(() =>
    revokeHarness.calls.some((call) => call.path.endsWith("/revoke")),
  );
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
    document.getElementById("home-provider-list").textContent,
    /cannot reach/i,
  );

  fail = false;
  window.dispatchEvent(new window.Event("online"));
  await waitFor(() =>
    document.getElementById("service-dot").classList.contains("online"),
  );
  assert.equal(document.getElementById("connection-banner").hidden, true);
  assert.equal(
    document.querySelectorAll("#home-provider-list .glance-item").length,
    5,
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
    "Provider and model settings",
    "Models &amp; Providers",
    "Copy &amp; Chat",
    "Settings portal scope",
  ]) {
    assert.ok(
      htmlSource.includes(term),
      `missing portal hierarchy term: ${term}`,
    );
  }
  for (const deadPlaceholder of [
    "What are we building?",
    "New Agent Session",
    "Agent transcript",
    "Session creation arrives",
  ]) {
    assert.equal(htmlSource.includes(deadPlaceholder), false);
  }
  for (const token of [
    "--space-4: 4px",
    "--space-16: 16px",
    "--space-32: 32px",
    "ui-rounded",
    "ui-monospace",
  ]) {
    assert.ok(cssSource.includes(token), `missing visual token: ${token}`);
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
