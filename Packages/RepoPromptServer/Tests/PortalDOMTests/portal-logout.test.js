"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const path = require("node:path");

const {
  executePortalAPIRequest,
  installPortalAuthenticationSubmission,
  invalidatePortalLoadState,
  presentPortalAuthenticationMode,
  resetAuthenticatedPortalState,
  runPortalLoad,
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

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => (name === "content-type" ? "application/json" : "") },
    text: async () => JSON.stringify(body),
  };
}

async function nextTurn() {
  await new Promise((resolve) => setImmediate(resolve));
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
    this.listeners = new Map();
  }

  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) || [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }

  dispatch(name) {
    const event = {
      preventDefault() {},
      target: this,
    };
    for (const listener of this.listeners.get(name) || []) listener(event);
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
    authenticationMode: "authenticated",
    authenticationSubmitInstalled: false,
    authenticationSubmission: null,
    operatorAuthenticated: true,
    passwordLoginEnabled: true,
    loadGeneration: 0,
    loadOperation: null,
    loadPromise: null,
    loading: false,
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
  return {
    document,
    location: { hash: "#settings/operator-account" },
    nodes,
    secrets,
    state,
  };
}

function clearSecrets(secrets) {
  for (const secret of secrets) {
    secret.value = "";
    secret.removeAttribute("value");
  }
}

function activateFixture(state, nodes) {
  state.authenticationGeneration += 1;
  invalidatePortalLoadState(state);
  state.operatorAuthenticated = true;
  state.authenticationMode = "authenticated";
  nodes.get("app").hidden = false;
  nodes.get("app").inert = false;
  nodes.get("app").removeAttribute("aria-hidden");
  nodes.get("auth-gate").hidden = true;
}

async function submitAuthentication(state, nodes) {
  nodes.get("auth-form").dispatch("submit");
  const submission = state.authenticationSubmission;
  assert.ok(submission, "authentication submission should start");
  await submission.promise;
}

function installAuthenticationFixture(fixtureValue, requests, loads) {
  const { document, nodes, secrets, state } = fixtureValue;
  return installPortalAuthenticationSubmission(state, document, {
    request: (requestPath, options) =>
      executePortalAPIRequest(state, requestPath, options, {
        fetchImpl: async (path, requestOptions) => {
          requests.push({ options: requestOptions, path });
          return jsonResponse({});
        },
      }),
    activate: () => activateFixture(state, nodes),
    afterAuthenticated: () => {
      loads.push(state.authenticationGeneration);
      return Promise.resolve();
    },
    clearSecrets: () => clearSecrets(secrets),
  });
}

test("successful logout clears secrets, load ownership, and rendered portal state", async () => {
  const { document, location, nodes, secrets, state } = fixture();
  state.loadGeneration = 4;
  state.loadOperation = { authenticationGeneration: 7, loadGeneration: 4 };
  state.loadPromise = new Promise(() => {});
  state.loading = true;

  const logoutRequests = [];
  const succeeded = await terminatePortalSession(
    () =>
      executePortalAPIRequest(state, "api/v1/logout", { method: "POST" }, {
        fetchImpl: async (path, options) => {
          logoutRequests.push({ options, path });
          return jsonResponse(null, 204);
        },
      }),
    (failure) =>
      resetAuthenticatedPortalState(state, document, location, {
        passwordLoginEnabled: true,
        title: failure ? "Sign in again" : "Signed out",
        copy: "The portal session has ended. Sign in to continue.",
      }),
  );

  assert.equal(succeeded, true);
  assert.equal(logoutRequests[0].path, "api/v1/logout");
  assert.equal(logoutRequests[0].options.method, "POST");
  assert.equal(logoutRequests[0].options.headers["X-RepoPrompt-Portal-CSRF"], "1");
  assert.equal(state.operatorAuthenticated, false);
  assert.equal(state.authenticationGeneration, 8);
  assert.equal(state.authenticationMode, "login");
  assert.equal(state.loadGeneration, 5);
  assert.equal(state.loadOperation, null);
  assert.equal(state.loadPromise, null);
  assert.equal(state.loading, false);
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
    () =>
      executePortalAPIRequest(state, "api/v1/logout", { method: "POST" }, {
        fetchImpl: async () => {
          throw new Error("response lost");
        },
      }),
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
  assert.equal(state.authenticationMode, "login");
  assert.equal(nodes.get("app").hidden, true);
  assert.equal(nodes.get("auth-gate").hidden, false);
  assert.equal(nodes.get("auth-error").hidden, false);
  assert.equal(
    nodes.get("auth-error").textContent,
    "Logout could not be confirmed.",
  );
});

