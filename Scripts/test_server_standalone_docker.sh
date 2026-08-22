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
umask 077
INSTALL_DIR="$TMP_ROOT/install"
BIN_DIR="$TMP_ROOT/bin"
DATA_DIR="$TMP_ROOT/data"
SECRETS_DIR="$TMP_ROOT/secrets"
BACKUP_DIR="$TMP_ROOT/backups"
PROVIDER_DIR="$TMP_ROOT/providers"
TOPOLOGY_ROOT="$TMP_ROOT/topology-validation"
INSTALL_LOG="$TMP_ROOT/install.log"
SERVER_LOG="$TMP_ROOT/server.log"
PROVIDER_LOG="$TMP_ROOT/provider-check.log"
TOKEN_ONE="$TMP_ROOT/setup-token-one"
TOKEN_TWO="$TMP_ROOT/setup-token-two"
TOKEN_SETUP="$TMP_ROOT/setup-token-current"
PASSWORD_FILE="$TMP_ROOT/operator-password"
SETUP_BODY="$TMP_ROOT/setup-request.json"
LOGIN_BODY="$TMP_ROOT/login-request.json"
PROJECT_BODY="$TMP_ROOT/project-request.json"
SETUP_RESPONSE="$TMP_ROOT/setup-response.json"
AUTH_RESPONSE="$TMP_ROOT/auth-response.json"
LOGIN_RESPONSE="$TMP_ROOT/login-response.json"
SESSIONS_RESPONSE="$TMP_ROOT/sessions-response.json"
PROVIDER_RESPONSE="$TMP_ROOT/provider-response.json"
PROJECT_RESPONSE="$TMP_ROOT/project-response.json"
BOOTSTRAP_RESPONSE="$TMP_ROOT/bootstrap-response.json"
SETUP_COOKIE_JAR="$TMP_ROOT/setup-cookies"
LOGIN_COOKIE_JAR="$TMP_ROOT/login-cookies"
SETUP_COOKIE_HEADER="$TMP_ROOT/setup-cookie-header"
LOGIN_COOKIE_HEADER="$TMP_ROOT/login-cookie-header"
CURRENT_PHASE=bootstrap

phase() {
  CURRENT_PHASE="$1"
  printf 'Standalone acceptance phase: %s\n' "$CURRENT_PHASE"
}

diagnose_failure() {
  local status="$1"
  printf 'Standalone acceptance failed during phase %q (exit %s).\n' "$CURRENT_PHASE" "$status" >&2
  if [[ -s "$INSTALL_LOG" ]]; then
    printf '%s\n' 'Secret-safe installer diagnostics:' >&2
    awk '
      /^ERROR:/ ||
      /^Configuration is valid\.$/ ||
      /^RepoPrompt Server state and owner-only secrets are initialized\.$/ ||
      /^RepoPrompt Server did not become ready before the timeout$/
    ' "$INSTALL_LOG" >&2 || true
  fi
  if docker inspect repoprompt-server >/dev/null 2>&1; then
    docker inspect --format \
      'Container state: status={{.State.Status}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restart_count={{.RestartCount}}' \
      repoprompt-server >&2 || true
    printf '%s\n' 'Secret-safe structured Server events:' >&2
    docker logs --tail 100 repoprompt-server 2>&1 | python3 -c '
import json
import sys

for raw in sys.stdin:
    try:
        entry = json.loads(raw)
    except (TypeError, ValueError):
        continue
    fields = entry.get("fields") if isinstance(entry.get("fields"), dict) else {}
    projected = {
        key: entry[key]
        for key in ("timestamp", "level", "event", "outcome")
        if isinstance(entry.get(key), str)
    }
    if isinstance(fields.get("errorType"), str):
        projected["errorType"] = fields["errorType"]
    if projected:
        print(json.dumps(projected, sort_keys=True, separators=(",", ":")))
' >&2 || true
  fi
}

cleanup() {
  if [[ -x "$INSTALL_DIR/repoprompt-server" && -f "$INSTALL_DIR/.env" ]]; then
    REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
      "$INSTALL_DIR/repoprompt-server" uninstall >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}

