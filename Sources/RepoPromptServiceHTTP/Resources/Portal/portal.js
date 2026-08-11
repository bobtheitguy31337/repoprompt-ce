"use strict";

(() => {
  const providerOrder = [
    "codex",
    "claudeCompatible",
    "openCodeACP",
    "cursorACP",
    "xAI",
  ];
  const supportedRoutes = new Set([
    "overview",
    "cli-providers",
    "agent-models",
    "api-providers",
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

  const state = {
    providers: [],
    bootstrap: null,
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
    focusAfterRoute: false,
    initialized: false,
    agent: {
      selectedProjectID: null,
      selectedSessionID: null,
      newSessionMode: false,
      searchText: "",
      transcriptItems: [],
      transcriptPage: null,
      transcriptPromise: null,
      transcriptPromiseSessionID: null,
      mutationPromise: null,
      pollTimer: null,
      selectionGeneration: 0,
      retryOperation: null,
    },
  };

  // Hand-authored web-safe semantic line glyphs substitute for non-portable
  // SF Symbols without copying Apple artwork.
  const icons = {
    search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3.5 3.5"/>',
    refresh: '<path d="M13 5V2l-2 2a5.5 5.5 0 1 0 1.2 7.8"/>',
    settings:
      '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M12.6 3.4l-1.4 1.4M4.8 11.2l-1.4 1.4"/>',
    message: '<path d="M2 3.5h12v8H7l-3.5 2v-2H2z"/>',
    folder: '<path d="M1.5 4h5l1.4 1.5h6.6v7.5h-13z"/>',
    workflow:
      '<circle cx="4" cy="3" r="1.5"/><circle cx="12" cy="8" r="1.5"/><circle cx="4" cy="13" r="1.5"/><path d="M5.5 3h2A2.5 2.5 0 0 1 10 5.5V8M5.5 13h2A2.5 2.5 0 0 0 10 10.5V8"/>',
    model: '<path d="M8 1.5 14 5v6l-6 3.5L2 11V5zM2 5l6 3.5L14 5M8 8.5v6"/>',
    shield:
      '<path d="M8 1.5 13 3v4.3c0 3.2-2 5.7-5 7.2-3-1.5-5-4-5-7.2V3z"/><path d="m5.5 8 1.5 1.5 3.5-4"/>',
    chevron: '<path d="m6 3 5 5-5 5"/>',
    terminal: '<path d="M1.5 3h13v10h-13zM4 6l2 2-2 2M8 10h3"/>',
    agent:
      '<circle cx="8" cy="5" r="3"/><path d="M2.5 14c.5-3 2.4-4.5 5.5-4.5s5 1.5 5.5 4.5"/>',
    appearance: '<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 0 0 0 12z"/>',
    keyboard:
      '<path d="M1.5 4h13v8h-13zM4 7h.1M7 7h.1M10 7h.1M12 7h.1M4 10h8"/>',
    sliders: '<path d="M2 4h12M2 8h12M2 12h12M5 2v4M11 6v4M7 10v4"/>',
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
    send: '<path d="M1.5 8 14.5 2 10 14l-2-5zM8 9l6.5-7"/>',
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

  async function api(path, options = {}) {
    const method = (options.method || "GET").toUpperCase();
    const mutation = ["POST", "PUT", "PATCH", "DELETE"].includes(method);
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
    return body;
  }

  function orderedProviders() {
    return providerOrder
      .map((id) =>
        state.providers.find((provider) => provider.providerID === id),
      )
      .filter(Boolean);
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
    };
    return (
      presentations[provider.providerID] || {
        title: provider.displayName,
        subtitle: provider.summary,
      }
    );
  }

  function providerStatus(provider) {
    if (!provider.deploymentAllowed)
      return { label: "Unavailable · deployment disabled", tone: "" };
    if (!provider.preference?.enabled) return { label: "Disabled", tone: "" };
    if (
      provider.connection?.testState === "invalid" ||
      provider.authentication?.state === "attention" ||
      provider.preflight?.reason === "invalidCredential"
    ) {
      return { label: "Validation failed", tone: "attention" };
    }
    if (
      provider.authentication?.authenticated &&
      (provider.connection?.testState === "valid" || provider.preflight?.ready)
    ) {
      return { label: "Connected", tone: "connected" };
    }
    if (provider.authentication?.authenticated)
      return { label: "Connected · validation required", tone: "available" };
    if (provider.cli?.healthy || provider.runtimePreflightVerified)
      return {
        label: "Available · authentication required",
        tone: "available",
      };
    if (provider.cli && !provider.cli.installed)
      return { label: "Unavailable · executable missing", tone: "attention" };
    return {
      label: humanize(provider.preflight?.reason || "Unavailable"),
      tone: "attention",
    };
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
    const dot = document.getElementById("service-dot");
    const banner = document.getElementById("connection-banner");
    const bannerText = document.getElementById("connection-banner-text");
    dot.classList.remove("online", "stale", "offline");
    dot.classList.add(kind);
    banner.hidden = kind === "online";
    bannerText.textContent = message || "";
    state.online = kind !== "offline";
  }

  function setLoading(loading) {
    const refresh = document.getElementById("refresh-button");
    state.loading = loading;
    refresh.classList.toggle("loading", loading);
    refresh.setAttribute("aria-busy", String(loading));
    setDisabledReason(refresh, loading, "Refresh is already in progress.");
    document
      .getElementById("session-list")
      .setAttribute("aria-busy", String(loading));
    document
      .getElementById("settings-content")
      .setAttribute("aria-busy", String(loading));
  }

  function renderInitialLoading() {
    const projects = document.getElementById("project-list");
    const sessions = document.getElementById("session-list");
    projects.replaceChildren(
      element("div", "sidebar-loading", "Loading projects…"),
    );
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

  async function loadAll(refresh = false) {
    if (state.loadPromise) return state.loadPromise;
    setLoading(true);
    state.loadPromise = (async () => {
      try {
        const [bootstrap, providerCatalog] = await Promise.all([
          api("api/v1/bootstrap"),
          api(`api/v1/provider-settings${refresh ? "?refresh=true" : ""}`),
        ]);
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
        state.providers = providerCatalog.providers;
        state.generatedAt =
          providerCatalog.generatedAt || new Date().toISOString();
        document.getElementById("service-caption").textContent =
          "Connected · authenticated portal";
        setConnectionPresentation("online", "");
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
        document.getElementById("service-caption").textContent = offline
          ? "Server connection unavailable"
          : "Server state may be stale";
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
    const project = selectedProject() || state.bootstrap?.projects?.[0];
    document.getElementById("active-workspace-name").textContent =
      project?.name || "RepoPrompt Server";
    const freshness = state.generatedAt
      ? `Updated ${formatDate(state.generatedAt)}`
      : "Not yet loaded";
    document.getElementById("catalog-freshness").textContent = freshness;
    document.getElementById("settings-freshness").textContent = freshness;
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
    return orderedProviders().filter(
      (provider) =>
        provider.category === "cliProvider" &&
        provider.deploymentAllowed &&
        provider.effectiveEnabled,
    );
  }

  function reconcileAgentSelection() {
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
    if (
      !sessions.some((item) => item.sessionId === state.agent.selectedSessionID)
    ) {
      state.agent.selectedSessionID =
        [...sessions].sort(
          (left, right) =>
            new Date(right.lastActivityAt || 0) -
              new Date(left.lastActivityAt || 0) ||
            left.sessionId.localeCompare(right.sessionId),
        )[0]?.sessionId || null;
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
    const list = document.getElementById("project-list");
    list.replaceChildren();
    const projects = state.bootstrap?.projects || [];
    if (!projects.length) {
      list.append(
        element("div", "sidebar-empty", "No projects are available."),
      );
    }
    projects.forEach((project) => {
      const button = element("button", "project-row");
      button.type = "button";
      button.dataset.projectId = project.projectId;
      button.dataset.action = "select-project";
      button.classList.toggle(
        "active",
        project.projectId === state.agent.selectedProjectID,
      );
      button.setAttribute(
        "aria-pressed",
        String(project.projectId === state.agent.selectedProjectID),
      );
      const glyph = iconNode("folder", "project-row-icon");
      const copy = element("span", "project-row-copy");
      copy.append(
        element("strong", "", project.name),
        element(
          "small",
          "",
          project.rootNames?.length
            ? project.rootNames.join(" · ")
            : humanize(project.state),
        ),
      );
      button.append(glyph, copy);
      button.addEventListener("click", () => selectProject(project.projectId));
      list.append(button);
    });
    const newChat = document.getElementById("new-chat-button");
    const reason = !projects.length
      ? "Create a project through an authorized RepoPrompt client first."
      : !eligibleSessionProviders().length
        ? "Connect and validate a CLI provider before starting a chat."
        : "";
    setDisabledReason(newChat, Boolean(reason), reason);
    installIcons(list);
  }

  function sessionDepths(sessions) {
    const byID = new Map(
      sessions.map((session) => [session.sessionId, session]),
    );
    const depthByID = new Map();
    function resolve(session, visiting = new Set()) {
      if (depthByID.has(session.sessionId))
        return depthByID.get(session.sessionId);
      if (!session.parentSessionId || !byID.has(session.parentSessionId)) {
        depthByID.set(session.sessionId, 0);
        return 0;
      }
      if (visiting.has(session.sessionId)) {
        depthByID.set(session.sessionId, 0);
        return 0;
      }
      visiting.add(session.sessionId);
      const depth = Math.min(
        6,
        resolve(byID.get(session.parentSessionId), visiting) + 1,
      );
      visiting.delete(session.sessionId);
      depthByID.set(session.sessionId, depth);
      return depth;
    }
    sessions.forEach((session) => resolve(session));
    return depthByID;
  }

  function renderSessions() {
    const list = document.getElementById("session-list");
    list.replaceChildren();
    const query = state.agent.searchText.trim().toLowerCase();
    let sessions = (state.bootstrap?.sessions || []).filter(
      (session) => session.projectId === state.agent.selectedProjectID,
    );
    const depthByID = sessionDepths(sessions);
    sessions = sessions
      .filter((session) => {
        if (!query) return true;
        return [session.title, session.provider, session.model]
          .filter(Boolean)
          .some((value) => String(value).toLowerCase().includes(query));
      })
      .sort(
        (left, right) =>
          new Date(right.lastActivityAt || 0) -
            new Date(left.lastActivityAt || 0) ||
          left.sessionId.localeCompare(right.sessionId),
      );
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
      const depth = depthByID.get(session.sessionId) || 0;
      const button = element("button", `session-row depth-${depth}`);
      button.type = "button";
      button.dataset.sessionId = session.sessionId;
      button.dataset.action = "select-session";
      const active =
        !state.agent.newSessionMode &&
        session.sessionId === state.agent.selectedSessionID;
      button.classList.toggle("active", active);
      if (active) button.setAttribute("aria-current", "true");
      const plate = element("span", `session-status-plate ${session.state}`);
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
        element("span", "session-row-state", humanize(session.state)),
      );
      button.addEventListener("click", () => selectSession(session.sessionId));
      list.append(button);
    });
    list.setAttribute("aria-busy", "false");
  }

  function selectProject(projectID) {
    if (state.agent.selectedProjectID === projectID) return;
    clearAgentPoll();
    state.agent.selectedProjectID = projectID;
    state.agent.selectedSessionID = null;
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.newSessionMode = false;
    reconcileAgentSelection();
    renderHomeProviders();
    updateShell();
    if (state.agent.selectedSessionID) loadTranscript();
  }

  function selectSession(sessionID) {
    if (
      state.agent.selectedSessionID === sessionID &&
      !state.agent.newSessionMode
    )
      return;
    clearAgentPoll();
    state.agent.selectedSessionID = sessionID;
    state.agent.newSessionMode = false;
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.selectionGeneration += 1;
    renderHomeProviders();
    loadTranscript();
  }

  function beginNewSession() {
    clearAgentPoll();
    state.agent.newSessionMode = true;
    state.agent.selectedSessionID = null;
    state.agent.transcriptItems = [];
    state.agent.transcriptPage = null;
    state.agent.selectionGeneration += 1;
    renderHomeProviders();
    document.getElementById("composer-text").focus({ preventScroll: true });
  }

  function renderAgentDetail() {
    const session = selectedSession();
    const title = document.getElementById("active-session-title");
    const metadata = document.getElementById("session-metadata");
    const stateDot = document.getElementById("session-state-dot");
    stateDot.className = "session-state-dot";
    if (state.agent.newSessionMode) {
      title.textContent = "New chat";
      metadata.replaceChildren(
        element(
          "span",
          "metadata-pill",
          selectedProject()?.name || "No project",
        ),
      );
      stateDot.classList.add("idle");
    } else if (session) {
      title.textContent = session.title || "Agent Session";
      metadata.replaceChildren(
        element("span", "metadata-pill", humanize(session.provider)),
        element("span", "metadata-pill", session.model || "Provider default"),
        element(
          "span",
          `metadata-pill state-${session.state}`,
          humanize(session.state),
        ),
      );
      stateDot.classList.add(session.state);
    } else {
      title.textContent = "What are we building?";
      metadata.replaceChildren();
      stateDot.classList.add("idle");
    }
    renderTranscript();
    renderAgentComposer();
  }

  function renderTranscript() {
    const list = document.getElementById("transcript-list");
    const status = document.getElementById("transcript-status");
    const earlier = document.getElementById("load-earlier-button");
    list.replaceChildren();
    status.textContent = "";
    earlier.hidden = !state.agent.transcriptPage?.hasMoreBefore;
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
            ? "Loading transcript…"
            : "This session has no transcript yet.",
        ),
      );
    }
    state.agent.transcriptItems.forEach((item) => {
      const row = element("article", `transcript-entry kind-${item.kind}`);
      row.dataset.entryId = item.entryId;
      const header = element("header", "transcript-entry-header");
      const role =
        item.kind === "human"
          ? "You"
          : item.kind === "assistant"
            ? "RepoPrompt"
            : humanize(item.kind);
      header.append(
        element("strong", "", role),
        element("time", "", formatDate(item.timestamp)),
      );
      const content = element("div", "transcript-entry-content", item.content);
      row.append(header, content);
      if (item.truncated)
        row.append(
          element(
            "small",
            "transcript-truncated",
            "Entry truncated by the portal safety bound.",
          ),
        );
      list.append(row);
    });
    list.setAttribute(
      "aria-busy",
      String(Boolean(state.agent.transcriptPromise)),
    );
  }

  function mergeTranscriptItems(items, prepend = false) {
    const merged = new Map(
      (prepend
        ? items.concat(state.agent.transcriptItems)
        : state.agent.transcriptItems.concat(items)
      ).map((item) => [item.entryId, item]),
    );
    state.agent.transcriptItems = [...merged.values()].sort(
      (left, right) => left.sessionSequence - right.sessionSequence,
    );
  }

  async function loadTranscript({
    before = null,
    after = null,
    silent = false,
  } = {}) {
    const sessionID = state.agent.selectedSessionID;
    if (!sessionID || state.agent.newSessionMode) return null;
    if (
      state.agent.transcriptPromise &&
      state.agent.transcriptPromiseSessionID === sessionID
    )
      return state.agent.transcriptPromise;
    const generation = state.agent.selectionGeneration;
    const query = new URLSearchParams({ limit: "200" });
    if (before !== null) query.set("beforeSequence", String(before));
    if (after !== null) query.set("afterSequence", String(after));
    const requestPromise = (async () => {
      if (!silent) renderTranscript();
      try {
        const page = await api(
          `api/v1/sessions/${encodeURIComponent(sessionID)}/transcript?${query}`,
        );
        if (
          generation !== state.agent.selectionGeneration ||
          sessionID !== state.agent.selectedSessionID
        )
          return null;
        state.agent.transcriptPage = page;
        mergeTranscriptItems(page.items || [], before !== null);
        const index = state.bootstrap.sessions.findIndex(
          (item) => item.sessionId === sessionID,
        );
        if (index >= 0) state.bootstrap.sessions[index] = page.session;
        renderSessions();
        renderAgentDetail();
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
    const delay = window.__REPOPROMPT_PORTAL_TEST_HOOK__ ? 60_000 : 2_500;
    state.agent.pollTimer = window.setTimeout(async () => {
      state.agent.pollTimer = null;
      const latest = state.agent.transcriptItems.at(-1)?.sessionSequence || 0;
      await loadTranscript({ after: latest, silent: true });
    }, delay);
  }

  function renderAgentComposer() {
    const form = document.getElementById("composer-form");
    const options = document.getElementById("new-session-options");
    const providerSelect = document.getElementById("composer-provider");
    const modelSelect = document.getElementById("composer-model");
    const help = document.getElementById("composer-capability-help");
    const text = document.getElementById("composer-text");
    const submit = document.getElementById("composer-submit");
    options.hidden = !state.agent.newSessionMode;
    const providers = eligibleSessionProviders();
    const previousProvider = providerSelect.value;
    const previousModel = modelSelect.value;
    providerSelect.replaceChildren();
    providers.forEach((provider) => {
      const option = element("option", "", provider.displayName);
      option.value = provider.providerID;
      option.selected = provider.providerID === previousProvider;
      providerSelect.append(option);
    });
    const provider =
      providers.find((item) => item.providerID === providerSelect.value) ||
      providers[0];
    modelSelect.replaceChildren();
    const providerDefault = element("option", "", "Provider default");
    providerDefault.value = "";
    modelSelect.append(providerDefault);
    (provider?.models || []).forEach((model) => {
      const option = element("option", "", model.displayName);
      option.value = model.id;
      option.selected = previousModel
        ? model.id === previousModel
        : model.id === provider.preference?.defaultModel;
      modelSelect.append(option);
    });
    const modelReason = !provider
      ? "Connect and validate a CLI provider in Settings."
      : !provider.capabilities.supportsModelSelection
        ? "This provider uses its own default model."
        : !(provider.models || []).length
          ? "No sanitized model catalog is available for this account."
          : "Model choices come from the live provider catalog.";
    setDisabledReason(
      modelSelect,
      !provider?.capabilities.supportsModelSelection ||
        !(provider?.models || []).length,
      modelReason,
    );
    help.textContent = modelReason;
    const unavailable =
      state.agent.newSessionMode && (!selectedProject() || !provider);
    const empty = !text.value.trim();
    const reason = state.agent.mutationPromise
      ? "A message is already being sent."
      : !state.online
        ? "The server connection is unavailable."
        : unavailable
          ? "Select a project and connect a validated CLI provider first."
          : empty
            ? "Enter a message to send."
            : "";
    setDisabledReason(submit, Boolean(reason), reason);
    form.setAttribute(
      "aria-busy",
      String(Boolean(state.agent.mutationPromise)),
    );
    document.getElementById("composer-message").textContent =
      reason ||
      (state.agent.newSessionMode
        ? "Start a private root session."
        : "Send a follow-up to this session.");
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
    if (state.agent.mutationPromise) return state.agent.mutationPromise;
    const text = document.getElementById("composer-text").value.trim();
    if (!text) return null;
    const newSession = state.agent.newSessionMode;
    const payload = newSession
      ? {
          projectId: state.agent.selectedProjectID,
          providerId: document.getElementById("composer-provider").value,
          model: document.getElementById("composer-model").value || null,
          initialPrompt: text,
        }
      : {
          expectedRevision:
            state.agent.transcriptPage?.session?.revision ||
            selectedSession()?.revision,
          text,
        };
    const operationID = operationIDFor(payload);
    if (!operationID) {
      toast("This browser cannot create secure operation identifiers.", true);
      return null;
    }
    const body = { operationId: operationID, ...payload };
    state.agent.mutationPromise = (async () => {
      renderAgentComposer();
      try {
        if (newSession) {
          const session = await api("api/v1/sessions", {
            method: "POST",
            body: JSON.stringify(body),
          });
          state.bootstrap.sessions.push(session);
          state.agent.selectedSessionID = session.sessionId;
          state.agent.newSessionMode = false;
          state.agent.transcriptItems = [];
          state.agent.transcriptPage = null;
          state.agent.selectionGeneration += 1;
        } else {
          await api(
            `api/v1/sessions/${encodeURIComponent(state.agent.selectedSessionID)}/messages`,
            { method: "POST", body: JSON.stringify(body) },
          );
        }
        document.getElementById("composer-text").value = "";
        state.agent.retryOperation = null;
        renderHomeProviders();
        await loadTranscript({ silent: true });
        toast(newSession ? "Chat started" : "Message accepted");
      } catch (error) {
        const composerMessage = document.getElementById("composer-message");
        composerMessage.textContent =
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
    state.route = route.surface === "home" ? "home" : `settings/${route.page}`;
    const home = document.getElementById("home-shell");
    const settings = document.getElementById("settings-shell");
    home.hidden = route.surface !== "home";
    settings.hidden = route.surface !== "settings";
    document.getElementById("window-title-text").textContent =
      route.surface === "home" ? "Agent Mode" : "Settings";
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
        "api-providers": "API Providers",
      };
      document.getElementById("settings-detail-title").textContent =
        titles[route.page];
      if (!state.providers.length && state.loading)
        renderInitialSettingsLoading();
      else if (route.page === "overview") renderOverview();
      else if (route.page === "cli-providers") {
        renderProviders(
          "cliProvider",
          "CLI Providers",
          "Configure provider admission, defaults, and server-isolated authentication for Agent Mode CLI runtimes.",
        );
      } else if (route.page === "api-providers") {
        renderProviders(
          "apiProvider",
          "API Providers",
          "Configure direct providers advertised by the server. Portable runtime availability is reported honestly by preflight.",
        );
      } else renderAgentModels();
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

  function recommendation(icon, title, detail) {
    const banner = element("div", "recommendation-banner");
    banner.append(iconNode(icon));
    const copy = element("div");
    copy.append(
      element("strong", "", title),
      document.createElement("br"),
      document.createTextNode(detail),
    );
    banner.append(copy);
    return banner;
  }

  function renderOverview() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren();
    content.append(
      pageHeader(
        "Provider Settings",
        "Server-owned runtime availability, model defaults, and authenticated connection state in one place.",
        "agent",
      ),
    );

    const providers = orderedProviders();
    const validated = providers.filter(
      (provider) => provider.preflight?.ready || provider.effectiveEnabled,
    ).length;
    const enabled = providers.filter(
      (provider) => provider.preference?.enabled,
    ).length;
    const connected = providers.filter(
      (provider) => provider.authentication?.authenticated,
    ).length;
    const summary = element("section", "settings-card provider-status-grid");
    [
      ["Advertised", String(providers.length), "Server catalog entries"],
      ["Enabled", String(enabled), "Administrative preference"],
      ["Authenticated", String(connected), "Sanitized connection state"],
      ["Validated", String(validated), "Passed provider preflight"],
    ].forEach(([label, value, detail]) =>
      summary.append(statusTile(label, value, detail)),
    );
    content.append(summary);

    if (!providers.length) {
      const empty = element("div", "empty-state-panel");
      empty.append(
        element("h2", "", "No provider catalog"),
        element(
          "p",
          "",
          "Refresh after the provider settings service becomes available.",
        ),
      );
      content.append(empty);
      return;
    }

    const card = element("section", "settings-card");
    card.append(
      element("h2", "", "Provider status"),
      element(
        "p",
        "card-subtitle",
        "Open the relevant settings page to resolve an availability reason.",
      ),
    );
    const list = element("div", "glance-list");
    providers.forEach((provider) => {
      const link = element("a", "glance-item");
      link.href = `#settings/${providerDestination(provider)}`;
      link.dataset.routeLink = "";
      const status = providerStatus(provider);
      link.append(
        element("strong", "", provider.displayName),
        element("small", "", provider.preflight?.detail || provider.summary),
      );
      const badge = element("span", `glance-status ${status.tone}`.trim());
      badge.append(element("i"), document.createTextNode(status.label));
      link.append(badge);
      list.append(link);
    });
    card.append(list);
    content.append(card);
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
      (provider) => provider.category === category,
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

  function renderAgentModels() {
    const content = document.getElementById("settings-content");
    disposeSensitiveInputs(content);
    content.replaceChildren(
      pageHeader(
        "Agent Models",
        "Choose provider defaults and only the reasoning, fast-mode, and service-tier values advertised for the selected model.",
        "model",
      ),
      recommendation(
        "model",
        "Server defaults",
        "Explicit per-session choices take precedence. These defaults apply only when a session omits the corresponding value.",
      ),
    );
    const stack = element("div", "provider-stack");
    const providers = orderedProviders();
    if (!providers.length) {
      const empty = element("div", "empty-state-panel");
      empty.append(
        element("h2", "", "No model catalogs"),
        element(
          "p",
          "",
          "The provider settings service has not advertised models.",
        ),
      );
      stack.append(empty);
    } else {
      providers.forEach((provider, index) =>
        stack.append(providerCard(provider, index === 0, true)),
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
    if (!modelsOnly) body.append(statusGrid(provider));
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

  function statusGrid(provider) {
    const grid = element("div", "provider-status-grid");
    const cli = provider.cli;
    const authentication = provider.authentication || {};
    const connection = provider.connection;
    const cliValue = cli
      ? cli.healthy
        ? "Healthy"
        : cli.installed
          ? "Attention"
          : "Not installed"
      : "API provider";
    const cliDetail = cli
      ? cli.version || cli.expectedVersion || cli.detail
      : "No CLI executable is required";
    const authValue = authentication.authenticated
      ? "Authenticated"
      : humanize(authentication.state || "notConfigured");
    const authDetail =
      authentication.accountLabel ||
      authentication.detail ||
      "No sanitized account status";
    const testValue = connection
      ? humanize(connection.testState)
      : "Not configured";
    const testDetail = connection?.lastTestedAt
      ? `Last tested ${formatDate(connection.lastTestedAt)}`
      : connection?.detail || "Connect a credential to test";
    const availability = providerStatus(provider);
    grid.append(
      statusTile("Runtime", cliValue, cliDetail),
      statusTile("Authentication", authValue, authDetail),
      statusTile("Credential test", testValue, testDetail),
      statusTile(
        "Availability",
        availability.label,
        provider.preflight?.detail || "No preflight detail",
      ),
    );
    return grid;
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

    const enabledLabel = element("label", "", "Provider");
    const enabledRow = element("div", "toggle-row");
    const toggle = element("label", "toggle");
    const enabled = document.createElement("input");
    enabled.type = "checkbox";
    enabled.name = "enabled";
    enabled.checked = provider.preference.enabled;
    enabled.setAttribute("aria-label", `Enable ${provider.displayName}`);
    const deploymentReason =
      provider.providerID === "xAI"
        ? "This provider has no portable server runtime yet."
        : "Deployment configuration does not allow this provider runtime.";
    setDisabledReason(enabled, !provider.deploymentAllowed, deploymentReason);
    toggle.append(enabled, element("span"));
    const enabledText = element(
      "span",
      "",
      enabled.checked ? "Enabled" : "Disabled",
    );
    enabledRow.append(toggle, enabledText);
    form.append(enabledLabel, enabledRow);
    if (!provider.deploymentAllowed) appendFieldHelp(form, deploymentReason);

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
      "Disabling blocks new runs; it does not terminate work already in flight.",
    );
    const save = element("button", "primary-button", "Save Settings");
    save.type = "submit";
    save.dataset.action = "save-provider-settings";
    setDisabledReason(save, true, "Change a setting to save.");
    actions.append(note, save);
    form.append(message, actions);

    function markDirty() {
      enabledText.textContent = enabled.checked ? "Enabled" : "Disabled";
      setDisabledReason(save, false, "");
      message.textContent = "Unsaved changes";
      message.className = "inline-message info form-message";
    }
    enabled.addEventListener("change", markDirty);
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
              enabled: enabled.checked,
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
    const methods = [...(provider.capabilities.authenticationMethods || [])];
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
      const direct = directAuthenticationMethods.has(method);
      const action = element(
        "button",
        active
          ? "secondary-button auth-choice-action active"
          : "secondary-button auth-choice-action",
        active
          ? "Connected"
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
      if (active) {
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
        ? "RepoPrompt CE will keep checking this separate Codex sign-in until it completes or expires."
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
          "No browser-manageable authentication operation is advertised. Configure this provider in its isolated server account.",
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

  function credentialForm(provider, methods) {
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
        codexAPIKey
          ? "OpenAI API Key"
          : hasDirectConnection
            ? "Change connection"
            : "Add connection",
      ),
      element(
        "p",
        "card-subtitle",
        codexAPIKey
          ? "API keys for direct model access. OpenAI API usage is API-billed."
          : "Credential fields are write-only and are disposed after every request outcome.",
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
    form.append(methodLabel, method, fields, message, actions);

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
      if (routeLink.hash === location.hash) window.setTimeout(renderRoute, 0);
    }
    const action = event.target.closest("[data-action]")?.dataset.action;
    if (action === "refresh") loadAll(true);
    else if (action === "new-chat") beginNewSession();
    else if (action === "load-earlier") {
      const earliest = state.agent.transcriptItems[0]?.sessionSequence;
      if (earliest) loadTranscript({ before: earliest });
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
    else if (action === "cancel-confirm") closeConfirm(false);
    else if (action === "accept-confirm") closeConfirm(true);
  }

  function handleDocumentKeydown(event) {
    trapDialogFocus(event);
    if (event.key !== "Escape") return;
    if (!document.getElementById("confirm-dialog").hidden) {
      event.preventDefault();
      closeConfirm(false);
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
      .getElementById("session-search")
      .addEventListener("input", (event) => {
        state.agent.searchText = event.target.value;
        document.getElementById("clear-session-search").hidden =
          !event.target.value;
        renderSessions();
      });
    document
      .getElementById("composer-provider")
      .addEventListener("change", () => {
        state.agent.retryOperation = null;
        renderAgentComposer();
      });
    document.getElementById("composer-model").addEventListener("change", () => {
      state.agent.retryOperation = null;
    });
    document.getElementById("composer-text").addEventListener("input", () => {
      state.agent.retryOperation = null;
      renderAgentComposer();
    });
    document
      .getElementById("composer-form")
      .addEventListener("submit", (event) => {
        event.preventDefault();
        submitComposer();
      });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) clearAgentPoll();
      else scheduleAgentPoll();
    });
    window.addEventListener("hashchange", renderRoute);
    window.addEventListener("offline", () => {
      setConnectionPresentation(
        "offline",
        "This browser is offline. Changes cannot be sent until the connection returns.",
      );
      document.getElementById("service-caption").textContent =
        "Browser offline";
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
    });
    renderRoute();
    loadAll(false);
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
        await state.agent.transcriptPromise;
        await state.agent.mutationPromise;
      },
    });
  }

  start();
})();