test("initially authenticated logout leaves one functional dynamic login handler", async () => {
  const fixtureValue = fixture();
  const { document, location, nodes, state } = fixtureValue;
  const requests = [];
  const loads = [];

  assert.equal(installAuthenticationFixture(fixtureValue, requests, loads), true);
  assert.equal(installAuthenticationFixture(fixtureValue, requests, loads), false);
  assert.equal(nodes.get("auth-form").listeners.get("submit").length, 1);

  resetAuthenticatedPortalState(state, document, location, {
    passwordLoginEnabled: true,
    title: "Signed out",
  });
  nodes.get("auth-password").value = "login-password";
  await submitAuthentication(state, nodes);

  assert.deepEqual(requests.map((request) => request.path), ["api/v1/login"]);
  assert.deepEqual(JSON.parse(requests[0].options.body), {
    password: "login-password",
  });
  assert.equal(requests[0].options.headers["X-RepoPrompt-Portal-CSRF"], "1");
  assert.equal(state.operatorAuthenticated, true);
  assert.equal(state.authenticationMode, "authenticated");
  assert.deepEqual(loads, [9]);
  assert.equal(nodes.get("app").hidden, false);
  assert.equal(nodes.get("auth-gate").hidden, true);
});

test("first-run setup then logout reuses the listener in login mode", async () => {
  const fixtureValue = fixture();
  const { document, location, nodes, state } = fixtureValue;
  const requests = [];
  const loads = [];
  state.operatorAuthenticated = false;
  state.authenticationMode = "checking";

  assert.equal(installAuthenticationFixture(fixtureValue, requests, loads), true);
  assert.equal(
    presentPortalAuthenticationMode(state, document, {
      authenticated: false,
      needsSetup: true,
      passwordLoginEnabled: true,
    }),
    "setup",
  );
  nodes.get("auth-password").value = "setup-password";
  nodes.get("auth-password-confirm").value = "setup-password";
  nodes.get("auth-token").value = "owner-token";
  await submitAuthentication(state, nodes);

  assert.equal(requests[0].path, "api/v1/setup");
  assert.deepEqual(JSON.parse(requests[0].options.body), {
    password: "setup-password",
    passwordConfirmation: "setup-password",
    setupToken: "owner-token",
  });
  assert.equal(requests[0].options.headers["X-RepoPrompt-Portal-CSRF"], "1");

  resetAuthenticatedPortalState(state, document, location, {
    passwordLoginEnabled: true,
    title: "Signed out",
  });
  nodes.get("auth-password").value = "login-password";
  await submitAuthentication(state, nodes);

  assert.deepEqual(requests.map((request) => request.path), [
    "api/v1/setup",
    "api/v1/login",
  ]);
  assert.deepEqual(JSON.parse(requests[1].options.body), {
    password: "login-password",
  });
  assert.equal(nodes.get("auth-form").listeners.get("submit").length, 1);
  assert.equal(state.operatorAuthenticated, true);
  assert.equal(state.authenticationMode, "authenticated");
  assert.deepEqual(loads, [8, 10]);
});

