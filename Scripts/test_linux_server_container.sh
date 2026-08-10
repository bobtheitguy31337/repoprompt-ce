#!/usr/bin/env bash
set -euo pipefail

image="${REPOPROMPT_SERVER_IMAGE:-repoprompt-server:test}"
suffix="${RANDOM}-$$"
container="repoprompt-server-test-${suffix}"
state_volume="repoprompt-state-${suffix}"
artifact_volume="repoprompt-artifacts-${suffix}"
project_volume="repoprompt-projects-${suffix}"
worktree_volume="repoprompt-worktrees-${suffix}"
cache_volume="repoprompt-cache-${suffix}"
temporary="$(mktemp -d)"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm -f "$state_volume" "$artifact_volume" "$project_volume" "$worktree_volume" "$cache_volume" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}

finish() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    docker logs "$container" >&2 || true
  fi
  cleanup
  exit "$status"
}
trap finish EXIT

for volume in "$state_volume" "$artifact_volume" "$project_volume" "$worktree_volume" "$cache_volume"; do
  docker volume create "$volume" >/dev/null
done

cat >"$temporary/server.ext" <<'EOF'
subjectAltName=DNS:repoprompt
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF
cat >"$temporary/operator.ext" <<'EOF'
subjectAltName=DNS:operator.internal
extendedKeyUsage=clientAuth
keyUsage=digitalSignature
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=RepoPrompt Test CA' -keyout "$temporary/ca.key" -out "$temporary/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=repoprompt' -keyout "$temporary/server.key" -out "$temporary/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$temporary/server.csr" -CA "$temporary/ca.crt" -CAkey "$temporary/ca.key" -CAcreateserial -extfile "$temporary/server.ext" -out "$temporary/server.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=operator' -keyout "$temporary/operator.key" -out "$temporary/operator.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$temporary/operator.csr" -CA "$temporary/ca.crt" -CAkey "$temporary/ca.key" -CAcreateserial -extfile "$temporary/operator.ext" -out "$temporary/operator.crt" >/dev/null 2>&1
printf '%s' 'app-test-secret-0000000000000000' >"$temporary/app.hmac"
printf '%s' 'sync-test-secret-000000000000000' >"$temporary/sync.hmac"
printf '%s' 'operator-test-secret-00000000000' >"$temporary/operator.hmac"
printf '%s' 'event-test-secret-00000000000000' >"$temporary/event.hmac"
chmod 0755 "$temporary"
chmod 0644 "$temporary"/*.crt "$temporary"/*.key "$temporary"/*.hmac

run_container() {
  docker run -d --name "$container" --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m,uid=65532,gid=65532 \
    --mount "type=bind,src=$temporary,dst=/run/repoprompt/trust,readonly" \
    --mount "type=volume,src=$state_volume,dst=/var/lib/repoprompt/state" \
    --mount "type=volume,src=$artifact_volume,dst=/var/lib/repoprompt/artifacts" \
    --mount "type=volume,src=$project_volume,dst=/srv/repoprompt/projects" \
    --mount "type=volume,src=$worktree_volume,dst=/srv/repoprompt/worktrees" \
    --mount "type=volume,src=$cache_volume,dst=/var/cache/repoprompt" \
    -e REPOPROMPT_TLS_CERT_FILE=/run/repoprompt/trust/server.crt \
    -e REPOPROMPT_TLS_KEY_FILE=/run/repoprompt/trust/server.key \
    -e REPOPROMPT_TLS_CLIENT_CA_FILE=/run/repoprompt/trust/ca.crt \
    -e REPOPROMPT_GOBLIN_APP_HMAC_FILE=/run/repoprompt/trust/app.hmac \
    -e REPOPROMPT_GOBLIN_SYNC_HMAC_FILE=/run/repoprompt/trust/sync.hmac \
    -e REPOPROMPT_OPERATOR_HMAC_FILE=/run/repoprompt/trust/operator.hmac \
    -e REPOPROMPT_EVENT_HMAC_FILE=/run/repoprompt/trust/event.hmac \
    -e REPOPROMPT_GOBLIN_APP_CERT_IDENTITY=app.internal \
    -e REPOPROMPT_GOBLIN_SYNC_CERT_IDENTITY=sync.internal \
    -e REPOPROMPT_OPERATOR_CERT_IDENTITY=operator.internal \
    -e REPOPROMPT_DISABLED_PROVIDERS=codex,claudeCompatible,openCodeACP,cursorACP \
    -e REPOPROMPT_MINIMUM_FREE_BYTES=1 \
    -e REPOPROMPT_MINIMUM_FREE_NODES=1 \
    "$image" >/dev/null
}

wait_ready() {
  local attempts=60
  while ((attempts > 0)); do
    if docker exec "$container" curl -fsS --max-time 1 http://127.0.0.1:9080/health/ready >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]]; then
      docker logs "$container" >&2
      return 1
    fi
    attempts=$((attempts - 1))
    sleep 1
  done
  docker logs "$container" >&2
  return 1
}

# The image contract is part of the runtime API.
test "$(docker image inspect "$image" --format '{{.Config.User}}')" = '65532:65532'
test "$(docker image inspect "$image" --format '{{index .Config.Labels "io.degentlemen.repoprompt.schema-version"}}')" = '2'
test "$(docker image inspect "$image" --format '{{json .Config.ExposedPorts}}')" = '{"9080/tcp":{},"9443/tcp":{}}'
test "$(docker image inspect "$image" --format '{{index .Config.Labels "io.degentlemen.repoprompt.port.internal-api"}}')" = '9443/tcp;mtls'
test "$(docker image inspect "$image" --format '{{index .Config.Labels "io.degentlemen.repoprompt.port.health"}}')" = '9080/tcp;loopback-only'

# Exercise the shipped provider binaries as the runtime UID, then prove that a
# persisted family with an escaped descendant is reconstructed and reaped by a
# fresh Linux supervision port.
docker run --rm --entrypoint /bin/sh "$image" -c \
  'codex --version | grep -F "0.147.0" && claude --version | grep -F "2.1.226" && opencode --version | grep -F "1.15.11" && cursor-agent --version | grep -F "2026.08.04-aaa8809"' >/dev/null
docker run --rm --init --entrypoint /usr/local/bin/RepoPromptServer "$image" process-family-smoke | grep -F 'process-family smoke passed' >/dev/null

run_container
wait_ready

test "$(docker exec "$container" id -u)" = '65532'
test "$(docker exec "$container" curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve repoprompt:9443:127.0.0.1 --cacert /run/repoprompt/trust/ca.crt https://repoprompt:9443/internal/v1/diagnostics || true)" = '000'
test "$(docker exec "$container" curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --resolve repoprompt:9443:127.0.0.1 --cacert /run/repoprompt/trust/ca.crt --cert /run/repoprompt/trust/operator.crt --key /run/repoprompt/trust/operator.key https://repoprompt:9443/internal/v1/diagnostics)" = '401'

# Canonical x-internal request authentication and exact-byte response signing
# are exercised through the real mTLS listener, not only by unit tests.
request_path='/internal/v1/diagnostics'
request_timestamp="$(python3 -c 'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))')"
request_nonce='Y29udGFpbmVyLWF1ZGl0LTE'
empty_digest="$(printf '' | openssl dgst -sha256 | awk '{print $2}')"
request_key_id='repoprompt-operator-v1'
request_canonical="$(printf 'GET\n%s\n%s\n%s\n%s\n%s\n%s' "$request_path" "$request_timestamp" "$request_nonce" "$empty_digest" "$empty_digest" "$request_key_id")"
request_signature="$(printf '%s' "$request_canonical" | openssl dgst -sha256 -hmac 'operator-test-secret-00000000000' | awk '{print $2}')"
response_wire="$(docker exec "$container" curl --noproxy '*' -sS -o /tmp/diagnostics.json \
  -w '%{http_code}|%header{x-internal-body-digest}|%header{x-internal-timestamp}|%header{x-internal-nonce}|%header{x-internal-key-id}|%header{x-internal-signature}' \
  --resolve repoprompt:9443:127.0.0.1 --cacert /run/repoprompt/trust/ca.crt \
  --cert /run/repoprompt/trust/operator.crt --key /run/repoprompt/trust/operator.key \
  -H "x-internal-key-id: $request_key_id" -H "x-internal-timestamp: $request_timestamp" \
  -H "x-internal-nonce: $request_nonce" -H "x-internal-body-digest: $empty_digest" \
  -H "x-internal-authorization-digest: $empty_digest" -H "x-internal-signature: $request_signature" \
  "https://repoprompt:9443$request_path")"
IFS='|' read -r response_status response_digest response_timestamp response_nonce response_key_id response_signature <<<"$response_wire"
test "$response_status" = '200'
test "$response_key_id" = 'repoprompt-event-v1'
response_body="$(docker exec "$container" cat /tmp/diagnostics.json)"
test "$response_digest" = "$(printf '%s' "$response_body" | openssl dgst -sha256 | awk '{print $2}')"
response_canonical="$(printf 'RESPONSE\n%s#200\n%s\n%s\n%s\n%s\n%s' "$request_path" "$response_timestamp" "$response_nonce" "$response_digest" "$empty_digest" "$response_key_id")"
test "$response_signature" = "$(printf '%s' "$response_canonical" | openssl dgst -sha256 -hmac 'event-test-secret-00000000000000' | awk '{print $2}')"

# An unclean stop must leave a restartable durable store.
docker kill -s KILL "$container" >/dev/null
docker start "$container" >/dev/null
wait_ready

# SIGTERM is drained for at most 15 seconds, providers are canceled, and SQLite checkpoints cleanly.
started="$(date +%s)"
docker stop --time 25 "$container" >/dev/null
elapsed=$(( $(date +%s) - started ))
test "$elapsed" -le 25
test "$(docker inspect -f '{{.State.Running}}' "$container")" = 'false'
docker start "$container" >/dev/null
wait_ready

# Tini and the supervisor must not leave descendants behind after the final stop.
docker stop --time 25 "$container" >/dev/null
test "$(docker inspect -f '{{.State.Running}}' "$container")" = 'false'
echo 'RepoPromptServer container lifecycle checks passed'
