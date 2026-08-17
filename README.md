# RepoPrompt Server

[![Linux Server](https://github.com/repoprompt/repoprompt-ce/actions/workflows/linux-server.yml/badge.svg?branch=rp-server)](https://github.com/repoprompt/repoprompt-ce/actions/workflows/linux-server.yml?query=branch%3Arp-server)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-black)

Headless Agent Mode for Linux. SQLite-backed projects and sessions, an operator
portal, and MCP over the same `RepoPromptHeadlessAuthority` as the macOS app.

## Run

```bash
make dev-server-build
state="$(pwd)/.repoprompt-server-state"
mkdir -p "$state"
REPOPROMPT_STATE_DB="$state/repoprompt.sqlite" \
REPOPROMPT_ENABLED_PROVIDERS= \
./.build/debug/RepoPromptServer
```

Open the printed `https://127.0.0.1:9443/portal/` URL and set the operator
password. TLS files and a client certificate are not required. Loopback health
is `http://127.0.0.1:9080/health/ready`.

```bash
make dev-server-test
docker build -f Dockerfile.server .
```

See [`docs/server/getting-started.md`](docs/server/getting-started.md).

## Docs

- [`docs/server/getting-started.md`](docs/server/getting-started.md) — boot, portal, optional mTLS
- [`docs/architecture/linux-server.md`](docs/architecture/linux-server.md) — authority, persistence, portal map
- [`AGENTS.md`](AGENTS.md) — coordinated `dev-server-*` commands

## License

Apache-2.0. See [LICENSE](LICENSE).
