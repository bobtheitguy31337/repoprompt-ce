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

  function providerStatus(provider) {
    if (provider.preflight?.ready || provider.effectiveEnabled)
      return { label: "Ready", tone: "ready" };
    if (!provider.deploymentAllowed)
      return { label: "Deployment disabled", tone: "" };
    if (!provider.preference?.enabled) return { label: "Disabled", tone: "" };
    if (
      provider.connection?.testState === "invalid" ||
      provider.authentication?.state === "attention"
    ) {
      return { label: "Needs attention", tone: "attention" };
    }
    return {
      label: humanize(provider.preflight?.reason || "Needs attention"),
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
      .getElementById("home-provider-list")
      .setAttribute("aria-busy", String(loading));
    document
      .getElementById("settings-content")
      .setAttribute("aria-busy", String(loading));
  }

  function renderInitialLoading() {
    const list = document.getElementById("home-provider-list");
    list.replaceChildren();
    for (let index = 0; index < providerOrder.length; index += 1)
      list.append(element("div", "skeleton-card"));
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
        state.bootstrap = bootstrap || { projects: [] };
        state.providers = providerCatalog.providers;
        state.generatedAt =
          providerCatalog.generatedAt || new Date().toISOString();
        document.getElementById("service-caption").textContent =
          "Connected · authenticated portal";
        setConnectionPresentation("online", "");
        updateShell();
        renderHomeProviders();
        renderRoute();
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
    const firstProject = state.bootstrap?.projects?.[0];
    document.getElementById("active-workspace-name").textContent =
      firstProject?.name || "RepoPrompt Server";
    const freshness = state.generatedAt
      ? `Updated ${formatDate(state.generatedAt)}`
      : "Not yet loaded";
    document.getElementById("catalog-freshness").textContent = freshness;
    document.getElementById("settings-freshness").textContent = freshness;
  }

  function renderHomeProviders() {
    const list = document.getElementById("home-provider-list");
    list.replaceChildren();
    const providers = orderedProviders();
    if (!providers.length) {
      list.append(
        element(
          "div",
          "empty-state-panel",
          "No providers are advertised by this server.",
        ),
      );
      list.setAttribute("aria-busy", "false");
      return;
    }
    providers.forEach((provider) => {
      const link = element("a", "glance-item");
      link.href = `#settings/${providerDestination(provider)}`;
      link.dataset.routeLink = "";
      link.dataset.providerLink = provider.providerID;
      const status = providerStatus(provider);
      const badge = element("span", `glance-status ${status.tone}`.trim());
      badge.append(element("i"), document.createTextNode(status.label));
      link.append(
        element("strong", "", provider.displayName),
        element(
          "small",
          "",
          provider.preference?.defaultModel || "Provider default model",
        ),
        badge,
      );
      list.append(link);
    });
    list.setAttribute("aria-busy", "false");
  }

  function renderHomeError(error) {
    const list = document.getElementById("home-provider-list");
    const panel = element("div", "error-banner");
    panel.setAttribute("role", "alert");
    panel.append(iconNode("warning"), document.createTextNode(error.message));
    list.replaceChildren(panel);
    list.setAttribute("aria-busy", "false");
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
      route.surface === "home" ? "Server Portal" : "Settings";
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
          ? document.getElementById("main-content")
          : home
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
        "Server-owned provider readiness, model defaults, and authenticated connection state in one place.",
        "agent",
      ),
    );

    const providers = orderedProviders();
    const ready = providers.filter(
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
      ["Ready", String(ready), "Passed provider preflight"],
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
      element("h2", "", "Provider readiness"),
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
    const details = element("details", "provider-card");
    details.open = open;
    details.dataset.providerId = provider.providerID;
    const summary = document.createElement("summary");
    const status = providerStatus(provider);
    const badge = element("span", `connection-badge ${status.tone}`.trim());
    badge.append(element("i"), element("span", "", status.label));
    const name = element("span", "provider-name");
    name.append(
      element("strong", "", provider.displayName),
      element("small", "", provider.summary),
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

  function authenticationSection(provider) {
    const section = element("section", "provider-section");
    section.dataset.controlFamily = "authentication";
    section.append(
      sectionHeading(
        "Connection & authentication",
        "Only methods advertised by this provider are rendered.",
      ),
    );

    const methods = element("div", "auth-methods");
    provider.capabilities.authenticationMethods.forEach((method) => {
      const chip = element(
        "span",
        `auth-chip${provider.connection?.authenticationMethod === method ? " active" : ""}`,
        humanize(method),
      );
      methods.append(chip);
    });
    section.append(methods);

    if (provider.connection) section.append(connectionPanel(provider));

    const directMethods = provider.capabilities.authenticationMethods.filter(
      (method) => directAuthenticationMethods.has(method),
    );
    if (directMethods.length)
      section.append(credentialForm(provider, directMethods));

    const flows = provider.capabilities.authFlows || [];
    if (
      flows.length ||
      provider.capabilities.authenticationMethods.some((method) =>
        transientAuthenticationMethods.has(method),
      )
    ) {
      section.append(flowControls(provider, flows));
    }

    if (!directMethods.length && !flows.length) {
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
    panel.append(
      element("h2", "", "Current connection"),
      element(
        "p",
        "card-subtitle",
        `${humanize(connection.authenticationMethod)} · ${connection.accountLabel || "No account label"} · revision ${connection.revision}`,
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
    wrapper.append(
      element(
        "h2",
        "",
        provider.connection ? "Rotate connection" : "Add connection",
      ),
      element(
        "p",
        "card-subtitle",
        "Credential fields are write-only and are disposed after every request outcome.",
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
      provider.connection ? "Rotate Credential" : "Connect",
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
      submit.textContent = provider.connection ? "Rotating…" : "Connecting…";
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

  function flowControls(provider, flows) {
    const wrapper = element("div", "settings-card flow-card");
    wrapper.append(
      element("h2", "", "Provider authentication flows"),
      element(
        "p",
        "card-subtitle",
        "Only server-advertised transient flows can start in the portal.",
      ),
    );
    const message = element(
      "div",
      "inline-message info",
      "Device codes remain only in this transient page state.",
    );
    message.setAttribute("role", "status");
    message.tabIndex = -1;
    const list = element("div", "flow-list");
    flows.forEach((flow) => {
      const row = element("div", "flow-option");
      const copy = element("div");
      copy.append(
        element("strong", "", flow.displayName),
        element("small", "", flow.detail),
      );
      const button = element(
        "button",
        "secondary-button",
        flow.startable ? `Start ${flow.displayName}` : "Unavailable",
      );
      button.type = "button";
      button.dataset.action = "start-auth-flow";
      button.dataset.flowKind = flow.kind;
      const anotherFlow =
        state.activeFlow && state.activeFlow.providerID !== provider.providerID;
      const reason = !flow.startable
        ? flow.detail
        : anotherFlow
          ? "Finish or cancel the active authentication flow first."
          : "";
      setDisabledReason(button, !flow.startable || anotherFlow, reason);
      if (!button.disabled) {
        button.addEventListener("click", () =>
          startAuthFlow(provider, flow, button, message),
        );
      }
      row.append(copy, button);
      list.append(row);
    });

    const missingDescriptors =
      provider.capabilities.authenticationMethods.filter(
        (method) =>
          transientAuthenticationMethods.has(method) &&
          !flows.some((flow) => flow.kind === method),
      );
    if (missingDescriptors.length) {
      const unavailable = element("div", "unavailable-panel");
      unavailable.append(
        iconNode("info"),
        document.createTextNode(
          `${missingDescriptors.map(humanize).join(", ")} requires a provider flow, but this server does not advertise a startable adapter.`,
        ),
      );
      list.append(unavailable);
    }

    wrapper.append(list, message);
    if (state.activeFlow?.providerID === provider.providerID)
      wrapper.append(devicePanel(provider));
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
      element("h4", "", humanize(flow.kind)),
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
    else if (action === "skip-content") {
      const target = document.getElementById("settings-shell").hidden
        ? document.getElementById("home-shell")
        : document.getElementById("main-content");
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
      disposeSensitiveInputs,
      whenIdle: async () => state.loadPromise,
    });
  }

  start();
})();
