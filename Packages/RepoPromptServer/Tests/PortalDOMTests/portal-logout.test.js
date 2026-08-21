"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const path = require("node:path");

const {
  authenticatedPortalResponseGeneration,
  fenceAuthenticatedPortalResponse,
  resetAuthenticatedPortalState,
  terminatePortalSession,
} = require(path.resolve(
  __dirname,
  "../../Sources/RepoPromptServiceHTTP/Resources/Portal/portal.js",
));

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

class FakeNode {
  constructor({ value = "", textContent = "", hidden = false } = {}) {
    this.value = value;
    this.textContent = textContent;
    this.hidden = hidden;
    this.inert = false;
    this.autocomplete = "";
    this.children = ["sensitive-rendered-state"];
    this.attributes = new Map([["value", value]]);
  }

  replaceChildren(...children) {
    this.children = children;
  }

  setAttribute(name, value) {
    this.attributes.set(name, value);
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }
}

function fixture() {
  const nodes = new Map();
  const node = (id, options) => {
    const value = new FakeNode(options);
    nodes.set(id, value);
    return value;
  };
  const secrets = [
    node("auth-token", { value: "setup-secret" }),
    node("auth-password", { value: "password-secret" }),
    node("auth-password-confirm", { value: "confirmation-secret" }),
    node("provider-secret", { value: "provider-secret" }),
  ];
  for (const id of [
    "project-list",
    "session-list",
    "transcript-list",
    "settings-content",
    "toast-region",
    "composer-text",
    "session-search",
    "session-metadata",
    "active-session-title",
    "active-workspace-name",
    "service-caption",
    "app",
    "auth-gate",
    "auth-form",
    "auth-token-field",
    "auth-confirm-field",
    "auth-title",
    "auth-copy",
    "auth-submit",
    "auth-error",
  ]) {
    if (!nodes.has(id)) node(id);
  }
  const document = {
    querySelectorAll(selector) {
      assert.equal(selector, "input[data-sensitive]");
      return secrets;
    },
    getElementById(id) {
      return nodes.get(id) || null;
    },
  };
  const state = {
    authenticationGeneration: 7,
    operatorAuthenticated: true,
    passwordLoginEnabled: true,
    providers: [{ providerID: "secret-provider" }],
    bootstrap: { projects: [{ name: "Sensitive Project" }] },
    desktopSettings: { revision: 3 },
    settingsMutation: Promise.resolve(),
    domainMutations: { settings: Promise.resolve() },
    settingsFeedback: { activeCount: 1, outcome: "saved", message: "Saved" },
    typedSettings: { advanced: { revision: 4 } },
    generatedAt: "2026-08-21T00:00:00Z",
    operatorSessions: [{ username: "operator" }],
    operations: { securityAudit: [{ actor: "operator" }] },
    activeFlow: { userCode: "secret-code" },
    pollTimer: 1,
    pollPromise: Promise.resolve(),
    confirmResolver: () => {},
    confirmReturnFocus: {},
    settingsDrawerReturnFocus: {},
    focusAfterRoute: true,
    agent: {
      selectedProjectID: "project-secret",
      selectedSessionID: "session-secret",
      newSessionMode: false,
      searchText: "secret search",
      transcriptItems: [{ content: "secret transcript" }],
      transcriptPage: { session: {} },
      transcriptPromise: Promise.resolve(),
      transcriptPromiseSessionID: "session-secret",
      mutationPromise: Promise.resolve(),
      pollTimer: 2,
      selectionGeneration: 11,
      retryOperation: { fingerprint: "secret" },
    },
  };
  return { document, location: { hash: "#settings/operator-account" }, nodes, secrets, state };
}

