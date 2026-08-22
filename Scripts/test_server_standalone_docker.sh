#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${REPOPROMPT_SERVER_ACCEPTANCE_IMAGE:-repoprompt-server-standalone:test}"

command -v docker >/dev/null 2>&1 || { printf 'Docker is required.\n' >&2; exit 1; }
docker info >/dev/null 2>&1 || { printf 'Docker daemon is unavailable.\n' >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { printf 'Docker Compose v2 is required.\n' >&2; exit 1; }
[[ "$(uname -s)" == Linux && -f /etc/os-release ]] || { printf 'Ubuntu 24.04 is required.\n' >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || { printf 'Ubuntu 24.04 is required.\n' >&2; exit 1; }
if [[ "$(id -u)" != 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { printf 'Root or passwordless sudo is required.\n' >&2; exit 1; }
  exec sudo env REPOPROMPT_SERVER_ACCEPTANCE_IMAGE="$IMAGE" "$0" "$@"
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/repoprompt-server-standalone.XXXXXX")"
INSTALL_DIR="$TMP_ROOT/install"
BIN_DIR="$TMP_ROOT/bin"
DATA_DIR="$TMP_ROOT/data"
SECRETS_DIR="$TMP_ROOT/secrets"
BACKUP_DIR="$TMP_ROOT/backups"
PROVIDER_DIR="$TMP_ROOT/providers"
INSTALL_LOG="$TMP_ROOT/install.log"
TOKEN_ONE="$TMP_ROOT/setup-token-one"
TOKEN_TWO="$TMP_ROOT/setup-token-two"

cleanup() {
  if [[ -x "$INSTALL_DIR/repoprompt-server" && -f "$INSTALL_DIR/.env" ]]; then
    REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
      "$INSTALL_DIR/repoprompt-server" uninstall >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

BIND_PORT="$(free_port)"
HEALTH_PORT="$(free_port)"
while [[ "$HEALTH_PORT" == "$BIND_PORT" ]]; do HEALTH_PORT="$(free_port)"; done

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build --tag "$IMAGE" -f "$ROOT/Dockerfile.server" "$ROOT"
fi

install_command=(
  "$ROOT/Distribution/Server/install.sh"
  --image "$IMAGE"
  --allow-unpinned-image
  --hostname localhost
  --bind-port "$BIND_PORT"
  --health-port "$HEALTH_PORT"
  --install-dir "$INSTALL_DIR"
  --bin-dir "$BIN_DIR"
  --data-dir "$DATA_DIR"
  --secrets-dir "$SECRETS_DIR"
  --backup-dir "$BACKUP_DIR"
  --provider-dir "$PROVIDER_DIR"
)

"${install_command[@]}" >"$INSTALL_LOG" 2>&1
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" setup-token --output "$TOKEN_ONE"
[[ "$(stat -c '%a' "$TOKEN_ONE")" == 600 ]] || { printf 'Setup token mode is not 0600.\n' >&2; exit 1; }
TOKEN_DIGEST_ONE="$(sha256sum "$TOKEN_ONE" | cut -d' ' -f1)"
VAULT_DIGEST_ONE="$(sha256sum "$SECRETS_DIR/provider-vault.key" | cut -d' ' -f1)"
AGE_DIGEST_ONE="$(sha256sum "$SECRETS_DIR/backup-age-identity.txt" | cut -d' ' -f1)"
grep -Fq "$(tr -d '\n' < "$TOKEN_ONE")" "$INSTALL_LOG" && { printf 'Setup token leaked to install log.\n' >&2; exit 1; }
grep -Fq "$(grep '^AGE-SECRET-KEY-' "$SECRETS_DIR/backup-age-identity.txt")" "$INSTALL_LOG" && { printf 'Backup identity leaked to install log.\n' >&2; exit 1; }
curl -kfsS --max-time 5 "https://127.0.0.1:$BIND_PORT/portal/" | grep -q 'RepoPrompt'
curl -fsS --max-time 5 "http://127.0.0.1:$HEALTH_PORT/health/ready" | grep -q '"ready":true'

# Re-running the complete installation command must preserve configuration,
# state, secrets, the live container, and the outstanding one-use setup token.
"${install_command[@]}" >>"$INSTALL_LOG" 2>&1
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" setup-token --output "$TOKEN_TWO"
TOKEN_DIGEST_TWO="$(sha256sum "$TOKEN_TWO" | cut -d' ' -f1)"
[[ "$TOKEN_DIGEST_ONE" == "$TOKEN_DIGEST_TWO" ]] || { printf 'Idempotent rerun replaced the setup token.\n' >&2; exit 1; }
[[ "$VAULT_DIGEST_ONE" == "$(sha256sum "$SECRETS_DIR/provider-vault.key" | cut -d' ' -f1)" ]] || { printf 'Idempotent rerun replaced the provider vault key.\n' >&2; exit 1; }
[[ "$AGE_DIGEST_ONE" == "$(sha256sum "$SECRETS_DIR/backup-age-identity.txt" | cut -d' ' -f1)" ]] || { printf 'Idempotent rerun replaced the backup identity.\n' >&2; exit 1; }
[[ "$(docker ps --filter name='^/repoprompt-server$' --format '{{.ID}}' | wc -l | tr -d ' ')" == 1 ]] || {
  printf 'Idempotent rerun did not retain exactly one Server container.\n' >&2
  exit 1
}

REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" provider-check
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" backup acceptance.age >/dev/null
[[ -s "$BACKUP_DIR/acceptance.age" && -s "$BACKUP_DIR/acceptance.age.sidecar.json" ]] || {
  printf 'Verified backup artifacts were not created.\n' >&2
  exit 1
}

REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" uninstall >/dev/null
[[ -d "$DATA_DIR" && -f "$SECRETS_DIR/provider-vault.key" && -f "$BACKUP_DIR/acceptance.age" ]] || {
  printf 'Preserving uninstall removed operator state.\n' >&2
  exit 1
}
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" uninstall --destroy-data --confirm DESTROY-REPOPROMPT-DATA >/dev/null
[[ ! -e "$DATA_DIR" && -f "$SECRETS_DIR/backup-age-identity.txt" && -f "$BACKUP_DIR/acceptance.age" ]] || {
  printf 'Explicit destroy semantics did not match the contract.\n' >&2
  exit 1
}

printf 'Standalone Server Docker acceptance passed: fresh install, idempotent rerun, safe token export, readiness, backup, and uninstall semantics.\n'