test("logout detaches stale API load so re-login can complete a new load", async () => {
  const { document, location, state } = fixture();
  const oldFetch = deferred();
  const newFetch = deferred();
  const loading = [];
  let oldApplied = false;
  let newApplied = false;

  const oldLoad = runPortalLoad(
    state,
    state.authenticationGeneration,
    (value) => {
      state.loading = value;
      loading.push(`old:${value}`);
    },
    async () => {
      const body = await executePortalAPIRequest(state, "api/v1/bootstrap", {}, {
        fetchImpl: () => oldFetch.promise,
      });
      oldApplied = true;
      state.bootstrap = body;
    },
  );
  assert.equal(state.loadPromise, oldLoad);

  resetAuthenticatedPortalState(state, document, location, {
    passwordLoginEnabled: true,
    title: "Signed out",
  });
  state.authenticationGeneration += 1;
  invalidatePortalLoadState(state);
  state.operatorAuthenticated = true;
  state.authenticationMode = "authenticated";

  const newLoad = runPortalLoad(
    state,
    state.authenticationGeneration,
    (value) => {
      state.loading = value;
      loading.push(`new:${value}`);
    },
    async () => {
      const body = await executePortalAPIRequest(state, "api/v1/bootstrap", {}, {
        fetchImpl: () => newFetch.promise,
      });
      newApplied = true;
      state.bootstrap = body;
    },
  );
  assert.equal(state.loadPromise, newLoad);
  assert.notEqual(newLoad, oldLoad);

  oldFetch.resolve(jsonResponse({ projects: [{ id: "late-project" }] }));
  await nextTurn();
  assert.equal(oldApplied, false);
  assert.equal(state.loadPromise, newLoad);
  assert.equal(state.loading, true);

  newFetch.resolve(jsonResponse({ projects: [{ id: "current-project" }] }));
  await newLoad;
  assert.equal(newApplied, true);
  assert.deepEqual(state.bootstrap, {
    projects: [{ id: "current-project" }],
  });
  assert.equal(state.loadOperation, null);
  assert.equal(state.loadPromise, null);
  assert.equal(state.loading, false);
  assert.deepEqual(loading, ["old:true", "new:true", "new:false"]);
});

test("late provider and auth-flow success or failure cannot restore portal state", async () => {
  const { document, location, nodes, state } = fixture();
  const providerSuccess = deferred();
  const providerFailure = deferred();
  const authFlowSuccess = deferred();
  const authFlowFailure = deferred();
  const resumed = [];

  void executePortalAPIRequest(state, "api/v1/provider-settings/connect", {}, {
    fetchImpl: () => providerSuccess.promise,
  }).then((provider) => {
    resumed.push("provider-success");
    state.providers = [provider];
    state.operatorAuthenticated = true;
    nodes.get("app").hidden = false;
  });
  void executePortalAPIRequest(state, "api/v1/provider-settings/connect", {}, {
    fetchImpl: () => providerFailure.promise,
  }).catch(() => {
    resumed.push("provider-failure");
    state.providers = [{ providerID: "restored-by-failure" }];
    nodes.get("app").hidden = false;
  });
  void executePortalAPIRequest(state, "api/v1/provider-auth-flows", {
    method: "POST",
  }, {
    fetchImpl: () => authFlowSuccess.promise,
  }).then((flow) => {
    resumed.push("auth-flow-success");
    state.activeFlow = flow;
    state.operatorAuthenticated = true;
    nodes.get("app").hidden = false;
  });
  void executePortalAPIRequest(state, "api/v1/provider-auth-flows", {
    method: "POST",
  }, {
    fetchImpl: () => authFlowFailure.promise,
  }).catch(() => {
    resumed.push("auth-flow-failure");
    state.activeFlow = { userCode: "restored-by-failure" };
    nodes.get("app").hidden = false;
  });

  resetAuthenticatedPortalState(state, document, location, {
    passwordLoginEnabled: true,
    title: "Signed out",
  });
  providerSuccess.resolve(jsonResponse({ providerID: "late-provider" }));
  providerFailure.reject(new Error("late provider failure"));
  authFlowSuccess.resolve(jsonResponse({ userCode: "late-auth-code" }));
  authFlowFailure.resolve(jsonResponse({ message: "late auth-flow failure" }, 500));
  await nextTurn();

  assert.deepEqual(resumed, []);
  assert.equal(state.operatorAuthenticated, false);
  assert.deepEqual(state.providers, []);
  assert.equal(state.activeFlow, null);
  assert.equal(nodes.get("app").hidden, true);
  assert.equal(nodes.get("app").inert, true);
  assert.equal(nodes.get("app").attributes.get("aria-hidden"), "true");
  assert.equal(nodes.get("auth-gate").hidden, false);
});
