"use strict";

(() => {
  const supportedRoutes = new Set([
    "overview",
    "cli-providers",
    "agent-models",
    "agent-permissions",
    "agent-workflows",
    "context-builder",
    "portal-appearance",
    "advanced",
    "mcp-server",
    "mcp-tools",
    "workspace-approvals",
    "model-presets",
    "api-providers",
    "openrouter",
    "custom-api",
    "model-config",
    "manage-workspaces",
    "manage-presets",
    "client-integrations",
  ]);
  const directAuthenticationMethods = new Set([
    "apiKey",
    "enterpriseAccessToken",
    "authToken",
    "keyHelper",
    "workloadIdentityFederation",
    "providerSpecific",
  ]);
  const transientAuthenticationMethods = new Set([
    "browserOAuth",
    "deviceCodeBeta",
    "browserLogin",
  ]);
  const terminalFlowStates = new Set([
    "completed",
    "failed",
    "cancelled",
    "expired",
  ]);
  const pollDelay = window.__REPOPROMPT_PORTAL_TEST_HOOK__ ? 60_000 : 1_600;
  const selectedProjectStorageKey = "rpce_portal_selected_project_id";
  const selectedSessionStorageKey = "rpce_portal_selected_session_id";

  const state = {
    providers: [],
    bootstrap: null,
    desktopSettings: null,
    clientIntegrations: null,
    lifecycleDisclosure: null,
    lifecycleMutation: null,
    settingsMutation: null,
    domainMutations: {},
    settingsFeedback: {
      activeCount: 0,
      outcome: null,
      message: "No changes saved yet",
    },
    typedSettings: {
      agentModels: null,
      directAgentPermissions: null,
      subagentPermissions: null,
      contextBuilder: null,
      modelPresets: null,
      advanced: null,
      workspaceApprovals: null,
      mcpDisabledTools: null,
      showModelPresets: null,
      selectionPresets: null,
      workflows: null,
      selections: {},
      directConfigurations: {},
    },
    generatedAt: null,
    route: "home",
    loading: false,
    loadPromise: null,
    online: navigator.onLine !== false,
    activeFlow: null,
    pollTimer: null,
    pollPromise: null,
    confirmResolver: null,
    confirmReturnFocus: null,
    settingsDrawerReturnFocus: null,
    focusAfterRoute: false,
    initialized: false,
    agent: {
      selectedProjectID: null,
      selectedSessionID: null,
      newSessionMode: false,
      projectCreationOpen: false,
      searchText: "",
      transcriptItems: [],
      transcriptPage: null,
      transcriptPromise: null,
      transcriptPromiseSessionID: null,
      mutationPromise: null,
      pollTimer: null,
      selectionGeneration: 0,
      retryOperation: null,
      blockExpansion: new Map(),
      toolExpansion: new Map(),
      composerCatalog: null,
      composerCatalogKey: null,
      composerCatalogPromise: null,
      composerCatalogGeneration: 0,
      composerCatalogVersion: 0,
      composerControlsSignature: null,
      composerAttachmentsSignature: null,
      composerStates: new Map(),
      activeComposerKey: null,
      attachmentPromise: null,
      eventSource: null,
      eventRefreshRevision: 0,
      appliedEventRefreshRevision: 0,
      eventRefreshPromise: null,
      runClockTimer: null,
      actionPromise: null,
      actionName: null,
    },
  };

  const appearanceCookieName = "rpce_portal_appearance";
  const appearanceThemes = new Set(["system", "light", "dark"]);
  const appearanceDensities = new Set(["normal", "large", "extraLarge"]);

  function storedSelectedProjectID() {
    try {
      return window.localStorage.getItem(selectedProjectStorageKey);
    } catch (_) {
      return null;
    }
  }

  function rememberSelectedProjectID(projectID) {
    if (!projectID) return;
    try {
      window.localStorage.setItem(selectedProjectStorageKey, projectID);
    } catch (_) {}
  }

  function storedSelectedSessionID() {
    try {
      return window.localStorage.getItem(selectedSessionStorageKey);
    } catch (_) {
      return null;
    }
  }

  function rememberSelectedSessionID(sessionID) {
    try {
      if (sessionID) {
        window.localStorage.setItem(selectedSessionStorageKey, sessionID);
      } else {
        window.localStorage.removeItem(selectedSessionStorageKey);
      }
    } catch (_) {}
  }

  function portalAppearance() {
    const encoded = document.cookie
      .split(";")
      .map((entry) => entry.trim())
      .find((entry) => entry.startsWith(`${appearanceCookieName}=`))
      ?.slice(appearanceCookieName.length + 1);
    const [version, theme, density] = decodeURIComponent(encoded || "").split(
      ".",
    );
    return {
      theme: version === "v1" && appearanceThemes.has(theme) ? theme : "system",
      density:
        version === "v1" && appearanceDensities.has(density)
          ? density
          : "normal",
    };
  }

  function applyPortalAppearance(preference = portalAppearance()) {
    document.documentElement.dataset.portalTheme = preference.theme;
    document.documentElement.dataset.textDensity = preference.density;
  }

  function savePortalAppearance(preference) {
    beginSettingsMutation();
    try {
      const theme = appearanceThemes.has(preference.theme)
        ? preference.theme
        : "system";
      const density = appearanceDensities.has(preference.density)
        ? preference.density
        : "normal";
      document.cookie = `${appearanceCookieName}=${encodeURIComponent(`v1.${theme}.${density}`)}; Path=/portal; SameSite=Strict; Secure`;
      applyPortalAppearance({ theme, density });
      finishSettingsMutation();
    } catch (error) {
      finishSettingsMutation(error);
      toast(error.message || "Browser appearance could not be saved.", true);
    }
  }

  // Web-safe semantic line glyphs substitute for non-portable SF Symbols.
  const icons = {
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3.5 3.5"/>',
    message: '<path d="M2 3.5h12v8H7l-3.5 2v-2H2z"/>',
    folder: '<path d="M1.5 4h5l1.4 1.5h6.6v7.5h-13z"/>',
    document: '<path d="M3 1.5h6l4 4V14.5H3zM9 1.5v4h4M5.5 9h5M5.5 11.5h4"/>',
    pencil: '<path d="m3 11 8.5-8.5 2 2L5 13l-3 .8zM10 4l2 2"/>',
    globe: '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c2 1.7 3 3.7 3 6s-1 4.3-3 6c-2-1.7-3-3.7-3-6s1-4.3 3-6z"/>',
    branch: '<circle cx="4" cy="3" r="1.5"/><circle cx="12" cy="5" r="1.5"/><circle cx="4" cy="13" r="1.5"/><path d="M4 4.5v7M5.5 10c4.3 0 3-5 5-5"/>',
    selection: '<circle cx="8" cy="8" r="6"/><path d="m5 8 2 2 4-4"/>',
    quote: '<path d="M3 4h4v4H5c0 2-1 3-2 3M9 4h4v4h-2c0 2-1 3-2 3"/>',
    tools: '<path d="M9.5 3.5a3 3 0 0 0 3.8 3.8L8 12.6a2 2 0 1 1-2.8-2.8l5.3-5.3a3 3 0 0 0-1-1z"/>',
    workflow:
      '<circle cx="4" cy="3" r="1.5"/><circle cx="12" cy="8" r="1.5"/><circle cx="4" cy="13" r="1.5"/><path d="M5.5 3h2A2.5 2.5 0 0 1 10 5.5V8M5.5 13h2A2.5 2.5 0 0 0 10 10.5V8"/>',
    bolt: '<path d="M9 1.5 3.5 8H8l-1 6.5L12.5 7H8z"/>',
    sparkles:
      '<path d="M5 1.5c.3 2.1 1.4 3.2 3.5 3.5C6.4 5.3 5.3 6.4 5 8.5 4.7 6.4 3.6 5.3 1.5 5 3.6 4.7 4.7 3.6 5 1.5zM11.5 8c.2 1.6 1.1 2.5 2.7 2.7-1.6.2-2.5 1.1-2.7 2.7-.2-1.6-1.1-2.5-2.7-2.7 1.6-.2 2.5-1.1 2.7-2.7z"/>',
    model: '<path d="M8 1.5 14 5v6l-6 3.5L2 11V5zM2 5l6 3.5L14 5M8 8.5v6"/>',
    shield:
      '<path d="M8 1.5 13 3v4.3c0 3.2-2 5.7-5 7.2-3-1.5-5-4-5-7.2V3z"/><path d="m5.5 8 1.5 1.5 3.5-4"/>',
    chevron: '<path d="m6 3 5 5-5 5"/>',
    terminal: '<path d="M1.5 3h13v10h-13zM4 6l2 2-2 2M8 10h3"/>',
    agent:
      '<circle cx="8" cy="5" r="3"/><path d="M2.5 14c.5-3 2.4-4.5 5.5-4.5s5 1.5 5.5 4.5"/>',
    brain:
      '<path d="M6.5 2.2A2.5 2.5 0 0 0 2.8 5a2.7 2.7 0 0 0 .4 4.8 2.5 2.5 0 0 0 3.3 3.1V2.2zM9.5 2.2A2.5 2.5 0 0 1 13.2 5a2.7 2.7 0 0 1-.4 4.8 2.5 2.5 0 0 1-3.3 3.1V2.2zM6.5 5H5M9.5 7H11M6.5 10H5.2M9.5 11h1.2"/>',
    appearance: '<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 0 0 0 12z"/>',
    keyboard:
      '<path d="M1.5 4h13v8h-13zM4 7h.1M7 7h.1M10 7h.1M12 7h.1M4 10h8"/>',
    sliders: '<path d="M2 4h12M2 8h12M2 12h12M5 2v4M11 6v4M7 10v4"/>',
    key: '<circle cx="5" cy="7" r="3"/><path d="m7.3 9.3 5.2 5.2M10 12l1.5-1.5M8.5 10.5 10 9"/>',
    network:
      '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c2 1.7 3 3.7 3 6s-1 4.3-3 6c-2-1.7-3-3.7-3-6s1-4.3 3-6z"/>',
    stack:
      '<rect x="2" y="3" width="12" height="9" rx="1"/><path d="M4 1.5h8M4 14.5h8"/>',
    listStar:
      '<path d="M2 3h6M2 7h5M2 11h6"/><path d="m11.5 7 .7 1.5 1.7.2-1.2 1.2.3 1.7-1.5-.8-1.5.8.3-1.7-1.2-1.2 1.7-.2z"/>',
    sidebar:
      '<rect x="1.5" y="2" width="13" height="12" rx="1.5"/><path d="M5.5 2v12"/>',
    context:
      '<path d="M2 3h12v10H2zM5 6h6M5 9h4"/><path d="M1 5V2h3M15 5V2h-3M1 11v3h3M15 11v3h-3"/>',
    server:
      '<rect x="2" y="2" width="12" height="5" rx="1"/><rect x="2" y="9" width="12" height="5" rx="1"/><circle cx="5" cy="4.5" r=".6" fill="currentColor"/><circle cx="5" cy="11.5" r=".6" fill="currentColor"/>',
    cloud:
      '<path d="M4.5 12.5H12a3 3 0 0 0 .4-6A4.5 4.5 0 0 0 4 5.5a3.5 3.5 0 0 0 .5 7z"/>',
    back: '<path d="m9.5 3-5 5 5 5M5 8h9"/>',
    info: '<circle cx="8" cy="8" r="6"/><path d="M8 7v4M8 4.5h.01"/>',
    warning: '<path d="M8 1.5 15 14H1zM8 6v3.5M8 12h.01"/>',
    close: '<path d="m3 3 10 10M13 3 3 13"/>',
    check: '<path d="m2.5 8 3.5 3.5 7.5-7.5"/>',
    link: '<path d="M6.5 9.5 9.5 6.5M5 11H3.5a2.5 2.5 0 0 1 0-5H6M10 5h2.5a2.5 2.5 0 0 1 0 5H10"/>',
    send: '<path d="M8 13.5v-11M3.5 7 8 2.5 12.5 7"/>',
    stop: '<rect x="4" y="4" width="8" height="8" rx="1" fill="currentColor" stroke="none"/>',
  };

  class PortalError extends Error {
    constructor(message, options = {}) {
      super(message);
      this.name = "PortalError";
      this.status = options.status || 0;
      this.code = options.code || null;
      this.retryable = options.retryable === true;
      this.network = options.network === true;
    }
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function iconNode(name, className) {
    const node = element("span", className);
    node.dataset.icon = name;
    node.setAttribute("aria-hidden", "true");
    return node;
  }

  function installIcons(root = document) {
    root.querySelectorAll("[data-icon]").forEach((node) => {
      const content = icons[node.dataset.icon];
      if (!content || node.querySelector("svg")) return;
      node.insertAdjacentHTML(
        "afterbegin",
        `<svg viewBox="0 0 16 16" aria-hidden="true">${content}</svg>`,
      );
    });
  }

  function setIcon(node, name) {
    if (node.dataset.icon === name && node.querySelector("svg")) return;
    const content = icons[name];
    node.dataset.icon = name;
    node.replaceChildren();
    if (content) {
      node.insertAdjacentHTML(
        "afterbegin",
        `<svg viewBox="0 0 16 16" aria-hidden="true">${content}</svg>`,
      );
    }
  }

  function humanize(value) {
    const labels = {
      browserOAuth: "Browser OAuth",
      deviceCodeBeta: "Device auth (beta)",
      apiKey: "API key",
      enterpriseAccessToken: "Enterprise access token",
      authToken: "Auth token",
      keyHelper: "Key helper",
      workloadIdentityFederation: "Workload identity federation",
      browserLogin: "Browser login",
      providerSpecific: "Provider-specific authentication",
      notConfigured: "Not configured",
      notTested: "Not tested",
      deploymentDisabled: "Deployment disabled",
      missingExecutable: "Missing executable",
      missingCredential: "Missing credential",
      invalidCredential: "Invalid credential",
      authenticationPending: "Authentication pending",
      unsupportedModel: "Unsupported model",
      unsupportedControl: "Unsupported control",
      runtimeUnavailable: "Runtime unavailable",
      xhigh: "XHigh",
      max: "Max",
      ultra: "Ultra",
    };
    return (
      labels[value] ||
      String(value || "")
        .replace(/([a-z])([A-Z])/g, "$1 $2")
        .replace(/^./, (character) => character.toUpperCase())
    );
  }

  function formatDate(value, fallback = "—") {
    if (!value) return fallback;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return fallback;
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  }

  function announce(message) {
    const announcer = document.getElementById("announcer");
    announcer.textContent = "";
    window.setTimeout(() => {
      announcer.textContent = message;
    }, 0);
  }

  function toast(message, isError = false) {
    const node = element("div", `toast${isError ? " error" : ""}`, message);
    document.getElementById("toast-region").append(node);
    window.setTimeout(() => node.remove(), 4_200);
  }

  function renderSettingsFeedback() {
    const node = document.getElementById("settings-save-status");
    if (!node) return;
    const feedback = state.settingsFeedback;
    const phase =
      feedback.outcome === "error"
        ? "error"
        : feedback.activeCount > 0
          ? "saving"
          : feedback.outcome || "idle";
    node.dataset.state = phase;
    node.textContent = feedback.message;
    node.setAttribute("role", phase === "error" ? "alert" : "status");
    node.setAttribute("aria-live", phase === "error" ? "assertive" : "polite");
  }

  function beginSettingsMutation() {
    const feedback = state.settingsFeedback;
    if (feedback.activeCount === 0) feedback.outcome = null;
    feedback.activeCount += 1;
    if (feedback.outcome !== "error") feedback.message = "Saving…";
    renderSettingsFeedback();
    announce("Saving settings");
  }

  function finishSettingsMutation(error = null) {
    const feedback = state.settingsFeedback;
    feedback.activeCount = Math.max(0, feedback.activeCount - 1);
    if (error) {
      feedback.outcome = "error";
      feedback.message = `Save failed: ${error.message || "The change was not saved."} Review the setting and try again.`;
    } else if (feedback.activeCount === 0 && feedback.outcome !== "error") {
      feedback.outcome = "saved";
      feedback.message = "Saved";
    } else if (feedback.activeCount > 0 && feedback.outcome !== "error") {
      feedback.message = "Saving…";
    }
    renderSettingsFeedback();
    announce(feedback.message);
  }

  function isSettingsMutationPath(path, method) {
    if (!["POST", "PUT", "PATCH", "DELETE"].includes(method)) return false;
    return (
      path === "api/v1/desktop-settings" ||
      /^api\/v1\/settings\//.test(path) ||
      /^api\/v1\/projects\/[^/]+\/settings\//.test(path) ||
      /^api\/v1\/provider-settings\//.test(path) ||
      /^api\/v1\/provider-auth-flows\//.test(path) ||
      /^api\/v1\/client-integrations(?:\/|$)/.test(path) ||
      /^api\/v1\/workflows(?:\/|$)/.test(path) ||
      /^api\/v1\/projects\/[^/]+\/selection-presets(?:\/|$)/.test(path)
    );
  }

  async function api(path, options = {}) {
    const method = (options.method || "GET").toUpperCase();
    const mutation = ["POST", "PUT", "PATCH", "DELETE"].includes(method);
    const reportsSettingsFeedback = isSettingsMutationPath(path, method);
    if (reportsSettingsFeedback) beginSettingsMutation();
    try {
      let response;
      try {
        response = await fetch(path, {
          cache: "no-store",
          credentials: "same-origin",
          ...options,
          method,
          headers: {
            Accept: "application/json",
            ...(options.body ? { "Content-Type": "application/json" } : {}),
            ...(mutation ? { "X-RepoPrompt-Portal-CSRF": "1" } : {}),
            ...(options.headers || {}),
          },
        });
      } catch (_error) {
        throw new PortalError(
          "Cannot reach the RepoPrompt server. Check the connection and try again.",
          {
            network: true,
            retryable: true,
          },
        );
      }

      const contentType = response.headers.get("content-type") || "";
      const text = response.status === 204 ? "" : await response.text();
      let body = null;
      if (text && contentType.includes("application/json")) {
        try {
          body = JSON.parse(text);
        } catch (_error) {
          throw new PortalError("The server returned an unreadable response.", {
            status: response.status,
          });
        }
      }
      if (!response.ok) {
        throw new PortalError(
          body?.message || `Request failed (${response.status}).`,
          {
            status: response.status,
            code: body?.code,
            retryable: body?.retryable,
          },
        );
      }
      if (reportsSettingsFeedback) finishSettingsMutation();
      return body;
    } catch (error) {
      if (reportsSettingsFeedback) finishSettingsMutation(error);
      throw error;
    }
  }

  function orderedProviders() {
    return state.providers.slice();
  }

  function replaceProvider(provider) {
    const index = state.providers.findIndex(
      (item) => item.providerID === provider.providerID,
    );
    if (index >= 0) state.providers[index] = provider;
    else state.providers.push(provider);
    state.generatedAt = new Date().toISOString();
  }

  function providerDestination(provider) {
    return provider.category === "apiProvider"
      ? "api-providers"
      : "cli-providers";
  }

  function desktopProviderPresentation(provider) {
    const presentations = {
      codex: {
        title: "Codex CLI",
        subtitle:
          "Runs RepoPrompt CE's managed Codex runtime with a separate sign-in from ~/.codex.",
      },
      claudeCompatible: {
        title: "Claude Code CLI",
        subtitle:
          "Uses your Claude Code CLI login for Anthropic models. Compatible backends use their own API keys.",
      },
      claudeGLM: {
        title: settingValue("claudeGLMDisplayName", provider.displayName),
        subtitle: `Claude Code routed through Z.ai. Haiku → ${settingValue("claudeGLMHaikuModel")} · Sonnet → ${settingValue("claudeGLMSonnetModel")} · Opus → ${settingValue("claudeGLMOpusModel")}.`,
      },
      claudeKimi: {
        title: settingValue("claudeKimiDisplayName", provider.displayName),
        subtitle:
          "Claude Code routed through Kimi's coding backend. RepoPrompt does not pass --model.",
      },
      claudeCustom: {
        title: settingValue("claudeCustomDisplayName", provider.displayName),
        subtitle:
          "Your own configurable Claude Code-compatible HTTPS endpoint.",
      },
      openCodeACP: {
        title: "OpenCode CLI",
        subtitle:
          "Uses OpenCode's ACP runtime for Agent Mode; headless OpenCode runs use a managed no-native-tools mode.",
      },
      cursorACP: {
        title: "Cursor CLI",
        subtitle:
          "Uses Cursor's ACP runtime for Agent Mode, headless tasks, and chat.",
      },
      grokBuildACP: {
        title: "Grok Build CLI",
        subtitle:
          "Uses Grok Build's ACP runtime for Agent Mode, headless tasks, and chat.",
      },
    };
    return (
      presentations[provider.providerID] || {
        title: provider.displayName,
        subtitle: provider.summary,
      }
    );
  }

  function providerStatus(provider) {
    const connectionFailed =
      provider.connection?.state === "attention" ||
      ["invalid", "unavailable"].includes(provider.connection?.testState) ||
      provider.authentication?.state === "attention" ||
      provider.preflight?.reason === "invalidCredential";
    if (connectionFailed) {
      return {
        label:
          provider.connection?.detail ||
          provider.authentication?.detail ||
          "Connection failed",
        tone: "attention",
      };
    }
    if (isSessionReadyProvider(provider)) {
      return { label: "Connected", tone: "connected" };
    }
    if (isConnectedProvider(provider)) {
      return {
        label:
          provider.preflight?.detail ||
          "Provider setup is still completing.",
        tone: "attention",
      };
    }
    return { label: "Not configured", tone: "" };
  }

  function setDisabledReason(control, disabled, reason) {
    control.disabled = disabled;
    if (disabled && reason) {
      control.title = reason;
      control.dataset.disabledReason = reason;
    } else {
      control.removeAttribute("data-disabled-reason");
      control.removeAttribute("title");
    }
  }

  function setConnectionPresentation(kind, message) {
    const banner = document.getElementById("connection-banner");
    const bannerText = document.getElementById("connection-banner-text");
    banner.hidden = kind === "online";
    bannerText.textContent = message || "";
    state.online = kind !== "offline";
  }

  function setLoading(loading) {
    state.loading = loading;
    document
      .getElementById("session-list")
      .setAttribute("aria-busy", String(loading));
    document
      .getElementById("settings-content")
      .setAttribute("aria-busy", String(loading));
  }

  function renderInitialLoading() {
    const projectSelector = document.getElementById("project-selector");
    const sessions = document.getElementById("session-list");
    const loadingProject = document.createElement("option");
    loadingProject.textContent = "Loading projects…";
    projectSelector.replaceChildren(loadingProject);
    projectSelector.disabled = true;
    document.getElementById("current-project-name").textContent = "Loading…";
    sessions.replaceChildren(
      element("div", "sidebar-loading", "Loading sessions…"),
    );
    document
      .getElementById("transcript-list")
      .replaceChildren(
        element("div", "transcript-empty", "Loading workspace…"),
      );
    const content = document.getElementById("settings-content");
    content.replaceChildren(
      element("div", "empty-state-panel", "Loading provider settings…"),
    );
  }

  async function loadSettingsDomain(domain) {
    const projectID = state.agent.selectedProjectID;
    const sessionID = state.agent.selectedSessionID;
    switch (domain) {
      case "agentModels":
        state.typedSettings.agentModels = await api(
          projectID
            ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models`
            : "api/v1/settings/agent-models",
        );
        break;
      case "directAgentPermissions":
        state.typedSettings.directAgentPermissions = await api(
          "api/v1/settings/direct-agent-permissions",
        );
        break;
      case "subagentPermissions":
        state.typedSettings.subagentPermissions = await api(
          "api/v1/settings/subagent-permissions",
        );
        break;
      case "contextBuilder":
        state.typedSettings.contextBuilder = await api(
          projectID
            ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder`
            : "api/v1/settings/context-builder",
        );
        break;
      case "modelPresets":
        state.typedSettings.modelPresets = await api(
          "api/v1/settings/model-presets",
        );
        break;
      case "advanced":
        state.typedSettings.advanced = await api("api/v1/settings/advanced");
        break;
      case "workspaceApprovals":
        state.typedSettings.workspaceApprovals = await api(
          "api/v1/settings/workspace-approvals",
        );
        break;
      case "mcpDisabledTools":
        state.typedSettings.mcpDisabledTools = await api(
          "api/v1/settings/mcp-disabled-tools",
        );
        break;
      case "showModelPresets":
        state.typedSettings.showModelPresets = await api(
          "api/v1/settings/show-model-presets",
        );
        break;
      case "selectionPresets":
        state.typedSettings.selectionPresets = projectID
          ? await api(
              `api/v1/projects/${encodeURIComponent(projectID)}/selection-presets`,
            )
          : null;
        break;
      case "workflows":
        applyWorkflowRepository(await api("api/v1/workflows"));
        break;
      case "selection":
        if (sessionID) {
          state.typedSettings.selections[sessionID] = await api(
            `api/v1/sessions/${encodeURIComponent(sessionID)}/selection`,
          );
        }
        break;
      case "directConfigurations": {
        const configurations = {};
        await Promise.all(
          orderedProviders()
            .filter(
              (provider) =>
                provider.category === "apiProvider" &&
                provider.deploymentAllowed,
            )
            .map(async (provider) => {
              configurations[provider.providerID] = await api(
                `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/direct-configuration`,
              );
            }),
        );
        state.typedSettings.directConfigurations = configurations;
        break;
      }
      default:
        throw new PortalError(`Unknown settings domain: ${domain}`);
    }
  }

  function applyWorkflowRepository(value) {
    state.typedSettings.workflows = value;
    if (!value || !Array.isArray(value.workflows)) return;
    state.bootstrap ||= { projects: [], sessions: [], workflows: [] };
    state.bootstrap.workflows = value.workflows.filter(
      (workflow) => workflow.enabled && workflow.visible,
    );
    state.bootstrap.workflowRepositoryRevision = value.revision;
    if (typeof value.includeSessionCleanupGuidance === "boolean") {
      state.bootstrap.includeSessionCleanupGuidance =
        value.includeSessionCleanupGuidance;
    }
  }

  async function loadTypedSettings() {
    await Promise.all([
      loadSettingsDomain("agentModels"),
      loadSettingsDomain("directAgentPermissions"),
      loadSettingsDomain("subagentPermissions"),
      loadSettingsDomain("contextBuilder"),
      loadSettingsDomain("modelPresets"),
      loadSettingsDomain("advanced"),
      loadSettingsDomain("workspaceApprovals"),
      loadSettingsDomain("mcpDisabledTools"),
      loadSettingsDomain("showModelPresets"),
      loadSettingsDomain("selectionPresets"),
      loadSettingsDomain("workflows"),
      loadSettingsDomain("selection"),
      loadSettingsDomain("directConfigurations"),
    ]);
  }

  async function mutateDomain(domain, control, operation, applyResult) {
    if (state.domainMutations[domain]) return state.domainMutations[domain];
    if (control) setDisabledReason(control, true, "Saving…");
    state.domainMutations[domain] = (async () => {
      try {
        const result = await operation();
        applyResult(result);
        renderRoute();
        return result;
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision") {
          await loadSettingsDomain(domain);
        }
        renderRoute();
        return null;
      } finally {
        state.domainMutations[domain] = null;
      }
    })();
    return state.domainMutations[domain];
  }

  async function mutateProjects(control, operation, successMessage) {
    if (state.domainMutations.projects) return state.domainMutations.projects;
    if (control) setDisabledReason(control, true, "Saving…");
    state.domainMutations.projects = (async () => {
      try {
        await operation();
        await loadAll(false);
        toast(successMessage);
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision") await loadAll(false);
        else renderRoute();
      } finally {
        state.domainMutations.projects = null;
      }
    })();
    return state.domainMutations.projects;
  }

  async function loadAll(refresh = false) {
    if (state.loadPromise) return state.loadPromise;
    setLoading(true);
    state.loadPromise = (async () => {
      try {
        const [
          bootstrap,
          providerCatalog,
          desktopSettings,
          clientIntegrations,
        ] = await Promise.all(
          [
            api("api/v1/bootstrap"),
            api(`api/v1/provider-settings${refresh ? "?refresh=true" : ""}`),
            api("api/v1/desktop-settings"),
            api("api/v1/client-integrations"),
          ],
        );
        if (!providerCatalog || !Array.isArray(providerCatalog.providers)) {
          throw new PortalError("The provider catalog response is incomplete.");
        }
        state.bootstrap = bootstrap || {
          projects: [],
          sessions: [],
          workflows: [],
        };
        state.bootstrap.projects ||= [];
        state.bootstrap.sessions ||= [];
        state.bootstrap.workflows ||= [];
        if (!state.agent.selectedProjectID) {
          state.agent.selectedProjectID = storedSelectedProjectID();
        }
        if (!state.agent.selectedSessionID && !state.agent.newSessionMode) {
          state.agent.selectedSessionID = storedSelectedSessionID();
        }
        state.providers = providerCatalog.providers;
        state.desktopSettings = desktopSettings;
        state.clientIntegrations = clientIntegrations;
        reconcileAgentSelection();
        rememberSelectedProjectID(state.agent.selectedProjectID);
        rememberSelectedSessionID(state.agent.selectedSessionID);
        await loadTypedSettings();
        state.generatedAt =
          providerCatalog.generatedAt || new Date().toISOString();
        setConnectionPresentation("online", "");
        connectAgentEvents();
        updateShell();
        renderHomeProviders();
        renderRoute();
        if (state.route === "home" && state.agent.selectedSessionID) {
          await loadTranscript({ silent: true });
        }
        if (refresh) {
          toast("Server state refreshed");
          announce("Server state refreshed");
        }
      } catch (error) {
        const offline = error.network || navigator.onLine === false;
        setConnectionPresentation(
          offline ? "offline" : "stale",
          offline ? "The server is offline or unreachable." : error.message,
        );
        if (!state.providers.length) {
          renderHomeError(error);
          if (!document.getElementById("settings-shell").hidden)
            renderPageError(error);
        }
        toast(error.message, true);
        announce(error.message);
      } finally {
        setLoading(false);
        state.loadPromise = null;
      }
    })();
    return state.loadPromise;
  }

  function updateShell() {
    const freshness = state.generatedAt
      ? `Updated ${formatDate(state.generatedAt)}`
      : "Not yet loaded";
    document.getElementById("catalog-freshness").textContent = freshness;
    renderSettingsFeedback();
  }

  function selectedProject() {
    return state.bootstrap?.projects?.find(
      (project) => project.projectId === state.agent.selectedProjectID,
    );
  }

  function selectedSession() {
    return state.bootstrap?.sessions?.find(
      (session) => session.sessionId === state.agent.selectedSessionID,
    );
  }

  function eligibleSessionProviders() {
    return orderedProviders().filter(isSessionReadyProvider);
  }

  function onboardingStage() {
    if (!state.providers.length && state.loading) return null;
    if (!eligibleSessionProviders().length) return "provider";
    if (
      !(state.bootstrap?.projects || []).length ||
      state.agent.projectCreationOpen
    )
      return "project";
    return null;
  }

  function reconcileAgentSelection() {
    if (!state.bootstrap) return;
    const projects = state.bootstrap?.projects || [];
    if (
      !projects.some((item) => item.projectId === state.agent.selectedProjectID)
    ) {
      state.agent.selectedProjectID =
        projects.find((item) => item.state === "active")?.projectId ||
        projects[0]?.projectId ||
        null;
    }
    const sessions = (state.bootstrap?.sessions || []).filter(
      (item) => item.projectId === state.agent.selectedProjectID,
    );
    if (state.agent.newSessionMode) {
      state.agent.selectedSessionID = null;
    } else if (
      !sessions.some((item) => item.sessionId === state.agent.selectedSessionID)
    ) {
      state.agent.selectedSessionID = sessions[0]?.sessionId || null;
      state.agent.newSessionMode = !state.agent.selectedSessionID;
    }
  }

  function renderHomeProviders() {
    reconcileAgentSelection();
    renderProjects();
    renderSessions();
    renderAgentDetail();
  }

  function renderProjects() {
    const selector = document.getElementById("project-selector");
    selector.replaceChildren();
    const projects = [...(state.bootstrap?.projects || [])].sort((left, right) =>
      left.name.localeCompare(right.name, undefined, {
        numeric: true,
        sensitivity: "base",
      }),
    );
    const providersReady = eligibleSessionProviders().length > 0;
    const activeProject = selectedProject();
    document.getElementById("current-project-name").textContent =
      activeProject?.name || "No project";

    const create = document.createElement("option");
    create.value = "__create_project__";
    create.textContent = "Create New Project";
    create.disabled = !providersReady;
    selector.append(create);

    projects.forEach((project) => {
      const option = document.createElement("option");
      option.value = project.projectId;
      option.textContent = project.name;
      selector.append(option);
    });
    if (activeProject) selector.value = activeProject.projectId;
    selector.disabled = !providersReady && !projects.length;

    const newChat = document.getElementById("new-chat-button");
    const reason = !providersReady
      ? "Set up a CLI provider before starting a chat."
      : !projects.length
        ? "Create a project folder before starting a chat."
        : "";
    setDisabledReason(newChat, Boolean(reason), reason);
  }

  function renderSessions() {
    const list = document.getElementById("session-list");
    list.replaceChildren();
    const query = state.agent.searchText.trim().toLowerCase();
    const projectSessions = (state.bootstrap?.sessions || []).filter(
      (session) => session.projectId === state.agent.selectedProjectID,
    );
    let sessions = projectSessions;
    if (query) {
      const byID = new Map(
        projectSessions.map((session) => [session.sessionId, session]),
      );
      const visibleIDs = new Set();
      projectSessions.forEach((session) => {
        const matches = [session.title, session.provider, session.model]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
        if (!matches) return;
        let cursor = session;
        while (cursor && !visibleIDs.has(cursor.sessionId)) {
          visibleIDs.add(cursor.sessionId);
          cursor = cursor.parentSessionId
            ? byID.get(cursor.parentSessionId)
            : null;
        }
      });
      sessions = projectSessions.filter((session) =>
        visibleIDs.has(session.sessionId),
      );
    }
    document.getElementById("session-count").textContent = String(
      sessions.length,
    );
    if (!sessions.length) {
      list.append(
        element(
          "div",
          "sidebar-empty",
          query
            ? "No matching sessions."
            : "No sessions yet. Start a new chat.",
        ),
      );
    }
    sessions.forEach((session) => {
      const depth = session.sidebarDepth || 0;
      const displayState = session.agentControl?.displayState || session.state;
      const button = element("button", `session-row depth-${depth}`);
      button.type = "button";
      button.dataset.sessionId = session.sessionId;
      button.dataset.action = "select-session";
      const active =
        !state.agent.newSessionMode &&
        session.sessionId === state.agent.selectedSessionID;
      button.classList.toggle("active", active);
      if (active) button.setAttribute("aria-current", "true");
      const plate = element("span", `session-status-plate ${displayState}`);
      plate.setAttribute("aria-hidden", "true");
      plate.append(element("i"));
      const copy = element("span", "session-row-copy");
      copy.append(
        element("strong", "", session.title || "Agent Session"),
        element(
          "small",
          "",
          `${humanize(session.provider)}${session.model ? ` · ${session.model}` : ""}`,
        ),
      );
      button.append(
        plate,
        copy,
        element("span", "session-row-state", humanize(displayState)),
      );
      button.addEventListener("click", () => selectSession(session.sessionId));
      list.append(button);
    });
    list.setAttribute("aria-busy", "false");
  }

  function selectProject(projectID) {
    rememberSelectedProjectID(projectID);
    if (
      state.agent.selectedProjectID === projectID &&
      !state.agent.projectCreationOpen
    )
      return;
    clearAgentPoll();
    state.agent.projectCreationOpen = false;
    state.agent.selectedProjectID = projectID;
    state.agent.selectedSessionID = null;
    state.agent.blockExpansion.clear();
    state.agent.toolExpansion.clear();
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.newSessionMode = false;
    reconcileAgentSelection();
    rememberSelectedSessionID(state.agent.selectedSessionID);
    renderHomeProviders();
    updateShell();
    Promise.all([
      loadSettingsDomain("agentModels"),
      loadSettingsDomain("contextBuilder"),
      loadSettingsDomain("selectionPresets"),
      loadSettingsDomain("selection"),
    ])
      .then(renderRoute)
      .catch((error) => toast(error.message, true));
    if (state.agent.selectedSessionID) loadTranscript();
  }

  function beginProjectCreation() {
    state.agent.projectCreationOpen = true;
    renderHomeProviders();
    window.setTimeout(
      () =>
        document.getElementById("project-name")?.focus({ preventScroll: true }),
      0,
    );
  }

  function selectSession(sessionID) {
    if (
      state.agent.selectedSessionID === sessionID &&
      !state.agent.newSessionMode
    )
      return;
    clearAgentPoll();
    state.agent.selectedSessionID = sessionID;
    rememberSelectedSessionID(sessionID);
    state.agent.newSessionMode = false;
    state.agent.blockExpansion.clear();
    state.agent.toolExpansion.clear();
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.selectionGeneration += 1;
    renderHomeProviders();
    loadSettingsDomain("selection").catch((error) =>
      toast(error.message, true),
    );
    loadTranscript();
  }

  function beginNewSession() {
    if (onboardingStage()) return;
    clearAgentPoll();
    state.agent.newSessionMode = true;
    state.agent.selectedSessionID = null;
    rememberSelectedSessionID(null);
    state.agent.blockExpansion.clear();
    state.agent.toolExpansion.clear();
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.selectionGeneration += 1;
    renderHomeProviders();
    document.getElementById("composer-text").focus({ preventScroll: true });
  }

  function renderAgentDetail() {
    const setupStage = onboardingStage();
    const session = selectedSession();
    const title = document.getElementById("active-session-title");
    const metadata = document.getElementById("session-metadata");
    if (setupStage === "provider") {
      title.textContent = "Set up a provider";
      metadata.replaceChildren(
        element("span", "metadata-pill", "Install · Sign in"),
      );
    } else if (setupStage === "project") {
      title.textContent = "Create a project";
      metadata.replaceChildren(
        element("span", "metadata-pill", "A project is a folder"),
      );
    } else if (state.agent.newSessionMode) {
      title.textContent = "New chat";
      metadata.replaceChildren(
        element(
          "span",
          "metadata-pill",
          selectedProject()?.name || "No project",
        ),
      );
    } else if (session) {
      title.textContent = session.title || "Agent Session";
      metadata.replaceChildren();
    } else {
      title.textContent = "What are we building?";
      metadata.replaceChildren();
    }
    renderTranscript();
    renderAgentComposer();
  }

  function formatAgentRuntime(startValue, endValue = Date.now()) {
    const start = new Date(startValue).getTime();
    const end = endValue instanceof Date ? endValue.getTime() : Number(endValue);
    if (!Number.isFinite(start) || !Number.isFinite(end)) return "";
    const totalSeconds = Math.max(0, Math.floor((end - start) / 1000));
    if (totalSeconds < 60) return `${totalSeconds}s`;
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = String(totalSeconds % 60).padStart(2, "0");
    return `${minutes}m ${seconds}s`;
  }

  function updateAgentRunClocks() {
    document.querySelectorAll("[data-run-started-at]").forEach((node) => {
      const elapsed = formatAgentRuntime(node.dataset.runStartedAt);
      if (elapsed) node.textContent = `· ${elapsed}`;
    });
  }

  function clearAgentRunClock() {
    if (state.agent.runClockTimer !== null) {
      window.clearInterval(state.agent.runClockTimer);
      state.agent.runClockTimer = null;
    }
  }

  function syncAgentRunClock() {
    clearAgentRunClock();
    updateAgentRunClocks();
    if (
      state.route !== "home" ||
      document.hidden ||
      !document.querySelector("[data-run-started-at]")
    )
      return;
    state.agent.runClockTimer = window.setInterval(updateAgentRunClocks, 1_000);
  }

  function renderTurnRuntime(turn) {
    if (!turn?.startedAt || !turn?.completedAt) return null;
    const elapsed = formatAgentRuntime(
      turn.startedAt,
      new Date(turn.completedAt),
    );
    if (!elapsed) return null;
    return element("div", "turn-runtime-footer", `Worked for ${elapsed}`);
  }

  function sessionRecoveryAction(control) {
    if (control?.retry?.allowed) return { name: "retry", label: "Retry" };
    if (control?.resume?.allowed) return { name: "resume", label: "Resume" };
    return null;
  }

  function activeTurnStartedAt() {
    return [...state.agent.transcriptItems]
      .reverse()
      .find((turn) => turn?.startedAt && !turn?.completedAt)?.startedAt || null;
  }

  function renderAgentRunStatus() {
    const session = selectedSession();
    const control = session?.agentControl;
    const presentation = session?.runPresentation;
    const displayState = control?.displayState;
    const active = ["preparing", "thinking", "working", "cancelling"].includes(
      displayState,
    );
    const waiting = displayState === "waiting";
    const recovery = sessionRecoveryAction(control);
    if (!active && !waiting && !recovery) return null;

    const host = element(
      "div",
      `agent-run-status state-${displayState || "idle"}`,
    );
    host.setAttribute("role", "status");
    if (active) host.append(element("span", "agent-run-spinner"));
    else host.append(element("span", "agent-run-state-dot"));
    host.append(
      element(
        "span",
        "agent-run-status-text",
        control?.statusText || presentation?.runningStatusText || humanize(displayState),
      ),
    );
    const turnStartedAt = active ? activeTurnStartedAt() : null;
    if (turnStartedAt) {
      const elapsed = element("span", "agent-run-elapsed");
      elapsed.dataset.runStartedAt = turnStartedAt;
      host.append(elapsed);
    }
    if (recovery) {
      const action = element("button", "agent-run-action", recovery.label);
      action.type = "button";
      action.disabled = Boolean(state.agent.actionPromise) || !state.online;
      action.addEventListener("click", () =>
        performSessionAction(recovery.name),
      );
      host.append(action);
    }
    return host;
  }

  function setupProgress(stage) {
    const progress = element("ol", "setup-progress");
    [
      ["provider", "1", "Provider"],
      ["project", "2", "Project"],
    ].forEach(([key, number, label]) => {
      const item = element("li");
      const completed = key === "provider" && stage === "project";
      item.classList.toggle("active", key === stage);
      item.classList.toggle("completed", completed);
      item.append(
        element("span", "setup-step-number", completed ? "✓" : number),
        element("span", "setup-step-label", label),
      );
      progress.append(item);
    });
    return progress;
  }

  function renderProviderOnboarding(list) {
    const surface = element("section", "onboarding-surface");
    const header = element("div", "onboarding-heading");
    header.append(
      iconNode("terminal", "onboarding-icon"),
      element("h2", "", "Choose an agent provider"),
      element(
        "p",
        "",
        "Install one provider with its official installer, then sign in. RepoPrompt continues automatically when the provider is ready.",
      ),
    );
    surface.append(setupProgress("provider"), header);
    const providers = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const choices = [
      providers.codex,
      providers.claudeCompatible,
      providers.openCodeACP,
      providers.cursorACP,
      providers.grokBuildACP,
    ].filter((provider) => provider?.deploymentAllowed);
    const stack = element("div", "onboarding-provider-list desktop-provider-list");
    choices.forEach((provider, index) => {
      const card = cliProviderCard(provider);
      card.open = index === 0 || isConnectedProvider(provider);
      stack.append(card);
    });
    if (!choices.length) {
      stack.append(
        element(
          "div",
          "empty-state-panel",
          "This server does not currently advertise an installable CLI provider.",
        ),
      );
    }
    surface.append(stack);
    list.append(surface);
    installIcons(surface);
  }

  function renderProjectOnboarding(list) {
    const surface = element("section", "onboarding-surface project-onboarding");
    const header = element("div", "onboarding-heading");
    header.append(
      iconNode("folder", "onboarding-icon"),
      element("h2", "", "Create a project folder"),
      element(
        "p",
        "",
        "A project is an ordinary writable folder on this RepoPrompt server. It does not need to be a Git repository.",
      ),
    );
    const provider = eligibleSessionProviders()[0];
    const ready = element("div", "setup-ready-row");
    ready.append(
      iconNode("check"),
      element(
        "span",
        "",
        `${provider?.displayName || "Provider"} is connected and ready.`,
      ),
    );
    const card = element("section", "project-create-card");
    const form = element("form", "project-create-form");
    const label = document.createElement("label");
    label.htmlFor = "project-name";
    label.textContent = "Project name";
    const input = document.createElement("input");
    input.id = "project-name";
    input.name = "projectName";
    input.type = "text";
    input.maxLength = 128;
    input.autocomplete = "off";
    input.placeholder = "My Project";
    input.required = true;
    const help = element(
      "p",
      "field-help",
      "RepoPrompt creates a folder with this name in the server projects directory.",
    );
    const message = element("div", "inline-message info", "Your files stay in this folder across app deployments.");
    message.setAttribute("role", "status");
    const actions = element("div", "form-actions");
    if ((state.bootstrap?.projects || []).length) {
      const cancel = element("button", "secondary-button", "Cancel");
      cancel.type = "button";
      cancel.addEventListener("click", () => {
        state.agent.projectCreationOpen = false;
        renderHomeProviders();
      });
      actions.append(cancel);
    }
    const submit = element("button", "primary-button", "Create Project");
    submit.type = "submit";
    actions.append(submit);
    label.append(input);
    form.append(label, help, message, actions);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      createManagedProject(input.value, submit, message);
    });
    card.append(form);
    surface.append(setupProgress("project"), header, ready, card);
    list.append(surface);
    installIcons(surface);
  }

  async function createManagedProject(rawName, button, message) {
    const name = rawName.trim();
    if (!name) {
      message.className = "inline-message error";
      message.textContent = "Enter a name for the project folder.";
      return;
    }
    const operationID = window.crypto?.randomUUID?.();
    if (!operationID) {
      message.className = "inline-message error";
      message.textContent = "This browser cannot create secure operation identifiers.";
      return;
    }
    button.textContent = "Creating…";
    setDisabledReason(button, true, "Creating the project folder…");
    message.className = "inline-message info";
    message.textContent = "Creating the folder and preparing Agent Mode…";
    try {
      const result = await api("api/v1/projects", {
        method: "POST",
        body: JSON.stringify({
          operationId: operationID,
          name,
          logicalName: name,
          source: { type: "managedDirectory", name },
        }),
      });
      state.agent.selectedProjectID = result.projectId;
      rememberSelectedProjectID(result.projectId);
      state.agent.selectedSessionID = null;
      rememberSelectedSessionID(null);
      state.agent.newSessionMode = true;
      state.agent.projectCreationOpen = false;
      await loadAll(false);
      toast(`${name} is ready`);
      announce(`Project ${name} created. Agent composer ready.`);
      window.setTimeout(
        () => document.getElementById("composer-text").focus({ preventScroll: true }),
        0,
      );
    } catch (error) {
      button.textContent = "Create Project";
      setDisabledReason(button, false, "");
      message.className = "inline-message error";
      message.textContent = error.message;
      toast(error.message, true);
    }
  }

  function renderTranscript() {
    const list = document.getElementById("transcript-list");
    const status = document.getElementById("transcript-status");
    const earlier = document.getElementById("load-earlier-button");
    const presentation = state.agent.transcriptPage?.presentation;
    clearAgentRunClock();
    list.replaceChildren();
    status.textContent = "";
    earlier.hidden = !presentation?.nextPageToken;
    const setupStage = onboardingStage();
    if (setupStage === "provider") {
      earlier.hidden = true;
      renderProviderOnboarding(list);
      list.setAttribute("aria-busy", "false");
      return;
    }
    if (setupStage === "project") {
      earlier.hidden = true;
      renderProjectOnboarding(list);
      list.setAttribute("aria-busy", "false");
      return;
    }
    if (state.agent.newSessionMode || !state.agent.selectedSessionID) {
      const empty = element("div", "agent-welcome");
      const brand = document.createElement("img");
      brand.src = "assets/repoprompt-icon.png";
      brand.alt = "";
      empty.append(
        brand,
        element("h2", "", "What are we building?"),
        element(
          "p",
          "",
          "Choose a connected provider, describe the task, and RepoPrompt will start an authoritative server session.",
        ),
      );
      list.append(empty);
      list.setAttribute("aria-busy", "false");
      return;
    }
    if (!state.agent.transcriptItems.length) {
      list.append(
        element(
          "div",
          "transcript-empty",
          state.agent.transcriptPromise
            ? "Loading activity…"
            : "This session has no activity yet.",
        ),
      );
    }
    const attachedInteractionIDs = new Set();
    state.agent.transcriptItems.forEach((turn) => {
      const article = element(
        "article",
        `agent-turn${turn.legacyStandalone ? " legacy" : ""}`,
      );
      article.dataset.turnId = turn.turnId;
      (turn.blocks || []).forEach((block) =>
        article.append(renderPresentationBlock(block)),
      );
      (turn.interactions || []).forEach((interaction) => {
        attachedInteractionIDs.add(interaction.interactionId);
        article.append(renderInteraction(interaction));
      });
      const runtime = renderTurnRuntime(turn);
      if (runtime) article.append(runtime);
      list.append(article);
    });
    (presentation?.pendingInteractions || []).forEach((interaction) => {
      if (!attachedInteractionIDs.has(interaction.interactionId))
        list.append(renderInteraction(interaction));
    });
    const runStatus = renderAgentRunStatus();
    if (runStatus) list.append(runStatus);
    syncAgentRunClock();
    list.setAttribute(
      "aria-busy",
      String(Boolean(state.agent.transcriptPromise)),
    );
  }

  function scrollTranscriptToBottom() {
    const viewport = document.getElementById("main-content");
    window.requestAnimationFrame(() => {
      viewport.scrollTop = viewport.scrollHeight;
    });
  }

  function preserveTranscriptViewport(previousHeight, previousTop) {
    const viewport = document.getElementById("main-content");
    window.requestAnimationFrame(() => {
      viewport.scrollTop = previousTop + (viewport.scrollHeight - previousHeight);
    });
  }

  function renderPresentationBlock(block) {
    const type = block?.type || "standaloneNote";
    if (type === "activityCluster") {
      const details = element(
        "details",
        "presentation-block activity-cluster",
      );
      details.dataset.blockId = block.id;
      if (!state.agent.blockExpansion.has(block.id))
        state.agent.blockExpansion.set(
          block.id,
          Boolean(block.summary?.defaultExpanded || block.summary?.running),
        );
      details.open = state.agent.blockExpansion.get(block.id);
      details.addEventListener("toggle", () => {
        state.agent.blockExpansion.set(block.id, details.open);
      });
      const summary = element("summary", "activity-cluster-summary");
      const summaryPrimary = element("div", "activity-cluster-primary");
      summaryPrimary.append(
        iconNode("tools", "activity-cluster-icon"),
        element("strong", "", activityClusterTitle(block.summary)),
      );
      if (block.summary?.toolCount)
        summaryPrimary.append(
          element("span", "activity-count", String(block.summary.toolCount)),
        );
      const groups = (block.summary?.toolGroups || [])
        .map(toolDisplayName)
        .filter((value, index, values) => values.indexOf(value) === index)
        .slice(0, 4);
      if (groups.length)
        summaryPrimary.append(
          element("span", "activity-tool-groups", groups.join(", ")),
        );
      summaryPrimary.append(toolStatusDot(activityClusterStatus(block.summary)));
      summary.append(summaryPrimary);
      if (block.summary?.narration)
        summary.append(
          element("span", "activity-narration", block.summary.narration),
        );
      details.append(summary);
      const rows = element("div", "activity-cluster-rows");
      (block.rows || []).forEach((row) =>
        rows.append(renderPresentationRow(row)),
      );
      details.append(rows);
      return details;
    }
    if (type === "groupedHistory") {
      const group = element("section", "presentation-block grouped-history");
      group.append(element("h3", "", block.title || "Earlier activity"));
      (block.rows || []).forEach((row) =>
        group.append(renderPresentationRow(row)),
      );
      return group;
    }
    if (type === "collapsedHistoryRange")
      return element(
        "div",
        "presentation-block collapsed-history",
        `${block.title || "Earlier activity"} · ${block.count || 0}`,
      );
    if (type === "middleSummary") {
      const summary = element("aside", "presentation-block middle-summary");
      summary.append(renderMarkdown(block.text || ""));
      return summary;
    }
    const classes = {
      request: "request-block",
      standaloneAssistant: "assistant-block",
      standaloneTool: "tool-block",
      standaloneNote: "note-block",
      conclusion: "conclusion-block",
    };
    const host = element(
      "section",
      `presentation-block ${classes[type] || "note-block"}`,
    );
    if (block.row) host.append(renderPresentationRow(block.row));
    return host;
  }

  function renderPresentationRow(row) {
    if (row?.type === "tool") return renderPresentationTool(row.tool, row.id);
    const host = element(
      "div",
      `presentation-row row-${row?.type || "note"}`,
    );
    host.dataset.rowId = row?.id || "";
    const labels = {
      userRequest: "You",
      assistant: "RepoPrompt",
      thinking: "Thinking",
      progress: "Progress",
      note: "Note",
      error: "Error",
    };
    host.append(
      element(
        "strong",
        "presentation-row-label",
        labels[row?.type] || humanize(row?.type || "note"),
      ),
      renderMarkdown(row?.text || ""),
    );
    if (row?.type === "userRequest") {
      const chips = element("div", "request-chips");
      (row.taggedFiles || []).forEach((file) =>
        chips.append(
          element(
            "span",
            "request-chip",
            file.displayName || file.logicalPath,
          ),
        ),
      );
      if ((row.attachmentIds || []).length)
        chips.append(
          element(
            "span",
            "request-chip",
            `${row.attachmentIds.length} attachments`,
          ),
        );
      if (chips.childElementCount) host.append(chips);
    }
    if (row?.code) host.append(element("code", "error-code", row.code));
    return host;
  }

  const markdownRenderer = globalThis.marked
    ? new globalThis.marked.Renderer()
    : null;
  if (markdownRenderer) {
    // Provider-authored raw HTML is always shown as source text. Markdown syntax
    // is rendered by marked, then the resulting DOM is constrained below.
    markdownRenderer.html = (html) => escapeHTML(html);
  }

  const markdownElements = new Set([
    "a",
    "blockquote",
    "br",
    "code",
    "del",
    "em",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "img",
    "input",
    "li",
    "ol",
    "p",
    "pre",
    "strong",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "ul",
  ]);

  function escapeHTML(source) {
    return String(source || "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function safeMarkdownURL(value, kind) {
    try {
      const resolved = new URL(value, window.location.href);
      if (kind === "link" && ["http:", "https:", "mailto:"].includes(resolved.protocol))
        return resolved.href;
      if (
        kind === "image" &&
        (resolved.origin === window.location.origin ||
          (resolved.protocol === "data:" && /^data:image\/(?:png|jpeg|gif|webp);/i.test(value)))
      )
        return resolved.href;
    } catch {
      return null;
    }
    return null;
  }

  function sanitizeMarkdown(root) {
    [...root.querySelectorAll("*")].forEach((node) => {
      const tag = node.tagName.toLowerCase();
      if (!markdownElements.has(tag)) {
        node.replaceWith(document.createTextNode(node.textContent || ""));
        return;
      }
      const href = tag === "a" ? safeMarkdownURL(node.getAttribute("href") || "", "link") : null;
      const src = tag === "img" ? safeMarkdownURL(node.getAttribute("src") || "", "image") : null;
      const language = tag === "code" ? (node.getAttribute("class") || "").match(/^language-[A-Za-z0-9_+.-]+$/)?.[0] : null;
      const checked = tag === "input" && node.getAttribute("checked") !== null;
      [...node.attributes].forEach((attribute) => node.removeAttribute(attribute.name));
      if (href) {
        node.setAttribute("href", href);
        node.setAttribute("rel", "noopener noreferrer");
        if (/^https?:/i.test(href)) node.setAttribute("target", "_blank");
      }
      if (src) {
        node.setAttribute("src", src);
        node.setAttribute("alt", "");
        node.setAttribute("loading", "lazy");
      }
      if (language) node.setAttribute("class", language);
      if (tag === "input") {
        node.setAttribute("type", "checkbox");
        node.setAttribute("disabled", "");
        if (checked) node.setAttribute("checked", "");
      }
    });
    root.querySelectorAll("table").forEach((table) => {
      const wrapper = element("div", "markdown-table-scroll");
      table.replaceWith(wrapper);
      wrapper.append(table);
    });
  }

  // Use the same mature GFM parser family as Gabblin. The DOM allowlist keeps
  // provider output inside the portal's existing no-raw-HTML security boundary.
  function renderMarkdown(source) {
    const root = element("div", "presentation-row-content markdown-content");
    if (!markdownRenderer || !globalThis.marked) {
      root.textContent = String(source || "");
      return root;
    }
    root.innerHTML = globalThis.marked.parse(String(source || ""), {
      breaks: true,
      gfm: true,
      headerIds: false,
      mangle: false,
      renderer: markdownRenderer,
    });
    sanitizeMarkdown(root);
    return root;
  }

  function parseToolPayload(raw) {
    if (typeof raw !== "string" || !raw.trim()) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  }

  function toolObject(raw) {
    const parsed = parseToolPayload(raw);
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object")
      return null;
    for (const key of ["Ok", "ok", "Err", "err"])
      if (parsed[key] && typeof parsed[key] === "object" && !Array.isArray(parsed[key]))
        return parsed[key];
    return parsed;
  }

  function toolValue(object, keys) {
    if (!object) return null;
    for (const key of keys) {
      const value = object[key];
      if (typeof value === "string" && value.trim()) return value.trim();
      if (typeof value === "number") return value;
    }
    return null;
  }

  function toolArray(object, keys) {
    if (!object) return [];
    for (const key of keys)
      if (Array.isArray(object[key])) return object[key];
    return [];
  }

  function compactToolText(value, maximum = 160) {
    const text = String(value || "").replace(/\s+/g, " ").trim();
    if (text.length <= maximum) return text;
    return `${text.slice(0, maximum - 1).trimEnd()}…`;
  }

  function compactToolPath(value) {
    const path = String(value || "").trim();
    if (!path) return "";
    const parts = path.split(/[\\/]/).filter(Boolean);
    return parts.length <= 2 ? parts.join("/") : `…/${parts.slice(-2).join("/")}`;
  }

  function toolBaseName(value) {
    const parts = String(value || "").split(/[\\/]/).filter(Boolean);
    return parts.at(-1) || "";
  }

  function normalizedToolName(rawName) {
    let name = String(rawName || "")
      .trim()
      .replace(/^mcp__RepoPrompt__/i, "")
      .replace(/^functions\./i, "");
    name = name.split(".").at(-1)?.toLowerCase().replace(/[ -]+/g, "_") || "";
    if (["local_shell", "shell", "unified_exec", "exec_command", "run_shell_command"].includes(name))
      return "bash";
    if (["filechange", "file_change"].includes(name)) return "apply_patch";
    if (name === "requestuserinput") return "request_user_input";
    if (["web_search", "websearch", "search_web", "google_web_search"].includes(name))
      return "search";
    if (["webfetch", "web_fetch", "read_web", "open_url", "read_url", "fetch_url"].includes(name))
      return "web_read";
    return name;
  }

  const toolTitles = {
    request_user_input: "Question",
    ask_user: "Question",
    ask_user_question: "Question",
    bash: "Bash",
    search: "Web Search",
    web_read: "Read Web Page",
    read: "Read",
    read_file: "Read File",
    apply_edits: "Edit",
    apply_patch: "Patch",
    edit: "Edit File",
    file_actions: "File Action",
    file_search: "Search",
    get_file_tree: "File Tree",
    get_code_structure: "Code Structure",
    manage_selection: "Selection",
    workspace_context: "Context",
    ask_oracle: "Oracle",
    oracle_send: "Oracle",
    oracle_chat_log: "Oracle Log",
    chat_send: "Chat",
    context_builder: "Context Builder",
    git: "Git",
    manage_worktree: "Worktrees",
    prompt: "Prompt",
    chats: "Chats",
    list_models: "Models",
    bind_context: "Bind Context",
    manage_workspaces: "Workspaces",
    agent_explore: "Agent Explore",
    agent_run: "Agent Run",
    agent_manage: "Agent Manage",
    app_settings: "App Settings",
  };

  function toolDisplayName(rawName) {
    const name = normalizedToolName(rawName);
    return toolTitles[name] || humanizeToolValue(name || "tool");
  }

  function humanizeToolValue(value) {
    return String(value || "")
      .replace(/[_-]+/g, " ")
      .replace(/([a-z])([A-Z])/g, "$1 $2")
      .replace(/^./, (character) => character.toUpperCase());
  }

  function toolFamily(name) {
    if (["get_file_tree", "read_file", "read", "file_search", "search", "web_read", "get_code_structure"].includes(name))
      return "navigation";
    if (["apply_edits", "apply_patch", "edit", "file_actions"].includes(name))
      return "edit";
    if (name === "bash") return "execution";
    if (["ask_oracle", "oracle_send", "oracle_utils", "oracle_chat_log", "chat_send", "ask_user", "ask_user_question", "request_user_input", "chats"].includes(name))
      return "communication";
    if (["agent_explore", "agent_run", "agent_manage"].includes(name))
      return "communication";
    if (["manage_selection", "workspace_context", "prompt", "git", "manage_worktree", "bind_context", "manage_workspaces", "list_models", "context_builder", "app_settings"].includes(name))
      return "config";
    return "other";
  }

  function toolIconName(name) {
    if (["read", "read_file"].includes(name)) return "document";
    if (name === "bash") return "terminal";
    if (["search", "web_read"].includes(name)) return "globe";
    if (["apply_edits", "apply_patch", "edit"].includes(name)) return "pencil";
    if (name === "file_actions") return "document";
    if (name === "file_search") return "search";
    if (name === "get_file_tree") return "folder";
    if (name === "get_code_structure") return "listStar";
    if (name === "manage_selection") return "selection";
    if (["workspace_context", "context_builder", "bind_context"].includes(name)) return "context";
    if (["ask_oracle", "oracle_send"].includes(name)) return "brain";
    if (["chat_send", "chats", "oracle_chat_log", "request_user_input"].includes(name)) return "message";
    if (["git", "manage_worktree"].includes(name)) return "branch";
    if (name === "prompt") return "quote";
    if (["agent_explore", "agent_run", "agent_manage"].includes(name)) return "agent";
    if (name === "list_models") return "model";
    if (["manage_workspaces", "app_settings"].includes(name)) return "settings";
    return "tools";
  }

  function toolRenderStatus(status) {
    if (["pending", "running"].includes(status)) return "running";
    if (status === "success") return "success";
    if (status === "warning") return "warning";
    if (["failed", "cancelled"].includes(status)) return "failure";
    return "neutral";
  }

  function toolStatusDot(status) {
    const rendered = toolRenderStatus(status);
    const dot = element("span", `tool-status-dot status-${rendered}`);
    dot.setAttribute("aria-label", humanize(status || "unknown"));
    return dot;
  }

  function activityClusterStatus(summary = {}) {
    if (summary.failed) return "failed";
    if (summary.warning) return "warning";
    if (summary.running) return "running";
    return "unknown";
  }

  function activityClusterTitle(summary = {}) {
    if (summary.running) return "Working";
    const names = summary.toolGroups || [];
    const normalized = names.map(normalizedToolName);
    const navigated = normalized.some((name) => ["get_file_tree", "read_file", "read", "file_search", "search", "web_read", "get_code_structure"].includes(name));
    const edited = normalized.some((name) => ["apply_edits", "apply_patch", "edit", "file_actions"].includes(name));
    const executed = normalized.includes("bash");
    if (navigated && edited) return "Explored and edited";
    if (edited) return "Made changes";
    if (executed) return "Ran commands";
    if (navigated) return "Explored codebase";
    return summary.title && !/^\d+ tools?$/.test(summary.title)
      ? toolDisplayName(summary.title)
      : "Tool activity";
  }

  function toolSubtitle(name, args, result, tool) {
    const path = toolValue(args, ["path", "file_path", "filePath"])
      || toolValue(result, ["display_path", "displayPath", "path"]);
    const op = toolValue(args, ["op", "operation", "action", "mode"])
      || toolValue(result, ["op", "operation", "action", "mode"]);
    if (["read", "read_file", "apply_edits", "edit"].includes(name) && path)
      return compactToolPath(path);
    if (name === "apply_patch") {
      if (path) return compactToolPath(path);
      const paths = toolArray(args, ["paths"]);
      if (paths.length)
        return `${compactToolPath(paths[0])}${paths.length > 1 ? ` (+${paths.length - 1} more)` : ""}`;
      const count = toolValue(args, ["change_count", "changeCount"]);
      if (count) return `${count} file${Number(count) === 1 ? "" : "s"}`;
    }
    if (name === "bash") {
      const command = toolValue(args, ["cmd", "command"])
        || toolValue(result, ["command"]);
      if (command) return compactToolText(command, 180);
      if (tool.processId != null) return `pid ${tool.processId}`;
    }
    if (name === "file_search") {
      const pattern = toolValue(args, ["pattern", "query"]);
      const matches = toolValue(result, ["total_matches", "totalMatches", "matches"]);
      const files = toolValue(result, ["total_files", "totalFiles"]);
      return [pattern ? `"${compactToolText(pattern, 70)}"` : "", matches != null && files != null ? `${matches} matches in ${files} files` : ""].filter(Boolean).join(" • ");
    }
    if (name === "search") {
      const query = toolValue(args, ["query", "q", "search_query", "searchQuery", "text"]);
      return query ? `"${compactToolText(query, 90)}"` : "";
    }
    if (name === "web_read") {
      const url = toolValue(args, ["url", "uri", "href"]);
      if (url) {
        try {
          const parsed = new URL(url);
          return compactToolText(`${parsed.host}${parsed.pathname === "/" ? "" : parsed.pathname}`, 90);
        } catch {
          return compactToolText(url, 90);
        }
      }
    }
    if (name === "get_file_tree")
      return [toolValue(args, ["type"]), path ? compactToolPath(path) : ""].filter(Boolean).join(" • ");
    if (name === "get_code_structure") {
      const paths = toolArray(args, ["paths"]);
      return paths.length ? `${paths.length} path${paths.length === 1 ? "" : "s"}` : "selection";
    }
    if (name === "file_actions") {
      const target = path ? compactToolPath(path) : "";
      const next = toolValue(args, ["new_path", "newPath"]);
      return [op ? humanizeToolValue(op) : "", target && next ? `${target} → ${compactToolPath(next)}` : target].filter(Boolean).join(": ");
    }
    if (name === "workspace_context") {
      const include = toolArray(args, ["include"]);
      return include.map(humanizeToolValue).join(", ");
    }
    if (name === "prompt" && op) {
      const target = toolValue(args, ["path", "copy_preset", "copyPreset"]);
      return [humanizeToolValue(op), target ? compactToolPath(target) : ""].filter(Boolean).join(" • ");
    }
    if (op) return humanizeToolValue(op);
    if ((tool.keyPaths || []).length)
      return `${compactToolPath(tool.keyPaths[0])}${tool.keyPaths.length > 1 ? ` (+${tool.keyPaths.length - 1} more)` : ""}`;
    const summary = compactToolText(tool.summary, 160);
    return summary && normalizedToolName(summary) !== name ? summary : "";
  }

  function formattedToolPayload(raw) {
    const parsed = parseToolPayload(raw);
    return parsed == null ? String(raw || "") : JSON.stringify(parsed, null, 2);
  }

  function renderPresentationTool(tool = {}, rowID = "") {
    const name = normalizedToolName(tool.name);
    const args = toolObject(tool.displayArguments);
    const result = toolObject(tool.displayResult);
    const hasPayload = Boolean(tool.displayArguments || tool.displayResult);
    const card = element(hasPayload ? "details" : "article", `typed-tool tool-status-${toolRenderStatus(tool.status)} tool-family-${toolFamily(name)}`);
    card.dataset.rowId = rowID;
    card.dataset.executionId = tool.executionId || "";
    if (["pending", "running"].includes(tool.status))
      card.setAttribute("role", "status");
    if (hasPayload) {
      card.open = state.agent.toolExpansion.get(rowID) === true;
      card.addEventListener("toggle", () => {
        state.agent.toolExpansion.set(rowID, card.open);
      });
    }
    const header = element(hasPayload ? "summary" : "header", "typed-tool-header");
    const leading = element("span", "typed-tool-leading");
    leading.append(
      iconNode(toolIconName(name), "typed-tool-icon"),
      element("strong", "typed-tool-title", toolDisplayName(name)),
      toolStatusDot(tool.status),
    );
    const subtitle = toolSubtitle(name, args, result, tool);
    if (subtitle) leading.append(element("span", "tool-summary", subtitle));
    header.append(leading);
    const process = [
      tool.processId != null ? `pid ${tool.processId}` : "",
      tool.exitCode != null ? `exit ${tool.exitCode}` : "",
    ].filter(Boolean).join(" · ");
    if (process) header.append(element("span", "tool-process", process));
    card.append(header);
    if (hasPayload) {
      const body = element("div", "tool-details");
      if (tool.displayArguments) {
        const section = element("section", "tool-payload-section");
        section.append(
          element("strong", "tool-payload-label", "Arguments"),
          element("pre", "tool-payload", formattedToolPayload(tool.displayArguments)),
        );
        body.append(section);
      }
      if (tool.displayResult) {
        const section = element("section", `tool-payload-section${name === "bash" ? " bash-output" : ""}`);
        section.append(
          element("strong", "tool-payload-label", name === "bash" ? "Output" : "Result"),
          element("pre", "tool-payload", formattedToolPayload(tool.displayResult)),
        );
        body.append(section);
      }
      card.append(body);
    }
    return card;
  }

  function renderInteraction(interaction) {
    const card = element(
      "section",
      `agent-interaction state-${interaction.state || "unknown"}`,
    );
    card.dataset.interactionId = interaction.interactionId;
    if (interaction.requiresAttention) card.setAttribute("role", "group");
    card.append(
      element(
        "strong",
        "interaction-title",
        interaction.kind === "approval" ? "Approval required" : "Question",
      ),
      element(
        "p",
        "interaction-prompt",
        interaction.prompt || "The agent needs your response.",
      ),
    );
    if (interaction.resolution)
      card.append(
        element(
          "p",
          "interaction-resolution",
          `Resolution: ${interaction.resolution}`,
        ),
      );
    else if (
      interaction.state === "pending" &&
      interaction.mutable &&
      interaction.input
    ) {
      const form = element("form", "interaction-form");
      form.dataset.interactionId = interaction.interactionId;
      renderInteractionInput(form, interaction.input);
      const submit = element("button", "primary-button", "Submit response");
      submit.type = "submit";
      form.append(submit);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        submitInteraction(form, interaction);
      });
      card.append(form);
    } else if (interaction.state === "pending") {
      card.append(element("p", "interaction-pending", "Awaiting response"));
    }
    return card;
  }

  function renderInteractionInput(form, input) {
    if (input.type === "singleChoice") {
      (input.choices || []).forEach((choice) => {
        const label = element("label", "interaction-option");
        const control = document.createElement("input");
        control.type = "radio";
        control.name = "choice";
        control.value = choice.id;
        control.required = true;
        label.append(control, document.createTextNode(choice.displayName));
        if (choice.detailText)
          label.append(element("small", "", choice.detailText));
        form.append(label);
      });
      if (input.allowsCustom) {
        const custom = document.createElement("input");
        custom.type = "text";
        custom.name = "customText";
        custom.placeholder = "Optional detail";
        form.append(custom);
      }
      return;
    }
    if (input.type === "freeText") {
      const control = input.multiline
        ? document.createElement("textarea")
        : document.createElement("input");
      if (!input.multiline) control.type = "text";
      control.name = "text";
      control.required = true;
      control.maxLength = 64000;
      control.placeholder = input.placeholder || "Enter your response";
      form.append(control);
      return;
    }
    if (input.type === "questionnaire") {
      (input.questions || []).forEach((question, index) => {
        const fieldset = element("fieldset", "interaction-question");
        fieldset.dataset.questionId = question.id;
        fieldset.dataset.required = String(Boolean(question.required));
        fieldset.append(element("legend", "", question.prompt));
        (question.choices || []).forEach((choice) => {
          const label = element("label", "interaction-option");
          const control = document.createElement("input");
          control.type = question.allowsMultiple ? "checkbox" : "radio";
          control.name = `question-${index}`;
          control.value = choice.id;
          label.append(control, document.createTextNode(choice.displayName));
          if (choice.detailText)
            label.append(element("small", "", choice.detailText));
          fieldset.append(label);
        });
        if (question.allowsCustom) {
          const custom = document.createElement("input");
          custom.type = "text";
          custom.name = "customText";
          custom.maxLength = 64000;
          custom.placeholder = "Optional custom response";
          if (!question.allowsMultiple)
            custom.addEventListener("input", () => {
              if (custom.value.trim())
                fieldset
                  .querySelectorAll('input[type="radio"]')
                  .forEach((control) => {
                    control.checked = false;
                  });
            });
          fieldset.append(custom);
        }
        if (!question.allowsMultiple)
          fieldset.querySelectorAll('input[type="radio"]').forEach((control) => {
            control.addEventListener("change", () => {
              if (control.checked) {
                const custom = fieldset.querySelector('input[name="customText"]');
                if (custom) custom.value = "";
              }
            });
          });
        const skipLabel = element("label", "interaction-option interaction-skip");
        const skip = document.createElement("input");
        skip.type = "checkbox";
        skip.name = "skipped";
        skipLabel.append(skip, document.createTextNode("Skip this question"));
        skip.addEventListener("change", () => {
          fieldset
            .querySelectorAll('input:not([name="skipped"])')
            .forEach((control) => {
              control.disabled = skip.checked;
              if (skip.checked) {
                if (["checkbox", "radio"].includes(control.type))
                  control.checked = false;
                else control.value = "";
              }
            });
        });
        fieldset.append(skipLabel);
        form.append(fieldset);
      });
    }
  }

  function interactionResponse(form, input) {
    if (input.type === "singleChoice") {
      const choiceID = form.querySelector('input[name="choice"]:checked')?.value;
      if (!choiceID) throw new Error("Choose a response.");
      return {
        type: "choice",
        choiceID,
        customText: form.elements.customText?.value.trim() || null,
      };
    }
    if (input.type === "freeText") {
      const value = form.elements.text?.value.trim();
      if (!value) throw new Error("Enter a response.");
      return { type: "text", text: value };
    }
    const answers = [...form.querySelectorAll("fieldset[data-question-id]")].map(
      (fieldset) => {
        const skipped = Boolean(
          fieldset.querySelector('input[name="skipped"]')?.checked,
        );
        const selectedChoiceIDs = [
          ...fieldset.querySelectorAll('input:not([name="skipped"]):checked'),
        ]
          .map((control) => control.value);
        const customText =
          fieldset.querySelector('input[name="customText"]')?.value.trim() ||
          null;
        if (
          fieldset.dataset.required === "true" &&
          !skipped &&
          !selectedChoiceIDs.length &&
          !customText
        )
          throw new Error("Answer every required question.");
        return {
          questionID: fieldset.dataset.questionId,
          selectedChoiceIDs,
          customText,
          skipped,
        };
      },
    );
    return { type: "questionnaire", answers };
  }

  async function submitInteraction(form, interaction) {
    if (state.agent.mutationPromise) return state.agent.mutationPromise;
    let response;
    try {
      response = interactionResponse(form, interaction.input);
    } catch (error) {
      toast(error.message, true);
      return null;
    }
    const operationID = window.crypto?.randomUUID?.();
    if (!operationID) {
      toast("This browser cannot create secure operation identifiers.", true);
      return null;
    }
    const submit = form.querySelector('button[type="submit"]');
    state.agent.mutationPromise = (async () => {
      submit.disabled = true;
      form.setAttribute("aria-busy", "true");
      renderAgentComposer();
      try {
        await api(
          `api/v1/sessions/${encodeURIComponent(state.agent.selectedSessionID)}/interactions/${encodeURIComponent(interaction.interactionId)}/answer`,
          {
            method: "POST",
            body: JSON.stringify({
              operationId: operationID,
              expectedRevision: interaction.revision,
              response,
            }),
          },
        );
        await loadTranscript({ silent: true });
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision")
          await loadTranscript({ silent: true });
      } finally {
        state.agent.mutationPromise = null;
        renderAgentComposer();
      }
    })();
    return state.agent.mutationPromise;
  }

  function mergeTranscriptItems(items, prepend = false) {
    const merged = new Map(
      (prepend
        ? items.concat(state.agent.transcriptItems)
        : state.agent.transcriptItems.concat(items)
      ).map((item) => [item.turnId, item]),
    );
    state.agent.transcriptItems = [...merged.values()];
  }

  async function loadTranscript({ pageToken = null, silent = false } = {}) {
    const sessionID = state.agent.selectedSessionID;
    if (!sessionID || state.agent.newSessionMode) return null;
    if (
      state.agent.transcriptPromise &&
      state.agent.transcriptPromiseSessionID === sessionID
    )
      return state.agent.transcriptPromise;
    const generation = state.agent.selectionGeneration;
    const transcriptViewport = document.getElementById("main-content");
    const previousScrollHeight = transcriptViewport.scrollHeight;
    const previousScrollTop = transcriptViewport.scrollTop;
    const previousPresentationCursor =
      state.agent.transcriptPage?.presentation?.presentationCursor || null;
    const query = new URLSearchParams({ limit: "25" });
    if (pageToken) query.set("pageToken", pageToken);
    const requestPromise = (async () => {
      if (!silent) renderTranscript();
      try {
        const page = await api(
          `api/v1/sessions/${encodeURIComponent(sessionID)}/presentation?${query}`,
        );
        if (
          generation !== state.agent.selectionGeneration ||
          sessionID !== state.agent.selectedSessionID
        )
          return null;
        if (
          silent &&
          !pageToken &&
          state.agent.transcriptPage?.presentation?.nextPageToken
        )
          page.presentation.nextPageToken =
            state.agent.transcriptPage.presentation.nextPageToken;
        state.agent.transcriptPage = page;
        mergeTranscriptItems(
          page.presentation?.turns || [],
          Boolean(pageToken),
        );
        const index = state.bootstrap.sessions.findIndex(
          (item) => item.sessionId === sessionID,
        );
        if (Array.isArray(page.sidebarSessions)) {
          const projectID = page.session.projectId;
          state.bootstrap.sessions = state.bootstrap.sessions
            .filter((item) => item.projectId !== projectID)
            .concat(page.sidebarSessions);
        } else if (index >= 0) {
          state.bootstrap.sessions[index] = page.session;
        }
        renderSessions();
        renderAgentDetail();
        if (pageToken)
          preserveTranscriptViewport(previousScrollHeight, previousScrollTop);
        else if (
          previousPresentationCursor !==
          (page.presentation?.presentationCursor || null)
        )
          scrollTranscriptToBottom();
        scheduleAgentPoll();
        return page;
      } catch (error) {
        if (generation === state.agent.selectionGeneration) {
          document.getElementById("transcript-status").textContent =
            `${error.message} Showing the last loaded transcript.`;
          toast(error.message, true);
          scheduleAgentPoll();
        }
        return null;
      } finally {
        if (state.agent.transcriptPromise === requestPromise) {
          state.agent.transcriptPromise = null;
          state.agent.transcriptPromiseSessionID = null;
        }
        if (
          generation === state.agent.selectionGeneration &&
          sessionID === state.agent.selectedSessionID
        )
          document
            .getElementById("transcript-list")
            .setAttribute("aria-busy", "false");
      }
    })();
    state.agent.transcriptPromise = requestPromise;
    state.agent.transcriptPromiseSessionID = sessionID;
    return requestPromise;
  }

  function clearAgentPoll() {
    if (state.agent.pollTimer !== null) {
      window.clearTimeout(state.agent.pollTimer);
      state.agent.pollTimer = null;
    }
  }

  function scheduleAgentPoll() {
    clearAgentPoll();
    if (
      state.route !== "home" ||
      !state.agent.selectedSessionID ||
      state.agent.newSessionMode ||
      document.hidden
    )
      return;
    const delay = window.__REPOPROMPT_PORTAL_TEST_HOOK__ ? 60_000 : 15_000;
    state.agent.pollTimer = window.setTimeout(async () => {
      state.agent.pollTimer = null;
      await loadTranscript({ silent: true });
    }, delay);
  }

  function requestAgentEventRefresh(event) {
    const selectedSessionID = state.agent.selectedSessionID;
    if (
      state.route !== "home" ||
      !selectedSessionID ||
      state.agent.newSessionMode ||
      (event?.sessionId && event.sessionId !== selectedSessionID)
    )
      return;
    state.agent.eventRefreshRevision += 1;
    if (state.agent.eventRefreshPromise) return;
    state.agent.eventRefreshPromise = (async () => {
      while (
        state.agent.appliedEventRefreshRevision <
        state.agent.eventRefreshRevision
      ) {
        state.agent.appliedEventRefreshRevision =
          state.agent.eventRefreshRevision;
        await loadTranscript({ silent: true });
      }
    })().finally(() => {
      state.agent.eventRefreshPromise = null;
      if (
        state.agent.appliedEventRefreshRevision <
        state.agent.eventRefreshRevision
      )
        requestAgentEventRefresh();
    });
  }

  function connectAgentEvents() {
    if (state.agent.eventSource || typeof EventSource === "undefined") return;
    const source = new EventSource("api/v1/events/stream");
    state.agent.eventSource = source;
    source.addEventListener("open", () => clearAgentPoll());
    source.addEventListener("refresh", (message) => {
      let event = null;
      try {
        event = JSON.parse(message.data);
      } catch (_) {}
      requestAgentEventRefresh(event);
    });
    source.addEventListener("error", () => scheduleAgentPoll());
  }

  function composerDestination() {
    const session = state.agent.newSessionMode ? null : selectedSession();
    const projectID = session?.projectId || state.agent.selectedProjectID;
    return {
      key: session ? `session:${session.sessionId}` : `project:${projectID || "none"}`,
      projectID,
      session,
    };
  }

  function activeComposerState() {
    const destination = composerDestination();
    const editor = document.getElementById("composer-text");
    if (state.agent.activeComposerKey !== destination.key) {
      const previous = state.agent.composerStates.get(state.agent.activeComposerKey);
      if (previous && editor) previous.text = editor.value;
      state.agent.activeComposerKey = destination.key;
      if (!state.agent.composerStates.has(destination.key)) {
        state.agent.composerStates.set(destination.key, {
          text: "",
          configuration: null,
          attachments: [],
          feedback: "",
        });
      }
      if (editor) editor.value = state.agent.composerStates.get(destination.key).text;
    }
    return state.agent.composerStates.get(destination.key);
  }

  function defaultToolValues(group) {
    return Object.fromEntries(
      (group?.toolControls || []).map((control) => {
        if (control.type === "toggle")
          return [control.common.id, { type: "boolean", value: Boolean(control.value) }];
        if (control.type === "singleChoice")
          return [control.common.id, { type: "choice", value: control.selectedID }];
        return [control.common.id, { type: "choices", value: control.selectedIDs || [] }];
      }),
    );
  }

  function initialComposerDraft(catalog) {
    const selected = catalog?.selected;
    const groups = catalog?.providerGroups || [];
    const providerID = selected?.providerId || groups[0]?.providerId || "";
    const group = groups.find((item) => item.providerId === providerID);
    const modelID = selected?.modelId || group?.models?.find((item) => item.enabled !== false)?.id || "";
    const model = group?.models?.find((item) => item.id === modelID);
    return {
      providerId: providerID,
      modelId: modelID,
      effortId: selected?.effortId ?? model?.defaultEffortID ?? null,
      workflowId: selected?.workflowId ?? null,
      permissionId: selected?.permissionId ?? group?.permissionControl?.selectedID ?? null,
      toolValues: { ...defaultToolValues(group), ...(selected?.toolValues || {}) },
    };
  }

  async function loadComposerCatalog(force = false) {
    const destination = composerDestination();
    if (!destination.projectID) return null;
    const sameDestination = state.agent.composerCatalogKey === destination.key;
    if (!force && sameDestination && state.agent.composerCatalog)
      return state.agent.composerCatalog;
    if (state.agent.composerCatalogPromise && sameDestination)
      return state.agent.composerCatalogPromise;
    const generation = ++state.agent.composerCatalogGeneration;
    state.agent.composerCatalogKey = destination.key;
    if (!sameDestination) state.agent.composerCatalog = null;
    const path = destination.session
      ? `api/v1/sessions/${encodeURIComponent(destination.session.sessionId)}/composer-catalog`
      : `api/v1/projects/${encodeURIComponent(destination.projectID)}/composer-catalog`;
    const promise = api(path)
      .then((catalog) => {
        if (generation !== state.agent.composerCatalogGeneration || composerDestination().key !== destination.key)
          return null;
        state.agent.composerCatalog = catalog;
        state.agent.composerCatalogVersion += 1;
        const composer = activeComposerState();
        if (!composer.configuration) composer.configuration = initialComposerDraft(catalog);
        composer.feedback = "";
        renderAgentComposer();
        return catalog;
      })
      .catch((error) => {
        if (generation === state.agent.composerCatalogGeneration) {
          activeComposerState().feedback = error.message;
          renderAgentComposer();
        }
        return null;
      })
      .finally(() => {
        if (state.agent.composerCatalogPromise === promise)
          state.agent.composerCatalogPromise = null;
      });
    state.agent.composerCatalogPromise = promise;
    renderAgentComposer();
    return promise;
  }

  function composerOptionButton(label, selected, disabled, detail, onSelect) {
    const button = element("button", `composer-option-button${selected ? " selected" : ""}`, label);
    button.type = "button";
    button.disabled = disabled;
    button.setAttribute("role", "menuitemradio");
    button.setAttribute("aria-checked", String(selected));
    if (detail) button.title = detail;
    button.addEventListener("click", () => {
      onSelect();
      state.agent.retryOperation = null;
      button.closest("details").open = false;
      renderAgentComposer();
      document.getElementById("composer-text").focus({ preventScroll: true });
    });
    return button;
  }

  function renderComposerMenu(host, rows) {
    host.replaceChildren(...rows);
  }

  function renderComposerTools(group, draft) {
    const menu = document.getElementById("composer-tools-menu");
    const host = document.getElementById("composer-tools");
    host.replaceChildren();
    (group?.toolControls || []).forEach((control) => {
      const common = control.common;
      if (control.type === "toggle") {
        const current = draft.toolValues[common.id]?.value ?? Boolean(control.value);
        const button = composerOptionButton(
          common.displayName,
          current,
          common.mutable === false,
          common.lockReasonCode || common.detailText || "",
          () => { draft.toolValues[common.id] = { type: "boolean", value: !current }; },
        );
        button.setAttribute("role", "menuitemcheckbox");
        host.append(button);
        return;
      }
      const label = element("label", "", common.displayName);
      const select = document.createElement("select");
      const current = draft.toolValues[common.id]?.value ??
        (control.type === "singleChoice" ? control.selectedID : control.selectedIDs || []);
      if (control.type === "multiChoice") select.multiple = true;
      (control.choices || []).forEach((choice) => {
        const option = element("option", "", choice.displayName);
        option.value = choice.id;
        option.disabled = choice.enabled === false;
        option.selected = control.type === "multiChoice" ? current.includes(choice.id) : current === choice.id;
        select.append(option);
      });
      select.disabled = common.mutable === false;
      select.addEventListener("change", () => {
        draft.toolValues[common.id] = control.type === "multiChoice"
          ? { type: "choices", value: Array.from(select.selectedOptions, (option) => option.value) }
          : { type: "choice", value: select.value };
        state.agent.retryOperation = null;
      });
      label.append(select);
      host.append(label);
    });
    menu.hidden = !host.childElementCount;
  }

  function renderComposerAttachments(composer) {
    const host = document.getElementById("composer-attachments");
    host.replaceChildren();
    composer.attachments.forEach((attachment) => {
      const chip = element("span", "composer-attachment-chip");
      chip.append(element("span", "", attachment.displayName || "Image"));
      const remove = element("button", "", "×");
      remove.type = "button";
      remove.setAttribute("aria-label", `Remove ${attachment.displayName || "image"}`);
      remove.addEventListener("click", () => removeComposerAttachment(attachment, remove));
      chip.append(remove);
      host.append(chip);
    });
    host.hidden = !composer.attachments.length;
  }

  async function stageComposerAttachments(files) {
    if (state.agent.attachmentPromise || !files.length) return;
    const destination = composerDestination();
    const composer = activeComposerState();
    const accepted = Array.from(files).slice(0, Math.max(0, 4 - composer.attachments.length));
    if (!accepted.length) return toast("You can attach up to four images.", true);
    state.agent.attachmentPromise = (async () => {
      try {
        for (const file of accepted) {
          const attachment = await api(
            `api/v1/projects/${encodeURIComponent(destination.projectID)}/composer-attachments?displayName=${encodeURIComponent(file.name || "image")}`,
            {
              method: "POST",
              headers: { "Content-Type": file.type || "application/octet-stream" },
              body: file,
            },
          );
          composer.attachments.push(attachment);
        }
      } catch (error) {
        toast(error.message, true);
      } finally {
        state.agent.attachmentPromise = null;
        document.getElementById("composer-attachment-input").value = "";
        renderAgentComposer();
      }
    })();
    renderAgentComposer();
    return state.agent.attachmentPromise;
  }

  async function removeComposerAttachment(attachment, button) {
    if (state.agent.attachmentPromise) return;
    const destination = composerDestination();
    const composer = activeComposerState();
    const attachmentID = attachment.attachmentId;
    setDisabledReason(button, true, "Removing attachment…");
    state.agent.attachmentPromise = api(
      `api/v1/projects/${encodeURIComponent(destination.projectID)}/composer-attachments/${encodeURIComponent(attachmentID)}`,
      { method: "DELETE", body: JSON.stringify({}) },
    );
    try {
      await state.agent.attachmentPromise;
      composer.attachments = composer.attachments.filter((item) => item.attachmentId !== attachmentID);
    } catch (error) {
      toast(error.message, true);
    } finally {
      state.agent.attachmentPromise = null;
      renderAgentComposer();
    }
  }

  function renderAgentComposer() {
    const form = document.getElementById("composer-form");
    if (onboardingStage()) {
      form.hidden = true;
      return;
    }
    form.hidden = false;
    const text = document.getElementById("composer-text");
    const submit = document.getElementById("composer-submit");
    const attach = document.getElementById("composer-attach");
    const composer = activeComposerState();
    const destination = composerDestination();
    const catalog = state.agent.composerCatalogKey === destination.key ? state.agent.composerCatalog : null;
    if (!catalog && !state.agent.composerCatalogPromise && destination.projectID)
      window.setTimeout(() => loadComposerCatalog(), 0);
    if (state.agent.activeComposerKey === destination.key) composer.text = text.value;
    if (catalog && !composer.configuration) composer.configuration = initialComposerDraft(catalog);
    const draft = composer.configuration || initialComposerDraft(catalog);
    const groups = catalog?.providerGroups || [];
    const group = groups.find((item) => item.providerId === draft.providerId);
    const model = group?.models?.find((item) => item.id === draft.modelId);
    const effortIDs = model?.supportedEffortIDs || [];
    const workflows = (catalog?.workflows || []).filter((item) =>
      ((item.enabled && item.visible) || item.id === draft.workflowId) &&
      (!item.providerIDs?.length || item.providerIDs.includes(draft.providerId)),
    );
    const permissions = group?.permissionControl?.choices || [];
    const controlsSignature = JSON.stringify({
      destination: destination.key,
      catalogVersion: catalog ? state.agent.composerCatalogVersion : null,
      configuration: draft,
    });

    if (state.agent.composerControlsSignature !== controlsSignature) {
      const providerRows = [];
      groups.forEach((provider) => {
        providerRows.push(element("span", "composer-popover-group", provider.displayName));
        (provider.models || []).forEach((candidate) => {
          providerRows.push(composerOptionButton(
            `${provider.displayName} · ${candidate.displayName}`,
            provider.providerId === draft.providerId && candidate.id === draft.modelId,
            catalog?.locks?.model?.locked === true || candidate.enabled === false,
            catalog?.locks?.model?.reasonText || candidate.description || "",
            () => {
              draft.providerId = provider.providerId;
              draft.modelId = candidate.id;
              draft.effortId = candidate.defaultEffortID || null;
              draft.permissionId = provider.permissionControl?.selectedID || null;
              draft.toolValues = defaultToolValues(provider);
            },
          ));
        });
      });
      renderComposerMenu(document.getElementById("composer-provider-model-options"), providerRows);
      renderComposerMenu(
        document.getElementById("composer-effort-options"),
        [null, ...effortIDs].map((effortID) => composerOptionButton(
          effortID ? humanize(effortID) : "Default",
          (draft.effortId || null) === effortID,
          catalog?.locks?.effort?.locked === true,
          catalog?.locks?.effort?.reasonText || "",
          () => { draft.effortId = effortID; },
        )),
      );
      renderComposerMenu(
        document.getElementById("composer-workflow-options"),
        [null, ...workflows].map((workflow) => composerOptionButton(
          workflow?.displayName || "None",
          (draft.workflowId || null) === (workflow?.id || null),
          catalog?.locks?.workflow?.locked === true || workflow?.enabled === false,
          catalog?.locks?.workflow?.reasonText || workflow?.description || "",
          () => { draft.workflowId = workflow?.id || null; },
        )),
      );
      renderComposerMenu(
        document.getElementById("composer-permission-options"),
        permissions.map((choice) => composerOptionButton(
          choice.displayName,
          choice.id === draft.permissionId,
          group?.permissionControl?.mutable === false || choice.enabled === false,
          group?.permissionControl?.lockReasonCode || choice.detailText || "",
          () => { draft.permissionId = choice.id; },
        )),
      );
      renderComposerTools(group, draft);
      state.agent.composerControlsSignature = controlsSignature;
    }
    document.getElementById("composer-provider-model-summary").textContent =
      group && model ? `${group.displayName} · ${model.displayName}` : "Provider · Model";

    document.getElementById("composer-effort-menu").hidden = !effortIDs.length;
    document.getElementById("composer-effort-summary").textContent =
      `Effort · ${draft.effortId ? humanize(draft.effortId) : "Default"}`;

    const workflow = workflows.find((item) => item.id === draft.workflowId);
    document.getElementById("composer-workflow-summary").textContent =
      `Workflow · ${workflow?.displayName || "None"}`;
    text.placeholder = workflow?.guidance || workflow?.description ||
      (state.agent.newSessionMode ? "Describe what to build…" : "Send a message…");

    document.getElementById("composer-permission-menu").hidden = !permissions.length;
    document.getElementById("composer-permission-summary").textContent =
      `Permissions · ${permissions.find((choice) => choice.id === draft.permissionId)?.displayName || "Default"}`;
    const attachmentsSignature = JSON.stringify({
      destination: destination.key,
      attachments: composer.attachments,
    });
    if (state.agent.composerAttachmentsSignature !== attachmentsSignature) {
      renderComposerAttachments(composer);
      state.agent.composerAttachmentsSignature = attachmentsSignature;
    }
    document.getElementById("composer-mcp-pill").hidden = catalog?.mcpControlled !== true;

    const control = destination.session?.agentControl;
    const hasCancelAction = control?.cancel?.allowed === true;
    const activeRun = ["preparing", "thinking", "working", "waiting", "cancelling"]
      .includes(control?.displayState);
    const showsStop = activeRun || hasCancelAction;
    const action = control?.steer?.allowed ? control.steer : control?.submitTurn;
    const hasContent = Boolean(text.value.trim() || composer.attachments.length);
    if (showsStop) {
      submit.type = "button";
      submit.dataset.mode = "cancel";
      submit.classList.add("cancel");
      submit.setAttribute("aria-label", "Stop agent run");
      setIcon(submit, "stop");
    } else {
      submit.type = "submit";
      submit.dataset.mode = "send";
      submit.classList.remove("cancel");
      submit.setAttribute("aria-label", "Send message");
      setIcon(submit, "send");
    }
    const reason = showsStop
      ? state.agent.actionPromise
        ? `${humanize(state.agent.actionName)} in progress…`
        : !state.online
          ? "Offline"
          : !hasCancelAction
            ? control?.cancel?.reasonText || "Cancellation unavailable"
            : ""
      : state.agent.actionPromise
        ? `${humanize(state.agent.actionName)} in progress…`
        : state.agent.mutationPromise
          ? "Sending…"
          : state.agent.attachmentPromise
            ? "Updating attachments…"
            : !state.online
              ? "Offline"
              : !catalog
                ? composer.feedback || "Loading composer…"
                : !draft.providerId || !draft.modelId
                  ? "Choose a provider and model"
                  : !state.agent.newSessionMode && !action?.allowed
                    ? action?.reasonText || "Session is read-only"
                    : !hasContent
                      ? "Type a message"
                      : catalog?.locks?.send?.locked
                        ? catalog.locks.send.reasonText || "Sending is locked"
                        : "";
    setDisabledReason(submit, Boolean(reason), reason);
    const attachmentAvailable = catalog?.capabilities?.attachments === true && model?.capabilities?.nativeImages === true;
    setDisabledReason(
      attach,
      !attachmentAvailable || catalog?.locks?.attachments?.locked || control?.steer?.allowed ||
        Boolean(state.agent.attachmentPromise) || composer.attachments.length >= 4,
      catalog?.locks?.attachments?.reasonText || (!attachmentAvailable ? "Selected model does not accept images" : ""),
    );
    form.setAttribute("aria-busy", String(Boolean(state.agent.mutationPromise || state.agent.attachmentPromise)));
    const notice = document.getElementById("composer-notice");
    notice.textContent = composer.feedback || (!["", "Type a message", "Loading composer…", "Sending…", "Updating attachments…"].includes(reason) ? reason : "");
    notice.hidden = !notice.textContent;
    document.getElementById("composer-message").textContent = reason || (control?.steer?.allowed ? "Steering" : "Ready");
    renderComposerContextUsage();
  }

  async function performSessionAction(actionName) {
    if (state.agent.actionPromise) return state.agent.actionPromise;
    const session = selectedSession();
    const action = session?.agentControl?.[actionName];
    if (!session || !action?.allowed) {
      toast(action?.reasonText || `This session cannot ${actionName}.`, true);
      return null;
    }
    const operationID = operationIDFor({
      action: actionName,
      sessionId: session.sessionId,
      revision: session.revision,
      runId: action.expectedRunId || action.sourceRunId || null,
    });
    if (!operationID) {
      toast("This browser cannot create secure operation identifiers.", true);
      return null;
    }
    state.agent.actionName = actionName;
    state.agent.actionPromise = (async () => {
      await Promise.resolve();
      renderTranscript();
      renderAgentComposer();
      try {
        await api(
          `api/v1/sessions/${encodeURIComponent(session.sessionId)}/actions/${actionName}`,
          {
            method: "POST",
            body: JSON.stringify({
              operationId: operationID,
              expectedRevision: action.expectedSessionRevision || session.revision,
            }),
          },
        );
        state.agent.retryOperation = null;
        await loadTranscript({ silent: true });
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision")
          await loadTranscript({ silent: true });
      } finally {
        state.agent.actionPromise = null;
        state.agent.actionName = null;
        renderTranscript();
        renderAgentComposer();
      }
    })();
    return state.agent.actionPromise;
  }

  function selectedTurnConfiguration() {
    const catalog = state.agent.composerCatalog;
    const draft = activeComposerState().configuration;
    if (!catalog || !draft?.providerId || !draft?.modelId) return null;
    return {
      schemaVersion: 1,
      catalogRevision: catalog.revision,
      providerId: draft.providerId,
      modelId: draft.modelId,
      effortId: draft.effortId || null,
      workflowId: draft.workflowId || null,
      permissionId: draft.permissionId || null,
      toolValues: draft.toolValues || {},
    };
  }

  function renderComposerContextUsage() {
    const host = document.getElementById("composer-context-usage");
    const ring = document.getElementById("composer-context-usage-ring");
    const percentLabel = document.getElementById(
      "composer-context-usage-percent",
    );
    const progress = document.getElementById(
      "composer-context-usage-progress",
    );
    const session = selectedSession();
    const usage = session?.contextUsage || {};
    const last = Number(usage.lastTotalTokens) || 0;
    const total = Number(usage.totalTotalTokens) || 0;
    const used = last > 0 ? last : total;
    const windowTokens = Number(session?.effectiveContextWindowTokens) || 0;
    const show =
      Boolean(session) &&
      !state.agent.newSessionMode &&
      (used > 0 || windowTokens > 0);
    host.hidden = !show;
    if (!show) {
      ring.removeAttribute("title");
      ring.removeAttribute("data-level");
      return;
    }
    const percent =
      used > 0 && windowTokens > 0
        ? Math.min(Math.max((used / windowTokens) * 100, 0), 100)
        : 0;
    const rounded = Math.round(percent);
    const circumference = 2 * Math.PI * 7;
    percentLabel.textContent = String(rounded);
    progress.setAttribute("stroke-dasharray", String(circumference));
    progress.setAttribute(
      "stroke-dashoffset",
      String(circumference * (1 - Math.min(Math.max(percent / 100, 0), 1))),
    );
    ring.dataset.level =
      percent > 90 ? "critical" : percent > 75 ? "warn" : "";
    ring.setAttribute("aria-valuenow", String(rounded));
    ring.title = contextUsageTooltip(used, windowTokens, percent);
  }

  function contextUsageTooltip(used, windowTokens, percent) {
    if (used > 0 && windowTokens > 0) {
      return `Context used: ${Math.round(percent)}%\n${formatTokens(used)} / ${formatTokens(windowTokens)} tokens`;
    }
    if (used > 0) return `Used tokens: ${formatTokens(used)}`;
    return "Context usage unavailable";
  }

  function formatTokens(count) {
    if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(1)}M`;
    if (count >= 1000) return `${(count / 1000).toFixed(1)}K`;
    return String(count);
  }

  function operationIDFor(payload) {
    const fingerprint = JSON.stringify(payload);
    if (state.agent.retryOperation?.fingerprint === fingerprint)
      return state.agent.retryOperation.operationID;
    if (!window.crypto?.randomUUID) return null;
    const operationID = window.crypto.randomUUID();
    state.agent.retryOperation = { fingerprint, operationID };
    return operationID;
  }

  async function submitComposer() {
    if (state.agent.mutationPromise || state.agent.attachmentPromise)
      return state.agent.mutationPromise;
    const composer = activeComposerState();
    composer.text = document.getElementById("composer-text").value;
    const text = composer.text.trim();
    const newSession = state.agent.newSessionMode;
    const session = selectedSession();
    const control = session?.agentControl;
    const configuration = selectedTurnConfiguration();
    const attachmentIds = composer.attachments.map((item) => item.attachmentId);
    const steering = !newSession && control?.steer?.allowed === true;
    if ((steering ? !text : !text && !attachmentIds.length) || !configuration)
      return null;
    const content = {
      schemaVersion: 1,
      text,
      attachmentIds,
      taggedFiles: [],
      resolvedSuggestionTokens: [],
    };
    let path;
    let payload;
    if (newSession) {
      path = "api/v1/agent-sessions";
      payload = {
        start: {
          projectId: state.agent.selectedProjectID,
          visibility: "private",
          turn: { content, configuration },
        },
      };
    } else if (steering) {
      path = `api/v1/sessions/${encodeURIComponent(session.sessionId)}/messages`;
      payload = {
        expectedRevision: session.revision,
        text,
      };
    } else {
      path = `api/v1/sessions/${encodeURIComponent(session.sessionId)}/turns`;
      payload = {
        turn: {
          content,
          configuration,
          expectedSessionRevision:
            control?.submitTurn?.expectedSessionRevision || session.revision,
        },
      };
    }
    const operationID = operationIDFor(payload);
    if (!operationID) {
      toast("This browser cannot create secure operation identifiers.", true);
      return null;
    }
    const body = { operationId: operationID, ...payload };
    state.agent.mutationPromise = (async () => {
      renderAgentComposer();
      try {
        const receipt = await api(path, {
          method: "POST",
          body: JSON.stringify(body),
        });
        if (newSession) {
          const acceptedSession = receipt.session || {
            sessionId: receipt.sessionId,
            projectId: state.agent.selectedProjectID,
            title: text || "Agent Session",
            revision: receipt.sessionRevision,
          };
          const existing = state.bootstrap.sessions.findIndex(
            (item) => item.sessionId === acceptedSession.sessionId,
          );
          if (existing >= 0) state.bootstrap.sessions[existing] = acceptedSession;
          else state.bootstrap.sessions.push(acceptedSession);
          state.agent.selectedSessionID = acceptedSession.sessionId;
          rememberSelectedSessionID(acceptedSession.sessionId);
          state.agent.newSessionMode = false;
          state.agent.transcriptItems = [];
          state.agent.transcriptPage = null;
          state.agent.selectionGeneration += 1;
        }
        composer.text = "";
        if (!steering) composer.attachments = [];
        document.getElementById("composer-text").value = "";
        state.agent.retryOperation = null;
        renderHomeProviders();
        await loadComposerCatalog(true);
        await loadTranscript({ silent: true });
      } catch (error) {
        composer.feedback =
          error.code === "staleRevision"
            ? "Session changed; review your message and send again."
            : error.message;
        toast(error.message, true);
        if (error.code === "staleRevision")
          await loadTranscript({ silent: true });
      } finally {
        state.agent.mutationPromise = null;
        renderAgentComposer();
      }
    })();
    return state.agent.mutationPromise;
  }

  function renderHomeError(error) {
    const panel = element("div", "error-banner");
    panel.setAttribute("role", "alert");
    panel.append(iconNode("warning"), document.createTextNode(error.message));
    document.getElementById("session-list").replaceChildren(panel);
    document
      .getElementById("transcript-list")
      .replaceChildren(panel.cloneNode(true));
    installIcons(document.getElementById("home-shell"));
  }

  function normalizedRoute() {
    const raw = location.hash.replace(/^#/, "");
    if (!raw || raw === "home") return { surface: "home", page: null };
    if (raw === "settings") return { surface: "settings", page: "overview" };
    if (raw.startsWith("settings/")) {
      const page = raw.slice("settings/".length);
      return {
        surface: "settings",
        page: supportedRoutes.has(page) ? page : "overview",
      };
    }
    return { surface: "home", page: null };
  }

  function disposeSensitiveInputs(root = document) {
    root.querySelectorAll("input[data-sensitive]").forEach((input) => {
      input.value = "";
      input.removeAttribute("value");
    });
  }

  function renderRoute() {
    const route = normalizedRoute();
    const nextRoute =
      route.surface === "home" ? "home" : `settings/${route.page}`;
    if (state.route !== nextRoute) disposeLifecycleDisclosure();
    state.route = nextRoute;
    const home = document.getElementById("home-shell");
    const settings = document.getElementById("settings-shell");
    home.hidden = route.surface !== "home";
    settings.hidden = route.surface !== "settings";
    if (route.surface === "home") {
      renderHomeProviders();
      if (state.agent.selectedSessionID && !state.agent.transcriptPage) {
        loadTranscript();
      } else {
        scheduleAgentPoll();
      }
    } else {
      clearAgentPoll();
    }
    document.querySelectorAll("#settings-nav a[data-route]").forEach((link) => {
      const active =
        route.surface === "settings" && link.dataset.route === route.page;
      link.classList.toggle("active", active);
      if (active) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });

    if (route.surface === "settings") {
      const titles = {
        overview: "Overview",
        "cli-providers": "CLI Providers",
        "agent-models": "Agent Models",
        "agent-permissions": "Agent Permissions",
        "agent-workflows": "Agent Workflows",
        "context-builder": "Context Builder",
        "portal-appearance": "Appearance",
        advanced: "Advanced",
        "mcp-server": "MCP Server",
        "mcp-tools": "Tools",
        "workspace-approvals": "Workspace Approvals",
        "model-presets": "Model Presets",
        "api-providers": "API Providers",
        openrouter: "OpenRouter",
        "custom-api": "Custom API",
        "model-config": "Model Config",
        "manage-workspaces": "Manage Workspaces",
        "manage-presets": "Manage Presets",
        "client-integrations": "Client Integrations",
      };
      document.getElementById("settings-detail-title").textContent =
        titles[route.page];
      const renderers = {
        overview: renderOverview,
        "cli-providers": renderCLIProviders,
        "agent-models": renderTypedAgentModels,
        "agent-permissions": renderAgentPermissions,
        "agent-workflows": renderTypedAgentWorkflows,
        "context-builder": renderTypedContextBuilder,
        "portal-appearance": renderPortalAppearance,
        advanced: renderAdvanced,
        "mcp-server": renderMCPServer,
        "mcp-tools": renderMCPTools,
        "workspace-approvals": renderWorkspaceApprovals,
        "model-presets": renderTypedModelPresets,
        "api-providers": renderTypedAPIProviders,
        openrouter: renderTypedOpenRouter,
        "custom-api": renderTypedCustomAPI,
        "model-config": renderModelConfig,
        "manage-workspaces": renderManageWorkspaces,
        "manage-presets": renderTypedManagePresets,
        "client-integrations": renderClientIntegrations,
      };
      if ((!state.providers.length || !state.desktopSettings) && state.loading)
        renderInitialSettingsLoading();
      else renderers[route.page]();
    }

    if (state.focusAfterRoute) {
      state.focusAfterRoute = false;
      window.setTimeout(() => {
        (route.surface === "settings"
          ? document.getElementById("settings-main-content")
          : document.getElementById("main-content")
        ).focus({
          preventScroll: true,
        });
      }, 0);
    }
  }

  function renderInitialSettingsLoading() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    const panel = element("div", "empty-state-panel");
    panel.append(
      element("h2", "", "Loading settings"),
      element("p", "", "Reading the provider catalog and server readiness."),
    );
    content.replaceChildren(panel);
  }

  function pageHeader(title, subtitle, icon) {
    const header = element("header", "settings-header");
    const titleRow = element("div", "settings-header-icon");
    if (icon) titleRow.append(iconNode(icon));
    titleRow.append(element("h1", "", title));
    header.append(titleRow, element("p", "", subtitle));
    return header;
  }

  function recommendation(icon, title, detail, action = null) {
    const banner = element("div", "recommendation-banner");
    banner.append(iconNode(icon));
    const copy = element("div", "recommendation-copy");
    copy.append(
      element("strong", "", title),
      document.createElement("br"),
      document.createTextNode(detail),
    );
    banner.append(copy);
    if (action) {
      const button = element(
        "button",
        "secondary-button recommendation-action",
        action.label,
      );
      button.type = "button";
      button.dataset.action = action.id || "recommendation-action";
      button.addEventListener("click", action.handler);
      banner.append(button);
    }
    return banner;
  }

  function isConnectedProvider(provider) {
    return Boolean(
      provider?.authentication?.authenticated &&
        provider?.connection?.state === "connected" &&
        provider?.connection?.testState === "valid",
    );
  }

  function isSessionReadyProvider(provider) {
    return Boolean(
      provider?.category === "cliProvider" &&
        provider?.deploymentAllowed &&
        provider?.preflight?.ready === true &&
        isConnectedProvider(provider),
    );
  }

  function navigateToSettings(page) {
    state.focusAfterRoute = true;
    window.location.hash = `#settings/${page}`;
  }

  function settingValue(key, fallback = "") {
    return state.desktopSettings?.values?.[key] ?? fallback;
  }

  function settingBool(key, fallback = false) {
    const value = settingValue(key, fallback ? "true" : "false");
    return value === "true";
  }

  function settingArray(key) {
    try {
      const value = JSON.parse(settingValue(key, "[]"));
      return Array.isArray(value) ? value : [];
    } catch (_error) {
      return [];
    }
  }

  async function saveSetting(key, value, control) {
    return saveSettingsChanges({ [key]: String(value) }, control);
  }

  async function saveSettingsChanges(changes, control) {
    if (!state.desktopSettings || state.settingsMutation) return;
    state.settingsMutation = (async () => {
      if (control) setDisabledReason(control, true, "Saving setting…");
      try {
        state.desktopSettings = await api("api/v1/desktop-settings", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: state.desktopSettings.revision,
            changes,
          }),
        });
        renderRoute();
      } catch (error) {
        toast(error.message, true);
        if (error.code === "staleRevision") await loadAll(false);
        else renderRoute();
      } finally {
        state.settingsMutation = null;
      }
    })();
    return state.settingsMutation;
  }

  function desktopCard(title, detail) {
    const card = element("section", "desktop-settings-card");
    if (title) card.append(element("h2", "", title));
    if (detail) card.append(element("p", "card-subtitle", detail));
    return card;
  }

  function desktopRow(label, detail, control) {
    const row = element("div", "desktop-setting-row");
    const copy = element("div", "desktop-setting-copy");
    copy.append(element("strong", "", label));
    if (detail) copy.append(element("small", "", detail));
    row.append(copy, control);
    return row;
  }

  function toggleSetting(key, label, detail, fallback = false) {
    const toggle = element("label", "toggle desktop-toggle");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = settingBool(key, fallback);
    input.setAttribute("aria-label", label);
    input.addEventListener("change", () =>
      saveSetting(key, input.checked, input),
    );
    toggle.append(input, element("span"));
    return desktopRow(label, detail, toggle);
  }

  function selectSetting(key, label, detail, options, fallback = "") {
    const select = document.createElement("select");
    select.setAttribute("aria-label", label);
    options.forEach(([value, title]) => {
      const option = element("option", "", title);
      option.value = value;
      option.selected = value === settingValue(key, fallback);
      select.append(option);
    });
    select.addEventListener("change", () =>
      saveSetting(key, select.value, select),
    );
    return desktopRow(label, detail, select);
  }

  function textSetting(key, label, detail, placeholder = "") {
    const input = document.createElement("input");
    input.type = "text";
    input.value = settingValue(key);
    input.placeholder = placeholder;
    input.setAttribute("aria-label", label);
    input.addEventListener("change", () =>
      saveSetting(key, input.value.trim(), input),
    );
    return desktopRow(label, detail, input);
  }

  function numberSetting(key, label, detail, min, max, step = 1) {
    const input = document.createElement("input");
    input.type = "number";
    input.min = String(min);
    input.max = String(max);
    input.step = String(step);
    input.value = settingValue(key);
    input.setAttribute("aria-label", label);
    input.addEventListener("change", () =>
      saveSetting(key, input.value, input),
    );
    return desktopRow(label, detail, input);
  }

  function modelChoices(includeAutomatic = true) {
    const choices = [];
    if (includeAutomatic) choices.push(["", "Automatic"]);
    const seen = new Set();
    orderedProviders().forEach((provider) =>
      (provider.models || []).forEach((model) => {
        if (seen.has(model.id)) return;
        seen.add(model.id);
        choices.push([
          model.id,
          `${model.displayName} · ${provider.displayName}`,
        ]);
      }),
    );
    return choices;
  }

  function settingsPage(title, subtitle, icon, cards = [], banner = null) {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(pageHeader(title, subtitle, icon));
    if (banner) content.append(banner);
    cards.forEach((card) => content.append(card));
    installIcons(content);
  }

  function disposeLifecycleDisclosure() {
    state.lifecycleDisclosure = null;
    document.querySelectorAll("[data-lifecycle-secret]").forEach((node) => {
      node.textContent = "Disposed";
      node.removeAttribute("data-lifecycle-secret");
    });
  }

  function clientIntegrationState(inventory) {
    return inventory?.client || null;
  }

  async function runClientIntegrationMutation(control, operation) {
    if (state.lifecycleMutation) return state.lifecycleMutation;
    setDisabledReason(control, true, "An integration operation is in progress.");
    state.lifecycleMutation = (async () => {
      try {
        await operation();
        state.clientIntegrations = await api("api/v1/client-integrations");
        renderRoute();
      } catch (error) {
        toast(error.message, true);
      } finally {
        state.lifecycleMutation = null;
        if (control.isConnected) setDisabledReason(control, false, "");
      }
    })();
    return state.lifecycleMutation;
  }

  function clientDisclosureCard() {
    const disclosure = state.lifecycleDisclosure;
    if (!disclosure) return null;
    const card = desktopCard(
      "API token",
      "Copy this token into the connecting app now. It will not be shown again.",
    );
    const secret = element("pre", "lifecycle-secret", disclosure);
    secret.dataset.lifecycleSecret = "true";
    secret.setAttribute("aria-label", "API token");
    const actions = element("div", "button-row");
    const copy = element("button", "secondary-button", "Copy token");
    copy.type = "button";
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(disclosure);
        toast("Token copied");
      } catch (_error) {
        toast("Copy failed. Select the token manually.", true);
      }
    });
    const done = element("button", "secondary-button", "Done");
    done.type = "button";
    done.addEventListener("click", () => {
      disposeLifecycleDisclosure();
      renderRoute();
    });
    actions.append(copy, done);
    card.append(secret, actions);
    return card;
  }

  function clientIntegrationCard(client) {
    const integration = client?.integration;
    const card = desktopCard("API client", "Connect an app to RepoPrompt.");
    if (!integration || integration.status !== "active") {
      const create = element("button", "primary-button", "Generate API token");
      create.type = "button";
      create.addEventListener("click", () =>
        runClientIntegrationMutation(create, async () => {
          disposeLifecycleDisclosure();
          const disclosure = await api("api/v1/client-integrations", {
            method: "POST",
          });
          state.lifecycleDisclosure = disclosure.token;
        }),
      );
      card.append(create);
      return card;
    }
    const members = client.members || [];
    card.append(
      desktopRow(
        "API client connected",
        `Connected ${formatDate(integration.createdAt)} · ${members.length} ${members.length === 1 ? "member" : "members"}`,
        element("span", "status-pill connected", "Connected"),
      ),
    );
    const actions = element("div", "button-row");
    const rotate = element("button", "secondary-button", "Generate new token");
    rotate.type = "button";
    rotate.addEventListener("click", () =>
      runClientIntegrationMutation(rotate, async () => {
        disposeLifecycleDisclosure();
        const disclosure = await api("api/v1/client-integrations/rotate", {
          method: "POST",
        });
        state.lifecycleDisclosure = disclosure.token;
      }),
    );
    const disconnect = element("button", "danger-button", "Disconnect");
    disconnect.type = "button";
    disconnect.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: "Disconnect API client?",
        message:
          "The connected app will lose access to RepoPrompt until you generate and save a new token.",
        label: "Disconnect",
        returnFocus: disconnect,
      });
      if (!accepted) return;
      await runClientIntegrationMutation(disconnect, async () => {
        await api("api/v1/client-integrations", { method: "DELETE" });
        disposeLifecycleDisclosure();
      });
    });
    actions.append(rotate, disconnect);
    card.append(actions);
    members.forEach((member) =>
      card.append(
        desktopRow(
          member.displayName,
          `${member.username} · last seen ${formatDate(member.lastSeenAt)}`,
          element("span", "read-only-value", "Observed"),
        ),
      ),
    );
    return card;
  }

  function renderClientIntegrations() {
    const inventory = state.clientIntegrations;
    if (!inventory) {
      settingsPage(
        "Client Integrations",
        "Loading client integration state…",
        "link",
      );
      return;
    }
    const cards = [];
    const disclosure = clientDisclosureCard();
    if (disclosure) cards.push(disclosure);
    cards.push(clientIntegrationCard(clientIntegrationState(inventory)));
    settingsPage(
      "Client Integrations",
      "Connect and manage apps that use RepoPrompt.",
      "link",
      cards,
    );
  }

  function renderCLIProviders() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        "CLI Providers",
        "Install and connect Claude Code, Codex, OpenCode, Cursor, or Grok Build for Agent Mode.",
        "terminal",
      ),
    );
    const byID = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const connectedMainProviders = [
      byID.codex,
      byID.claudeCompatible,
      byID.openCodeACP,
      byID.cursorACP,
      byID.grokBuildACP,
    ].filter(isConnectedProvider);
    if (connectedMainProviders.length) {
      content.append(
        recommendation(
          "check",
          "CLI providers connected.",
          "Check recommendations to optimize your setup.",
          {
            label: "Check Now",
            id: "check-agent-model-recommendations",
            handler: () => navigateToSettings("agent-models"),
          },
        ),
      );
    }
    const stack = element("div", "desktop-provider-list");
    if (byID.codex) stack.append(cliProviderCard(byID.codex));
    if (byID.claudeCompatible)
      stack.append(cliProviderCard(byID.claudeCompatible));
    stack.append(
      compatibleBackendsCard(
        [byID.claudeGLM, byID.claudeKimi, byID.claudeCustom].filter(Boolean),
      ),
    );
    if (byID.openCodeACP) stack.append(cliProviderCard(byID.openCodeACP));
    if (byID.cursorACP) stack.append(cliProviderCard(byID.cursorACP));
    if (byID.grokBuildACP) stack.append(cliProviderCard(byID.grokBuildACP));
    content.append(stack);
    installIcons(content);
  }

  const externalCLIAuthenticationMethods = {
    claudeCompatible: "providerSpecific",
    openCodeACP: "providerSpecific",
    cursorACP: "browserLogin",
    grokBuildACP: "providerSpecific",
  };

  function cliProviderCard(provider) {
    const presentation = desktopProviderPresentation(provider);
    const details = element("details", "desktop-provider-card");
    details.dataset.providerId = provider.providerID;
    const summary = document.createElement("summary");
    const status = providerStatus(provider);
    const badge = element("span", `connection-badge ${status.tone}`.trim());
    badge.append(element("i"), element("span", "", status.label));
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", presentation.title),
      element("small", "", presentation.subtitle),
    );
    summary.append(
      iconNode("terminal", "provider-glyph"),
      name,
      badge,
      iconNode("chevron"),
    );
    const body = element("div", "desktop-provider-body");
    const compatibleBackend = [
      "claudeGLM",
      "claudeKimi",
      "claudeCustom",
    ].includes(provider.providerID);
    const connected = isConnectedProvider(provider);

    if (compatibleBackend) {
      body.append(compatibleBackendPrerequisite(provider));
      const directMethods = (
        provider.capabilities.authenticationMethods || []
      ).filter((method) => directAuthenticationMethods.has(method));
      if (directMethods.length) {
        const labels = {
          claudeGLM: [
            "Z.ai API Key",
            "Save the key for the Z.ai coding-plan backend. The same Claude CLI binary runs this route; a Claude account login is not required.",
          ],
          claudeKimi: [
            "Kimi API Key",
            "Save the key for Kimi's coding backend. Model behavior and slot mappings live in the backend settings below.",
          ],
        };
        body.append(
          credentialForm(provider, directMethods, {
            title: labels[provider.providerID]?.[0],
            subtitle: labels[provider.providerID]?.[1],
          }),
        );
      }
      body.append(compatibleBackendSettingsCard(provider));
      if (connected) body.append(connectedProviderSummary(provider));
      else if (!directMethods.length)
        body.append(
          element(
            "p",
            "unavailable-panel",
            providerActionUnavailableReason(provider),
          ),
        );
      details.append(summary, body);
      return details;
    }

    body.append(providerCLIInstallationCard(provider));

    if (connected) {
      body.append(connectedProviderSummary(provider));
      body.append(providerRuntimeControls(provider));
    } else if (provider.providerID === "codex") {
      const note = element("p", "codex-auth-note");
      note.append(
        document.createTextNode(
          "ChatGPT may require identity verification (KYC) to access Codex. ",
        ),
      );
      const link = element("a", "", "Learn more");
      link.href = "https://chatgpt.com/cyber";
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      note.append(link);
      body.append(
        note,
        element(
          "p",
          "card-subtitle",
          "Permissions and runtime controls appear here after Codex is connected.",
        ),
      );
      const methods = provider.capabilities.authenticationMethods || [];
      if (methods.length) {
        const message = element(
          "div",
          "inline-message info",
          "Choose a sign-in method to connect Codex.",
        );
        message.setAttribute("role", "status");
        body.append(authenticationMethodChoices(provider, message));
        if (state.activeFlow?.providerID === provider.providerID)
          body.append(devicePanel(provider));
        const directMethods = methods.filter((method) =>
          directAuthenticationMethods.has(method),
        );
        if (directMethods.length)
          body.append(credentialForm(provider, directMethods));
        body.append(message);
      } else {
        body.append(
          element(
            "p",
            "unavailable-panel",
            providerActionUnavailableReason(provider),
          ),
        );
      }
    } else if (externalCLIAuthenticationMethods[provider.providerID]) {
      body.append(externalCLIConnectPanel(provider));
      if (provider.providerID === "claudeCompatible")
        body.append(providerRuntimeControls(provider));
    } else {
      body.append(
        element(
          "p",
          "unavailable-panel",
          providerActionUnavailableReason(provider),
        ),
      );
    }
    details.append(summary, body);
    return details;
  }

  function providerCLIInstallationCard(provider) {
    const installed = provider.cli?.installed === true;
    const version = provider.cli?.version || "Version unavailable";
    const card = desktopCard(
      "CLI installation",
      installed
        ? `${version}. Installed on this server and reinstalled automatically after app deployment.`
        : "Install the current release directly from the provider. The CLI is not part of the RepoPrompt app image.",
    );
    const actions = element("div", "form-actions");
    actions.append(
      element(
        "span",
        "form-note",
        installed
          ? "Provider releases update independently of RepoPrompt."
          : "Uses the provider's official installer.",
      ),
    );
    if (!installed) {
      const install = element("button", "primary-button", "Install");
      install.type = "button";
      if (!provider.deploymentAllowed)
        setDisabledReason(
          install,
          true,
          "This provider is not available in this RepoPrompt installation.",
        );
      else
        install.addEventListener("click", () =>
          mutateProviderCLI(provider, "install", install, "Installing…"),
        );
      actions.append(install);
    } else {
      const update = element("button", "secondary-button", "Update");
      update.type = "button";
      update.addEventListener("click", () =>
        mutateProviderCLI(provider, "update-cli", update, "Updating…"),
      );
      const uninstall = element("button", "secondary-button", "Uninstall");
      uninstall.type = "button";
      const uninstallReason = provider.connection
        ? "Disconnect this provider before uninstalling its CLI."
        : "";
      if (uninstallReason)
        setDisabledReason(uninstall, true, uninstallReason);
      else
        uninstall.addEventListener("click", () =>
          mutateProviderCLI(
            provider,
            "uninstall",
            uninstall,
            "Uninstalling…",
          ),
        );
      actions.append(update, uninstall);
    }
    card.append(actions);
    return card;
  }

  async function mutateProviderCLI(provider, action, button, pendingLabel) {
    const originalLabel = button.textContent;
    button.textContent = pendingLabel;
    setDisabledReason(
      button,
      true,
      `${pendingLabel.replace("…", "")} provider CLI.`,
    );
    try {
      const updated = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/${action}`,
        { method: "POST" },
      );
      replaceProvider(updated);
      renderRoute();
      const verb =
        action === "install"
          ? "installed"
          : action === "uninstall"
            ? "uninstalled"
            : "updated";
      toast(`${provider.displayName} CLI ${verb}`);
      announce(`${provider.displayName} CLI ${verb}`);
    } catch (error) {
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function externalCLIConnectPanel(provider) {
    const method = externalCLIAuthenticationMethods[provider.providerID];
    const methods = provider.capabilities.authenticationMethods || [];
    const guidance = {
      claudeCompatible: [
        "Connect the installed Claude Code CLI.",
        "If Claude Code is not signed in, run claude login for the RepoPrompt service account. Compatible backends below use their own API keys and do not require this login.",
      ],
      openCodeACP: [
        "Connect the installed OpenCode CLI.",
        "If OpenCode is not signed in, run opencode auth login for the RepoPrompt service account.",
      ],
      cursorACP: [
        "Connect the installed Cursor CLI.",
        "If Cursor is not signed in, complete its login for the RepoPrompt service account.",
      ],
      grokBuildACP: [
        "Connect the installed Grok Build CLI.",
        "If Grok Build is not signed in, complete its login for the RepoPrompt service account.",
      ],
    }[provider.providerID];
    const card = desktopCard("Connection", guidance[0]);
    card.append(
      element("p", "card-subtitle external-login-guidance", guidance[1]),
    );
    const message = element(
      "div",
      "inline-message info",
      "RepoPrompt checks the CLI's existing login without receiving or copying its credentials.",
    );
    message.setAttribute("role", "status");
    const actions = element("div", "form-actions");
    const button = element("button", "primary-button", "Connect");
    button.type = "button";
    button.dataset.action = "connect-external-cli-provider";
    const available =
      provider.deploymentAllowed &&
      provider.cli?.installed !== false &&
      methods.includes(method);
    if (!available)
      setDisabledReason(
        button,
        true,
        providerActionUnavailableReason(provider),
      );
    else
      button.addEventListener("click", () =>
        connectExternalCLIProvider(provider, method, button, message),
      );
    actions.append(
      element("span", "form-note", "No credential fields are sent."),
      button,
    );
    card.append(actions, message);
    return card;
  }

  async function connectExternalCLIProvider(provider, method, button, message) {
    const originalLabel = button.textContent;
    button.textContent = "Connecting…";
    setDisabledReason(button, true, "Connection request is in progress.");
    message.textContent = "Checking the CLI login…";
    try {
      const updated = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/connect`,
        {
          method: "POST",
          body: JSON.stringify({ authenticationMethod: method }),
        },
      );
      replaceProvider(updated);
      renderHomeProviders();
      renderRoute();
      toast(`${provider.displayName} connected`);
      announce(`${provider.displayName} connected`);
    } catch (error) {
      message.textContent = error.message;
      message.className = "inline-message error";
      message.focus({ preventScroll: true });
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function providerActionUnavailableReason(provider) {
    if (!provider.deploymentAllowed)
      return "This provider is not available in this RepoPrompt installation.";
    if (provider.cli?.installed === false)
      return "Install the provider CLI to continue.";
    if (provider.providerID === "claudeCustom")
      return "This custom endpoint cannot be connected until RepoPrompt can validate it safely.";
    if (
      ["claudeCompatible", "openCodeACP", "cursorACP"].includes(
        provider.providerID,
      )
    )
      return "The CLI login is unavailable. Sign in for the RepoPrompt service account, then refresh.";
    return "No connection method is available for this provider.";
  }

  function connectedProviderSummary(provider) {
    const external = ["providerSpecific", "browserLogin"].includes(
      provider.connection?.authenticationMethod,
    );
    const compatibleBackend = [
      "claudeGLM",
      "claudeKimi",
      "claudeCustom",
    ].includes(provider.providerID);
    const card = desktopCard(
      provider.providerID === "codex" ? "Signed in to Codex" : "Connected",
    );
    const summary = provider.authentication || {};
    const rows = element("dl", "desktop-account-summary");
    const account =
      summary.accountLabel ||
      provider.connection?.accountLabel ||
      (external ? "RepoPrompt service account" : "Connected account");
    rows.append(element("dt", "", "Account"), element("dd", "", account));
    if (provider.providerID === "codex" || summary.planLabel)
      rows.append(
        element("dt", "", "Plan"),
        element("dd", "", summary.planLabel || "Plan not provided"),
      );
    rows.append(
      element("dt", "", "Authentication"),
      element(
        "dd",
        "",
        summary.authenticationLabel ||
          (external
            ? "CLI login"
            : humanize(
                summary.method || provider.connection?.authenticationMethod,
              )),
      ),
    );
    const actions = element("div", "button-row desktop-connection-actions");
    const message = element(
      "div",
      "inline-message info",
      external
        ? provider.connection?.detail ||
            "The CLI login passed validation."
        : "Connection is ready.",
    );
    const test = element("button", "secondary-button", "Test Connection");
    test.type = "button";
    test.dataset.action = "test-connection";
    test.addEventListener("click", () =>
      runConnectionAction(provider, "test", test, message),
    );
    const removalLabel = external
      ? "Disconnect"
      : compatibleBackend
        ? "Delete Key"
        : "Sign Out";
    const remove = element("button", "danger-button subtle", removalLabel);
    remove.type = "button";
    remove.dataset.action = "request-disconnect";
    remove.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: `${removalLabel} ${provider.displayName}?`,
        message: external
          ? "New agent runs will stop using this login. The CLI's sign-in files are not modified."
          : "The stored connection will be removed and new agent runs will no longer use it.",
        label: removalLabel,
        returnFocus: remove,
      });
      if (accepted)
        await runConnectionAction(provider, "disconnect", remove, message);
    });
    actions.append(test, remove);
    card.append(rows, actions, message);
    return card;
  }

  function providerRuntimeControls(provider, title = "Permissions & Runtime") {
    const card = desktopCard(
      title,
      "Permission Level is edited on Agent Permissions. These leftover tool flags still apply at launch.",
    );
    if (provider.providerID === "codex") {
      card.append(
        element("h3", "desktop-subheading", "Core tools"),
        toggleSetting(
          "codexSearchEnabled",
          "Search",
          "Allow live web search requests from Codex.",
          true,
        ),
        toggleSetting(
          "codexGoalsEnabled",
          "Goals",
          "Enable /goal support and the goal lifecycle for Codex Agent Mode.",
          true,
        ),
        toggleSetting(
          "codexReasoningSummariesEnabled",
          "Reasoning Summaries",
          "Request model reasoning summaries for app-server threads.",
          false,
        ),
        toggleSetting(
          "codexMemoriesEnabled",
          "Local Memories",
          "Allow Codex to generate and use local memories.",
          false,
        ),
      );
      const mcp = desktopRow(
        "MCP servers",
        "RepoPrompt is required for Agent Mode.",
        element("span", "required-pill", "RepoPrompt · Required"),
      );
      card.append(mcp);
    } else if (provider.providerID === "claudeCompatible") {
      card.append(
        element("h3", "desktop-subheading", "Tools"),
        toggleSetting(
          "claudeToolSearchEnabled",
          "Lazy Tool Loading",
          "Claude searches for each tool before use; this saves context but adds latency.",
          true,
        ),
        promptDeliveryPicker(),
      );
    } else {
      card.append(
        desktopRow(
          provider.providerID === "cursorACP"
            ? "ACP Auto-Approve"
            : "ACP Session Mode",
          "Typed Direct Agents settings are the permission authority.",
          element("span", "read-only-value", liveManagedPermissionLabel(provider.providerID)),
        ),
      );
    }
    return card;
  }

  function compatibleBackendPrerequisite(provider) {
    const installed = provider.cli?.installed !== false;
    const panel = element(
      "div",
      installed ? "inline-message success" : "inline-message warning",
    );
    panel.append(
      iconNode(installed ? "check" : "warning"),
      document.createTextNode(
        installed
          ? "Claude CLI is installed. This backend uses its own API key; a Claude account login is not required."
          : "Claude CLI is missing. Install the packaged Claude Code CLI before testing this backend.",
      ),
    );
    return panel;
  }

  function compatibleBackendsCard(providers) {
    const details = element(
      "details",
      "desktop-provider-card compatible-provider-card",
    );
    const summary = document.createElement("summary");
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", "Claude Code–Compatible Backends"),
      element(
        "small",
        "",
        "Use Claude Code with GLM (Z.AI), Kimi (Moonshot AI), or a custom compatible endpoint.",
      ),
    );
    const badge = element("span", "connection-badge");
    badge.append(
      element("i"),
      element(
        "span",
        "",
        providers.some((provider) => provider.authentication?.authenticated)
          ? "Connected"
          : "Not configured",
      ),
    );
    summary.append(
      iconNode("terminal", "provider-glyph"),
      name,
      badge,
      iconNode("chevron"),
    );
    const body = element("div", "compatible-backend-list");
    providers.forEach((provider) => body.append(cliProviderCard(provider)));
    if (!providers.length)
      body.append(
        element(
          "p",
          "unavailable-panel",
          "Compatible backend settings are not present in the server catalog.",
        ),
      );
    details.append(summary, body);
    return details;
  }

  function compatibleBackendSettingsCard(provider) {
    const definitions = {
      claudeGLM: {
        keys: {
          displayName: "claudeGLMDisplayName",
          baseURL: "claudeGLMBaseURL",
          auth: "claudeGLMAuthHeader",
          haiku: "claudeGLMHaikuModel",
          sonnet: "claudeGLMSonnetModel",
          opus: "claudeGLMOpusModel",
        },
        behavior: "claudeSlotMapping",
      },
      claudeKimi: {
        keys: {
          displayName: "claudeKimiDisplayName",
          baseURL: "claudeKimiBaseURL",
          auth: "claudeKimiAuthHeader",
          behavior: "claudeKimiModelBehavior",
          haiku: "claudeKimiHaikuModel",
          sonnet: "claudeKimiSonnetModel",
          opus: "claudeKimiOpusModel",
        },
        behavior: settingValue("claudeKimiModelBehavior", "noModel"),
      },
      claudeCustom: {
        keys: {
          displayName: "claudeCustomDisplayName",
          baseURL: "claudeCustomBaseURL",
          auth: "claudeCustomAuthHeader",
          behavior: "claudeCustomModelBehavior",
          haiku: "claudeCustomHaikuModel",
          sonnet: "claudeCustomSonnetModel",
          opus: "claudeCustomOpusModel",
        },
        behavior: settingValue("claudeCustomModelBehavior", "noModel"),
      },
    };
    const definition = definitions[provider.providerID];
    const custom = provider.providerID === "claudeCustom";
    const card = desktopCard(
      custom ? "Custom Backend" : "Backend Behavior",
      custom
        ? "Define an Anthropic-compatible endpoint. Credential entry is unavailable because this backend does not advertise a safe configured-host validator."
        : "These runtime settings mirror the desktop backend behavior. Provider credentials are managed in the key section above.",
    );
    const form = element("form", "compatible-backend-form");
    const primaryFields = element("div", "settings-form");
    const advancedFields = element("div", "settings-form");
    function field(container, name, label, type = "text") {
      const key = definition.keys[name];
      const wrapper = element("label", "field");
      wrapper.append(element("span", "", label));
      const input = document.createElement(
        type === "select" ? "select" : "input",
      );
      input.name = name;
      input.dataset.settingKey = key;
      if (type !== "select") {
        input.type = type;
        input.value = settingValue(key);
      }
      wrapper.append(input);
      container.append(wrapper);
      return input;
    }

    function addAuthField(container) {
      const auth = field(container, "auth", "Auth header", "select");
      [
        ["anthropicAPIKey", "ANTHROPIC_API_KEY"],
        ["anthropicAuthToken", "ANTHROPIC_AUTH_TOKEN"],
      ].forEach(([value, label]) => {
        const option = element("option", "", label);
        option.value = value;
        option.selected = value === settingValue(definition.keys.auth);
        auth.append(option);
      });
    }

    let behavior = definition.behavior;
    let behaviorSelect = null;
    if (custom) {
      field(primaryFields, "displayName", "Display name");
      field(primaryFields, "baseURL", "Base URL", "url");
      addAuthField(primaryFields);
    }
    if (definition.keys.behavior) {
      behaviorSelect = field(
        primaryFields,
        "behavior",
        "Model behavior",
        "select",
      );
      [
        ["noModel", "No model flag"],
        ["claudeSlotMapping", "Claude slot mappings"],
      ].forEach(([value, label]) => {
        const option = element("option", "", label);
        option.value = value;
        option.selected = value === behavior;
        behaviorSelect.append(option);
      });
    }

    const slots = element("fieldset", "compatible-slot-fields");
    slots.append(element("legend", "", "Claude slot → backend model ID"));
    if (definition.keys.haiku) {
      [
        ["haiku", "Haiku"],
        ["sonnet", "Sonnet"],
        ["opus", "Opus"],
      ].forEach(([name, label]) => {
        const wrapper = element("label", "field");
        wrapper.append(element("span", "", label));
        const input = document.createElement("input");
        input.name = name;
        input.dataset.settingKey = definition.keys[name];
        input.value = settingValue(definition.keys[name]);
        wrapper.append(input);
        slots.append(wrapper);
      });
      slots.hidden = behavior !== "claudeSlotMapping";
      primaryFields.append(slots);
    }
    if (behaviorSelect)
      behaviorSelect.addEventListener("change", () => {
        behavior = behaviorSelect.value;
        slots.hidden = behavior !== "claudeSlotMapping";
      });

    if (!custom) {
      field(advancedFields, "displayName", "Display name");
      field(advancedFields, "baseURL", "Base URL", "url");
      addAuthField(advancedFields);
      const advanced = element("details", "compatible-advanced");
      advanced.append(
        element("summary", "", "Advanced"),
        element(
          "p",
          "card-subtitle",
          "Override the desktop preset's display name, fixed compatible base URL, or authentication header.",
        ),
        advancedFields,
      );
      form.append(primaryFields, advanced);
    } else {
      form.append(primaryFields);
    }

    const message = element(
      "div",
      "inline-message info",
      "Secrets are stored separately and never appear in these settings.",
    );
    message.setAttribute("role", "status");
    const actions = element("div", "form-actions");
    const save = element("button", "primary-button", "Save Settings");
    save.type = "submit";
    save.dataset.action = "save-compatible-backend-settings";
    actions.append(
      element("span", "form-note", "Applies to new sessions."),
      save,
    );
    form.append(message, actions);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const changes = {};
      form.querySelectorAll("[data-setting-key]").forEach((input) => {
        changes[input.dataset.settingKey] = input.value.trim();
      });
      if (custom) changes.claudeCustomEnabled = "true";
      await saveSettingsChanges(changes, save);
      await loadAll(true);
    });
    card.append(form);
    return card;
  }

  function typedSelect(label, options, currentValue) {
    const select = document.createElement("select");
    select.setAttribute("aria-label", label);
    options.forEach(([value, title]) => {
      const option = element("option", "", title);
      option.value = value;
      option.selected = value === currentValue;
      select.append(option);
    });
    return select;
  }

  function typedToggle(label, checked) {
    const toggle = element("label", "toggle desktop-toggle");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.checked = checked;
    input.setAttribute("aria-label", label);
    toggle.append(input, element("span"));
    return { toggle, input };
  }

  function promptDeliveryChoices() {
    return [
      ["nativeSystemPrompt", "Replace System Prompt"],
      [
        "userMessageXMLWithEmptySystemPrompt",
        "User Message (No Native)",
      ],
      ["userMessageXML", "User Message (Keep Native)"],
    ];
  }

  function livePromptDelivery() {
    return (
      state.typedSettings.directAgentPermissions?.settings?.claude
        ?.promptDelivery || "nativeSystemPrompt"
    );
  }

  function promptDeliveryPicker() {
    const select = typedSelect(
      "Sys Prompt Packaging",
      promptDeliveryChoices(),
      livePromptDelivery(),
    );
    select.addEventListener("change", () => savePromptDelivery(select));
    return desktopRow(
      "Sys Prompt Packaging",
      "Choose how RepoPrompt instructions are delivered to Claude Code.",
      select,
    );
  }

  async function savePromptDelivery(select) {
    const snapshot = state.typedSettings.directAgentPermissions;
    if (!snapshot) return;
    const settings = snapshot.settings;
    return mutateDomain(
      "directAgentPermissions",
      select,
      () =>
        api("api/v1/settings/direct-agent-permissions", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings: {
              ...settings,
              claude: {
                ...settings.claude,
                promptDelivery: select.value,
              },
            },
          }),
        }),
      (value) => {
        state.typedSettings.directAgentPermissions = value;
      },
    );
  }

  const workspaceApprovalOperations = [
    ["create_workspace", "Create Workspace", "Create a desktop workspace."],
    ["delete_workspace", "Delete Workspace", "Delete a desktop workspace."],
    ["add_folder", "Add Folder", "Attach a folder to a desktop workspace."],
    [
      "remove_folder",
      "Remove Folder",
      "Detach a folder from a desktop workspace.",
    ],
  ];

  function cloneWorkspaceApprovalSettings(snapshot) {
    return {
      autoApproveAll: !!snapshot.settings?.autoApproveAll,
      autoApproveOperations: [
        ...(snapshot.settings?.autoApproveOperations || []),
      ],
      clientPolicies: JSON.parse(
        JSON.stringify(snapshot.settings?.clientPolicies || {}),
      ),
    };
  }

  function saveWorkspaceApprovals(snapshot, mutateSettings, control) {
    const settings = cloneWorkspaceApprovalSettings(snapshot);
    mutateSettings(settings);
    return mutateDomain(
      "workspaceApprovals",
      control,
      () =>
        api("api/v1/settings/workspace-approvals", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings,
          }),
        }),
      (value) => {
        state.typedSettings.workspaceApprovals = value;
      },
    );
  }

  function saveMCPDisabledTools(snapshot, disabledTools, control) {
    return mutateDomain(
      "mcpDisabledTools",
      control,
      () =>
        api("api/v1/settings/mcp-disabled-tools", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings: { disabledTools: [...disabledTools] },
          }),
        }),
      (value) => {
        state.typedSettings.mcpDisabledTools = value;
      },
    );
  }

  function saveShowModelPresets(snapshot, enabled, control) {
    return mutateDomain(
      "showModelPresets",
      control,
      () =>
        api("api/v1/settings/show-model-presets", {
          method: "PATCH",
          body: JSON.stringify({
            expectedRevision: snapshot.revision,
            settings: { showModelPresets: enabled },
          }),
        }),
      (value) => {
        state.typedSettings.showModelPresets = value;
      },
    );
  }

  function agentTargetValue(target) {
    if (!target) return "";
    return [
      target.providerID,
      target.modelID || "",
      target.reasoningEffort || "",
    ]
      .map(encodeURIComponent)
      .join("|");
  }

  function agentTargetFromValue(value, pinned = false) {
    if (!value) return null;
    const [providerID, modelID, reasoningEffort] = value
      .split("|")
      .map(decodeURIComponent);
    return {
      providerID,
      modelID: modelID || null,
      reasoningEffort: reasoningEffort || null,
      pinned,
    };
  }

  function agentTargetChoices() {
    const choices = [["", "Unassigned"]];
    orderedProviders()
      .filter((provider) => provider.deploymentAllowed)
      .forEach((provider) => {
        if (!(provider.models || []).length) {
          const target = { providerID: provider.providerID };
          choices.push([
            agentTargetValue(target),
            `${provider.displayName} · Provider default`,
          ]);
        }
        (provider.models || []).forEach((modelEntry) => {
          const efforts = modelEntry.reasoningEfforts?.length
            ? modelEntry.reasoningEfforts
            : [null];
          efforts.forEach((effort) => {
            const target = {
              providerID: provider.providerID,
              modelID: modelEntry.id,
              reasoningEffort: effort,
            };
            choices.push([
              agentTargetValue(target),
              `${provider.displayName} · ${modelEntry.displayName}${effort ? ` · ${humanize(effort)}` : ""}`,
            ]);
          });
        });
      });
    return choices;
  }

  function renderTypedAgentModels() {
    const snapshot = state.typedSettings.agentModels;
    if (!snapshot) {
      settingsPage(
        "Agent Models",
        "Loading model settings…",
        "model",
        [],
      );
      return;
    }
    const projectID = state.agent.selectedProjectID;
    const projectOverride =
      Boolean(projectID) && snapshot.projectMode === "projectOverride";
    const scope = desktopCard(
      "Scope",
      "Use the global model choices for every project, or override them for the active project.",
    );
    if (projectID) {
      const mode = typedSelect(
        "Agent Models scope",
        [
          ["inheritGlobal", "Use global settings"],
          ["projectOverride", "Use project override"],
        ],
        snapshot.projectMode,
      );
      mode.addEventListener("change", () =>
        mutateDomain(
          "agentModels",
          mode,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: snapshot.projectRevision,
                  mode: mode.value,
                  profile:
                    mode.value === "projectOverride"
                      ? snapshot.projectProfile || snapshot.globalProfile
                      : snapshot.projectProfile,
                }),
              },
            ),
          (value) => {
            state.typedSettings.agentModels = value;
          },
        ),
      );
      scope.append(
        desktopRow(
          "Project routing",
          "Project overrides are complete snapshots. Inherited projects track global edits immediately and keep any unused override snapshot, matching Desktop workspace inherit/override.",
          mode,
        ),
      );
      const copy = element(
        "button",
        "secondary-button",
        "Copy Global to Project",
      );
      copy.type = "button";
      copy.dataset.action = "copy-global-agent-models";
      copy.addEventListener("click", () =>
        mutateDomain(
          "agentModels",
          copy,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models/copy-global`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedGlobalRevision: snapshot.globalRevision,
                  expectedProjectRevision: snapshot.projectRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.agentModels = value;
          },
        ),
      );
      scope.append(copy);
      const copyProject = element(
        "button",
        "secondary-button",
        "Copy Project to Global",
      );
      copyProject.type = "button";
      copyProject.dataset.action = "copy-project-agent-models";
      copyProject.addEventListener("click", () =>
        mutateDomain(
          "agentModels",
          copyProject,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models/copy-project`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedGlobalRevision: snapshot.globalRevision,
                  expectedProjectRevision: snapshot.projectRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.agentModels = value;
          },
        ),
      );
      scope.append(copyProject);
    } else {
      scope.append(
        element(
          "p",
          "empty-inline",
          "No active project is available; editing the global profile.",
        ),
      );
    }

    const recommendations = desktopCard(
      "Recommended Setup",
      `Server profile ${snapshot.recommendationProfileVersion} is the canonical recommendation authority. OpenCode remains a connection signal but is never invented as a routing target.`,
    );
    (snapshot.recommendations || []).forEach((row) => {
      const provider = orderedProviders().find(
        (candidate) =>
          candidate.providerID === row.recommendedTarget?.providerID,
      );
      const target = row.recommendedTarget;
      const value = target
        ? `${provider?.displayName || target.providerID}${target.modelID ? ` · ${target.modelID}` : ""}${target.reasoningEffort ? ` · ${humanize(target.reasoningEffort)}` : ""}`
        : humanize(row.availability);
      recommendations.append(
        desktopRow(
          humanize(row.target),
          row.detail,
          element(
            "span",
            row.availability === "exact"
              ? "recommended-value"
              : "read-only-value",
            value,
          ),
        ),
      );
    });
    const apply = element(
      "button",
      "primary-button",
      "Apply Recommended Setup",
    );
    apply.type = "button";
    apply.dataset.action = "apply-recommended-agent-models";
    apply.addEventListener("click", () => {
      const projectEndpoint = projectOverride
        ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models/apply-recommendations`
        : "api/v1/settings/agent-models/apply-recommendations";
      mutateDomain(
        "agentModels",
        apply,
        () =>
          api(projectEndpoint, {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: projectOverride
                ? snapshot.projectRevision
                : snapshot.globalRevision,
            }),
          }),
        (value) => {
          state.typedSettings.agentModels = value;
        },
      );
    });
    recommendations.append(apply);

    const profile = projectOverride
      ? snapshot.projectProfile || snapshot.effectiveProfile
      : snapshot.globalProfile;
    const routes = desktopCard(
      projectOverride ? "Project Agent Routes" : "Global Agent Routes",
      "Oracle and Context Builder cannot run while unassigned. Agent roles follow recommendations until you choose a model explicitly.",
    );
    const form = element("form", "typed-settings-form");
    const targetControls = {};
    [
      "oracle",
      "contextBuilder",
      "explore",
      "engineer",
      "pair",
      "design",
    ].forEach((targetName) => {
      const row = element("div", "typed-route-row");
      const failClosed =
        targetName === "oracle" || targetName === "contextBuilder";
      const select = typedSelect(
        `${humanize(targetName)} route`,
        [
          [
            "",
            failClosed
              ? "Unassigned (fail-closed)"
              : "Unassigned (tracks recommendation)",
          ],
          ...agentTargetChoices().slice(1),
        ],
        agentTargetValue(profile[targetName]),
      );
      row.append(element("strong", "", humanize(targetName)), select);
      form.append(row);
      targetControls[targetName] = { select };
    });
    const restrict = typedToggle(
      "Hide non-role models from MCP agents",
      profile.restrictDiscoveryToRoleModels === true,
    );
    const syncCompose = typedToggle(
      "Sync chat model with Oracle",
      profile.syncChatModelWithOracle === true,
    );
    const composeModel = document.createElement("input");
    composeModel.type = "text";
    composeModel.value = profile.preferredComposeModelRaw || "";
    composeModel.setAttribute("aria-label", "Preferred compose model");
    form.append(
      desktopRow(
        "Hide non-role models from MCP agents",
        "Hides the extra per-agent catalog on agent_manage list_agents. Task labels stay visible. Manually supplied compound IDs are still accepted.",
        restrict.toggle,
      ),
      desktopRow(
        "Sync chat model with Oracle",
        "When on, the compose/chat model live-reads the Oracle model.",
        syncCompose.toggle,
      ),
      desktopRow(
        "Preferred compose model",
        "Raw compose/chat model identifier. Empty tracks Oracle when sync is on.",
        composeModel,
      ),
    );
    const save = element("button", "primary-button", "Save Agent Routes");
    save.type = "submit";
    form.append(save);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const nextProfile = {
        ...profile,
        restrictDiscoveryToRoleModels: restrict.input.checked,
        preferredComposeModelRaw: composeModel.value.trim() || null,
        syncChatModelWithOracle: syncCompose.input.checked,
      };
      Object.entries(targetControls).forEach(([name, controls]) => {
        nextProfile[name] = agentTargetFromValue(controls.select.value);
      });
      mutateDomain(
        "agentModels",
        save,
        () =>
          api(
            projectOverride
              ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/agent-models`
              : "api/v1/settings/agent-models",
            {
              method: "PATCH",
              body: JSON.stringify(
                projectOverride
                  ? {
                      expectedRevision: snapshot.projectRevision,
                      mode: "projectOverride",
                      profile: nextProfile,
                    }
                  : {
                      expectedRevision: snapshot.globalRevision,
                      profile: nextProfile,
                    },
              ),
            },
          ),
        (value) => {
          state.typedSettings.agentModels = value;
        },
      );
    });
    routes.append(form);

    const providerDefaults = desktopCard(
      "Provider Defaults",
      "Default model choices reported by connected providers.",
    );
    const stack = element("div", "provider-stack");
    orderedProviders()
      .filter(
        (provider) =>
          provider.deploymentAllowed &&
          provider.category === "cliProvider" &&
          (provider.models || []).length,
      )
      .forEach((provider, index) =>
        stack.append(providerCard(provider, index === 0, true)),
      );
    providerDefaults.append(stack);
    settingsPage(
      "Agent Models",
      "Choose models for Oracle, Context Builder, and each agent role.",
      "model",
      [scope, recommendations, routes, providerDefaults],
      recommendation(
        "model",
        snapshot.recommendations.some((row) => row.availability === "exact")
          ? "Recommendation check complete"
          : "No desktop recommendation target available",
        snapshot.recommendations.some((row) => row.availability === "exact")
          ? `Connected providers were evaluated against desktop profile ${snapshot.recommendationProfileVersion} (2026-08).`
          : "The connected provider set has no exact profile target. OpenCode is not assigned to Oracle, Context Builder, or role defaults.",
      ),
    );
  }

  function renderAgentPermissions() {
    const fallback = desktopCard(
      "Portal Session Default",
      "Fallback for API providers that do not have provider-specific permission settings.",
    );
    fallback.append(
      selectSetting(
        "serverDefaultExecutionMode",
        "Default Execution Mode",
        "Does not replace Codex, Claude, OpenCode, Cursor, or Grok Build permissions.",
        [
          ["readOnly", "Read Only"],
          ["workspaceWrite", "Workspace Write"],
          ["fullAccess", "Full Access"],
        ],
        "workspaceWrite",
      ),
    );
    const byID = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const snapshot = state.typedSettings.directAgentPermissions;
    const providerCards = [];
    if (snapshot) {
      const settings = snapshot.settings;
      const form = element("form", "typed-settings-form");
      const sandbox = typedSelect(
        "Sandbox",
        [
          ["read-only", "Read Only"],
          ["workspace-write", "Workspace Write"],
          ["danger-full-access", "Full Access"],
        ],
        settings.codex.sandboxMode,
      );
      const approval = typedSelect(
        "Approval Policy",
        [
          ["on-request", "On Request"],
          ["unless-trusted", "Unless Trusted"],
          ["never", "Never"],
        ],
        settings.codex.approvalPolicy,
      );
      const reviewer = typedSelect(
        "Approval Reviewer",
        [
          ["user", "User"],
          ["auto-review", "Auto Review"],
        ],
        settings.codex.approvalReviewer,
      );
      const codexBash = typedToggle("Bash", settings.codex.bashEnabled);
      const claudeMode = typedSelect(
        "Permission Level",
        [
          ["default", "Require Approval"],
          ["acceptEdits", "Auto-Approve Edits"],
          ["auto", "Auto"],
          ["bypassPermissions", "Full Access"],
        ],
        settings.claude.permissionMode,
      );
      const claudeBash = typedToggle("Bash", settings.claude.bashEnabled);
      const claudeStrict = typedToggle(
        "RepoPrompt Only (Strict MCP)",
        settings.claude.mcpStrictModeEnabled,
      );
      const claudePromptDelivery = typedSelect(
        "Sys Prompt Packaging",
        promptDeliveryChoices(),
        settings.claude.promptDelivery || "nativeSystemPrompt",
      );
      const openCodeLevel = typedSelect(
        "ACP Session Mode",
        [
          ["managedDefault", "Managed Default"],
          ["fullAccess", "Full Access"],
        ],
        settings.openCode.permissionLevel,
      );
      const cursorLevel = typedSelect(
        "ACP Auto-Approve",
        [
          ["managedDefault", "Managed Default"],
          ["fullAccess", "Full Access"],
        ],
        settings.cursor.permissionLevel,
      );
      const codexCard = desktopCard(
        "Codex Direct Agent",
        "Sandbox, approval, and reviewer settings for new Codex sessions.",
      );
      const derived = element(
        "span",
        "read-only-value",
        liveCodexPermissionLevel(settings.codex),
      );
      codexCard.append(
        desktopRow(
          "Permission Level",
          "Derived from sandbox and reviewer the same way Desktop does.",
          derived,
        ),
        desktopRow(
          "Sandbox",
          "Controls the Codex sandbox boundary for new direct sessions.",
          sandbox,
        ),
        desktopRow(
          "Approval Policy",
          "When Codex must ask before acting.",
          approval,
        ),
        desktopRow(
          "Approval Reviewer",
          "User review or Auto Review for workspace-write sessions.",
          reviewer,
        ),
        desktopRow(
          "Bash",
          "Allow Codex to run shell commands in its approved execution mode.",
          codexBash.toggle,
        ),
      );
      if (byID.codex) {
        codexCard.append(
          element("h3", "desktop-subheading", "Core tools"),
          toggleSetting(
            "codexSearchEnabled",
            "Search",
            "Allow live web search requests from Codex.",
            true,
          ),
          toggleSetting(
            "codexGoalsEnabled",
            "Goals",
            "Enable /goal support and the goal lifecycle for Codex Agent Mode.",
            true,
          ),
          toggleSetting(
            "codexReasoningSummariesEnabled",
            "Reasoning Summaries",
            "Request model reasoning summaries for app-server threads.",
            false,
          ),
          toggleSetting(
            "codexMemoriesEnabled",
            "Local Memories",
            "Allow Codex to generate and use local memories.",
            false,
          ),
          desktopRow(
            "MCP servers",
            "RepoPrompt is required for Agent Mode.",
            element("span", "required-pill", "RepoPrompt · Required"),
          ),
        );
      }
      const claudeCard = desktopCard(
        "Claude Code Direct Agent",
        "Typed Claude permission mode, Bash, and MCP-strict. MCP-strict defaults on.",
      );
      claudeCard.append(
        desktopRow(
          "Permission Level",
          "Controls Claude Code permission prompts.",
          claudeMode,
        ),
        desktopRow(
          "Bash",
          "Allow Claude Code's native Bash tool.",
          claudeBash.toggle,
        ),
        desktopRow(
          "RepoPrompt Only (Strict MCP)",
          "Launch with strict MCP configuration so only RepoPrompt tools are active.",
          claudeStrict.toggle,
        ),
      );
      if (byID.claudeCompatible) {
        claudeCard.append(
          element("h3", "desktop-subheading", "Tools"),
          toggleSetting(
            "claudeToolSearchEnabled",
            "Lazy Tool Loading",
            "Claude searches for each tool before use; this saves context but adds latency.",
            true,
          ),
          desktopRow(
            "Sys Prompt Packaging",
            "Replace Claude Code's native system prompt, wrap RepoPrompt instructions in the user message, or keep the native prompt.",
            claudePromptDelivery,
          ),
        );
      }
      const openCodeCard = desktopCard(
        "OpenCode Direct Agent",
        "Typed ACP session mode from the Direct Agents store.",
      );
      openCodeCard.append(
        desktopRow(
          "ACP Session Mode",
          "Choose the provider's managed mode or full access.",
          openCodeLevel,
        ),
      );
      const cursorCard = desktopCard(
        "Cursor Direct Agent",
        "Typed ACP auto-approve from the Direct Agents store.",
      );
      cursorCard.append(
        desktopRow(
          "ACP Auto-Approve",
          "Choose the provider's managed mode or full access.",
          cursorLevel,
        ),
      );
      const save = element("button", "primary-button", "Save Direct Agents");
      save.type = "submit";
      form.append(codexCard, claudeCard, openCodeCard, cursorCard, save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        mutateDomain(
          "directAgentPermissions",
          save,
          () =>
            api("api/v1/settings/direct-agent-permissions", {
              method: "PATCH",
              body: JSON.stringify({
                expectedRevision: snapshot.revision,
                settings: {
                  codex: {
                    sandboxMode: sandbox.value,
                    approvalPolicy: approval.value,
                    approvalReviewer: reviewer.value,
                    bashEnabled: codexBash.input.checked,
                  },
                  claude: {
                    permissionMode: claudeMode.value,
                    bashEnabled: claudeBash.input.checked,
                    mcpStrictModeEnabled: claudeStrict.input.checked,
                    promptDelivery: claudePromptDelivery.value,
                  },
                  openCode: { permissionLevel: openCodeLevel.value },
                  cursor: { permissionLevel: cursorLevel.value },
                },
              }),
            }),
          (value) => {
            state.typedSettings.directAgentPermissions = value;
          },
        );
      });
      providerCards.push(form);
    }
    const subagentSnapshot = state.typedSettings.subagentPermissions;
    const subagents = desktopCard(
      "Sub-Agents",
      "Choose how new sub-agents inherit or override provider permissions. Invalid settings fall back to Safe Managed.",
    );
    if (subagentSnapshot) {
      const form = element("form", "typed-settings-form");
      const settings = subagentSnapshot.settings;
      const policy = typedSelect(
        "Sub-agent permission policy",
        [
          ["safeManaged", "Safe Managed (recommended)"],
          ["inheritProviderSettings", "Inherit Provider Settings"],
          ["custom", "Custom"],
        ],
        settings.policy,
      );
      form.append(
        desktopRow(
          "Policy",
          "Safe Managed resolves Codex to Auto Review, Claude to Require Approval, and ACP providers to Managed Default.",
          policy,
        ),
      );
      const custom = element("div", "subagent-custom-grid");
      const controls = {
        codex: typedSelect(
          "Custom Codex sub-agent mode",
          [
            ["readOnly", "Read Only"],
            ["defaultPermission", "Default Permission"],
            ["autoReview", "Auto Review"],
            ["fullAccess", "Full Access"],
          ],
          settings.codex,
        ),
        claude: typedSelect(
          "Custom Claude sub-agent mode",
          [
            ["requireApproval", "Require Approval"],
            ["autoApproveEdits", "Auto-Approve Edits"],
            ["auto", "Auto"],
            ["fullAccess", "Full Access"],
          ],
          settings.claude,
        ),
        openCode: typedSelect(
          "Custom OpenCode sub-agent mode",
          [
            ["managedDefault", "Managed Default"],
            ["fullAccess", "Full Access"],
          ],
          settings.openCode,
        ),
        cursor: typedSelect(
          "Custom Cursor sub-agent mode",
          [
            ["managedDefault", "Managed Default"],
            ["fullAccess", "Full Access"],
          ],
          settings.cursor,
        ),
      };
      Object.entries(controls).forEach(([name, control]) =>
        custom.append(
          desktopRow(humanize(name), "Custom permission mode.", control),
        ),
      );
      const warning = element(
        "div",
        "inline-message warning",
        "Full Access can allow delegated agents to act without a managed approval boundary.",
      );
      function updateCustomVisibility() {
        custom.hidden = policy.value !== "custom";
        warning.hidden =
          policy.value === "safeManaged" ||
          (policy.value === "custom" &&
            !Object.values(controls).some(
              (control) => control.value === "fullAccess",
            ));
      }
      policy.addEventListener("change", updateCustomVisibility);
      Object.values(controls).forEach((control) =>
        control.addEventListener("change", updateCustomVisibility),
      );
      updateCustomVisibility();
      const save = element("button", "primary-button", "Save Sub-Agent Policy");
      save.type = "submit";
      form.append(custom, warning, save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        mutateDomain(
          "subagentPermissions",
          save,
          () =>
            api("api/v1/settings/subagent-permissions", {
              method: "PATCH",
              body: JSON.stringify({
                expectedRevision: subagentSnapshot.revision,
                settings: {
                  policy: policy.value,
                  codex: controls.codex.value,
                  claude: controls.claude.value,
                  openCode: controls.openCode.value,
                  cursor: controls.cursor.value,
                },
              }),
            }),
          (value) => {
            state.typedSettings.subagentPermissions = value;
          },
        );
      });
      subagents.append(form);
    }
    settingsPage(
      "Agent Permissions",
      "Configure permissions for direct agents and delegated sub-agents.",
      "shield",
      [fallback, ...providerCards, subagents],
      recommendation(
        "shield",
        "Direct permissions apply to new sessions",
        "Permission changes apply to new sessions.",
      ),
    );
  }

  function renderTypedAgentWorkflows() {
    const snapshot = state.typedSettings.workflows;
    if (!snapshot) {
      settingsPage(
        "Agent Workflows",
        "Loading workflow repository…",
        "workflow",
        [],
      );
      return;
    }
    const preferences = desktopCard(
      "Workflow Runtime",
      "Built-in and custom workflows available in Agent Mode.",
    );
    const cleanup = typedToggle(
      "Include Session Cleanup Guidance",
      snapshot.includeSessionCleanupGuidance,
    );
    cleanup.input.addEventListener("change", () =>
      mutateDomain(
        "workflows",
        cleanup.input,
        () =>
          api("api/v1/workflows/preferences", {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              includeSessionCleanupGuidance: cleanup.input.checked,
            }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      ),
    );
    preferences.append(
      desktopRow(
        "Include Session Cleanup Guidance",
        "Appends bounded cleanup guidance during workflow prompt assembly.",
        cleanup.toggle,
      ),
      element(
        "div",
        "inline-message warning",
        "Hidden workflows are excluded from new discovery. Sessions do not persist a durable workflow association, so hidden-workflow lookup fails closed; re-enable the workflow before starting a new run.",
      ),
    );
    const reload = element("button", "secondary-button", "Reload & Revalidate");
    reload.type = "button";
    reload.addEventListener("click", () =>
      mutateDomain(
        "workflows",
        reload,
        () =>
          api("api/v1/workflows/reload", {
            method: "POST",
            body: JSON.stringify({ expectedRevision: snapshot.revision }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      ),
    );
    preferences.append(reload);

    const catalog = desktopCard(
      "Workflow Catalog",
      "Feature or hide workflows, and clone built-ins to create editable custom versions.",
    );
    const featured = snapshot.workflows
      .filter((workflow) => workflow.featuredOrder !== null)
      .sort((left, right) => left.featuredOrder - right.featuredOrder);
    const pickerWorkflows = snapshot.workflows
      .filter((workflow) => workflow.enabled && workflow.visible)
      .sort((left, right) => {
        if (left.featuredOrder !== null && right.featuredOrder !== null) {
          return left.featuredOrder - right.featuredOrder;
        }
        if (left.featuredOrder !== null) return -1;
        if (right.featuredOrder !== null) return 1;
        return String(left.name).localeCompare(String(right.name));
      });
    function reorderFeatured(workflowID, delta, control) {
      const ids = featured.map((workflow) => workflow.workflowID);
      const index = ids.indexOf(workflowID);
      const next = index + delta;
      if (index < 0 || next < 0 || next >= ids.length) return;
      [ids[index], ids[next]] = [ids[next], ids[index]];
      mutateDomain(
        "workflows",
        control,
        () =>
          api("api/v1/workflows/reorder", {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              featuredWorkflowIDs: ids,
            }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      );
    }
    const picker = desktopCard(
      "Picker Catalog",
      "Live discovery from the server repository: enabled and visible rows, featured order first. Hidden built-ins stay in Settings only.",
    );
    picker.dataset.workflowPicker = "server-catalog";
    if (!pickerWorkflows.length) {
      picker.append(
        element(
          "p",
          "scope-footnote",
          "No enabled visible workflows are advertised.",
        ),
      );
    } else {
      const pickerList = element("ol", "workflow-picker-list");
      pickerWorkflows.forEach((workflow) => {
        const item = element("li", "workflow-picker-item");
        item.dataset.workflowId = workflow.workflowID;
        item.dataset.featuredOrder =
          workflow.featuredOrder === null ? "" : String(workflow.featuredOrder);
        item.append(
          element("strong", "", workflow.name),
          element(
            "small",
            "",
            workflow.featuredOrder === null
              ? "Visible"
              : `Featured ${workflow.featuredOrder + 1}`,
          ),
        );
        pickerList.append(item);
      });
      picker.append(pickerList);
    }
    const list = element("div", "workflow-settings-list");
    snapshot.workflows.forEach((workflow) => {
      const details = element("details", "workflow-editor-row");
      const summary = element("summary", "workflow-editor-summary");
      const copy = element("span", "desktop-setting-copy");
      copy.append(
        element("strong", "", workflow.name),
        element(
          "small",
          "",
          `${humanize(workflow.source)} · revision ${workflow.rowRevision}${workflow.featuredOrder !== null ? ` · featured ${workflow.featuredOrder + 1}` : ""}`,
        ),
      );
      summary.append(
        copy,
        element(
          "span",
          workflow.visible ? "connection-badge connected" : "connection-badge",
          workflow.visible ? "Visible" : "Hidden",
        ),
      );
      details.append(summary);
      const actions = element("div", "workflow-inline-actions");
      const visible = element(
        "button",
        "secondary-button",
        workflow.visible ? "Hide" : "Show",
      );
      visible.type = "button";
      visible.addEventListener("click", () =>
        mutateDomain(
          "workflows",
          visible,
          () =>
            api(
              `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}/visibility`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: snapshot.revision,
                  expectedRowRevision: workflow.rowRevision,
                  visible: !workflow.visible,
                }),
              },
            ),
          (value) => {
            applyWorkflowRepository(value);
          },
        ),
      );
      const clone = element("button", "secondary-button", "Clone");
      clone.type = "button";
      clone.addEventListener("click", () =>
        mutateDomain(
          "workflows",
          clone,
          () =>
            api(
              `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}/clone`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedRevision: snapshot.revision,
                  expectedSourceRowRevision: workflow.rowRevision,
                  name: `${workflow.name} Copy`,
                }),
              },
            ),
          (value) => {
            applyWorkflowRepository(value);
          },
        ),
      );
      const feature = element(
        "button",
        "secondary-button",
        workflow.featuredOrder === null ? "Feature" : "Unfeature",
      );
      feature.type = "button";
      if (!workflow.visible && workflow.featuredOrder === null) {
        feature.disabled = true;
        feature.title = "Hidden workflows cannot be featured.";
      }
      feature.addEventListener("click", () => {
        const ids = featured
          .map((item) => item.workflowID)
          .filter((id) => id !== workflow.workflowID);
        if (workflow.featuredOrder === null) ids.push(workflow.workflowID);
        mutateDomain(
          "workflows",
          feature,
          () =>
            api("api/v1/workflows/reorder", {
              method: "POST",
              body: JSON.stringify({
                expectedRevision: snapshot.revision,
                featuredWorkflowIDs: ids,
              }),
            }),
          (value) => {
            applyWorkflowRepository(value);
          },
        );
      });
      if (workflow.source === "builtin") {
        actions.append(visible);
      }
      actions.append(clone, feature);
      if (workflow.featuredOrder !== null) {
        const earlier = element("button", "secondary-button", "Move Earlier");
        earlier.type = "button";
        earlier.disabled = workflow.featuredOrder === 0;
        earlier.addEventListener("click", () =>
          reorderFeatured(workflow.workflowID, -1, earlier),
        );
        const later = element("button", "secondary-button", "Move Later");
        later.type = "button";
        later.disabled = workflow.featuredOrder === featured.length - 1;
        later.addEventListener("click", () =>
          reorderFeatured(workflow.workflowID, 1, later),
        );
        actions.append(earlier, later);
      }
      details.append(actions);
      if (workflow.source === "custom") {
        const form = element("form", "workflow-definition-form");
        const name = document.createElement("input");
        name.type = "text";
        name.maxLength = 128;
        name.value = workflow.name;
        name.setAttribute("aria-label", `Workflow name for ${workflow.name}`);
        const definition = document.createElement("textarea");
        definition.rows = 10;
        definition.maxLength = 262144;
        definition.value = workflow.definition;
        definition.setAttribute(
          "aria-label",
          `Markdown definition for ${workflow.name}`,
        );
        const enabled = typedToggle(
          `Enable ${workflow.name}`,
          workflow.enabled,
        );
        const featuredToggle = typedToggle(
          `Feature ${workflow.name}`,
          workflow.featuredOrder !== null,
        );
        const save = element("button", "primary-button", "Save Workflow");
        save.type = "submit";
        const remove = element("button", "danger-button", "Delete");
        remove.type = "button";
        remove.addEventListener("click", async () => {
          if (
            !(await confirmAction({
              title: "Delete workflow?",
              message: `Delete ${workflow.name}?`,
              label: "Delete",
              returnFocus: remove,
            }))
          )
            return;
          mutateDomain(
            "workflows",
            remove,
            () =>
              api(
                `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}`,
                {
                  method: "DELETE",
                  body: JSON.stringify({
                    expectedRevision: snapshot.revision,
                    expectedRowRevision: workflow.rowRevision,
                  }),
                },
              ),
            (value) => {
              applyWorkflowRepository(value);
            },
          );
        });
        form.append(
          desktopRow("Name", "Server-visible workflow name.", name),
          definition,
          desktopRow(
            "Enabled",
            "Admitted to runtime execution.",
            enabled.toggle,
          ),
          desktopRow(
            "Featured",
            "Included in the ordered featured catalog.",
            featuredToggle.toggle,
          ),
          save,
          remove,
        );
        form.addEventListener("submit", (event) => {
          event.preventDefault();
          mutateDomain(
            "workflows",
            save,
            () =>
              api(
                `api/v1/workflows/${encodeURIComponent(workflow.workflowID)}`,
                {
                  method: "PATCH",
                  body: JSON.stringify({
                    expectedRevision: snapshot.revision,
                    expectedRowRevision: workflow.rowRevision,
                    name: name.value.trim(),
                    definition: definition.value,
                    enabled: enabled.input.checked,
                    visible: workflow.visible,
                    featured: featuredToggle.input.checked,
                  }),
                },
              ),
            (value) => {
              applyWorkflowRepository(value);
            },
          );
        });
        details.append(form);
      } else {
        details.append(
          element(
            "p",
            "scope-footnote",
            "Built-in definitions are immutable. Clone this workflow to edit a custom copy.",
          ),
        );
      }
      list.append(details);
    });
    catalog.append(list);

    const create = desktopCard(
      "New Custom Workflow",
      "Create a reusable custom workflow for Agent Mode.",
    );
    const createForm = element("form", "workflow-definition-form");
    const name = document.createElement("input");
    name.type = "text";
    name.maxLength = 128;
    name.placeholder = "Workflow name";
    name.setAttribute("aria-label", "New workflow name");
    const definition = document.createElement("textarea");
    definition.rows = 10;
    definition.maxLength = 262144;
    definition.placeholder =
      "# Workflow\n\n## Purpose\nDescribe the workflow.\n\n## Instructions\n- Add bounded steps.";
    definition.setAttribute("aria-label", "New workflow markdown definition");
    const save = element("button", "primary-button", "Create Workflow");
    save.type = "submit";
    if (
      snapshot.workflows.filter((workflow) => workflow.source === "custom")
        .length >= 200
    ) {
      [name, definition, save].forEach((control) =>
        setDisabledReason(
          control,
          true,
          "The server supports at most 200 custom workflows.",
        ),
      );
    }
    createForm.append(name, definition, save);
    createForm.addEventListener("submit", (event) => {
      event.preventDefault();
      mutateDomain(
        "workflows",
        save,
        () =>
          api("api/v1/workflows", {
            method: "POST",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              name: name.value.trim(),
              definition: definition.value,
              enabled: true,
              visible: true,
              featured: false,
            }),
          }),
        (value) => {
          applyWorkflowRepository(value);
        },
      );
    });
    create.append(createForm);
    settingsPage(
      "Agent Workflows",
      "Manage built-in and custom Agent Mode workflows.",
      "workflow",
      [preferences, picker, catalog, create],
    );
  }

  function renderTypedContextBuilder() {
    const snapshot = state.typedSettings.contextBuilder;
    if (!snapshot) {
      settingsPage(
        "Context Builder",
        "Loading Context Builder settings…",
        "context",
        [],
      );
      return;
    }
    const projectID = state.agent.selectedProjectID;
    const projectOverride =
      Boolean(projectID) && snapshot.projectMode === "projectOverride";
    const scope = desktopCard(
      "Scope",
      "Project settings override global defaults for the active project.",
    );
    if (projectID) {
      const mode = typedSelect(
        "Context Builder scope",
        [
          ["inheritGlobal", "Use global settings"],
          ["projectOverride", "Use project override"],
        ],
        snapshot.projectMode,
      );
      mode.addEventListener("change", () =>
        mutateDomain(
          "contextBuilder",
          mode,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: snapshot.projectRevision,
                  mode: mode.value,
                  profile:
                    mode.value === "projectOverride"
                      ? snapshot.globalProfile
                      : null,
                }),
              },
            ),
          (value) => {
            state.typedSettings.contextBuilder = value;
          },
        ),
      );
      const copy = element(
        "button",
        "secondary-button",
        "Copy Global to Project",
      );
      copy.type = "button";
      copy.addEventListener("click", () =>
        mutateDomain(
          "contextBuilder",
          copy,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder/copy-global`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedGlobalRevision: snapshot.globalRevision,
                  expectedProjectRevision: snapshot.projectRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.contextBuilder = value;
          },
        ),
      );
      scope.append(
        desktopRow(
          "Project defaults",
          "Inherited projects track global settings immediately.",
          mode,
        ),
        copy,
      );
    }

    const profile = JSON.parse(
      JSON.stringify(
        projectOverride
          ? snapshot.projectProfile || snapshot.effectiveProfile
          : snapshot.globalProfile,
      ),
    );
    const settings = desktopCard(
      projectOverride ? "Project Defaults" : "Global Defaults",
      "These values are consumed by Context Builder, including connected chat agents using RepoPrompt MCP and optional follow-up Oracle analysis.",
    );
    const form = element("form", "typed-settings-form");
    const budget = document.createElement("input");
    budget.type = "number";
    budget.min = "10000";
    budget.max = "200000";
    budget.step = "5000";
    budget.value = String(profile.budget);
    budget.setAttribute("aria-label", "Context Budget");
    const enhancement = typedSelect(
      "Prompt Enhancement",
      [
        ["rewrite", "Rewrite"],
        ["augment", "Augment"],
        ["preserve", "Preserve"],
      ],
      profile.enhancementMode,
    );
    const timeout = typedSelect(
      "Question Timeout",
      [
        ["30", "30 seconds"],
        ["60", "1 minute"],
        ["120", "2 minutes"],
        ["300", "5 minutes"],
      ],
      String(profile.questionTimeoutSeconds),
    );
    const clarifyingQuestions = typedToggle(
      "Allow Clarifying Questions",
      profile.mcpClarifyingQuestions,
    );
    const followUp = typedSelect(
      "Follow-up Analysis",
      [
        ["disabled", "Disabled"],
        ["plan", "Plan"],
        ["review", "Review"],
        ["question", "Question"],
      ],
      profile.followUpAnalysis,
    );
    const followUpBudget = document.createElement("input");
    followUpBudget.type = "number";
    followUpBudget.min = "40000";
    followUpBudget.max = "200000";
    followUpBudget.step = "5000";
    followUpBudget.value = String(profile.followUpBudget);
    followUpBudget.setAttribute("aria-label", "Follow-up Analysis Budget");
    form.append(
      desktopRow("Context Budget", "10k–200k in 5k steps.", budget),
      desktopRow(
        "Prompt Enhancement",
        "Rewrite, augment, or preserve caller instructions.",
        enhancement,
      ),
      desktopRow(
        "Question Timeout",
        "Applied to ask_user settlement.",
        timeout,
      ),
      desktopRow(
        "Allow Clarifying Questions",
        "Connected chat agents using RepoPrompt MCP can ask clarifying questions during Context Builder.",
        clarifyingQuestions.toggle,
      ),
      desktopRow(
        "Follow-up Analysis",
        "Runs Oracle after proposal and before committing selection.",
        followUp,
      ),
      desktopRow("Analysis Budget", "40k–200k in 5k steps.", followUpBudget),
    );
    const save = element(
      "button",
      "primary-button",
      "Save Context Builder Settings",
    );
    save.type = "submit";
    form.append(save);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const nextProfile = {
        budget: Number(budget.value),
        enhancementMode: enhancement.value,
        questionTimeoutSeconds: Number(timeout.value),
        portalClarifyingQuestions: profile.portalClarifyingQuestions,
        mcpClarifyingQuestions: clarifyingQuestions.input.checked,
        followUpAnalysis: followUp.value,
        followUpBudget: Number(followUpBudget.value),
      };
      mutateDomain(
        "contextBuilder",
        save,
        () =>
          api(
            projectOverride
              ? `api/v1/projects/${encodeURIComponent(projectID)}/settings/context-builder`
              : "api/v1/settings/context-builder",
            {
              method: "PATCH",
              body: JSON.stringify(
                projectOverride
                  ? {
                      expectedRevision: snapshot.projectRevision,
                      mode: "projectOverride",
                      profile: nextProfile,
                    }
                  : {
                      expectedRevision: snapshot.globalRevision,
                      profile: nextProfile,
                    },
              ),
            },
          ),
        (value) => {
          state.typedSettings.contextBuilder = value;
        },
      );
    });
    settings.append(form);

    settingsPage(
      "Context Builder",
      "Configure Context Builder defaults globally or for the active project.",
      "context",
      [scope, settings],
    );
  }

  function renderPortalAppearance() {
    const preference = portalAppearance();
    const card = desktopCard(
      "Browser Appearance",
      "These controls are browser-local and apply immediately. They never enter server settings, audit rows, or session state.",
    );
    const theme = typedSelect(
      "Portal theme",
      [
        ["system", "System"],
        ["light", "Light"],
        ["dark", "Dark"],
      ],
      preference.theme,
    );
    const density = typedSelect(
      "Portal text density",
      [
        ["normal", "Normal"],
        ["large", "Large"],
        ["extraLarge", "Extra Large"],
      ],
      preference.density,
    );
    function save() {
      savePortalAppearance({ theme: theme.value, density: density.value });
    }
    theme.addEventListener("change", save);
    density.addEventListener("change", save);
    card.append(
      desktopRow("Theme", "System, light, or dark browser rendering.", theme),
      desktopRow(
        "Text Density",
        "Scales portal typography without changing desktop text-size settings.",
        density,
      ),
    );
    settingsPage(
      "Appearance",
      "Choose the portal theme and text size for this browser.",
      "appearance",
      [card],
    );
  }

  function renderAdvanced() {
    const snapshot = state.typedSettings.advanced;
    if (!snapshot) {
      settingsPage(
        "Advanced",
        "Loading advanced settings…",
        "sliders",
        [],
      );
      return;
    }
    const settings = snapshot.settings;
    const card = desktopCard(
      "Server Scanning, Code Maps & History",
      `Revision ${snapshot.revision} is also scanner policy generation ${snapshot.scannerPolicyGeneration}; updates invalidate subsequent scans by generation.`,
    );
    card.append(
      element(
        "div",
        "inline-message warning",
        "Ignore and symlink changes can widen repository scanning. Review project root confinement before saving.",
      ),
    );
    const toggles = {
      respectRepoIgnore: typedToggle(
        "Respect .repo_ignore rules",
        settings.respectRepoIgnore,
      ),
      respectCursorIgnore: typedToggle(
        "Respect .cursorignore rules",
        settings.respectCursorIgnore,
      ),
      respectNestedIgnoreFiles: typedToggle(
        "Respect nested ignore files",
        settings.respectNestedIgnoreFiles,
      ),
      followSymbolicLinks: typedToggle(
        "Follow symbolic links",
        settings.followSymbolicLinks,
      ),
      showEmptyFolders: typedToggle(
        "Show empty folders",
        settings.showEmptyFolders,
      ),
      codeMapsEnabled: typedToggle(
        "Enable Code Maps",
        settings.codeMapsEnabled,
      ),
    };
    Object.entries(toggles).forEach(([key, toggle]) =>
      card.append(
        desktopRow(
          toggle.input.getAttribute("aria-label"),
          key === "codeMapsEnabled"
            ? "Disabling rejects code-map generation and suppresses tool admission."
            : "Used when RepoPrompt scans project files.",
          toggle.toggle,
        ),
      ),
    );
    const history = document.createElement("input");
    history.type = "number";
    history.min = "0";
    history.max = "1440";
    history.step = "1";
    history.value = String(settings.historyIdleThresholdMinutes);
    history.setAttribute("aria-label", "Default history idle threshold");
    const globalIgnoreDefaults = document.createElement("textarea");
    globalIgnoreDefaults.rows = 6;
    globalIgnoreDefaults.value =
      settings.globalIgnoreDefaults === undefined
        ? ""
        : String(settings.globalIgnoreDefaults);
    globalIgnoreDefaults.setAttribute("aria-label", "Global ignore defaults");
    card.append(
      desktopRow(
        "History Idle Threshold",
        "Default idle threshold for history queries, from 0 to 1440 minutes.",
        history,
      ),
      desktopRow(
        "Global ignore defaults",
        "App-wide gitignore-style patterns. Leave empty to disable global defaults.",
        globalIgnoreDefaults,
      ),
    );
    const packaging = desktopCard(
      "Prompt Packaging",
      "Live-read by materialized context, Oracle/copy packaging, and MCP app_settings. There is no separate Copy Prompt Order page.",
    );
    const fileEdit = typedSelect(
      "File edit format",
      [
        ["Diff", "Diff"],
        ["Whole", "Whole"],
        ["None", "None"],
      ],
      settings.fileEditFormat || "Diff",
    );
    const pathDisplay = typedSelect(
      "File path display",
      [
        ["Full", "Full"],
        ["Relative", "Relative"],
      ],
      settings.filePathDisplayOption || "Full",
    );
    const temperatureEnabled = typedToggle(
      "Set model temperature",
      settings.setModelTemperature !== false,
    );
    const temperature = document.createElement("input");
    temperature.type = "number";
    temperature.min = "0";
    temperature.max = "2";
    temperature.step = "0.1";
    temperature.value = String(settings.modelTemperature ?? 0);
    temperature.setAttribute("aria-label", "Model temperature");
    const planning = document.createElement("textarea");
    planning.rows = 4;
    planning.value = settings.customPlanningPrompt || "";
    planning.setAttribute("aria-label", "Custom planning prompt");
    const sectionOrder = document.createElement("input");
    sectionOrder.type = "text";
    sectionOrder.value =
      settings.promptSectionsOrder ||
      '["fileMap","fileContents","gitDiff","metaPrompts","userInstructions"]';
    sectionOrder.setAttribute("aria-label", "Prompt sections order");
    const duplicate = typedToggle(
      "Duplicate user instructions at top",
      settings.duplicateUserInstructionsAtTop === true,
    );
    const datetime = typedToggle(
      "Include datetime in user instructions",
      settings.includeDatetimeInUserInstructions === true,
    );
    packaging.append(
      desktopRow(
        "File edit format",
        "Diff, Whole, or None. Missing or invalid raw live-reads Diff.",
        fileEdit,
      ),
      desktopRow(
        "File path display",
        "Full uses the root path; Relative uses the logical path.",
        pathDisplay,
      ),
      desktopRow(
        "Set model temperature",
        "Off, or a stored 0.0, omits temperature from provider payloads.",
        temperatureEnabled.toggle,
      ),
      desktopRow("Model temperature", "0–2. Live-read when the enable flag is on.", temperature),
      desktopRow(
        "Custom planning prompt",
        "Empty live-reads the built-in Architect fallback.",
        planning,
      ),
      desktopRow(
        "Prompt sections order",
        "JSON array containing each prompt section once. Invalid or incomplete values use the default order.",
        sectionOrder,
      ),
      desktopRow(
        "Duplicate user instructions at top",
        "Prepends user instructions and still emits them in section order.",
        duplicate.toggle,
      ),
      desktopRow(
        "Include datetime in user instructions",
        'Adds date="yyyy-MM-dd\'T\'HH:mm" when packaging user instructions.',
        datetime.toggle,
      ),
    );
    const save = element("button", "primary-button", "Save Advanced Settings");
    save.type = "button";
    save.addEventListener("click", () => {
      const historyIdleThresholdMinutes = Number(history.value);
      if (
        !Number.isInteger(historyIdleThresholdMinutes) ||
        historyIdleThresholdMinutes < 0 ||
        historyIdleThresholdMinutes > 1440
      ) {
        toast(
          "History idle threshold must be an integer from 0 through 1440.",
          true,
        );
        return;
      }
      const modelTemperature = Number(temperature.value);
      if (
        !Number.isFinite(modelTemperature) ||
        modelTemperature < 0 ||
        modelTemperature > 2
      ) {
        toast("Model temperature must be a number from 0 through 2.", true);
        return;
      }
      mutateDomain(
        "advanced",
        save,
        () =>
          api("api/v1/settings/advanced", {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              settings: {
                ...settings,
                ...Object.fromEntries(
                  Object.entries(toggles).map(([key, toggle]) => [
                    key,
                    toggle.input.checked,
                  ]),
                ),
                codeMapsGloballyDisabled: !toggles.codeMapsEnabled.input.checked,
                historyIdleThresholdMinutes,
                globalIgnoreDefaults: globalIgnoreDefaults.value,
                fileEditFormat: fileEdit.value,
                customPlanningPrompt: planning.value,
                modelTemperature,
                setModelTemperature: temperatureEnabled.input.checked,
                promptSectionsOrder: sectionOrder.value,
                duplicateUserInstructionsAtTop: duplicate.input.checked,
                filePathDisplayOption: pathDisplay.value,
                includeDatetimeInUserInstructions: datetime.input.checked,
              },
            }),
          }),
        (value) => {
          state.typedSettings.advanced = value;
        },
      );
    });
    packaging.append(save);
    settingsPage(
      "Advanced",
      "Configure scanning, history, and prompt packaging.",
      "sliders",
      [card, packaging],
    );
  }

  function renderMCPServer() {
    const tools = state.bootstrap?.tools || [];
    const snapshot = state.typedSettings.showModelPresets;
    if (!snapshot) {
      settingsPage("MCP Server", "Loading MCP server settings…", "server", []);
      return;
    }
    const status = desktopCard(
      "MCP Server",
      "Live status and settings for RepoPrompt's shared MCP service.",
    );
    const toolsLink = element(
      "a",
      "secondary-button compact-link",
      `${tools.length} tools`,
    );
    toolsLink.href = "#settings/mcp-tools";
    toolsLink.dataset.routeLink = "";
    const presets = typedToggle(
      "Use Oracle Model Presets for MCP",
      !!snapshot.settings.showModelPresets,
    );
    presets.input.addEventListener("change", () =>
      saveShowModelPresets(snapshot, presets.input.checked, presets.input),
    );
    status.append(
      desktopRow(
        "Server Status",
        "Shared by connected agents.",
        element(
          "span",
          state.online ? "required-pill" : "connection-badge attention",
          state.online ? "Running" : "Unavailable",
        ),
      ),
      desktopRow(
        "Use Oracle Model Presets for MCP",
        "When off, list_models omits named presets and ask_oracle / oracle_send fail-closed on preset IDs.",
        presets.toggle,
      ),
      desktopRow(
        "Tools",
        "Available MCP tools.",
        toolsLink,
      ),
      desktopRow(
        "Context Builder route",
        "The context_builder tool owns shared discovery runs.",
        element("code", "read-only-value", "context_builder"),
      ),
    );
    settingsPage(
      "MCP Server",
      "Manage RepoPrompt's shared MCP service.",
      "server",
      [status],
    );
  }

  function renderMCPTools() {
    const tools = state.bootstrap?.tools || [];
    const snapshot = state.typedSettings.mcpDisabledTools;
    if (!snapshot) {
      settingsPage("Tools", "Loading MCP tool availability…", "sliders", []);
      return;
    }
    const disabled = new Set(snapshot.settings.disabledTools || []);
    const enabledCount = tools.filter((tool) => !disabled.has(tool.name)).length;
    const card = desktopCard(
      "Advertised MCP Tools",
      "Choose which MCP tools connected clients can use.",
    );
    const toolbar = element("div", "tool-catalog-toolbar");
    const searchLabel = element("label", "tool-search-field");
    searchLabel.append(element("span", "sr-only", "Search MCP tools"));
    const search = document.createElement("input");
    search.type = "search";
    search.placeholder = "Search tools";
    search.setAttribute("aria-label", "Search MCP tools");
    searchLabel.append(search);
    const count = element("span", "tool-count");
    count.setAttribute("role", "status");
    toolbar.append(searchLabel, count);
    const list = element("div", "tool-catalog-list");

    function renderToolList() {
      const query = search.value.trim().toLowerCase();
      const filtered = tools.filter((tool) =>
        [tool.name, tool.scope, tool.capability, tool.admissionClass]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query)),
      );
      count.textContent = `${filtered.length} of ${tools.length} advertised`;
      list.replaceChildren();
      filtered.forEach((tool) => {
        const row = element("div", "tool-catalog-row");
        const copy = element("div", "tool-catalog-copy");
        copy.append(
          element("code", "tool-name", tool.name),
          element(
            "small",
            "",
            `${humanize(tool.capability)} capability · ${humanize(tool.admissionClass)} admission`,
          ),
        );
        const toggle = typedToggle(tool.name, !disabled.has(tool.name));
        toggle.input.addEventListener("change", () => {
          const next = new Set(disabled);
          if (toggle.input.checked) next.delete(tool.name);
          else next.add(tool.name);
          saveMCPDisabledTools(snapshot, next, toggle.input);
        });
        const badges = element("div", "tool-badges");
        badges.append(
          element("span", "required-pill", humanize(tool.scope)),
          toggle.toggle,
        );
        row.append(copy, badges);
        list.append(row);
      });
      if (!filtered.length)
        list.append(
          element(
            "p",
            "empty-inline",
            "No advertised tools match this search.",
          ),
        );
    }
    search.addEventListener("input", renderToolList);
    renderToolList();
    card.append(toolbar, list);
    settingsPage(
      "Tools",
      "Search and toggle every MCP tool advertised by the shared RepoPrompt runtime.",
      "sliders",
      [card],
      recommendation(
        "check",
        `${enabledCount} of ${tools.length} enabled`,
        "Disabled tools are removed from the catalog and cannot be invoked.",
      ),
    );
  }

  function renderWorkspaceApprovals() {
    const snapshot = state.typedSettings.workspaceApprovals;
    if (!snapshot) {
      settingsPage(
        "Workspace Approvals",
        "Loading workspace approvals…",
        "shield",
        [],
      );
      return;
    }
    const settings = snapshot.settings || {};
    const operations = new Set(settings.autoApproveOperations || []);
    const master = desktopCard(
      "Global Settings",
      "Approvals for RepoPrompt workspace operations (creating folders, deleting workspaces, etc.). CLI agent and sub-agent permissions are configured in Agent Permissions.",
    );
    const autoApproveAll = typedToggle(
      "Auto-approve All Operations",
      !!settings.autoApproveAll,
    );
    autoApproveAll.input.addEventListener("change", () =>
      saveWorkspaceApprovals(
        snapshot,
        (next) => {
          next.autoApproveAll = autoApproveAll.input.checked;
        },
        autoApproveAll.input,
      ),
    );
    master.append(
      desktopRow(
        "Auto-approve All Operations",
        "Skip approval prompts for all workspace operations from all clients.",
        autoApproveAll.toggle,
      ),
    );
    if (settings.autoApproveAll) {
      master.append(
        element(
          "p",
          "empty-inline",
          "All workspace operations will be automatically approved without confirmation.",
        ),
      );
    }
    const perOp = desktopCard(
      "Operation Permissions",
      "Auto-approve specific operations. Other operations still require approval unless allowed for a trusted client.",
    );
    workspaceApprovalOperations.forEach(([value, title, detail]) => {
      const toggle = typedToggle(title, operations.has(value));
      toggle.input.disabled = !!settings.autoApproveAll;
      toggle.input.addEventListener("change", () =>
        saveWorkspaceApprovals(
          snapshot,
          (next) => {
            const listed = new Set(next.autoApproveOperations);
            if (toggle.input.checked) listed.add(value);
            else listed.delete(value);
            next.autoApproveOperations = [...listed];
          },
          toggle.input,
        ),
      );
      perOp.append(desktopRow(title, detail, toggle.toggle));
    });
    const trusted = desktopCard(
      "Trusted Clients",
      'Clients that received Always Allow appear here. Chat-server is not a trusted client by default.',
    );
    const policies = Object.values(settings.clientPolicies || {}).sort((left, right) =>
      String(left.clientID || "").localeCompare(String(right.clientID || "")),
    );
    if (policies.length) {
      const reset = element("button", "secondary-button", "Reset All");
      reset.type = "button";
      reset.addEventListener("click", async () => {
        const confirmed = await confirmAction({
          title: "Reset All Trusted Clients?",
          message:
            "This will remove all per-client auto-approve settings. You'll be prompted for approval on future operations.",
          label: "Reset",
          returnFocus: reset,
        });
        if (!confirmed) return;
        saveWorkspaceApprovals(
          snapshot,
          (next) => {
            next.clientPolicies = {};
          },
          reset,
        );
      });
      trusted.append(reset);
      policies.forEach((policy) => {
        const allowed = [...(policy.allowedOperations || [])].join(", ") || "none";
        const revoke = element("button", "secondary-button", "Revoke");
        revoke.type = "button";
        revoke.setAttribute("aria-label", `Revoke ${policy.clientID}`);
        revoke.addEventListener("click", () =>
          saveWorkspaceApprovals(
            snapshot,
            (next) => {
              delete next.clientPolicies[policy.clientID];
            },
            revoke,
          ),
        );
        trusted.append(
          desktopRow(
            policy.clientID || "unknown-client",
            `Always Allow: ${allowed}`,
            revoke,
          ),
        );
      });
    } else {
      trusted.append(
        element(
          "p",
          "empty-inline",
          'No Trusted Clients. When you approve operations with "Always Allow", clients will appear here.',
        ),
      );
    }
    settingsPage(
      "Workspace Approvals",
      "Control automatic approval of workspace-management operations.",
      "shield",
      [master, perOp, trusted],
    );
  }

  function renderTypedModelPresets() {
    const snapshot = state.typedSettings.modelPresets;
    if (!snapshot) {
      settingsPage("Model Presets", "Loading model presets…", "model", []);
      return;
    }
    const presetsGate = state.typedSettings.showModelPresets;
    const card = desktopCard(
      "Oracle Model Presets",
      presetsGate?.settings?.showModelPresets
        ? "These presets are available to list_models, ask_oracle, and oracle_send."
        : "Enable Oracle Model Presets on the MCP Server page to make named presets available to MCP clients.",
    );
    const form = element("form", "typed-settings-form");
    const rowsContainer = element("div", "model-preset-rows");
    const rows = [];
    const emptyState = element(
      "p",
      "empty-inline",
      "No model presets configured. Create one from the advertised provider catalog.",
    );
    function syncPresetRows() {
      rows.forEach((row, index) => {
        row.earlier.disabled = index === 0;
        row.later.disabled = index === rows.length - 1;
        rowsContainer.append(row.details);
      });
      if (rows.length === 0) {
        if (!emptyState.isConnected) rowsContainer.append(emptyState);
      } else {
        emptyState.remove();
      }
    }
    function appendPreset(preset) {
      const details = element("details", "model-preset-row");
      const summary = element("summary", "workflow-editor-summary");
      summary.append(
        element("strong", "", preset.name || "New Preset"),
        element(
          "span",
          preset.enabled ? "connection-badge connected" : "connection-badge",
          preset.enabled ? "Enabled" : "Disabled",
        ),
      );
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 128;
      name.value = preset.name;
      name.setAttribute("aria-label", "Model preset name");
      const description = document.createElement("textarea");
      description.rows = 3;
      description.maxLength = 1024;
      description.value = preset.description || "";
      description.setAttribute(
        "aria-label",
        `Description for ${preset.name || "preset"}`,
      );
      const target = typedSelect(
        `Model target for ${preset.name || "preset"}`,
        agentTargetChoices().filter(([value]) => value),
        agentTargetValue(preset.target),
      );
      const enabled = typedToggle(
        `Enable ${preset.name || "preset"}`,
        preset.enabled,
      );
      const availability = element("fieldset", "preset-availability");
      availability.append(element("legend", "", "Available modes"));
      const modeInputs = {};
      ["chat", "plan", "review"].forEach((mode) => {
        const label = element("label", "check-row");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.checked = preset.availability.includes(mode);
        modeInputs[mode] = input;
        label.append(input, document.createTextNode(humanize(mode)));
        availability.append(label);
      });
      const actions = element("div", "workflow-inline-actions");
      const earlier = element("button", "secondary-button", "Move Earlier");
      earlier.type = "button";
      const later = element("button", "secondary-button", "Move Later");
      later.type = "button";
      const remove = element("button", "danger-button", "Delete");
      remove.type = "button";
      const record = {
        presetID: preset.presetID,
        name,
        description,
        target,
        enabled: enabled.input,
        modeInputs,
        details,
        earlier,
        later,
      };
      earlier.addEventListener("click", () => {
        const index = rows.indexOf(record);
        if (index <= 0) return;
        [rows[index - 1], rows[index]] = [rows[index], rows[index - 1]];
        syncPresetRows();
      });
      later.addEventListener("click", () => {
        const index = rows.indexOf(record);
        if (index < 0 || index >= rows.length - 1) return;
        [rows[index], rows[index + 1]] = [rows[index + 1], rows[index]];
        syncPresetRows();
      });
      remove.addEventListener("click", async () => {
        if (
          !(await confirmAction({
            title: "Delete model preset?",
            message: `Delete ${name.value.trim() || preset.name || "this model preset"}?`,
            label: "Delete",
            returnFocus: remove,
          }))
        )
          return;
        const index = rows.indexOf(record);
        if (index < 0) return;
        rows.splice(index, 1);
        details.remove();
        syncPresetRows();
      });
      actions.append(earlier, later, remove);
      details.append(
        summary,
        desktopRow("Name", "Unique display and persisted name.", name),
        description,
        desktopRow("Provider / Model", "Exact advertised target.", target),
        desktopRow(
          "Enabled",
          "Available to MCP model resolution.",
          enabled.toggle,
        ),
        availability,
        actions,
      );
      rows.push(record);
      syncPresetRows();
    }
    rowsContainer.append(emptyState);
    snapshot.presets.forEach(appendPreset);
    syncPresetRows();
    const add = element("button", "secondary-button", "Add Preset");
    add.type = "button";
    add.addEventListener("click", () => {
      if (rows.length >= 100) {
        toast("Model Presets supports at most 100 entries.", true);
        return;
      }
      const firstTarget =
        agentTargetChoices().find(([value]) => value)?.[0] || "";
      if (!firstTarget) {
        toast("No advertised model target is available.", true);
        return;
      }
      appendPreset({
        presetID:
          window.crypto?.randomUUID?.() ||
          `00000000-0000-4000-8000-${String(Date.now()).slice(-12).padStart(12, "0")}`,
        name: "New Preset",
        description: null,
        target: agentTargetFromValue(firstTarget),
        availability: ["chat", "plan", "review"],
        enabled: true,
      });
    });
    const save = element("button", "primary-button", "Save Model Presets");
    save.type = "submit";
    const formActions = element(
      "div",
      "workflow-inline-actions model-preset-actions",
    );
    formActions.append(add, save);
    form.append(rowsContainer, formActions);
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const missingAvailability = rows.find(
        (row) => !Object.values(row.modeInputs).some((input) => input.checked),
      );
      if (missingAvailability) {
        missingAvailability.details.open = true;
        toast(
          "Each model preset must be available in at least one mode.",
          true,
        );
        return;
      }
      mutateDomain(
        "modelPresets",
        save,
        () =>
          api("api/v1/settings/model-presets", {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: snapshot.revision,
              presets: rows.map((row, order) => ({
                presetID: row.presetID,
                name: row.name.value.trim(),
                description: row.description.value.trim() || null,
                target: agentTargetFromValue(row.target.value),
                availability: Object.entries(row.modeInputs)
                  .filter(([, input]) => input.checked)
                  .map(([mode]) => mode),
                enabled: row.enabled.checked,
                order,
              })),
            }),
          }),
        (value) => {
          state.typedSettings.modelPresets = value;
        },
      );
    });
    card.append(form);
    settingsPage(
      "Model Presets",
      "Manage named Oracle model routes and their chat, plan, and review availability.",
      "model",
      [card],
    );
  }

  function acceptsPersistedBaseURL(providerID) {
    return ["openAIAPI", "customOpenAICompatible", "azure", "ollama"].includes(
      providerID,
    );
  }

  function acceptsPersistedAPIVersion(providerID) {
    return ["openAIAPI", "customOpenAICompatible", "azure"].includes(providerID);
  }

  function acceptsCustomHeaders(providerID) {
    return ["openRouter", "customOpenAICompatible", "azure"].includes(
      providerID,
    );
  }

  function dedicatedDirectProviderPage(providerID) {
    return ["openRouter", "customOpenAICompatible"].includes(providerID);
  }

  function parseJSONStringMap(raw, label) {
    const parsed = JSON.parse(raw || "{}");
    if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
      throw new Error(`${label} must be a JSON object.`);
    }
    const entries = Object.entries(parsed);
    if (entries.length > 16) {
      throw new Error(`At most 16 ${label.toLowerCase()} entries are allowed.`);
    }
    if (entries.some(([, value]) => typeof value !== "string")) {
      throw new Error(`Every ${label.toLowerCase()} value must be a string.`);
    }
    return parsed;
  }

  function parseEnabledModels(raw) {
    const text = String(raw || "").trim();
    if (!text) return [];
    if (text.startsWith("[")) {
      const parsed = JSON.parse(text);
      if (
        !Array.isArray(parsed) ||
        parsed.some((value) => typeof value !== "string")
      ) {
        throw new Error("Enabled models must be a JSON array of strings.");
      }
      return parsed.map((value) => value.trim()).filter(Boolean);
    }
    return text
      .split(/[\n,]/)
      .map((value) => value.trim())
      .filter(Boolean);
  }

  function baseURLCopy(providerID) {
    switch (providerID) {
      case "openAIAPI":
        return [
          "Optional Public HTTPS Base URL",
          "Empty keeps api.openai.com. HTTPS only; private, metadata, and credential-bearing URLs fail closed unless the local-URL escape is enabled.",
        ];
      case "azure":
        return [
          "Azure Resource URL",
          "Public HTTPS Azure resource endpoint. The API key stays in the vault; this field is not a credential bag.",
        ];
      case "ollama":
        return [
          "Ollama URL",
          "Desktop default is http://localhost:11434. Persist is allowed; execute still requires REPOPROMPT_ALLOW_LOCAL_PROVIDER_URLS=1.",
        ];
      default:
        return [
          "Public HTTPS Base URL",
          "HTTPS port 443 only; DNS is re-resolved and pinned for every request. Private, local, metadata, mixed, redirecting, and credential-bearing endpoints fail closed.",
        ];
    }
  }

  function directProviderCard(provider) {
    const configuration =
      state.typedSettings.directConfigurations[provider.providerID];
    const card = desktopCard(provider.displayName, provider.summary);
    card.dataset.providerId = provider.providerID;
    if (configuration) {
      const form = element("form", "typed-settings-form direct-provider-form");
      const persistBaseURL = acceptsPersistedBaseURL(provider.providerID);
      const persistAPIVersion = acceptsPersistedAPIVersion(provider.providerID);
      const persistHeaders = acceptsCustomHeaders(provider.providerID);
      const persistAllowlist = [
        "openRouter",
        "customOpenAICompatible",
      ].includes(provider.providerID);
      const baseURL = document.createElement("input");
      baseURL.type = provider.providerID === "ollama" ? "text" : "url";
      baseURL.value = configuration.baseURL || "";
      baseURL.placeholder =
        provider.providerID === "ollama"
          ? "http://localhost:11434"
          : "https://provider.example/v1";
      baseURL.setAttribute("aria-label", `${provider.displayName} base URL`);
      const apiVersion = document.createElement("input");
      apiVersion.type = "text";
      apiVersion.maxLength = 64;
      apiVersion.value = configuration.apiVersion || "";
      apiVersion.placeholder = "Optional API version";
      apiVersion.setAttribute(
        "aria-label",
        `${provider.displayName} API version`,
      );
      const preferredModel = document.createElement("input");
      preferredModel.type = "text";
      preferredModel.maxLength = 256;
      preferredModel.value = configuration.preferredModel || "";
      preferredModel.placeholder = "Provider default / auto-detect";
      preferredModel.setAttribute(
        "aria-label",
        `${provider.displayName} preferred model`,
      );
      const maximum = document.createElement("input");
      maximum.type = "number";
      maximum.min = "0";
      maximum.max = "65536";
      maximum.step = "1";
      maximum.value = String(configuration.maximumOutputTokens ?? 0);
      maximum.setAttribute(
        "aria-label",
        `${provider.displayName} maximum output tokens`,
      );
      const headers = document.createElement("textarea");
      headers.rows = 4;
      headers.value = JSON.stringify(
        configuration.customHeaders || {},
        null,
        2,
      );
      headers.setAttribute(
        "aria-label",
        `${provider.displayName} custom headers`,
      );
      const enabledModels = document.createElement("textarea");
      enabledModels.rows = 3;
      enabledModels.value = (configuration.enabledModels || []).join("\n");
      enabledModels.placeholder = "One model ID per line";
      enabledModels.setAttribute(
        "aria-label",
        `${provider.displayName} enabled models`,
      );
      const includeDefaultModels = typedToggle(
        `${provider.displayName} include default models`,
        configuration.includeDefaultModels !== false,
      );
      const useCustomSettings = typedToggle(
        `${provider.displayName} use custom settings`,
        configuration.useCustomSettings !== false,
      );
      const includeContentTypeHeader = typedToggle(
        `${provider.displayName} persist Content-Type header`,
        Boolean(configuration.includeContentTypeHeader),
      );
      const showServiceTierVariants = typedToggle(
        `${provider.displayName} show service-tier variants`,
        Boolean(configuration.showServiceTierVariants),
      );
      if (persistBaseURL) {
        const [label, detail] = baseURLCopy(provider.providerID);
        form.append(desktopRow(label, detail, baseURL));
      }
      if (persistAPIVersion) {
        form.append(
          desktopRow(
            "API Version",
            "Optional path or query version. Empty uses the provider default.",
            apiVersion,
          ),
        );
      }
      form.append(
        desktopRow(
          "Preferred Model",
          "Optional exact catalog ID; empty uses provider selection.",
          preferredModel,
        ),
        desktopRow(
          "Maximum Output Tokens",
          "0 omits the stored limit and uses the Desktop model default. Range is 0 through 65,536.",
          maximum,
        ),
      );
      if (provider.providerID === "openAIAPI") {
        form.append(
          desktopRow(
            "Show Service-Tier Variants",
            "When on, the live catalog keeps Desktop service-tier variants. This is not the leftover openAIServiceTier string bag.",
            showServiceTierVariants.toggle,
          ),
        );
      }
      if (provider.providerID === "openRouter") {
        form.append(
          desktopRow(
            "Use Custom Settings",
            "When off, OpenRouter still sends HTTP-Referer / X-Title and ignores stored tokens and extra headers.",
            useCustomSettings.toggle,
          ),
          desktopRow(
            "Include Default Models",
            "When off, picker and launch are limited to the enabled-model allowlist plus preferred.",
            includeDefaultModels.toggle,
          ),
        );
      }
      if (persistAllowlist) {
        form.append(
          desktopRow(
            "Enabled Models",
            "Allowlist IDs, one per line. Preferred is always included. Custom picker/launch is this set only.",
            enabledModels,
          ),
        );
      }
      if (provider.providerID === "customOpenAICompatible") {
        form.append(
          desktopRow(
            "Persist Content-Type Header Flag",
            "Stored only. Live requests stay application/json unless a custom header overrides Content-Type.",
            includeContentTypeHeader.toggle,
          ),
        );
      }
      if (persistHeaders) {
        form.append(
          desktopRow(
            "Custom Headers (JSON)",
            "Authorization, cookies, host/forwarding headers, controls, oversized values, and likely secrets are rejected.",
            headers,
          ),
        );
      }
      form.append(
        desktopRow(
          "Content-Type",
          "Fixed by the runtime; not a credential-bearing override.",
          element("span", "read-only-value", "application/json"),
        ),
      );
      const save = element(
        "button",
        "primary-button",
        "Save Runtime Configuration",
      );
      save.type = "submit";
      const editable = [
        baseURL,
        apiVersion,
        preferredModel,
        maximum,
        headers,
        enabledModels,
        includeDefaultModels.input,
        useCustomSettings.input,
        includeContentTypeHeader.input,
        showServiceTierVariants.input,
      ];
      if (provider.connection) {
        editable.forEach((control) =>
          setDisabledReason(
            control,
            true,
            "Disconnect the provider before changing runtime configuration.",
          ),
        );
        setDisabledReason(
          save,
          true,
          "Disconnect the provider before changing runtime configuration.",
        );
      }
      form.append(save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        let customHeaders = {};
        let allowlisted = [];
        try {
          customHeaders = persistHeaders
            ? parseJSONStringMap(headers.value, "Headers")
            : {};
          allowlisted = persistAllowlist
            ? parseEnabledModels(enabledModels.value)
            : [];
        } catch (error) {
          toast(error.message, true);
          return;
        }
        const maximumOutputTokens = Number(maximum.value);
        if (
          !Number.isInteger(maximumOutputTokens) ||
          maximumOutputTokens < 0 ||
          maximumOutputTokens > 65536
        ) {
          toast(
            "Maximum output tokens must be an integer from 0 through 65,536.",
            true,
          );
          return;
        }
        mutateDomain(
          "directConfigurations",
          save,
          () =>
            api(
              `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/direct-configuration`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedRevision: configuration.revision,
                  baseURL: persistBaseURL ? baseURL.value.trim() || null : null,
                  preferredModel: preferredModel.value.trim() || null,
                  maximumOutputTokens,
                  customHeaders,
                  contentTypePolicy: "applicationJSON",
                  apiVersion: persistAPIVersion
                    ? apiVersion.value.trim() || null
                    : null,
                  enabledModels: allowlisted,
                  includeDefaultModels: includeDefaultModels.input.checked,
                  useCustomSettings: useCustomSettings.input.checked,
                  includeContentTypeHeader:
                    includeContentTypeHeader.input.checked,
                  showServiceTierVariants:
                    showServiceTierVariants.input.checked,
                }),
              },
            ),
          (value) => {
            state.typedSettings.directConfigurations[provider.providerID] =
              value;
          },
        );
      });
      card.append(form);
    }
    if (provider.authentication?.authenticated) {
      card.append(connectedProviderSummary(provider));
    } else {
      const direct = (provider.capabilities.authenticationMethods || []).filter(
        (method) => directAuthenticationMethods.has(method),
      );
      if (direct.length) card.append(credentialForm(provider, direct));
      else
        card.append(
          element(
            "p",
            "empty-inline",
            "No write-only browser credential method is advertised by the completed backend contract.",
          ),
        );
    }
    return card;
  }

  function renderTypedAPIProviders() {
    const providers = orderedProviders().filter(
      (provider) =>
        provider.category === "apiProvider" &&
        provider.deploymentAllowed &&
        !dedicatedDirectProviderPage(provider.providerID),
    );
    const cards = providers.map(directProviderCard);
    if (!cards.length)
      cards.push(
        desktopCard(
          "No API providers available",
          "This RepoPrompt installation does not currently offer a direct API provider.",
        ),
      );
    settingsPage(
      "API Providers",
      "Configure direct API providers for Agent Mode.",
      "cloud",
      cards,
    );
  }

  function renderTypedOpenRouter() {
    const provider = orderedProviders().find(
      (candidate) =>
        candidate.providerID === "openRouter" && candidate.deploymentAllowed,
    );
    const cards = provider
      ? [directProviderCard(provider)]
      : [
          desktopCard(
            "OpenRouter unavailable",
            "OpenRouter is not available in this RepoPrompt installation.",
          ),
        ];
    settingsPage(
      "OpenRouter",
      "Configure OpenRouter for Agent Mode.",
      "cloud",
      cards,
    );
  }

  function renderTypedCustomAPI() {
    const provider = orderedProviders().find(
      (candidate) =>
        candidate.providerID === "customOpenAICompatible" &&
        candidate.deploymentAllowed,
    );
    const cards = provider
      ? [directProviderCard(provider)]
      : [
          desktopCard(
            "Custom API unavailable",
            "Custom OpenAI-compatible APIs are not available in this RepoPrompt installation.",
          ),
        ];
    settingsPage(
      "Custom API",
      "Configure a custom OpenAI-compatible API for Agent Mode.",
      "sliders",
      cards,
    );
  }

  function renderModelConfig() {
    const catalog = desktopCard(
      "Advertised Model Catalog",
      "Read-only models and option families supplied by the live provider settings service.",
    );
    const list = element("div", "model-config-list");
    orderedProviders().forEach((provider) =>
      (provider.models || []).forEach((model) => {
        const row = element("div", "model-config-row");
        const copy = element("div", "desktop-setting-copy");
        copy.append(
          element("strong", "", model.displayName),
          element("small", "", `${provider.displayName} · ${model.id}`),
        );
        const options = [
          ...(model.reasoningEfforts || []).map(
            (value) => `reasoning:${value}`,
          ),
          ...(model.speedModes || []).map((value) => `speed:${value}`),
          ...(model.serviceTiers || []).map((value) => `tier:${value}`),
        ];
        row.append(
          copy,
          element(
            "span",
            "model-option-summary",
            options.length ? options.join(" · ") : "Provider defaults",
          ),
        );
        list.append(row);
      }),
    );
    if (!list.childElementCount)
      list.append(element("p", "empty-inline", "No models are advertised."));
    catalog.append(list);
    settingsPage(
      "Model Config",
      "Inspect models and capabilities reported by connected providers.",
      "model",
      [catalog],
    );
  }

  function renderManageWorkspaces() {
    const projects = state.bootstrap?.projects || [];
    const cards = [];
    const capabilities = state.bootstrap?.projectSources;
    const createFolder = desktopCard(
      "New Project Folder",
      "Create an ordinary writable folder on this RepoPrompt server. Git is optional.",
    );
    const folderForm = element("form", "typed-settings-form");
    const folderName = document.createElement("input");
    folderName.type = "text";
    folderName.maxLength = 128;
    folderName.placeholder = "Project name";
    folderName.required = true;
    folderName.setAttribute("aria-label", "Project folder name");
    const createFolderButton = element("button", "primary-button", "Create Project");
    createFolderButton.type = "submit";
    folderForm.append(
      desktopRow(
        "Project Name",
        "Also used as the folder name in the server projects directory.",
        folderName,
      ),
      createFolderButton,
    );
    folderForm.addEventListener("submit", (event) => {
      event.preventDefault();
      const operationID = window.crypto?.randomUUID?.();
      const name = folderName.value.trim();
      if (!operationID || !name) {
        toast(
          !operationID
            ? "This browser cannot create secure operation identifiers."
            : "Enter a project name.",
          true,
        );
        return;
      }
      mutateProjects(
        createFolderButton,
        () =>
          api("api/v1/projects", {
            method: "POST",
            body: JSON.stringify({
              operationId: operationID,
              name,
              logicalName: name,
              source: { type: "managedDirectory", name },
            }),
          }),
        "Project created",
      );
    });
    createFolder.append(folderForm);
    cards.push(createFolder);
    if (capabilities?.gitCloneEnabled) {
      const create = desktopCard(
        "Clone Git Repository",
        "Optional: clone a Git repository and use the checkout as a new project folder.",
      );
      const form = element("form", "typed-settings-form");
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 200;
      name.placeholder = "Project name";
      name.setAttribute("aria-label", "Project name");
      const logicalName = document.createElement("input");
      logicalName.type = "text";
      logicalName.maxLength = 128;
      logicalName.placeholder = "Repository name";
      logicalName.setAttribute("aria-label", "Repository name");
      const remote = document.createElement("input");
      remote.type = "url";
      remote.placeholder = "https://github.com/owner/repository.git";
      remote.setAttribute("aria-label", "Git repository URL");
      const ref = document.createElement("input");
      ref.type = "text";
      ref.maxLength = 256;
      ref.value = "main";
      ref.setAttribute("aria-label", "Git branch or ref");
      const submit = element("button", "primary-button", "Create Project");
      submit.type = "submit";
      form.append(
        desktopRow("Project Name", "Shown in Agent Mode.", name),
        desktopRow("Repository Name", "Short name shown for this project root.", logicalName),
        desktopRow("Git Repository", "HTTPS clone URL.", remote),
        desktopRow("Branch or Ref", "Branch, tag, or commit to clone.", ref),
        submit,
      );
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const operationID = window.crypto?.randomUUID?.();
        if (!operationID) {
          toast("This browser cannot create secure operation identifiers.", true);
          return;
        }
        mutateProjects(
          submit,
          () =>
            api("api/v1/projects", {
              method: "POST",
              body: JSON.stringify({
                operationId: operationID,
                name: name.value.trim(),
                logicalName: logicalName.value.trim(),
                source: {
                  type: "gitClone",
                  remote: remote.value.trim(),
                  ref: ref.value.trim(),
                },
              }),
            }),
          "Project created",
        );
      });
      create.append(form);
      cards.push(create);
    }

    const card = desktopCard(
      "Projects",
      "Rename projects, add repositories, or remove projects that are no longer needed.",
    );
    const list = element("div", "workspace-project-list");
    projects.forEach((project) => {
      const roots = project.rootNames || [];
      const details = element("details", "desktop-provider-card workspace-project-editor");
      const summary = document.createElement("summary");
      const copy = element("span", "provider-name");
      copy.append(
        element("strong", "", project.name || project.projectId),
        element("small", "", roots.length ? roots.join(" · ") : "No repositories"),
      );
      summary.append(
        iconNode("folder", "provider-glyph"),
        copy,
        element("span", "required-pill", humanize(project.state)),
        iconNode("chevron"),
      );
      const body = element("div", "desktop-provider-body");
      const renameForm = element("form", "typed-settings-form compact-form");
      const projectName = document.createElement("input");
      projectName.type = "text";
      projectName.maxLength = 200;
      projectName.value = project.name;
      projectName.setAttribute("aria-label", `Project name for ${project.name}`);
      const rename = element("button", "secondary-button", "Save Name");
      rename.type = "submit";
      renameForm.append(
        desktopRow("Project Name", "Shown throughout Agent Mode.", projectName),
        rename,
      );
      renameForm.addEventListener("submit", (event) => {
        event.preventDefault();
        const operationID = window.crypto?.randomUUID?.();
        if (!operationID) {
          toast("This browser cannot create secure operation identifiers.", true);
          return;
        }
        mutateProjects(
          rename,
          () =>
            api(`api/v1/projects/${encodeURIComponent(project.projectId)}`, {
              method: "PATCH",
              body: JSON.stringify({
                operationId: operationID,
                expectedRevision: project.revision,
                name: projectName.value.trim(),
              }),
            }),
          "Project renamed",
        );
      });
      body.append(renameForm);

      if (capabilities?.gitCloneEnabled) {
        const addForm = element("form", "typed-settings-form compact-form");
        const repositoryName = document.createElement("input");
        repositoryName.type = "text";
        repositoryName.maxLength = 128;
        repositoryName.placeholder = "Repository name";
        repositoryName.setAttribute("aria-label", `New repository name for ${project.name}`);
        const repositoryRemote = document.createElement("input");
        repositoryRemote.type = "url";
        repositoryRemote.placeholder = "https://github.com/owner/repository.git";
        repositoryRemote.setAttribute("aria-label", `New Git repository URL for ${project.name}`);
        const repositoryRef = document.createElement("input");
        repositoryRef.type = "text";
        repositoryRef.maxLength = 256;
        repositoryRef.value = "main";
        repositoryRef.setAttribute("aria-label", `New Git branch or ref for ${project.name}`);
        const add = element("button", "secondary-button", "Add Repository");
        add.type = "submit";
        addForm.append(
          element("h3", "desktop-subheading", "Add Repository"),
          desktopRow("Repository Name", "Short name shown for this project root.", repositoryName),
          desktopRow("Git Repository", "HTTPS clone URL.", repositoryRemote),
          desktopRow("Branch or Ref", "Branch, tag, or commit to clone.", repositoryRef),
          add,
        );
        addForm.addEventListener("submit", (event) => {
          event.preventDefault();
          const operationID = window.crypto?.randomUUID?.();
          if (!operationID) {
            toast("This browser cannot create secure operation identifiers.", true);
            return;
          }
          mutateProjects(
            add,
            () =>
              api(
                `api/v1/projects/${encodeURIComponent(project.projectId)}/repositories`,
                {
                  method: "POST",
                  body: JSON.stringify({
                    operationId: operationID,
                    expectedRevision: project.revision,
                    logicalName: repositoryName.value.trim(),
                    remote: repositoryRemote.value.trim(),
                    ref: repositoryRef.value.trim(),
                  }),
                },
              ),
            "Repository added",
          );
        });
        body.append(addForm);
      }

      const remove = element("button", "danger-button subtle", "Remove Project");
      remove.type = "button";
      remove.addEventListener("click", async () => {
        const accepted = await confirmAction({
          title: `Remove ${project.name}?`,
          message: "The project must have no active sessions or worktrees. Managed repository data for this project may be removed.",
          label: "Remove Project",
          returnFocus: remove,
        });
        if (!accepted) return;
        const operationID = window.crypto?.randomUUID?.();
        if (!operationID) {
          toast("This browser cannot create secure operation identifiers.", true);
          return;
        }
        mutateProjects(
          remove,
          () =>
            api(`api/v1/projects/${encodeURIComponent(project.projectId)}`, {
              method: "DELETE",
              body: JSON.stringify({
                operationId: operationID,
                expectedRevision: project.revision,
              }),
            }),
          "Project removed",
        );
      });
      body.append(remove);
      details.append(summary, body);
      list.append(details);
    });
    if (!projects.length)
      list.append(
        element("p", "empty-inline", "No projects are available."),
      );
    card.append(list);
    cards.push(card);
    settingsPage(
      "Manage Workspaces",
      "Create and manage projects available to Agent Mode.",
      "folder",
      cards,
    );
  }

  function renderTypedManagePresets() {
    const snapshot = state.typedSettings.selectionPresets;
    const project = selectedProject();
    const session = selectedSession();
    if (!project || !snapshot) {
      const empty = desktopCard(
        "No Active Project",
        "Choose a project before managing its selection presets.",
      );
      settingsPage(
        "Manage Presets",
        "Manage named file-selection presets for the active server project.",
        "listStar",
        [empty],
      );
      return;
    }
    const card = desktopCard(
      `${project.name} Selection Presets`,
      "Save and reuse file selections for this project.",
    );
    const list = element("div", "selection-preset-list");
    function orderedIDsWithMove(presetID, delta) {
      const ids = snapshot.presets.map((preset) => preset.presetID);
      const index = ids.indexOf(presetID);
      const next = index + delta;
      if (index < 0 || next < 0 || next >= ids.length) return null;
      [ids[index], ids[next]] = [ids[next], ids[index]];
      return ids;
    }
    snapshot.presets.forEach((preset, index) => {
      const row = element("section", "selection-preset-row");
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 256;
      name.value = preset.name;
      name.setAttribute("aria-label", `Preset name for ${preset.name}`);
      const actions = element("div", "workflow-inline-actions");
      const rename = element("button", "secondary-button", "Save Name");
      rename.type = "button";
      rename.addEventListener("click", () =>
        mutateDomain(
          "selectionPresets",
          rename,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/${encodeURIComponent(preset.presetID)}`,
              {
                method: "PATCH",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  expectedRowRevision: preset.rowRevision,
                  name: name.value.trim(),
                  entries: preset.entries,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        ),
      );
      const apply = element("button", "primary-button", "Apply to Session");
      apply.type = "button";
      const selection = session
        ? state.typedSettings.selections[session.sessionId]
        : null;
      if (!session || !selection) {
        setDisabledReason(
          apply,
          true,
          "Select a session with a loaded selection before applying a preset.",
        );
      } else {
        apply.addEventListener("click", () =>
          mutateDomain(
            "selectionPresets",
            apply,
            () =>
              api(
                `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/apply`,
                {
                  method: "POST",
                  body: JSON.stringify({
                    presetID: preset.presetID,
                    expectedCollectionRevision: snapshot.revision,
                    sessionID: session.sessionId,
                    expectedSelectionRevision: selection.revision,
                  }),
                },
              ),
            (value) => {
              state.typedSettings.selections[session.sessionId] = value;
            },
          ),
        );
      }
      const earlier = element("button", "secondary-button", "Move Earlier");
      earlier.type = "button";
      earlier.disabled = index === 0;
      earlier.addEventListener("click", () => {
        const ids = orderedIDsWithMove(preset.presetID, -1);
        if (!ids) return;
        mutateDomain(
          "selectionPresets",
          earlier,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/reorder`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  orderedPresetIDs: ids,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      const later = element("button", "secondary-button", "Move Later");
      later.type = "button";
      later.disabled = index === snapshot.presets.length - 1;
      later.addEventListener("click", () => {
        const ids = orderedIDsWithMove(preset.presetID, 1);
        if (!ids) return;
        mutateDomain(
          "selectionPresets",
          later,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/reorder`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  orderedPresetIDs: ids,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      const remove = element("button", "danger-button", "Delete");
      remove.type = "button";
      remove.addEventListener("click", async () => {
        if (
          !(await confirmAction({
            title: "Delete selection preset?",
            message: `Delete ${preset.name}? Active selections are not changed.`,
            label: "Delete",
            returnFocus: remove,
          }))
        )
          return;
        mutateDomain(
          "selectionPresets",
          remove,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/${encodeURIComponent(preset.presetID)}`,
              {
                method: "DELETE",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  expectedRowRevision: preset.rowRevision,
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      actions.append(rename, apply, earlier, later, remove);
      row.append(
        name,
        element(
          "small",
          "scope-footnote",
          `${preset.entries.length} selection entr${preset.entries.length === 1 ? "y" : "ies"} · row revision ${preset.rowRevision}`,
        ),
        actions,
      );
      list.append(row);
    });
    if (!snapshot.presets.length) {
      list.append(
        element(
          "p",
          "empty-inline",
          "No named selection presets exist for this project.",
        ),
      );
    }
    card.append(list);
    const capture = desktopCard(
      "Capture Current Session",
      "Save the currently selected session files as a new named project preset.",
    );
    if (session && state.typedSettings.selections[session.sessionId]) {
      const selection = state.typedSettings.selections[session.sessionId];
      const form = element("form", "typed-settings-form compact-form");
      const name = document.createElement("input");
      name.type = "text";
      name.maxLength = 256;
      name.placeholder = "Preset name";
      name.setAttribute("aria-label", "New selection preset name");
      const save = element("button", "primary-button", "Capture Preset");
      save.type = "submit";
      if (snapshot.presets.length >= 100) {
        [name, save].forEach((control) =>
          setDisabledReason(
            control,
            true,
            "The server supports at most 100 named selection presets per project.",
          ),
        );
      }
      form.append(name, save);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        mutateDomain(
          "selectionPresets",
          save,
          () =>
            api(
              `api/v1/projects/${encodeURIComponent(project.projectId)}/selection-presets/capture`,
              {
                method: "POST",
                body: JSON.stringify({
                  expectedCollectionRevision: snapshot.revision,
                  sessionID: session.sessionId,
                  expectedSelectionRevision: selection.revision,
                  name: name.value.trim(),
                }),
              },
            ),
          (value) => {
            state.typedSettings.selectionPresets = value;
          },
        );
      });
      capture.append(form);
    } else {
      capture.append(
        element(
          "p",
          "empty-inline",
          "Select an existing session before capturing a preset.",
        ),
      );
    }
    settingsPage(
      "Manage Presets",
      "Manage project-scoped named file selections, not Agent Workflows or prompt presets.",
      "listStar",
      [card, capture],
    );
  }

  function liveRouteAssignment(target) {
    return state.typedSettings.agentModels?.effectiveProfile?.[target] || null;
  }

  function liveRouteStatus(target) {
    const assigned = liveRouteAssignment(target);
    if (!assigned) {
      return target === "oracle" || target === "contextBuilder"
        ? "Unconfigured"
        : "Tracks recommendation";
    }
    const provider = orderedProviders().find(
      (candidate) => candidate.providerID === assigned.providerID,
    );
    return `${provider?.displayName || assigned.providerID}${assigned.modelID ? ` · ${assigned.modelID}` : ""}${assigned.reasoningEffort ? ` · ${humanize(assigned.reasoningEffort)}` : ""}`;
  }

  function liveRouteDetail(target) {
    if (target === "oracle" || target === "contextBuilder") {
      return "Must be assigned before it can run.";
    }
    return "Empty tracks the recommendation. An explicit pick stays stored.";
  }

  function liveAgentModelsStatus() {
    const snapshot = state.typedSettings.agentModels;
    if (!snapshot) return "Loading";
    const profile = snapshot.effectiveProfile || {};
    if (profile.oracle || profile.contextBuilder) return liveRouteStatus("oracle");
    return orderedProviders().some(isConnectedProvider)
      ? "Recommendations ready"
      : "Connect a CLI provider";
  }

  function liveCodexPermissionLevel(codex) {
    if (!codex) return "Auto Review";
    if (codex.sandboxMode === "read-only") return "Read Only";
    if (codex.sandboxMode === "danger-full-access") return "Full Access";
    return codex.approvalReviewer === "auto-review"
      ? "Auto Review"
      : "Default Permission";
  }

  function liveSandboxLabel(mode) {
    return (
      {
        "read-only": "Read Only",
        "workspace-write": "Workspace Write",
        "danger-full-access": "Full Access",
      }[mode] || mode
    );
  }

  function liveClaudePermissionLabel(mode) {
    return (
      {
        default: "Require Approval",
        acceptEdits: "Auto-Approve Edits",
        auto: "Auto",
        bypassPermissions: "Full Access",
      }[mode] || mode
    );
  }

  function livePromptDeliveryLabel(mode) {
    return (
      {
        nativeSystemPrompt: "Replace System Prompt",
        userMessageXMLWithEmptySystemPrompt: "User Message (No Native)",
        userMessageXML: "User Message (Keep Native)",
      }[mode] || "Replace System Prompt"
    );
  }

  function liveManagedPermissionLabel(providerID) {
    const settings = state.typedSettings.directAgentPermissions?.settings;
    const level =
      providerID === "cursorACP"
        ? settings?.cursor?.permissionLevel
        : settings?.openCode?.permissionLevel;
    return level === "fullAccess" ? "Full Access" : "Managed Default";
  }

  function liveDirectAgentStatus() {
    const settings = state.typedSettings.directAgentPermissions?.settings;
    if (!settings) return "Loading";
    return `Codex ${liveSandboxLabel(settings.codex.sandboxMode)} · ${liveCodexPermissionLevel(settings.codex)}`;
  }

  function liveSubagentStatus() {
    const policy = state.typedSettings.subagentPermissions?.settings?.policy;
    if (policy === "safeManaged") return "Safe Managed";
    if (policy === "inheritProviderSettings") return "Inherit";
    if (policy === "custom") return "Custom";
    return "Editable";
  }

  function renderOverview() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        "Agent Mode",
        "Oracle reasons, Context Builder gathers files, and agents do the work. Each row links to the page that owns those settings.",
        "agent",
      ),
    );

    const byID = Object.fromEntries(
      orderedProviders().map((provider) => [provider.providerID, provider]),
    );
    const mainCLIProviders = [
      byID.codex,
      byID.claudeCompatible,
      byID.openCodeACP,
      byID.cursorACP,
    ].filter(Boolean);
    const connected = mainCLIProviders.filter(isConnectedProvider);
    const routes = desktopCard(
      "Agent Setup",
      "Configuration and connection status.",
    );
    function routeRow(title, detail, route, statusText) {
      const link = element("a", "overview-route-row");
      link.href = `#settings/${route}`;
      link.dataset.routeLink = "";
      const copy = element("div", "desktop-setting-copy");
      copy.append(element("strong", "", title), element("small", "", detail));
      link.append(
        copy,
        element("span", "read-only-value", statusText),
        iconNode("chevron"),
      );
      routes.append(link);
    }
    routeRow(
      "Agent Models",
      "Models for Oracle, Context Builder, and agent roles.",
      "agent-models",
      liveAgentModelsStatus(),
    );
    routeRow(
      "CLI Providers",
      "Codex, Claude Code, compatible backends, OpenCode, and Cursor.",
      "cli-providers",
      `${connected.length} of ${mainCLIProviders.length} connected`,
    );
    routeRow(
      "Context Builder",
      "Typed defaults for connected RepoPrompt MCP agents.",
      "context-builder",
      "Editable",
    );
    routeRow(
      "Agent Workflows",
      "Built-in and custom workflows.",
      "agent-workflows",
      `${state.typedSettings.workflows?.workflows?.length || 0} managed`,
    );
    routeRow(
      "Agent Permissions",
      "Direct-agent and sub-agent permissions.",
      "agent-permissions",
      liveDirectAgentStatus(),
    );
    content.append(routes);
    const liveRoutes = desktopCard(
      "Live routing",
      "Current model choices for Oracle, Context Builder, and agent roles.",
    );
    [
      ["oracle", "Oracle"],
      ["contextBuilder", "Context Builder"],
      ["explore", "Explore"],
      ["engineer", "Engineer"],
      ["pair", "Pair"],
      ["design", "Design"],
    ].forEach(([target, title]) => {
      liveRoutes.append(
        desktopRow(
          title,
          liveRouteDetail(target),
          element("span", "read-only-value", liveRouteStatus(target)),
        ),
      );
    });
    content.append(liveRoutes);

    const livePermissions = desktopCard(
      "Live permissions",
      "Current direct-agent and sub-agent permission policy.",
    );
    const permissionSettings =
      state.typedSettings.directAgentPermissions?.settings;
    const subagentSettings =
      state.typedSettings.subagentPermissions?.settings;
    [
      [
        "Codex",
        permissionSettings
          ? `${liveSandboxLabel(permissionSettings.codex.sandboxMode)} · ${liveCodexPermissionLevel(permissionSettings.codex)}`
          : "Loading",
        "Independent sandbox, approval, and reviewer. Not the 3-mode fallback.",
      ],
      [
        "Claude",
        permissionSettings
          ? `${liveClaudePermissionLabel(permissionSettings.claude.permissionMode)} · ${livePromptDeliveryLabel(permissionSettings.claude.promptDelivery)}`
          : "Loading",
        "Typed permission mode, Bash, MCP-strict, and Sys Prompt Packaging.",
      ],
      [
        "OpenCode",
        liveManagedPermissionLabel("openCodeACP"),
        "Typed ACP session mode.",
      ],
      [
        "Cursor",
        liveManagedPermissionLabel("cursorACP"),
        "Typed ACP auto-approve.",
      ],
      [
        "Sub-Agents",
        liveSubagentStatus(),
        "Safe Managed, Inherit, or Custom for new child sessions.",
      ],
    ].forEach(([title, status, detail]) => {
      livePermissions.append(
        desktopRow(title, detail, element("span", "read-only-value", status)),
      );
    });
    content.append(livePermissions);

    const providerCard = desktopCard(
      "CLI Provider Status",
      "Installed and connected CLI providers.",
    );
    const providerList = element("div", "provider-status-list");
    mainCLIProviders.forEach((provider) => {
      const status = providerStatus(provider);
      providerList.append(
        desktopRow(
          desktopProviderPresentation(provider).title,
          provider.cli?.version
            ? `CLI ${provider.cli.version}`
            : provider.cli?.installed === false
              ? "CLI not installed"
              : "CLI status available in provider details",
          element(
            "span",
            `connection-badge ${status.tone}`.trim(),
            status.label,
          ),
        ),
      );
    });
    providerCard.append(providerList);
    content.append(providerCard);

    installIcons(content);
  }

  function renderProviders(category, title, subtitle) {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        title,
        subtitle,
        category === "cliProvider" ? "terminal" : "cloud",
      ),
      recommendation(
        "shield",
        "Write-only credentials",
        "Credential values are sent only to the authenticated server connection endpoint. They are cleared from the DOM after every success or failure and never returned by the catalog.",
      ),
    );
    const stack = element("div", "provider-stack");
    const providers = orderedProviders().filter(
      (provider) =>
        provider.category === category && provider.deploymentAllowed,
    );
    if (!providers.length) {
      const empty = element("div", "empty-state-panel");
      empty.append(
        element("h2", "", "No providers in this category"),
        element(
          "p",
          "",
          "The server catalog does not currently advertise a configurable provider here.",
        ),
      );
      stack.append(empty);
    } else {
      providers.forEach((provider, index) =>
        stack.append(providerCard(provider, index === 0, false)),
      );
    }
    content.append(stack);
    installIcons(content);
  }

  function providerCard(provider, open, modelsOnly) {
    const presentation = desktopProviderPresentation(provider);
    const details = element("details", "provider-card");
    details.open = open;
    details.dataset.providerId = provider.providerID;
    const summary = document.createElement("summary");
    const status = providerStatus(provider);
    const badge = element("span", `connection-badge ${status.tone}`.trim());
    badge.append(element("i"), element("span", "", status.label));
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", presentation.title),
      element("small", "", presentation.subtitle),
    );
    summary.append(
      iconNode(
        provider.category === "cliProvider" ? "terminal" : "cloud",
        "provider-glyph",
      ),
      name,
      badge,
      iconNode("chevron"),
    );
    const body = element("div", "provider-card-body");
    body.append(settingsSection(provider));
    if (!modelsOnly) body.append(authenticationSection(provider));
    details.append(summary, body);
    return details;
  }

  function statusTile(label, value, detail) {
    const tile = element("div", "status-tile");
    tile.append(
      element("span", "", label),
      element("strong", "", value),
      element("small", "", detail || "—"),
    );
    return tile;
  }

  function sectionHeading(title, detail) {
    const heading = element("div", "provider-section-heading");
    const copy = element("div");
    copy.append(element("h3", "", title), element("p", "", detail));
    heading.append(copy);
    return heading;
  }

  function appendFieldHelp(form, text) {
    form.append(element("span", "field-help", text));
  }

  function addSelect(form, labelText, name, emptyLabel) {
    const label = element("label", "", labelText);
    const select = document.createElement("select");
    select.name = name;
    select.setAttribute("aria-label", labelText);
    populateSelect(
      select,
      [],
      "",
      (value) => value,
      (value) => value,
      emptyLabel,
    );
    form.append(label, select);
    return select;
  }

  function populateSelect(select, values, selected, label, key, emptyLabel) {
    select.replaceChildren();
    const empty = element("option", "", emptyLabel);
    empty.value = "";
    select.append(empty);
    values.forEach((value) => {
      const option = element("option", "", label(value));
      option.value = key(value);
      option.selected = option.value === selected;
      select.append(option);
    });
  }

  function setSelectAvailability(select, available, reason) {
    setDisabledReason(select, !available, reason);
    if (!available) select.value = "";
  }

  function settingsSection(provider) {
    const section = element("section", "provider-section");
    section.dataset.controlFamily = "provider-preferences";
    section.append(
      sectionHeading(
        "Provider defaults",
        "Revisioned settings contain no credential material.",
      ),
    );
    const form = element("form", "settings-form");
    form.dataset.providerSettings = provider.providerID;

    const model = addSelect(
      form,
      "Default model",
      "defaultModel",
      "Provider default",
    );
    populateSelect(
      model,
      provider.models || [],
      provider.preference.defaultModel || "",
      (item) => item.displayName,
      (item) => item.id,
      "Provider default",
    );
    const modelReason = !provider.capabilities.supportsModelSelection
      ? "This provider does not support model selection."
      : "No sanitized model catalog is available for this provider account.";
    setSelectAvailability(
      model,
      provider.capabilities.supportsModelSelection &&
        provider.models.length > 0,
      modelReason,
    );
    if (model.disabled) appendFieldHelp(form, modelReason);

    const effort = addSelect(
      form,
      "Reasoning effort",
      "reasoningEffort",
      "Model default",
    );
    const speed = addSelect(form, "Fast mode", "speedMode", "Standard speed");
    const tier = addSelect(
      form,
      "Service tier",
      "serviceTier",
      "Standard tier",
    );

    function refreshDependentOptions(initial = false) {
      const selectedModel = provider.models.find(
        (item) => item.id === model.value,
      );
      const currentEffort = initial
        ? provider.preference.reasoningEffort
        : effort.value;
      const currentSpeed = initial
        ? provider.preference.speedMode
        : speed.value;
      const currentTier = initial
        ? provider.preference.serviceTier
        : tier.value;
      const efforts = selectedModel?.reasoningEfforts || [];
      const speeds = selectedModel?.speedModes || [];
      const tiers = selectedModel?.serviceTiers || [];
      populateSelect(
        effort,
        efforts,
        efforts.includes(currentEffort) ? currentEffort : "",
        humanize,
        (value) => value,
        "Model default",
      );
      populateSelect(
        speed,
        speeds,
        speeds.includes(currentSpeed) ? currentSpeed : "",
        humanize,
        (value) => value,
        "Standard speed",
      );
      populateSelect(
        tier,
        tiers,
        tiers.includes(currentTier) ? currentTier : "",
        humanize,
        (value) => value,
        "Standard tier",
      );
      setSelectAvailability(
        effort,
        provider.capabilities.supportsReasoningEffort && efforts.length > 0,
        !provider.capabilities.supportsReasoningEffort
          ? "Reasoning effort is not supported by this provider."
          : "Choose a model that advertises reasoning effort values.",
      );
      setSelectAvailability(
        speed,
        provider.capabilities.supportsSpeedMode && speeds.length > 0,
        !provider.capabilities.supportsSpeedMode
          ? "Fast mode is not supported by this provider."
          : "The selected model does not advertise fast-mode values.",
      );
      setSelectAvailability(
        tier,
        provider.capabilities.supportsServiceTier && tiers.length > 0,
        !provider.capabilities.supportsServiceTier
          ? "Service tier is not supported by this provider."
          : "The selected model does not advertise service-tier values.",
      );
    }
    refreshDependentOptions(true);

    const message = element(
      "div",
      "inline-message info form-message",
      "Change a setting to save a new revision.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const actions = element("div", "form-actions");
    const note = element(
      "span",
      "form-note",
      "Defaults apply to new sessions.",
    );
    const save = element("button", "primary-button", "Save Settings");
    save.type = "submit";
    save.dataset.action = "save-provider-settings";
    setDisabledReason(save, true, "Change a setting to save.");
    actions.append(note, save);
    form.append(message, actions);

    function markDirty() {
      setDisabledReason(save, false, "");
      message.textContent = "Unsaved changes";
      message.className = "inline-message info form-message";
    }
    model.addEventListener("change", () => {
      refreshDependentOptions(false);
      markDirty();
    });
    [effort, speed, tier].forEach((select) =>
      select.addEventListener("change", markDirty),
    );

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (save.disabled) return;
      const originalLabel = save.textContent;
      setDisabledReason(save, true, "Settings are being saved.");
      save.textContent = "Saving…";
      form.setAttribute("aria-busy", "true");
      message.textContent = "Saving provider settings…";
      try {
        const updated = await api(
          `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}`,
          {
            method: "PATCH",
            body: JSON.stringify({
              expectedRevision: provider.preference.revision,
              enabled: provider.deploymentAllowed,
              defaultModel: model.value || null,
              reasoningEffort: effort.value || null,
              speedMode: speed.value || null,
              serviceTier: tier.value || null,
            }),
          },
        );
        replaceProvider(updated);
        renderHomeProviders();
        renderRoute();
        toast(`${provider.displayName} settings saved`);
        announce(`${provider.displayName} settings saved`);
      } catch (error) {
        message.textContent =
          error.code === "staleRevision"
            ? `${error.message} Refresh the catalog before trying again.`
            : error.message;
        message.className = "inline-message error form-message";
        message.focus({ preventScroll: true });
        save.textContent = originalLabel;
        setDisabledReason(save, false, "");
        toast(error.message, true);
      } finally {
        form.removeAttribute("aria-busy");
      }
    });

    section.append(form);
    return section;
  }

  function authFlowForMethod(flows, method) {
    return (
      flows.find((flow) => flow.kind === method) ||
      (method === "browserLogin" || method === "providerSpecific"
        ? flows.find((flow) => flow.kind === "externalProvisioning")
        : null)
    );
  }

  function authenticationMethodName(provider, method, flow) {
    if (flow?.displayName) return flow.displayName;
    if (provider.providerID === "codex" && method === "browserOAuth")
      return "Login with ChatGPT";
    if (provider.providerID === "codex" && method === "deviceCodeBeta")
      return "Use device code instead";
    if (provider.providerID === "codex" && method === "apiKey")
      return "OpenAI API Key";
    return humanize(method);
  }

  function authenticationMethodDescription(provider, method, flow) {
    if (flow?.detail) return flow.detail;
    if (
      provider.providerID === "codex" &&
      (method === "browserOAuth" || method === "deviceCodeBeta")
    )
      return "Uses your Codex subscription. RepoPrompt CE keeps this sign-in separate from ~/.codex.";
    if (provider.providerID === "codex" && method === "apiKey")
      return "API keys for direct model access. OpenAI API usage is API-billed.";
    return provider.authentication?.detail || provider.summary;
  }

  function authenticationMethodChoices(provider, flowMessage) {
    const choices = element("div", "auth-choice-grid");
    const flows = provider.capabilities.authFlows || [];
    const methods = (provider.capabilities.authenticationMethods || []).filter(
      (method) =>
        provider.providerID !== "codex" ||
        !directAuthenticationMethods.has(method),
    );
    if (provider.providerID === "codex") {
      const releaseOrder = ["deviceCodeBeta", "browserOAuth", "apiKey"];
      methods.sort((left, right) => {
        const leftIndex = releaseOrder.indexOf(left);
        const rightIndex = releaseOrder.indexOf(right);
        return (
          (leftIndex < 0 ? 99 : leftIndex) - (rightIndex < 0 ? 99 : rightIndex)
        );
      });
    }
    methods.forEach((method) => {
      const flow = authFlowForMethod(flows, method);
      const methodName = authenticationMethodName(provider, method, flow);
      const card = element("div", "auth-choice");
      card.dataset.authenticationMethod = method;
      const copy = element("div", "auth-choice-copy");
      copy.append(
        element("strong", "", methodName),
        element(
          "small",
          "",
          authenticationMethodDescription(provider, method, flow),
        ),
      );
      const active = provider.connection?.authenticationMethod === method;
      const activelyConnected =
        active && provider.connection?.state === "connected";
      const direct = directAuthenticationMethods.has(method);
      const action = element(
        "button",
        active
          ? "secondary-button auth-choice-action active"
          : "secondary-button auth-choice-action",
        activelyConnected
          ? "Connected"
          : active
            ? "Reconnect"
            : direct
              ? provider.connection
                ? "Change"
                : "Validate & Save"
              : methodName,
      );
      action.type = "button";
      action.dataset.action = direct ? "choose-auth-method" : "start-auth-flow";
      if (flow) action.dataset.flowKind = flow.kind;
      const anotherFlow =
        state.activeFlow && state.activeFlow.providerID !== provider.providerID;
      if (activelyConnected) {
        setDisabledReason(
          action,
          true,
          "This is the current connection method.",
        );
      } else if (direct) {
        action.addEventListener("click", () => {
          const select = card
            .closest(".provider-card")
            ?.querySelector('.secret-form select[name="authenticationMethod"]');
          if (!select) return;
          select.value = method;
          select.dispatchEvent(new window.Event("change", { bubbles: true }));
          select.focus({ preventScroll: true });
        });
      } else if (!flow?.startable || anotherFlow) {
        setDisabledReason(
          action,
          true,
          anotherFlow
            ? "Finish or cancel the active authentication flow first."
            : flow?.detail ||
                "This server does not advertise a startable adapter for this method.",
        );
      } else {
        action.addEventListener("click", () =>
          startAuthFlow(provider, flow, action, flowMessage),
        );
      }
      card.append(copy, action);
      choices.append(card);
    });
    return choices;
  }

  function authenticationSection(provider) {
    const section = element("section", "provider-section");
    section.dataset.controlFamily = "authentication";
    section.append(
      sectionHeading(
        "Connection & authentication",
        "Only methods advertised by this provider are rendered.",
      ),
    );

    if (provider.providerID === "codex") {
      const note = element("p", "codex-auth-note");
      note.append(
        document.createTextNode(
          "ChatGPT may require identity verification (KYC) to access Codex. ",
        ),
      );
      const learnMore = element("a", "", "Learn more");
      learnMore.href = "https://chatgpt.com/cyber";
      learnMore.target = "_blank";
      learnMore.rel = "noopener noreferrer";
      note.append(learnMore);
      section.append(note);
      if (!provider.authentication?.authenticated)
        section.append(
          element(
            "p",
            "card-subtitle codex-permissions-note",
            "Permissions and runtime controls appear here after Codex is connected.",
          ),
        );
    }

    const advertisedFlowDetail =
      provider.capabilities.authFlows?.find((flow) => flow.startable)?.detail ||
      provider.capabilities.authFlows?.[0]?.detail ||
      provider.authentication?.detail ||
      "No authentication flow detail is available.";
    const flowMessage = element(
      "div",
      "inline-message info auth-flow-message",
      provider.providerID === "codex"
        ? "RepoPrompt CE keeps checking this separate Codex sign-in while it is pending."
        : advertisedFlowDetail,
    );
    flowMessage.setAttribute("role", "status");
    flowMessage.tabIndex = -1;
    section.append(authenticationMethodChoices(provider, flowMessage));

    if (provider.connection) section.append(connectionPanel(provider));

    const directMethods = provider.capabilities.authenticationMethods.filter(
      (method) => directAuthenticationMethods.has(method),
    );
    if (directMethods.length)
      section.append(credentialForm(provider, directMethods));

    const hasTransientMethod = provider.capabilities.authenticationMethods.some(
      (method) => transientAuthenticationMethods.has(method),
    );
    if (hasTransientMethod) {
      section.append(flowMessage);
      if (state.activeFlow?.providerID === provider.providerID)
        section.append(devicePanel(provider));
    }

    if (!provider.capabilities.authenticationMethods.length) {
      const unavailable = element("div", "unavailable-panel");
      unavailable.append(
        iconNode("info"),
        document.createTextNode(
          "No browser sign-in is available for this provider. Sign in with its CLI for the RepoPrompt service account.",
        ),
      );
      section.append(unavailable);
    }
    return section;
  }

  function connectionPanel(provider) {
    const connection = provider.connection;
    const panel = element("div", "settings-card connection-panel");
    const activeFlow = authFlowForMethod(
      provider.capabilities.authFlows || [],
      connection.authenticationMethod,
    );
    panel.append(
      element(
        "h2",
        "",
        provider.providerID === "codex"
          ? "Signed in to Codex"
          : "Current connection",
      ),
      element(
        "p",
        "card-subtitle",
        `${authenticationMethodName(provider, connection.authenticationMethod, activeFlow)} · ${connection.accountLabel || "No account label"}`,
      ),
    );
    const grid = element("div", "provider-status-grid connection-details");
    grid.append(
      statusTile(
        "State",
        humanize(connection.state),
        connection.detail || "No additional detail",
      ),
      statusTile(
        "Credential test",
        humanize(connection.testState),
        connection.lastTestedAt
          ? formatDate(connection.lastTestedAt)
          : "Never tested",
      ),
      statusTile(
        "Expires",
        formatDate(connection.expiresAt, "No expiration reported"),
        connection.keyHelperConfigured
          ? "Key helper configured"
          : connection.workloadIdentityConfigured
            ? "Workload identity configured"
            : "Server-managed credential",
      ),
      statusTile(
        "Updated",
        formatDate(connection.updatedAt),
        `Created ${formatDate(connection.createdAt)}`,
      ),
    );
    panel.append(grid);

    const message = element(
      "div",
      "inline-message info",
      "Testing never returns credential material.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const actions = element("div", "provider-actions-footer");
    const testButton = element("button", "secondary-button", "Test Connection");
    testButton.type = "button";
    testButton.dataset.action = "test-connection";
    testButton.addEventListener("click", () =>
      runConnectionAction(provider, "test", testButton, message),
    );
    const destructive = element("div", "button-row");
    const disconnect = element("button", "danger-button subtle", "Disconnect");
    disconnect.type = "button";
    disconnect.dataset.action = "request-disconnect";
    disconnect.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: `Disconnect ${provider.displayName}?`,
        message:
          "The stored credential will be deleted and new runs will no longer use this connection.",
        label: "Disconnect",
        returnFocus: disconnect,
      });
      if (accepted)
        await runConnectionAction(provider, "disconnect", disconnect, message);
    });
    const revoke = element("button", "danger-button", "Revoke & Disconnect");
    revoke.type = "button";
    revoke.dataset.action = "request-revoke";
    revoke.addEventListener("click", async () => {
      const accepted = await confirmAction({
        title: `Revoke ${provider.displayName} access?`,
        message:
          "The server will request provider logout, delete its stored credential, and record a revocation audit entry.",
        label: "Revoke & Disconnect",
        returnFocus: revoke,
      });
      if (accepted)
        await runConnectionAction(provider, "revoke", revoke, message);
    });
    destructive.append(disconnect, revoke);
    actions.append(testButton, destructive);
    panel.append(message, actions);
    return panel;
  }

  async function runConnectionAction(provider, operation, button, message) {
    const originalLabel = button.textContent;
    const labels = {
      test: "Testing…",
      disconnect: "Disconnecting…",
      revoke: "Revoking…",
    };
    button.textContent = labels[operation];
    setDisabledReason(button, true, `${humanize(operation)} is in progress.`);
    message.textContent = labels[operation];
    try {
      const updated = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/${operation}`,
        {
          method: "POST",
          body: "{}",
        },
      );
      replaceProvider(updated);
      renderHomeProviders();
      renderRoute();
      const result =
        operation === "test"
          ? `${provider.displayName} connection tested`
          : `${provider.displayName} ${operation === "revoke" ? "revoked and disconnected" : "disconnected"}`;
      toast(result);
      announce(result);
    } catch (error) {
      message.textContent = error.message;
      message.className = "inline-message error";
      message.focus({ preventScroll: true });
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function credentialForm(provider, methods, options = {}) {
    const wrapper = element("div", "settings-card credential-card");
    const codexAPIKey =
      provider.providerID === "codex" && methods.includes("apiKey");
    const hasDirectConnection = methods.includes(
      provider.connection?.authenticationMethod,
    );
    wrapper.append(
      element(
        "h2",
        "",
        options.title ||
          (codexAPIKey
            ? "OpenAI API Key"
            : hasDirectConnection
              ? "Change connection"
              : "Add connection"),
      ),
      element(
        "p",
        "card-subtitle",
        options.subtitle ||
          (codexAPIKey
            ? "API keys for direct model access. OpenAI API usage is API-billed."
            : "Credential fields are write-only and are disposed after every request outcome."),
      ),
    );
    const form = element("form", "secret-form");
    form.dataset.providerConnect = provider.providerID;
    const methodLabel = element("label", "", "Authentication method");
    const method = document.createElement("select");
    method.name = "authenticationMethod";
    method.setAttribute("aria-label", "Authentication method");
    methods.forEach((value) => {
      const option = element("option", "", humanize(value));
      option.value = value;
      method.append(option);
    });
    const fields = element("div", "credential-fields");
    const message = element(
      "div",
      "inline-message info form-message",
      "The server never returns the submitted value.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const actions = element("div", "form-actions");
    const note = element(
      "span",
      "form-note",
      "Use a least-privilege credential scoped to this sandbox server.",
    );
    const submit = element(
      "button",
      "primary-button",
      hasDirectConnection ? "Change" : "Validate & Save",
    );
    submit.type = "submit";
    submit.dataset.action = "connect-provider";
    actions.append(note, submit);
    if (methods.length > 1) form.append(methodLabel, method);
    form.append(fields, message, actions);

    function addInput(name, labelText, options = {}) {
      const label = element("label", "", labelText);
      label.htmlFor = `${provider.providerID}-${name}`;
      const input = document.createElement("input");
      input.id = `${provider.providerID}-${name}`;
      input.name = name;
      input.type = options.type || "text";
      input.required = options.required === true;
      input.autocomplete = "off";
      input.spellcheck = false;
      input.setAttribute("autocapitalize", "none");
      if (options.placeholder) input.placeholder = options.placeholder;
      if (options.minLength) input.minLength = options.minLength;
      if (options.sensitive) input.dataset.sensitive = "true";
      fields.append(label, input);
      if (options.help)
        fields.append(element("span", "field-help", options.help));
      return input;
    }

    function renderFields() {
      disposeSensitiveInputs(fields);
      fields.replaceChildren();
      const selected = method.value;
      if (["apiKey", "enterpriseAccessToken", "authToken"].includes(selected)) {
        addInput("credential", humanize(selected), {
          type: "password",
          required: true,
          minLength: 8,
          sensitive: true,
          placeholder: "Enter write-only credential",
          help: "Required. Between 8 and 65,536 bytes; never echoed by the server.",
        });
        addInput("accountLabel", "Account label", {
          placeholder: "Optional non-secret label",
          help: "Do not paste credential material into the label.",
        });
      } else if (selected === "keyHelper") {
        addInput("keyHelperCommand", "Key helper executable", {
          required: true,
          sensitive: true,
          placeholder: "/absolute/path/to/helper",
          help: "Claude only. Enter an absolute executable path without arguments or whitespace.",
        });
      } else if (selected === "workloadIdentityFederation") {
        addInput("workloadIdentityProvider", "Identity provider", {
          required: true,
          placeholder: "Non-secret provider identifier",
        });
        addInput("workloadIdentityServiceAccount", "Service account", {
          required: true,
          placeholder: "Non-secret service account label",
        });
      } else {
        fields.append(
          element(
            "p",
            "field-wide form-note",
            "No raw credential is proxied. This creates a server-side provider-specific connection record; complete authentication in the isolated provider account.",
          ),
        );
      }
    }
    method.addEventListener("change", renderFields);
    renderFields();

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const payload = { authenticationMethod: method.value };
      fields.querySelectorAll("input[name]").forEach((input) => {
        const value = input.value.trim();
        if (value) payload[input.name] = value;
      });
      let requestBody = JSON.stringify(payload);
      const originalLabel = submit.textContent;
      form.setAttribute("aria-busy", "true");
      form.querySelectorAll("input, select, button").forEach((control) => {
        setDisabledReason(control, true, "Connection request is in progress.");
      });
      submit.textContent = hasDirectConnection ? "Saving…" : "Validating…";
      message.textContent = "Sending the write-only connection request…";
      try {
        const updated = await api(
          `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/connect`,
          {
            method: "POST",
            body: requestBody,
          },
        );
        replaceProvider(updated);
        renderHomeProviders();
        renderRoute();
        toast(`${provider.displayName} connection stored; test it before use`);
        announce(`${provider.displayName} connection stored`);
      } catch (error) {
        message.textContent = `${error.message} Credential fields were cleared; enter the value again to retry.`;
        message.className = "inline-message error form-message";
        message.focus({ preventScroll: true });
        form
          .querySelectorAll("input, select, button")
          .forEach((control) => setDisabledReason(control, false, ""));
        submit.textContent = originalLabel;
        toast(error.message, true);
      } finally {
        disposeSensitiveInputs(form);
        if (Object.hasOwn(payload, "credential")) payload.credential = null;
        if (Object.hasOwn(payload, "keyHelperCommand"))
          payload.keyHelperCommand = null;
        requestBody = "";
        form.removeAttribute("aria-busy");
      }
    });

    wrapper.append(form);
    return wrapper;
  }

  async function startAuthFlow(provider, flow, button, message) {
    const originalLabel = button.textContent;
    button.textContent = "Starting…";
    setDisabledReason(button, true, "Authentication flow is starting.");
    message.textContent = "Requesting a transient authentication challenge…";
    try {
      const status = await api(
        `api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/auth-flows`,
        {
          method: "POST",
          body: JSON.stringify({ kind: flow.kind }),
        },
      );
      state.activeFlow = {
        ...status,
        providerID: status.providerID || provider.providerID,
        error: null,
      };
      renderRoute();
      scheduleFlowPoll();
      toast(`${flow.displayName} started`);
      announce(`${flow.displayName} started`);
    } catch (error) {
      message.textContent = error.message;
      message.className = "inline-message error";
      message.focus({ preventScroll: true });
      button.textContent = originalLabel;
      setDisabledReason(button, false, "");
      toast(error.message, true);
    }
  }

  function devicePanel(provider) {
    const flow = state.activeFlow;
    const panel = element("section", "device-panel");
    panel.dataset.flowState = flow.state;
    const header = element("div", "device-panel-header");
    const copy = element("div");
    copy.append(
      element(
        "h4",
        "",
        authenticationMethodName(
          provider,
          flow.kind,
          authFlowForMethod(provider.capabilities.authFlows || [], flow.kind),
        ),
      ),
      element("p", "", flow.detail || "Waiting for provider authorization."),
    );
    header.append(copy);
    panel.append(header);
    if (flow.userCode)
      panel.append(element("code", "device-code", flow.userCode));
    if (flow.verificationURL) {
      const verification = element(
        "a",
        "secondary-button verification-link",
        "Open Verification Page",
      );
      verification.href = flow.verificationURL;
      verification.target = "_blank";
      verification.rel = "noopener noreferrer";
      verification.append(iconNode("link"));
      panel.append(verification);
    }
    panel.append(element("p", "", `Expires ${formatDate(flow.expiresAt)}`));
    if (flow.error) {
      const error = element("div", "inline-message error", flow.error);
      error.setAttribute("role", "alert");
      panel.append(error);
    }
    const status = element("span", "polling-status");
    status.append(
      element("i"),
      document.createTextNode(
        state.pollPromise ? "Checking provider…" : "Waiting for authorization",
      ),
    );
    const actions = element("div", "flow-actions");
    const poll = element("button", "secondary-button", "Check Now");
    poll.type = "button";
    poll.dataset.action = "poll-auth-flow";
    setDisabledReason(
      poll,
      Boolean(state.pollPromise),
      "A provider status check is already in progress.",
    );
    if (!poll.disabled)
      poll.addEventListener("click", () => pollActiveFlow(true));
    const cancel = element(
      "button",
      "danger-button subtle",
      "Cancel Authentication",
    );
    cancel.type = "button";
    cancel.dataset.action = "cancel-auth-flow";
    setDisabledReason(
      cancel,
      Boolean(state.pollPromise),
      "Wait for the current provider status check to finish.",
    );
    if (!cancel.disabled)
      cancel.addEventListener("click", () =>
        cancelActiveFlow(provider, cancel),
      );
    actions.append(poll, cancel);
    panel.append(status, actions);
    return panel;
  }

  function refreshActiveFlowPanel() {
    if (!state.activeFlow) return;
    const provider = state.providers.find(
      (item) => item.providerID === state.activeFlow.providerID,
    );
    const card = [...document.querySelectorAll("[data-provider-id]")].find(
      (item) => item.dataset.providerId === state.activeFlow.providerID,
    );
    const current = card?.querySelector(".device-panel");
    if (!provider || !current) return;
    current.replaceWith(devicePanel(provider));
    installIcons(card);
  }

  function clearPollTimer() {
    if (state.pollTimer !== null) {
      window.clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
  }

  function scheduleFlowPoll() {
    clearPollTimer();
    if (!state.activeFlow || state.activeFlow.state !== "pending") return;
    state.pollTimer = window.setTimeout(() => {
      state.pollTimer = null;
      pollActiveFlow(false);
    }, pollDelay);
  }

  async function pollActiveFlow(manual = false) {
    if (!state.activeFlow || state.pollPromise) return state.pollPromise;
    const flowID = state.activeFlow.flowID;
    clearPollTimer();
    state.pollPromise = (async () => {
      try {
        const status = await api(
          `api/v1/provider-auth-flows/${encodeURIComponent(flowID)}`,
        );
        if (!state.activeFlow || state.activeFlow.flowID !== flowID) return;
        state.activeFlow = {
          ...status,
          providerID: status.providerID || state.activeFlow.providerID,
          error: null,
        };
        if (terminalFlowStates.has(status.state)) {
          const terminal = status.state;
          const detail = status.detail || `Authentication ${terminal}.`;
          state.activeFlow.userCode = null;
          state.activeFlow.verificationURL = null;
          clearPollTimer();
          if (terminal === "completed") {
            state.activeFlow = null;
            toast("Authentication completed");
            announce("Authentication completed");
            await loadAll(true);
          } else {
            state.activeFlow = null;
            renderRoute();
            toast(detail, terminal === "failed");
            announce(detail);
          }
        } else {
          scheduleFlowPoll();
          if (manual) announce("Authentication is still pending");
        }
      } catch (error) {
        if (state.activeFlow?.flowID === flowID) {
          state.activeFlow.error = `${error.message} Automatic polling will retry.`;
          scheduleFlowPoll();
        }
        toast(error.message, true);
      } finally {
        state.pollPromise = null;
        if (state.activeFlow?.flowID === flowID) refreshActiveFlowPanel();
      }
    })();
    refreshActiveFlowPanel();
    return state.pollPromise;
  }

  async function cancelActiveFlow(provider, button) {
    if (!state.activeFlow) return;
    const flowID = state.activeFlow.flowID;
    clearPollTimer();
    button.textContent = "Cancelling…";
    setDisabledReason(
      button,
      true,
      "Authentication cancellation is in progress.",
    );
    try {
      await api(`api/v1/provider-auth-flows/${encodeURIComponent(flowID)}`, {
        method: "DELETE",
        body: "{}",
      });
      if (state.activeFlow?.flowID === flowID) state.activeFlow = null;
      renderRoute();
      toast(`${provider.displayName} authentication cancelled`);
      announce(`${provider.displayName} authentication cancelled`);
    } catch (error) {
      if (state.activeFlow?.flowID === flowID)
        state.activeFlow.error = error.message;
      renderRoute();
      toast(error.message, true);
      scheduleFlowPoll();
    }
  }

  function renderPageError(error) {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    const panel = element("div", "error-banner");
    panel.setAttribute("role", "alert");
    panel.append(iconNode("warning"), document.createTextNode(error.message));
    content.replaceChildren(panel);
    installIcons(content);
  }

  function confirmAction({ title, message, label, returnFocus }) {
    if (state.confirmResolver) state.confirmResolver(false);
    const backdrop = document.getElementById("confirm-dialog");
    document.getElementById("confirm-title").textContent = title;
    document.getElementById("confirm-message").textContent = message;
    document.getElementById("confirm-action-button").textContent = label;
    state.confirmReturnFocus = returnFocus || document.activeElement;
    backdrop.hidden = false;
    const dialog = backdrop.querySelector('[role="dialog"]');
    window.setTimeout(() => dialog.focus({ preventScroll: true }), 0);
    return new Promise((resolve) => {
      state.confirmResolver = resolve;
    });
  }

  function closeConfirm(accepted) {
    if (!state.confirmResolver) return;
    const resolve = state.confirmResolver;
    const returnFocus = state.confirmReturnFocus;
    state.confirmResolver = null;
    state.confirmReturnFocus = null;
    document.getElementById("confirm-dialog").hidden = true;
    resolve(accepted);
    if (!accepted && returnFocus?.isConnected)
      returnFocus.focus({ preventScroll: true });
  }

  function trapDialogFocus(event) {
    const backdrop = document.getElementById("confirm-dialog");
    if (backdrop.hidden || event.key !== "Tab") return;
    const focusable = [
      ...backdrop.querySelectorAll(
        'button:not(:disabled), [href], [tabindex]:not([tabindex="-1"])',
      ),
    ];
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function filterSettingsNavigation(query) {
    const normalized = query.trim().toLowerCase();
    let visibleCount = 0;
    document.querySelectorAll("[data-settings-section]").forEach((section) => {
      let sectionCount = 0;
      section.querySelectorAll("a, .unavailable-nav-row").forEach((row) => {
        const label = (
          row.dataset.searchLabel || row.textContent
        ).toLowerCase();
        const visible = !normalized || label.includes(normalized);
        row.hidden = !visible;
        if (visible) sectionCount += 1;
      });
      section.hidden = sectionCount === 0;
      visibleCount += sectionCount;
    });
    document.getElementById("settings-no-results").hidden = visibleCount > 0;
    document.getElementById("clear-settings-search").hidden = !normalized;
    document.getElementById("settings-search-status").textContent = normalized
      ? visibleCount
        ? `${visibleCount} setting${visibleCount === 1 ? "" : "s"} found.`
        : "No settings found."
      : "";
  }

  function visibleSettingsLinks() {
    return [...document.querySelectorAll("#settings-nav a[data-route]")].filter(
      (link) => !link.hidden && !link.closest("section")?.hidden,
    );
  }

  function openSettingsDrawer() {
    if (!window.matchMedia("(max-width: 720px)").matches) return;
    const shell = document.getElementById("settings-shell");
    const sidebar = document.getElementById("settings-sidebar");
    const toggle = document.getElementById("settings-drawer-toggle");
    state.settingsDrawerReturnFocus = document.activeElement;
    shell.classList.add("drawer-open");
    document.getElementById("settings-drawer-backdrop").hidden = false;
    toggle.setAttribute("aria-expanded", "true");
    toggle.setAttribute("aria-label", "Close settings navigation");
    sidebar.setAttribute("aria-modal", "true");
    window.setTimeout(
      () => document.getElementById("settings-search").focus(),
      0,
    );
  }

  function closeSettingsDrawer({ restoreFocus = true } = {}) {
    const shell = document.getElementById("settings-shell");
    if (!shell.classList.contains("drawer-open")) return;
    shell.classList.remove("drawer-open");
    document.getElementById("settings-drawer-backdrop").hidden = true;
    const toggle = document.getElementById("settings-drawer-toggle");
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-label", "Open settings navigation");
    document.getElementById("settings-sidebar").removeAttribute("aria-modal");
    const returnFocus = state.settingsDrawerReturnFocus;
    state.settingsDrawerReturnFocus = null;
    if (restoreFocus && returnFocus?.isConnected)
      returnFocus.focus({ preventScroll: true });
  }

  function clearSettingsSearch(focus = true) {
    const input = document.getElementById("settings-search");
    input.value = "";
    filterSettingsNavigation("");
    if (focus) input.focus({ preventScroll: true });
  }

  function handleDocumentClick(event) {
    const routeLink = event.target.closest("[data-route-link]");
    if (routeLink) {
      state.focusAfterRoute = true;
      if (routeLink.closest("#settings-sidebar"))
        closeSettingsDrawer({ restoreFocus: false });
      if (routeLink.hash === location.hash) window.setTimeout(renderRoute, 0);
    }
    const action = event.target.closest("[data-action]")?.dataset.action;
    if (action === "refresh") loadAll(true);
    else if (action === "new-chat") beginNewSession();
    else if (action === "load-earlier") {
      const pageToken =
        state.agent.transcriptPage?.presentation?.nextPageToken;
      if (pageToken) loadTranscript({ pageToken });
    } else if (action === "clear-session-search") {
      state.agent.searchText = "";
      document.getElementById("session-search").value = "";
      document.getElementById("clear-session-search").hidden = true;
      renderSessions();
      document.getElementById("session-search").focus({ preventScroll: true });
    } else if (action === "skip-content") {
      const target = document.getElementById("settings-shell").hidden
        ? document.getElementById("main-content")
        : document.getElementById("settings-main-content");
      target.focus({ preventScroll: true });
    } else if (action === "clear-settings-search") clearSettingsSearch();
    else if (action === "toggle-settings-drawer") {
      if (
        document
          .getElementById("settings-shell")
          .classList.contains("drawer-open")
      )
        closeSettingsDrawer();
      else openSettingsDrawer();
    } else if (action === "close-settings-drawer") closeSettingsDrawer();
    else if (action === "cancel-confirm") closeConfirm(false);
    else if (action === "accept-confirm") closeConfirm(true);
  }

  function handleDocumentKeydown(event) {
    trapDialogFocus(event);
    const drawerOpen = document
      .getElementById("settings-shell")
      .classList.contains("drawer-open");
    if (drawerOpen && event.key === "Tab") {
      const focusable = [
        ...document
          .getElementById("settings-sidebar")
          .querySelectorAll(
            "input:not(:disabled), button:not(:disabled):not([hidden]), a[href]:not([hidden])",
          ),
      ].filter((node) => !node.closest("[hidden]"));
      const first = focusable[0];
      const last = focusable.at(-1);
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    }
    if (event.key !== "Escape") return;
    if (!document.getElementById("confirm-dialog").hidden) {
      event.preventDefault();
      closeConfirm(false);
      return;
    }
    if (drawerOpen) {
      event.preventDefault();
      closeSettingsDrawer();
      return;
    }
    if (
      document.activeElement === document.getElementById("settings-search") &&
      document.getElementById("settings-search").value
    ) {
      event.preventDefault();
      clearSettingsSearch();
    } else if (
      document.activeElement === document.getElementById("session-search") &&
      document.getElementById("session-search").value
    ) {
      event.preventDefault();
      state.agent.searchText = "";
      document.getElementById("session-search").value = "";
      document.getElementById("clear-session-search").hidden = true;
      renderSessions();
    }
  }

  function start() {
    if (state.initialized) return;
    state.initialized = true;
    applyPortalAppearance();
    installIcons();
    renderInitialLoading();
    document.addEventListener("click", handleDocumentClick);
    document.addEventListener("keydown", handleDocumentKeydown);
    document
      .getElementById("settings-search")
      .addEventListener("input", (event) => {
        filterSettingsNavigation(event.target.value);
      });
    document
      .getElementById("settings-search")
      .addEventListener("keydown", (event) => {
        const links = visibleSettingsLinks();
        if ((event.key === "ArrowDown" || event.key === "Enter") && links[0]) {
          event.preventDefault();
          if (event.key === "Enter") links[0].click();
          else links[0].focus({ preventScroll: true });
        }
      });
    document
      .getElementById("settings-nav")
      .addEventListener("keydown", (event) => {
        if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key))
          return;
        const links = visibleSettingsLinks();
        const current = links.indexOf(document.activeElement);
        if (current < 0) return;
        event.preventDefault();
        const next =
          event.key === "Home"
            ? 0
            : event.key === "End"
              ? links.length - 1
              : event.key === "ArrowDown"
                ? Math.min(links.length - 1, current + 1)
                : Math.max(0, current - 1);
        links[next]?.focus({ preventScroll: true });
      });
    document
      .getElementById("session-search")
      .addEventListener("input", (event) => {
        state.agent.searchText = event.target.value;
        document.getElementById("clear-session-search").hidden =
          !event.target.value;
        renderSessions();
      });
    document
      .getElementById("project-selector")
      .addEventListener("change", (event) => {
        const projectID = event.target.value;
        if (projectID === "__create_project__") beginProjectCreation();
        else if (projectID) selectProject(projectID);
      });
    const composerText = document.getElementById("composer-text");
    composerText.addEventListener("input", () => {
      activeComposerState().text = composerText.value;
      state.agent.retryOperation = null;
      renderAgentComposer();
    });
    composerText.addEventListener("keydown", (event) => {
      if (
        event.key !== "Enter" ||
        event.shiftKey ||
        event.isComposing ||
        event.keyCode === 229
      )
        return;
      event.preventDefault();
      if (!document.getElementById("composer-submit").disabled)
        submitComposer();
    });
    document.getElementById("composer-submit").addEventListener("click", (event) => {
      if (event.currentTarget.dataset.mode !== "cancel") return;
      event.preventDefault();
      performSessionAction("cancel");
    });
    document.getElementById("composer-attach").addEventListener("click", () => {
      document.getElementById("composer-attachment-input").click();
    });
    document
      .getElementById("composer-attachment-input")
      .addEventListener("change", (event) => stageComposerAttachments(event.target.files));
    document
      .getElementById("composer-form")
      .addEventListener("submit", (event) => {
        event.preventDefault();
        submitComposer();
      });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        clearAgentPoll();
        clearAgentRunClock();
      } else {
        scheduleAgentPoll();
        syncAgentRunClock();
      }
    });
    window.addEventListener("hashchange", renderRoute);
    window.addEventListener("offline", () => {
      setConnectionPresentation(
        "offline",
        "This browser is offline. Changes require a restored connection.",
      );
      announce("Browser is offline");
    });
    window.addEventListener("online", () => {
      setConnectionPresentation(
        "stale",
        "Connection restored. Refreshing server state…",
      );
      loadAll(true);
    });
    window.addEventListener("pagehide", () => {
      disposeSensitiveInputs();
      clearPollTimer();
      clearAgentPoll();
      clearAgentRunClock();
      state.agent.eventSource?.close();
      state.agent.eventSource = null;
    });
    renderRoute();
    ensureOperatorSession().then((ready) => {
      if (ready) loadAll(false);
    });
  }

  async function ensureOperatorSession() {
    const gate = document.getElementById("auth-gate");
    const form = document.getElementById("auth-form");
    const error = document.getElementById("auth-error");
    let status;
    try {
      status = await api("api/v1/auth/status");
    } catch (failure) {
      gate.hidden = true;
      return true;
    }
    if (status.authenticated) {
      gate.hidden = true;
      return true;
    }
    gate.hidden = false;
    if (!status.passwordLoginEnabled) {
      document.getElementById("auth-title").textContent = "Operator certificate required";
      document.getElementById("auth-copy").textContent =
        "This server uses mutual TLS. Import the operator client certificate in your browser, then reload.";
      form.hidden = true;
      return false;
    }
    form.hidden = false;
    const setup = !!status.needsSetup;
    document.getElementById("auth-title").textContent = setup
      ? "Create the operator password"
      : "Sign in";
    document.getElementById("auth-copy").textContent = setup
      ? "This is the first launch. Choose a password for the operator account."
      : "Enter the operator password to open the portal.";
    document.getElementById("auth-confirm-field").hidden = !setup;
    document.getElementById("auth-password").autocomplete = setup
      ? "new-password"
      : "current-password";
    document.getElementById("auth-submit").textContent = setup
      ? "Create password"
      : "Sign in";
    return await new Promise((resolve) => {
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        error.hidden = true;
        const password = document.getElementById("auth-password").value;
        try {
          if (setup) {
            const confirmation = document.getElementById(
              "auth-password-confirm",
            ).value;
            await api("api/v1/setup", {
              method: "POST",
              body: JSON.stringify({
                password,
                passwordConfirmation: confirmation,
              }),
            });
          } else {
            await api("api/v1/login", {
              method: "POST",
              body: JSON.stringify({ password }),
            });
          }
          gate.hidden = true;
          resolve(true);
        } catch (failure) {
          error.hidden = false;
          error.textContent = failure.message;
        }
      });
    });
  }

  if (window.__REPOPROMPT_PORTAL_TEST_HOOK__) {
    window.RepoPromptPortalTest = Object.freeze({
      state,
      start,
      loadAll,
      renderRoute,
      pollActiveFlow,
      loadTranscript,
      selectSession,
      beginNewSession,
      submitComposer,
      disposeSensitiveInputs,
      whenIdle: async () => {
        await state.loadPromise;
        await state.settingsMutation;
        await Promise.all(Object.values(state.domainMutations).filter(Boolean));
        await state.agent.transcriptPromise;
        await state.agent.mutationPromise;
      },
    });
  }

  start();
})();