finish() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    diagnose_failure "$status"
  fi
  cleanup
  exit "$status"
}
trap finish EXIT

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
PORTAL_PORT="$(free_port)"
while [[ "$PORTAL_PORT" == "$BIND_PORT" || "$PORTAL_PORT" == "$HEALTH_PORT" ]]; do PORTAL_PORT="$(free_port)"; done
PUBLIC_HOST=proxy.example
PUBLIC_ORIGIN="https://$PUBLIC_HOST"
PORTAL_BASE="http://127.0.0.1:$PORTAL_PORT/portal"
PORTAL_IDENTITY_HEADERS=(
  --header 'X-Forwarded-For: 198.51.100.42'
  --header 'X-Forwarded-Proto: https'
  --header "X-Forwarded-Host: $PUBLIC_HOST"
)

portal_get() {
  local path="$1" output="$2" cookie_header="${3:-}"
  local -a command=(
    curl -fsS --max-time 10 --output "$output"
    "${PORTAL_IDENTITY_HEADERS[@]}"
  )
  [[ -z "$cookie_header" ]] || command+=(--header "@$cookie_header")
  command+=("$PORTAL_BASE/$path")
  "${command[@]}"
}

portal_post() {
  local path="$1" body="$2" output="$3" cookie_jar="$4" cookie_header="${5:-}"
  local -a command=(
    curl -fsS --max-time 10 --output "$output"
    --request POST
    --header "Origin: $PUBLIC_ORIGIN"
    --header 'Sec-Fetch-Site: same-origin'
    --header 'Content-Type: application/json'
    --header 'X-RepoPrompt-Portal-CSRF: 1'
    "${PORTAL_IDENTITY_HEADERS[@]}"
    --data-binary "@$body"
  )
  [[ -z "$cookie_jar" ]] || command+=(--cookie-jar "$cookie_jar")
  [[ -z "$cookie_header" ]] || command+=(--header "@$cookie_header")
  command+=("$PORTAL_BASE/$path")
  "${command[@]}"
}

write_cookie_header() {
  local jar="$1" output="$2"
  python3 - "$jar" "$output" <<'PY'
import os
import sys

jar, output = sys.argv[1:]
cookie = None
with open(jar, encoding="utf-8") as handle:
    for line in handle:
        if line.startswith("#HttpOnly_"):
            line = line.removeprefix("#HttpOnly_")
        elif line.startswith("#"):
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) == 7 and fields[5] == "rpce_operator_session":
            cookie = fields[6]
if not cookie:
    raise SystemExit("operator session cookie was not issued")
descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    handle.write(f"Cookie: rpce_operator_session={cookie}\n")
PY
}

phase image
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build --tag "$IMAGE" -f "$ROOT/Dockerfile.server" "$ROOT"
fi

validate_topology() {
  local topology="$1" hostname="$2" bind_port="$3" health_port="$4" portal_port="$5" cidrs="$6"
  local root="$TOPOLOGY_ROOT/$topology"
  local command=(
    "$ROOT/Distribution/Server/install.sh"
    --image "$IMAGE"
    --allow-unpinned-image
    --hostname "$hostname"
    --bind-port "$bind_port"
    --health-port "$health_port"
    --install-dir "$root/install"
    --bin-dir "$root/bin"
    --data-dir "$root/data"
    --secrets-dir "$root/secrets"
    --backup-dir "$root/backups"
    --provider-dir "$root/providers"
    --no-start
  )
  if [[ "$topology" == trusted-proxy ]]; then
    command+=(
      --topology trusted-proxy
      --public-origin "https://$hostname"
      --portal-port "$portal_port"
      --trusted-proxy-cidrs "$cidrs"
    )
  fi
  "${command[@]}" >/dev/null
  REPOPROMPT_SERVER_ENV_FILE="$root/install/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
    "$root/install/repoprompt-server" validate >/dev/null
  grep -Fqx "REPOPROMPT_TOPOLOGY=$topology" "$root/install/.env"
}

