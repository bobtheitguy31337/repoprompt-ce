"use strict";

const state = { providers: [], bootstrap: null, route: "agent", loading: false };
const providerOrder = ["codex", "claudeCompatible", "openCodeACP", "cursorACP", "xAI"];

// Hand-authored web-safe semantic line glyphs. They intentionally substitute
// for non-portable SF Symbols without copying Apple artwork.
const icons = {
  search: '<circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3.5 3.5"/>',
  refresh: '<path d="M13 5V2l-2 2a5.5 5.5 0 1 0 1.2 7.8"/>',
  settings: '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M12.6 3.4l-1.4 1.4M4.8 11.2l-1.4 1.4"/>',
  collapse: '<path d="m4 6 4-4 4 4M4 10l4 4 4-4"/>', message: '<path d="M2 3.5h12v8H7l-3.5 2v-2H2z"/>',
  folder: '<path d="M1.5 4h5l1.4 1.5h6.6v7.5h-13z"/>', more: '<circle cx="3" cy="8" r=".7" fill="currentColor"/><circle cx="8" cy="8" r=".7" fill="currentColor"/><circle cx="13" cy="8" r=".7" fill="currentColor"/>',
  workflow: '<circle cx="4" cy="3" r="1.5"/><circle cx="12" cy="8" r="1.5"/><circle cx="4" cy="13" r="1.5"/><path d="M5.5 3h2A2.5 2.5 0 0 1 10 5.5V8M5.5 13h2A2.5 2.5 0 0 0 10 10.5V8"/>',
  model: '<path d="M8 1.5 14 5v6l-6 3.5L2 11V5zM2 5l6 3.5L14 5M8 8.5v6"/>',
  shield: '<path d="M8 1.5 13 3v4.3c0 3.2-2 5.7-5 7.2-3-1.5-5-4-5-7.2V3z"/><path d="m5.5 8 1.5 1.5 3.5-4"/>',
  oracle: '<path d="M3 11.5V5.8A4.8 4.8 0 0 1 7.8 1h.4A4.8 4.8 0 0 1 13 5.8v5.7M5 11.5h6M6.5 14h3"/><circle cx="6" cy="7" r=".6" fill="currentColor"/><circle cx="10" cy="7" r=".6" fill="currentColor"/>',
  hammer: '<path d="m2 13 6-6M6 3l2-2 5 5-2 2zM1 14l2-1 1 1-1 1z"/>',
  eye: '<path d="M1.5 8s2.4-4 6.5-4 6.5 4 6.5 4-2.4 4-6.5 4-6.5-4-6.5-4z"/><circle cx="8" cy="8" r="2"/>',
  code: '<path d="m5 4-4 4 4 4M11 4l4 4-4 4M9.5 2 6.5 14"/>', chevron: '<path d="m6 3 5 5-5 5"/>',
  attach: '<path d="m5 8 4.5-4.5a3 3 0 0 1 4.2 4.2L7.5 14A4 4 0 0 1 2 8.2l6-6"/>', send: '<path d="m2 2 12 6-12 6 2-6zM4 8h10"/>',
  context: '<path d="M2 2.5h12v11H2zM5 2.5v11M7.5 5h4M7.5 8h4M7.5 11h2.5"/>', branch: '<circle cx="4" cy="3" r="1.5"/><circle cx="4" cy="13" r="1.5"/><circle cx="12" cy="8" r="1.5"/><path d="M4 4.5v7M5.5 4.5h2A4.5 4.5 0 0 1 12 8"/>',
  back: '<path d="m9.5 3-5 5 5 5M5 8h9"/>', terminal: '<path d="M1.5 3h13v10h-13zM4 6l2 2-2 2M8 10h3"/>',
  agent: '<circle cx="8" cy="5" r="3"/><path d="M2.5 14c.5-3 2.4-4.5 5.5-4.5s5 1.5 5.5 4.5"/>', appearance: '<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 0 0 0 12z"/>',
  keyboard: '<path d="M1.5 4h13v8h-13zM4 7h.1M7 7h.1M10 7h.1M12 7h.1M4 10h8"/>', sliders: '<path d="M2 4h12M2 8h12M2 12h12M5 2v4M11 6v4M7 10v4"/>',
  chart: '<path d="M2 14V8h3v6M6.5 14V3h3v11M11 14V6h3v8"/>', server: '<rect x="2" y="2" width="12" height="5" rx="1"/><rect x="2" y="9" width="12" height="5" rx="1"/><circle cx="5" cy="4.5" r=".6" fill="currentColor"/><circle cx="5" cy="11.5" r=".6" fill="currentColor"/>',
  tools: '<path d="m3 13 5-5M9 2a3 3 0 0 0 3.5 3.5L8 10l-2-2 4.5-4.5A3 3 0 0 0 9 2z"/><path d="m2 10 4 4"/>', check: '<path d="m2.5 8 3.5 3.5 7.5-7.5"/>',
  preset: '<path d="M2 2h12v12H2zM5 5h6M5 8h6M5 11h3"/>', cloud: '<path d="M4.5 12.5H12a3 3 0 0 0 .4-6A4.5 4.5 0 0 0 4 5.5a3.5 3.5 0 0 0 .5 7z"/>', list: '<path d="M5 4h9M5 8h9M5 12h9"/><circle cx="2" cy="4" r=".6" fill="currentColor"/><circle cx="2" cy="8" r=".6" fill="currentColor"/><circle cx="2" cy="12" r=".6" fill="currentColor"/>'
};