test("successful logout clears secrets, operator data, and rendered portal state", async () => {
  const { document, location, nodes, secrets, state } = fixture();

  const succeeded = await terminatePortalSession(
    async () => {},
    (failure) =>
      resetAuthenticatedPortalState(state, document, location, {
        passwordLoginEnabled: true,
        title: failure ? "Sign in again" : "Signed out",
        copy: "The portal session has ended. Sign in to continue.",
      }),
  );

  assert.equal(succeeded, true);
  assert.equal(state.operatorAuthenticated, false);
  assert.equal(state.authenticationGeneration, 8);
  assert.deepEqual(state.providers, []);
  assert.equal(state.bootstrap, null);
  assert.equal(state.desktopSettings, null);
  assert.deepEqual(state.operatorSessions, []);
  assert.equal(state.operations, null);
  assert.equal(state.activeFlow, null);
  assert.deepEqual(state.typedSettings.selections, {});
  assert.deepEqual(state.typedSettings.directConfigurations, {});
  assert.equal(state.agent.selectedProjectID, null);
  assert.equal(state.agent.selectedSessionID, null);
  assert.deepEqual(state.agent.transcriptItems, []);
  assert.equal(state.agent.selectionGeneration, 12);
  assert.equal(state.agent.retryOperation, null);
  for (const secret of secrets) {
    assert.equal(secret.value, "");
    assert.equal(secret.attributes.has("value"), false);
  }
  for (const id of [
    "project-list",
    "session-list",
    "transcript-list",
    "settings-content",
    "toast-region",
  ]) {
    assert.deepEqual(nodes.get(id).children, []);
  }
  assert.equal(nodes.get("app").hidden, true);
  assert.equal(nodes.get("app").inert, true);
  assert.equal(nodes.get("app").attributes.get("aria-hidden"), "true");
  assert.equal(nodes.get("auth-gate").hidden, false);
  assert.equal(nodes.get("auth-form").hidden, false);
  assert.equal(nodes.get("auth-token-field").hidden, true);
  assert.equal(nodes.get("auth-confirm-field").hidden, true);
  assert.equal(nodes.get("auth-title").textContent, "Signed out");
  assert.equal(nodes.get("auth-error").hidden, true);
  assert.equal(location.hash, "#home");
});

test("unconfirmed logout fails closed at the authentication gate", async () => {
  const { document, location, nodes, state } = fixture();

  const succeeded = await terminatePortalSession(
    async () => {
      throw new Error("response lost");
    },
    (failure) =>
      resetAuthenticatedPortalState(state, document, location, {
        passwordLoginEnabled: true,
        title: "Sign in again",
        copy: "Local portal state was cleared.",
        errorMessage: failure ? "Logout could not be confirmed." : "",
      }),
  );

  assert.equal(succeeded, false);
  assert.equal(state.operatorAuthenticated, false);
  assert.equal(nodes.get("app").hidden, true);
  assert.equal(nodes.get("auth-gate").hidden, false);
  assert.equal(nodes.get("auth-error").hidden, false);
  assert.equal(
    nodes.get("auth-error").textContent,
    "Logout could not be confirmed.",
  );
});

test("late authenticated success and failure responses cannot restore portal state", async () => {
  const { document, location, nodes, state } = fixture();
  const providerSuccess = deferred();
  const providerFailure = deferred();
  const authFlowSuccess = deferred();
  const authFlowFailure = deferred();
  const generation = authenticatedPortalResponseGeneration(state);
  const resumed = [];

  void fenceAuthenticatedPortalResponse(
    state,
    generation,
    () => providerSuccess.promise,
  ).then((provider) => {
    resumed.push("provider-success");
    state.providers = [provider];
    state.operatorAuthenticated = true;
    nodes.get("app").hidden = false;
  });
  void fenceAuthenticatedPortalResponse(
    state,
    generation,
    () => providerFailure.promise,
  ).catch(() => {
    resumed.push("provider-failure");
    state.providers = [{ providerID: "restored-by-failure" }];
    nodes.get("app").hidden = false;
  });
  void fenceAuthenticatedPortalResponse(
    state,
    generation,
    () => authFlowSuccess.promise,
  ).then((flow) => {
    resumed.push("auth-flow-success");
    state.activeFlow = flow;
    state.operatorAuthenticated = true;
    nodes.get("app").hidden = false;
  });
  void fenceAuthenticatedPortalResponse(
    state,
    generation,
    () => authFlowFailure.promise,
  ).catch(() => {
    resumed.push("auth-flow-failure");
    state.activeFlow = { userCode: "restored-by-failure" };
    nodes.get("app").hidden = false;
  });

  resetAuthenticatedPortalState(state, document, location, {
    passwordLoginEnabled: true,
    title: "Signed out",
  });
  providerSuccess.resolve({ providerID: "late-provider" });
  providerFailure.reject(new Error("late provider failure"));
  authFlowSuccess.resolve({ userCode: "late-auth-code" });
  authFlowFailure.reject(new Error("late auth-flow failure"));
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(resumed, []);
  assert.equal(state.operatorAuthenticated, false);
  assert.deepEqual(state.providers, []);
  assert.equal(state.activeFlow, null);
  assert.equal(nodes.get("app").hidden, true);
  assert.equal(nodes.get("app").inert, true);
  assert.equal(nodes.get("app").attributes.get("aria-hidden"), "true");
  assert.equal(nodes.get("auth-gate").hidden, false);
});