phase topology-validation
DIRECT_BIND_PORT="$(free_port)"
DIRECT_HEALTH_PORT="$(free_port)"
while [[ "$DIRECT_HEALTH_PORT" == "$DIRECT_BIND_PORT" ]]; do DIRECT_HEALTH_PORT="$(free_port)"; done
PROXY_BIND_PORT="$(free_port)"
PROXY_HEALTH_PORT="$(free_port)"
PROXY_PORTAL_PORT="$(free_port)"
while [[ "$PROXY_HEALTH_PORT" == "$PROXY_BIND_PORT" ]]; do PROXY_HEALTH_PORT="$(free_port)"; done
while [[ "$PROXY_PORTAL_PORT" == "$PROXY_BIND_PORT" || "$PROXY_PORTAL_PORT" == "$PROXY_HEALTH_PORT" ]]; do PROXY_PORTAL_PORT="$(free_port)"; done
validate_topology direct-tls localhost "$DIRECT_BIND_PORT" "$DIRECT_HEALTH_PORT" off ''
validate_topology trusted-proxy proxy.example "$PROXY_BIND_PORT" "$PROXY_HEALTH_PORT" "$PROXY_PORTAL_PORT" 127.0.0.1/32
grep -Fqx 'REPOPROMPT_PORTAL_PORT=off' "$TOPOLOGY_ROOT/direct-tls/install/.env"
grep -Fqx 'REPOPROMPT_PUBLIC_ORIGIN=' "$TOPOLOGY_ROOT/direct-tls/install/.env"
grep -Fqx "REPOPROMPT_PORTAL_PORT=$PROXY_PORTAL_PORT" "$TOPOLOGY_ROOT/trusted-proxy/install/.env"
grep -Fqx 'REPOPROMPT_PUBLIC_ORIGIN=https://proxy.example' "$TOPOLOGY_ROOT/trusted-proxy/install/.env"
grep -Fqx 'REPOPROMPT_TRUSTED_PROXY_CIDRS=127.0.0.1/32' "$TOPOLOGY_ROOT/trusted-proxy/install/.env"

install_command=(
  "$ROOT/Distribution/Server/install.sh"
  --image "$IMAGE"
  --allow-unpinned-image
  --hostname "$PUBLIC_HOST"
  --bind-port "$BIND_PORT"
  --health-port "$HEALTH_PORT"
  --topology trusted-proxy
  --public-origin "$PUBLIC_ORIGIN"
  --portal-port "$PORTAL_PORT"
  --trusted-proxy-cidrs 127.0.0.1/32
  --install-dir "$INSTALL_DIR"
  --bin-dir "$BIN_DIR"
  --data-dir "$DATA_DIR"
  --secrets-dir "$SECRETS_DIR"
  --backup-dir "$BACKUP_DIR"
  --provider-dir "$PROVIDER_DIR"
)

phase fresh-install
"${install_command[@]}" >"$INSTALL_LOG" 2>&1
phase fresh-token-export
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" setup-token --output "$TOKEN_ONE"
[[ "$(stat -c '%a' "$TOKEN_ONE")" == 600 ]] || { printf 'Setup token mode is not 0600.\n' >&2; exit 1; }
TOKEN_DIGEST_ONE="$(sha256sum "$TOKEN_ONE" | cut -d' ' -f1)"
VAULT_DIGEST_ONE="$(sha256sum "$SECRETS_DIR/provider-vault.key" | cut -d' ' -f1)"
AGE_DIGEST_ONE="$(sha256sum "$SECRETS_DIR/backup-age-identity.txt" | cut -d' ' -f1)"
python3 - "$INSTALL_LOG" "$TOKEN_ONE" "$SECRETS_DIR/backup-age-identity.txt" <<'PY'
import sys

log_path, token_path, identity_path = sys.argv[1:]
with open(log_path, "rb") as handle:
    log = handle.read()
with open(token_path, "rb") as handle:
    token = handle.read().strip()