function installIcons(root = document) {
  root.querySelectorAll("[data-icon]").forEach(node => {
    const content = icons[node.dataset.icon];
    if (!content || node.querySelector("svg")) return;
    node.insertAdjacentHTML("afterbegin", `<svg viewBox="0 0 16 16" aria-hidden="true">${content}</svg>`);
  });
}

function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>'"]/g, char => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"})[char]);
}

function humanize(value) {
  const labels = {browserOAuth:"Browser OAuth",deviceCodeBeta:"Device auth (beta)",apiKey:"API key",enterpriseAccessToken:"Enterprise access token",authToken:"Auth token",keyHelper:"Key helper",workloadIdentityFederation:"Workload identity federation",browserLogin:"Browser login",providerSpecific:"Provider-specific",fast:"Fast",priority:"Priority",xhigh:"XHigh",max:"Max",ultra:"Ultra"};
  return labels[value] || String(value ?? "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, c => c.toUpperCase());
}

async function api(path, options = {}) {
  const mutation = ["POST", "PUT", "PATCH", "DELETE"].includes((options.method || "GET").toUpperCase());
  const response = await fetch(path, {cache: "no-store", credentials: "same-origin", ...options, headers: {"Accept":"application/json", ...(options.body ? {"Content-Type":"application/json"} : {}), ...(mutation ? {"X-RepoPrompt-Portal-CSRF":"1"} : {}), ...(options.headers || {})}});
  const contentType = response.headers.get("content-type") || "";
  const body = contentType.includes("application/json") ? await response.json() : null;
  if (!response.ok) throw new Error(body?.message || `Request failed (${response.status})`);
  return body;
}

async function loadAll(refresh = false) {
  if (state.loading) return;
  state.loading = true;
  document.getElementById("refresh-button").classList.add("loading");
  try {
    const [bootstrap, providerCatalog] = await Promise.all([
      api("/portal/api/v1/bootstrap"),
      api(`/portal/api/v1/provider-settings${refresh ? "?refresh=true" : ""}`)
    ]);
    state.bootstrap = bootstrap;
    state.providers = providerCatalog.providers || [];
    updateShell();
    route();
    document.getElementById("service-dot").classList.add("healthy");
    document.getElementById("service-caption").textContent = "Connected · mTLS operator";
  } catch (error) {
    document.getElementById("service-dot").classList.remove("healthy");
    document.getElementById("service-caption").textContent = "Portal connection unavailable";
    toast(error.message, true);
    if (!document.getElementById("settings-shell").hidden) renderError(error);
  } finally {
    state.loading = false;
    document.getElementById("refresh-button").classList.remove("loading");
  }
}

function updateShell() {
  const projects = state.bootstrap?.projects || [];
  const sessions = state.bootstrap?.sessions || [];
  const firstProject = projects[0];
  document.getElementById("active-workspace-name").textContent = firstProject?.name || "RepoPrompt Server";
  const rootList = document.getElementById("workspace-root-list");
  rootList.textContent = "";
  const roots = projects.flatMap(project => (project.rootNames || []).map(name => ({logicalName:name, projectName:project.name})));
  if (!roots.length) appendRoot(rootList, "Open a project to begin", null);
  roots.slice(0, 8).forEach(root => appendRoot(rootList, root.logicalName, root.projectName));

  const list = document.getElementById("session-list");
  list.textContent = "";
  if (!sessions.length) {
    const row = sessionRow({title:"New Agent Session", subtitle:"Ready to build"}, true);
    list.append(row);
  } else {
    sessions.slice(0, 30).forEach((session, index) => list.append(sessionRow({title:session.title, subtitle:`${humanize(session.provider)} · ${humanize(session.state)}`}, index === 0)));
    document.getElementById("active-session-title").textContent = sessions[0].title;
    document.getElementById("active-provider-label").textContent = `${humanize(sessions[0].provider)} · ${sessions[0].model || "Provider default"}`;
  }
  const enabled = providerOrder.map(id => state.providers.find(provider => provider.providerID === id)).find(provider => provider?.effectiveEnabled);
  if (enabled) document.getElementById("model-pill-label").textContent = enabled.preference.defaultModel || enabled.displayName;
}

function appendRoot(list, name, projectName) {
  const row = document.createElement("div"); row.className = "root-row";
  const icon = document.createElement("span"); icon.dataset.icon = "folder";
  const text = document.createElement("span"); text.textContent = projectName ? `${name} · ${projectName}` : name;
  row.append(icon, text); list.append(row); installIcons(row);
}

function sessionRow(item, selected) {
  const button = document.createElement("button"); button.type = "button"; button.className = `session-row${selected ? " selected" : ""}`;
  const glyph = document.createElement("span"); glyph.className = "session-glyph"; glyph.dataset.icon = "message";
  const copy = document.createElement("span"); copy.className = "session-copy";
  const title = document.createElement("strong"); title.textContent = item.title;
  const subtitle = document.createElement("small"); subtitle.textContent = item.subtitle;
  copy.append(title, subtitle); button.append(glyph, copy); installIcons(button); return button;
}

function route() {
  const raw = location.hash.replace(/^#/, "") || "agent";
  state.route = raw;
  const settings = raw.startsWith("settings/");
  document.getElementById("agent-shell").hidden = settings;
  document.getElementById("settings-shell").hidden = !settings;
  document.getElementById("window-title-text").textContent = settings ? "Settings" : "Agent Mode";
  if (!settings) return;
  const page = raw.split("/")[1] || "cli-providers";
  document.querySelectorAll("#settings-nav a").forEach(link => link.classList.toggle("active", link.dataset.route === page));
  const titles = {"cli-providers":"CLI Providers","agent-models":"Agent Models","api-providers":"API Providers","overview":"Overview","agent-permissions":"Agent Permissions","agent-workflows":"Agent Workflows","context-builder":"Context Builder","appearance":"Appearance","updates":"Updates","keyboard":"Keyboard Shortcuts","advanced":"Advanced","telemetry":"Telemetry","mcp":"MCP Server","tools":"Tools","workspace-approvals":"Workspace Approvals","model-presets":"Model Presets","model-config":"Model Config","manage-workspaces":"Manage Workspaces","manage-presets":"Manage Presets","chat-settings":"Chat Settings","workflow-presets":"Workflow Presets","copy-order":"Copy Prompt Order"};
  const title = titles[page] || humanize(page);
  document.getElementById("settings-detail-title").textContent = title;
  if (page === "cli-providers") renderProviders("cliProvider", "CLI Providers", "Primary way to add Agent Mode model support. Connect Codex, Claude Code, OpenCode, or Cursor while credentials and native auth stay isolated on the server.");
  else if (page === "api-providers") renderProviders("apiProvider", "API Providers", "Server-managed API providers. Secrets are provisioned outside the browser and the portal receives only sanitized status.");
  else if (page === "agent-models") renderAgentModels();
  else renderPlaceholder(title, page);
}

function renderProviders(category, title, subtitle) {
  const content = document.getElementById("settings-content");
  const providers = providerOrder.map(id => state.providers.find(provider => provider.providerID === id)).filter(provider => provider?.category === category);
  content.innerHTML = `<header class="settings-header"><h1>${escapeHTML(title)}</h1><p>${escapeHTML(subtitle)}</p></header><div class="recommendation-banner"><span data-icon="shield"></span><div><strong>Secrets stay server-side</strong><br>Credential files, API keys, tokens, helper output, native auth endpoints, and raw logs are never returned by this portal contract.</div></div><div class="provider-stack" id="provider-stack"></div>`;
  const stack = content.querySelector("#provider-stack");
  if (!providers.length) stack.innerHTML = '<div class="error-banner">Provider catalog is unavailable.</div>';
  providers.forEach((provider, index) => stack.append(providerCard(provider, index === 0)));
  installIcons(content);
}

function renderAgentModels() {
  const content = document.getElementById("settings-content");
  content.innerHTML = '<header class="settings-header"><h1>Agent Models</h1><p>Single source of truth for provider defaults, reasoning effort, and service tier on the standalone server.</p></header><div class="recommendation-banner"><span data-icon="model"></span><div><strong>Server defaults</strong><br>Explicit per-session choices win; these defaults are applied in the shared Swift provider dispatcher when a session omits them.</div></div><div class="provider-stack" id="provider-stack"></div>';
  const stack = content.querySelector("#provider-stack");
  providerOrder.map(id => state.providers.find(provider => provider.providerID === id)).filter(provider => provider && provider.models.length).forEach(provider => stack.append(providerCard(provider, true, true)));
  installIcons(content);
}

function providerCard(provider, open, modelsOnly = false) {
  const connected = provider.effectiveEnabled && provider.authentication.authenticated && (provider.cli?.healthy ?? true);
  const details = document.createElement("details"); details.className = "provider-card"; details.open = open;
  const summary = document.createElement("summary");
  const badge = connected ? "Connected" : !provider.deploymentAllowed ? "Deployment disabled" : provider.preference.enabled ? "Needs attention" : "Disabled";
  summary.innerHTML = `<span data-icon="${provider.category === "cliProvider" ? "terminal" : "cloud"}"></span><span class="provider-name"><strong>${escapeHTML(provider.displayName)}</strong><small>${escapeHTML(provider.summary)}</small></span><span class="connection-badge ${connected ? "connected" : ""}"><i></i>${escapeHTML(badge)}</span><span data-icon="chevron"></span>`;
  const body = document.createElement("div"); body.className = "provider-card-body";
  if (!modelsOnly) body.append(statusGrid(provider));
  body.append(settingsForm(provider));
  if (!modelsOnly) body.append(authSection(provider));
  details.append(summary, body); installIcons(details); return details;
}

function statusGrid(provider) {
  const grid = document.createElement("div"); grid.className = "provider-status-grid";
  const cli = provider.cli;
  const auth = provider.authentication;
  const values = [
    ["CLI", cli ? (cli.healthy ? "Healthy" : cli.installed ? "Attention" : "Not installed") : "API runtime pending", cli?.version || cli?.detail || "No executable is exposed"],
    ["Authentication", auth.authenticated ? "Authenticated" : humanize(auth.state), auth.accountLabel || (auth.method ? humanize(auth.method) : auth.detail)],
    ["Runtime", provider.effectiveEnabled ? "Ready" : provider.preference.enabled ? "Not admitted" : "Disabled", provider.runtimePreflightVerified ? "Preflight verified" : provider.deploymentAllowed ? "Preflight required" : "Blocked by deployment policy"]
  ];
  values.forEach(([label, value, detail]) => {
    const tile = document.createElement("div"); tile.className = "status-tile";
    const l = document.createElement("span"); l.textContent = label;
    const v = document.createElement("strong"); v.textContent = value;
    const d = document.createElement("small"); d.textContent = detail || "—";
    tile.append(l, v, d); grid.append(tile);
  });
  return grid;
}

function settingsForm(provider) {
  const wrap = document.createElement("div");
  const form = document.createElement("form"); form.className = "settings-form";
  const enabledLabel = document.createElement("label"); enabledLabel.textContent = "Provider";
  const enabledRow = document.createElement("div"); enabledRow.className = "toggle-row";
  const toggle = document.createElement("label"); toggle.className = "toggle";
  const enabled = document.createElement("input"); enabled.type = "checkbox"; enabled.checked = provider.preference.enabled; enabled.disabled = !provider.deploymentAllowed;
  toggle.append(enabled, document.createElement("span"));
  const enabledText = document.createElement("span"); enabledText.textContent = enabled.checked ? "Enabled" : "Disabled";
  enabled.addEventListener("change", () => enabledText.textContent = enabled.checked ? "Enabled" : "Disabled");
  enabledRow.append(toggle, enabledText); form.append(enabledLabel, enabledRow);

  const model = addSelect(form, "Default model", provider.models, provider.preference.defaultModel, item => item.displayName, item => item.id, "Provider default");
  const effort = addSelect(form, "Reasoning effort", [], provider.preference.reasoningEffort, humanize, value => value, "Model default");
  const speed = addSelect(form, "Speed", [], provider.preference.speedMode, humanize, value => value, "Standard");
  const tier = addSelect(form, "Service tier", [], provider.preference.serviceTier, humanize, value => value, "Standard");

  function refreshModelOptions() {
    const selected = provider.models.find(item => item.id === model.value);
    populateSelect(effort, selected?.reasoningEfforts || [], provider.preference.reasoningEffort, humanize, value => value, "Model default");
    populateSelect(speed, selected?.speedModes || [], provider.preference.speedMode, humanize, value => value, "Standard");
    populateSelect(tier, selected?.serviceTiers || [], provider.preference.serviceTier, humanize, value => value, "Standard");
    effort.disabled = !provider.capabilities.supportsReasoningEffort || !selected?.reasoningEfforts.length;
    speed.disabled = !provider.capabilities.supportsSpeedMode || !selected?.speedModes.length;
    tier.disabled = !provider.capabilities.supportsServiceTier || !selected?.serviceTiers.length;
  }
  model.disabled = !provider.capabilities.supportsModelSelection || provider.models.length === 0;
  model.addEventListener("change", refreshModelOptions); refreshModelOptions();

  const actions = document.createElement("div"); actions.className = "provider-actions";
  const note = document.createElement("div"); note.className = "secret-note"; note.textContent = "Preferences contain no credentials. Disabling blocks new runs and does not terminate work already in flight.";
  const save = document.createElement("button"); save.type = "submit"; save.className = "primary-button"; save.textContent = "Save Settings";
  actions.append(note, save);
  form.addEventListener("submit", async event => {
    event.preventDefault(); save.disabled = true; save.textContent = "Saving…";
    try {
      const updated = await api(`/portal/api/v1/provider-settings/${encodeURIComponent(provider.providerID)}`, {method:"PATCH", body:JSON.stringify({expectedRevision:provider.preference.revision,enabled:enabled.checked,defaultModel:model.value || null,reasoningEffort:effort.value || null,speedMode:speed.value || null,serviceTier:tier.value || null})});
      const index = state.providers.findIndex(item => item.providerID === updated.providerID); if (index >= 0) state.providers[index] = updated;
      toast(`${provider.displayName} settings saved`); route(); updateShell();
    } catch (error) { toast(error.message, true); save.disabled = false; save.textContent = "Save Settings"; }
  });
  wrap.append(form, actions); return wrap;
}

function addSelect(form, labelText, values, selected, label, key, emptyLabel) {
  const labelNode = document.createElement("label"); labelNode.textContent = labelText;
  const select = document.createElement("select"); populateSelect(select, values, selected, label, key, emptyLabel);
  form.append(labelNode, select); return select;
}

function populateSelect(select, values, selected, label, key, emptyLabel) {
  select.textContent = "";
  const empty = document.createElement("option"); empty.value = ""; empty.textContent = emptyLabel; select.append(empty);
  values.forEach(value => { const option = document.createElement("option"); option.value = key(value); option.textContent = label(value); option.selected = option.value === selected; select.append(option); });
}

function authSection(provider) {
  const section = document.createElement("div");
  const label = document.createElement("div"); label.className = "provider-section-title"; label.textContent = "Connection & authentication";
  const methods = document.createElement("div"); methods.className = "auth-methods";
  provider.capabilities.authenticationMethods.forEach(method => { const chip = document.createElement("span"); chip.className = "auth-chip"; chip.textContent = humanize(method); methods.append(chip); });
  const actions = document.createElement("div"); actions.className = "provider-actions";
  const note = document.createElement("div"); note.className = "secret-note"; note.textContent = provider.authentication.detail || "Only sanitized authentication status is exposed.";
  const flowButtons = document.createElement("div"); flowButtons.className = "auth-methods";
  provider.capabilities.authFlows.forEach(flow => {
    const button = document.createElement("button"); button.type = "button"; button.className = "secondary-button auth-flow-button"; button.textContent = flow.displayName; button.disabled = !flow.startable; button.title = flow.detail;
    if (flow.startable) button.addEventListener("click", () => startAuthFlow(provider, flow, button));
    flowButtons.append(button);
  });
  actions.append(note, flowButtons); section.append(label, methods, actions); return section;
}

async function startAuthFlow(provider, flow, button) {
  button.disabled = true;
  try {
    const challenge = await api(`/portal/api/v1/provider-settings/${encodeURIComponent(provider.providerID)}/auth-flows`, {method:"POST", body:JSON.stringify({kind:flow.kind})});
    // Device codes are held only in this transient DOM toast; they are never
    // copied into storage, URLs, telemetry, or console output.
    toast(challenge.userCode ? `Device code: ${challenge.userCode}` : "Authentication flow started");
  } catch (error) { toast(error.message, true); }
  finally { button.disabled = !flow.startable; }
}

function renderPlaceholder(title, routeName) {
  const content = document.getElementById("settings-content");
  const mapped = {"manage-workspaces":"Workspace landing, recent project grid, and source provisioning will use the canonical project authority.","agent-workflows":"Built-in and custom workflow management will use the canonical workflow store.","context-builder":"Context Builder and Oracle will reuse the portable context runtime as it is extracted.","mcp":"MCP server configuration remains a separate RepoPrompt-owned surface."};
  content.innerHTML = `<header class="settings-header"><h1>${escapeHTML(title)}</h1><p>This desktop surface is mapped into the portal navigation hierarchy.</p></header><div class="placeholder-surface"><div class="placeholder-icon" data-icon="settings"></div><h2>${escapeHTML(title)}</h2><p>${escapeHTML(mapped[routeName] || "The browser shell preserves this RepoPrompt surface and terminology; its server-backed controls are scheduled after the provider/settings vertical slice.")}</p></div>`;
  installIcons(content);
}

function renderError(error) {
  document.getElementById("settings-content").innerHTML = `<div class="error-banner">${escapeHTML(error.message)}</div>`;
}

function toast(message, error = false) {
  const node = document.createElement("div"); node.className = `toast${error ? " error" : ""}`; node.textContent = message;
  document.getElementById("toast-region").append(node); setTimeout(() => node.remove(), 4200);
}

document.getElementById("refresh-button").addEventListener("click", () => loadAll(true));
document.getElementById("settings-search").addEventListener("input", event => {
  const query = event.target.value.trim().toLowerCase();
  document.querySelectorAll("#settings-nav a").forEach(link => link.hidden = query && !link.textContent.toLowerCase().includes(query));
});
document.getElementById("session-search").addEventListener("input", event => {
  const query = event.target.value.trim().toLowerCase();
  document.querySelectorAll("#session-list .session-row").forEach(row => row.hidden = query && !row.textContent.toLowerCase().includes(query));
});
window.addEventListener("hashchange", route);
installIcons(); route(); loadAll();
