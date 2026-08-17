# RepoPrompt Server

RepoPrompt Server is the Linux product: SQLite-backed Agent Mode, the operator portal, mTLS HTTP, and MCP over the same `RepoPromptHeadlessAuthority` as the macOS app. Chat collaboration is an optional signed-decision client. It is not required to boot or use `/portal`.

## Build and test without AppKit

```bash
make dev-server-build
make dev-server-test
```

These set `REPOPROMPT_SERVER_ONLY=1` and stay on the server target graph. The uncoordinated equivalents are:

```bash
REPOPROMPT_SERVER_ONLY=1 swift build --disable-automatic-resolution --product RepoPromptServer
REPOPROMPT_SERVER_ONLY=1 swift test --disable-automatic-resolution --filter RepoPromptServerTests
```

## First run

TLS material and an operator client certificate are not required to start. The process writes a local server certificate next to the state database if you did not supply one, then prints the portal URL.

```bash
state="$(pwd)/.repoprompt-server-state"
mkdir -p "$state"
REPOPROMPT_STATE_DB="$state/repoprompt.sqlite" \
REPOPROMPT_ENABLED_PROVIDERS= \
./.build/debug/RepoPromptServer
```

The log tells you to open `https://127.0.0.1:9443/portal/`. The first visit is a setup page: choose the operator password. If you are not on the same machine, paste the setup token printed in that log.

After setup, the same page is a password sign-in. The browser will warn about the local certificate; that is expected for a generated cert. Loopback health stays on `http://127.0.0.1:9080/health/ready`.

## Optional mutual TLS

Production deployments can still require operator client certificates. Set `REPOPROMPT_TLS_CERT_FILE`, `REPOPROMPT_TLS_KEY_FILE`, `REPOPROMPT_TLS_CLIENT_CA_FILE`, and `REPOPROMPT_OPERATOR_CERT_IDENTITY` together. In that mode the portal does not use a password.

| Optional integration | Purpose |
| --- | --- |
| `REPOPROMPT_APP_HMAC_FILE` / `REPOPROMPT_SYNC_HMAC_FILE` (pair) | Chat-host HMAC routes |
| `REPOPROMPT_OPERATOR_HMAC_FILE` | Operator HMAC |
| `REPOPROMPT_EVENT_HMAC_FILE` | Event signatures (otherwise a local key is created next to the state database) |
| `REPOPROMPT_APP_CERT_IDENTITY` / `REPOPROMPT_SYNC_CERT_IDENTITY` (pair) | App/sync client certificates |

## Optional chat adapter

A chat host can present a signed `AuthorizationDecision`, selected-message context (`explicit-selection` only), and HMAC-signed internal routes. Wire roles encode as `app` / `sync` / `repoprompt-operator`. Integration HMAC files and app/sync certificate identities use `REPOPROMPT_APP_*` and `REPOPROMPT_SYNC_*`.

See [`docs/architecture/linux-server.md`](../architecture/linux-server.md) for authority, persistence, and the portal map.