with open(identity_path, "rb") as handle:
    identity = next((line.strip() for line in handle if line.startswith(b"AGE-SECRET-KEY-")), b"")
if (token and token in log) or (identity and identity in log):
    raise SystemExit("an installation secret appeared in the installer log")
PY
phase fresh-readiness
portal_get '' "$TMP_ROOT/portal.html"
grep -q 'RepoPrompt' "$TMP_ROOT/portal.html"
curl -fsS --max-time 5 --output /dev/null "http://127.0.0.1:$HEALTH_PORT/health/ready"

# Re-running the complete installation command must preserve configuration,
# state, secrets, the live container, and the outstanding one-use setup token.
phase idempotent-rerun
"${install_command[@]}" >>"$INSTALL_LOG" 2>&1
phase idempotent-state
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

phase project-source-policy
SOURCE_DIR="$DATA_DIR/projects/acceptance-source"
install -d -m 0750 -o 65532 -g 65532 "$SOURCE_DIR"
printf '%s\n' 'bounded acceptance source' > "$SOURCE_DIR/README.txt"
chown 65532:65532 "$SOURCE_DIR/README.txt"
chmod 0640 "$SOURCE_DIR/README.txt"
python3 - "$DATA_DIR/project-source.policy.json" <<'PY'
import json
import os
import sys

policy = {
    "schemaVersion": 1,
    "configuredRoots": [
        {"alias": "acceptance", "path": "/data/projects/acceptance-source", "writable": False}
    ],
    "git": {
        "remoteRules": [],
        "allowedRefPatterns": [],
        "deniedRefPatterns": [],
        "maximumCloneBytes": 8_388_608,
        "maximumCloneSeconds": 5,
        "maximumConcurrentClones": 1,
        "maximumOutputBytes": 16_384,
    },
}
path = sys.argv[1]
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(policy, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
chown 65532:65532 "$DATA_DIR/project-source.policy.json"
sed -i 's|^REPOPROMPT_PROJECT_SOURCE_POLICY_FILE=$|REPOPROMPT_PROJECT_SOURCE_POLICY_FILE=/data/project-source.policy.json|' "$INSTALL_DIR/.env"
grep -Fqx 'REPOPROMPT_PROJECT_SOURCE_POLICY_FILE=/data/project-source.policy.json' "$INSTALL_DIR/.env"
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" up >/dev/null
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" setup-token --output "$TOKEN_SETUP"
[[ "$(stat -c '%a' "$TOKEN_SETUP")" == 600 ]] || { printf 'Current setup token mode is not 0600.\n' >&2; exit 1; }
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" project-onboarding > "$TMP_ROOT/project-onboarding.txt"
grep -Fq 'POST /portal/api/v1/projects/source-operations' "$TMP_ROOT/project-onboarding.txt"
grep -Fq "$DATA_DIR/project-source.policy.json" "$TMP_ROOT/project-onboarding.txt"

phase operator-setup
python3 - "$PASSWORD_FILE" "$TOKEN_SETUP" "$SETUP_BODY" "$LOGIN_BODY" <<'PY'
import json
import os
import secrets
import sys

password_path, token_path, setup_path, login_path = sys.argv[1:]
password = secrets.token_urlsafe(32)
with open(token_path, encoding="utf-8") as handle:
    token = handle.read().strip()
if not token:
    raise SystemExit("setup token export is empty")
for path, value in (
    (password_path, password + "\n"),
    (setup_path, json.dumps({"password": password, "passwordConfirmation": password, "setupToken": token}, separators=(",", ":"))),
    (login_path, json.dumps({"password": password}, separators=(",", ":"))),
):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(value)
PY
portal_post 'api/v1/setup' "$SETUP_BODY" "$SETUP_RESPONSE" "$SETUP_COOKIE_JAR"
[[ ! -e "$DATA_DIR/state/operator-setup-token" ]] || {
  printf 'Consumed setup-token file still exists after the setup response.\n' >&2
  exit 1
}
write_cookie_header "$SETUP_COOKIE_JAR" "$SETUP_COOKIE_HEADER"
portal_get 'api/v1/auth/status' "$AUTH_RESPONSE" "$SETUP_COOKIE_HEADER"
python3 - "$AUTH_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle)
if status.get("needsSetup") or not status.get("authenticated") or status.get("username") != "operator":
    raise SystemExit("setup session authentication status is invalid")
PY

phase operator-login
portal_post 'api/v1/login' "$LOGIN_BODY" "$LOGIN_RESPONSE" "$LOGIN_COOKIE_JAR"
write_cookie_header "$LOGIN_COOKIE_JAR" "$LOGIN_COOKIE_HEADER"
portal_get 'api/v1/auth/status' "$AUTH_RESPONSE" "$LOGIN_COOKIE_HEADER"
portal_get 'api/v1/account/sessions' "$SESSIONS_RESPONSE" "$LOGIN_COOKIE_HEADER"
python3 - "$AUTH_RESPONSE" "$SESSIONS_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    sessions = json.load(handle)
if status.get("needsSetup") or not status.get("authenticated") or status.get("username") != "operator":
    raise SystemExit("password login did not create an authenticated session")
if len(sessions) < 2 or sum(bool(session.get("current")) for session in sessions) != 1:
    raise SystemExit("operator session inventory did not include the setup and login sessions")
PY

docker logs repoprompt-server > "$SERVER_LOG" 2>&1
chmod 0600 "$SERVER_LOG"
python3 - "$INSTALL_LOG" "$SERVER_LOG" "$TOKEN_ONE" "$TOKEN_TWO" "$TOKEN_SETUP" "$PASSWORD_FILE" "$SETUP_COOKIE_JAR" "$LOGIN_COOKIE_JAR" "$SETUP_BODY" "$LOGIN_BODY" <<'PY'
import os
import sys

install_log, server_log, token_one, token_two, token_setup, password_file, setup_jar, login_jar, setup_body, login_body = sys.argv[1:]
secrets = []
for path in (token_one, token_two, token_setup, password_file):
    with open(path, encoding="utf-8") as handle:
        value = handle.read().strip()
    if value:
        secrets.append(value)
for path in (setup_jar, login_jar):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#HttpOnly_"):
                line = line.removeprefix("#HttpOnly_")
            elif line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) == 7 and fields[5] == "rpce_operator_session":
                secrets.append(fields[6])
try:
    logs = b"".join(open(path, "rb").read() for path in (install_log, server_log))
    if any(secret.encode() in logs for secret in secrets):
        raise SystemExit("an operator setup secret appeared in installer or Server logs")
finally:
    for path in (token_one, token_two, token_setup, password_file, setup_body, login_body):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
PY
[[ ! -e "$TOKEN_ONE" && ! -e "$TOKEN_TWO" && ! -e "$TOKEN_SETUP" ]] || {
  printf 'Exported setup-token copies were not deleted after setup.\n' >&2
  exit 1
}

phase provider-readiness
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" provider-check > "$PROVIDER_LOG" 2>&1
grep -Fq 'Core Server readiness passed; no CLI provider runtime is deployment-admitted.' "$PROVIDER_LOG"
grep -Fq 'Mount reviewed provider binaries, admit them in .env, then rerun this command.' "$PROVIDER_LOG"
portal_get 'api/v1/provider-settings' "$PROVIDER_RESPONSE" "$LOGIN_COOKIE_HEADER"
python3 - "$PROVIDER_RESPONSE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    providers = json.load(handle).get("providers", [])
if not providers:
    raise SystemExit("provider catalog is empty")
for provider in providers:
    authentication = provider.get("authentication", {})
    if provider.get("deploymentAllowed") or provider.get("effectiveEnabled"):
        raise SystemExit("a provider was unexpectedly deployment-ready")
    if provider.get("configurationPresent") or authentication.get("authenticated"):
        raise SystemExit("a provider was unexpectedly configured or authenticated")
    if authentication.get("state") != "notConfigured" or authentication.get("detail") != "Provision credentials on the server":
        raise SystemExit("provider authentication status is not actionable")
PY

phase project-admission
python3 - "$PROJECT_BODY" <<'PY'
import json
import os
import sys
import uuid

body = {
    "schemaVersion": 1,
    "operationId": str(uuid.uuid4()),
    "expectedRevision": 0,
    "name": "Disposable acceptance project",
    "logicalName": "source",
    "source": {"type": "configuredRoot", "alias": "acceptance"},
}
descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(body, handle, sort_keys=True, separators=(",", ":"))
PY
portal_post 'api/v1/projects/source-operations' "$PROJECT_BODY" "$PROJECT_RESPONSE" '' "$LOGIN_COOKIE_HEADER"
portal_get 'api/v1/bootstrap' "$BOOTSTRAP_RESPONSE" "$LOGIN_COOKIE_HEADER"
python3 - "$PROJECT_RESPONSE" "$BOOTSTRAP_RESPONSE" "$SOURCE_DIR" /data/projects/acceptance-source <<'PY'
import json
import sys

project_path, bootstrap_path, *forbidden_paths = sys.argv[1:]
with open(project_path, encoding="utf-8") as handle:
    project = json.load(handle)
with open(bootstrap_path, encoding="utf-8") as handle:
    projects = json.load(handle).get("projects", [])
if project.get("name") != "Disposable acceptance project" or project.get("rootNames") != ["source"] or project.get("state") != "active":
    raise SystemExit("configured project root was not admitted")
if not any(item.get("projectId") == project.get("projectId") and item.get("rootNames") == ["source"] for item in projects):
    raise SystemExit("admitted project is missing from the authenticated portal bootstrap")
for path in (project_path, bootstrap_path):
    with open(path, encoding="utf-8") as handle:
        projection = handle.read()
        if any(forbidden in projection for forbidden in forbidden_paths):
            raise SystemExit("portal project projection disclosed a physical path")
PY
docker exec repoprompt-server test -r /data/projects/acceptance-source/README.txt
docker logs repoprompt-server > "$SERVER_LOG" 2>&1
python3 - "$SERVER_LOG" "$SETUP_COOKIE_JAR" "$LOGIN_COOKIE_JAR" <<'PY'
import sys

log_path, *jars = sys.argv[1:]
secrets = []
for path in jars:
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#HttpOnly_"):
                line = line.removeprefix("#HttpOnly_")
            elif line.startswith("#"):
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) == 7 and fields[5] == "rpce_operator_session":
                secrets.append(fields[6])
with open(log_path, "rb") as handle:
    logs = handle.read()
if any(secret.encode() in logs for secret in secrets):
    raise SystemExit("an operator session secret appeared in Server logs")
PY

phase backup
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" backup acceptance.age >/dev/null
[[ -s "$BACKUP_DIR/acceptance.age" && -s "$BACKUP_DIR/acceptance.age.sidecar.json" ]] || {
  printf 'Verified backup artifacts were not created.\n' >&2
  exit 1
}

phase preserving-uninstall
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" uninstall >/dev/null
[[ -d "$DATA_DIR" && -f "$SECRETS_DIR/provider-vault.key" && -f "$BACKUP_DIR/acceptance.age" ]] || {
  printf 'Preserving uninstall removed operator state.\n' >&2
  exit 1
}
phase explicit-destroy
REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env" REPOPROMPT_ALLOW_UNPINNED_IMAGE=1 \
  "$INSTALL_DIR/repoprompt-server" uninstall --destroy-data --confirm DESTROY-REPOPROMPT-DATA >/dev/null
[[ ! -e "$DATA_DIR" && -f "$SECRETS_DIR/backup-age-identity.txt" && -f "$BACKUP_DIR/acceptance.age" ]] || {
  printf 'Explicit destroy semantics did not match the contract.\n' >&2
  exit 1
}

printf 'Standalone Server Docker acceptance passed: install lifecycle, trusted-proxy setup/login, provider status, bounded project admission, backup, and uninstall semantics.\n'
