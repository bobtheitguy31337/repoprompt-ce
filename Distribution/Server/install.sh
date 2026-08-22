#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/opt/repoprompt-server
BIN_DIR=/usr/local/bin
DATA_DIR=/var/lib/repoprompt-server
SECRETS_DIR=/etc/repoprompt-server/secrets
BACKUP_DIR=/var/backups/repoprompt-server
PROVIDER_DIR=/opt/repoprompt-server/providers
IMAGE=
HOSTNAME_VALUE=
PUBLIC_ORIGIN=
TOPOLOGY=direct-tls
BIND_PORT=9443
HEALTH_PORT=9080
PORTAL_PORT=off
TRUSTED_PROXY_CIDRS=
TLS_CERT=
TLS_KEY=
NO_START=0
ALLOW_UNPINNED=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh --image IMAGE@sha256:DIGEST --hostname HOST [options]

Required:
  --image IMAGE                  Official digest-pinned RepoPrompt Server image
  --hostname HOST               Operator-facing DNS name (localhost is allowed)

Network:
  --public-origin HTTPS_ORIGIN   Defaults to https://HOST:9443 for direct TLS
  --topology direct-tls|trusted-proxy
  --bind-port PORT               Internal TLS/portal port (default 9443)
  --health-port PORT             Loopback health port (default 9080)
  --portal-port PORT             Trusted-proxy loopback backend port (default 9081)
  --trusted-proxy-cidrs CIDRS    Immediate trusted proxy CIDRs
  --tls-cert FILE --tls-key FILE Required for public direct-TLS hostnames

Placement:
  --install-dir DIR --bin-dir DIR --data-dir DIR --secrets-dir DIR
  --backup-dir DIR --provider-dir DIR

Control:
  --no-start                     Install and validate without starting
  --allow-unpinned-image         Test/development only; rejected by default

The default paths require root. Set all placement paths to writable directories
for a non-root disposable installation.
EOF
}

while (($#)); do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --hostname) HOSTNAME_VALUE="${2:-}"; shift 2 ;;
    --public-origin) PUBLIC_ORIGIN="${2:-}"; shift 2 ;;
    --topology) TOPOLOGY="${2:-}"; shift 2 ;;
    --bind-port) BIND_PORT="${2:-}"; shift 2 ;;
    --health-port) HEALTH_PORT="${2:-}"; shift 2 ;;
    --portal-port) PORTAL_PORT="${2:-}"; shift 2 ;;
    --trusted-proxy-cidrs) TRUSTED_PROXY_CIDRS="${2:-}"; shift 2 ;;
    --tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
    --tls-key) TLS_KEY="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --bin-dir) BIN_DIR="${2:-}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:-}"; shift 2 ;;
    --secrets-dir) SECRETS_DIR="${2:-}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    --provider-dir) PROVIDER_DIR="${2:-}"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --allow-unpinned-image) ALLOW_UNPINNED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -n "$IMAGE" ]] || die "--image is required"
[[ -n "$HOSTNAME_VALUE" ]] || die "--hostname is required"
for path in "$INSTALL_DIR" "$BIN_DIR" "$DATA_DIR" "$SECRETS_DIR" "$BACKUP_DIR" "$PROVIDER_DIR"; do
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ && "$path" != / ]] ||
    die "Placement paths must be safe absolute directories other than /"
done
for path in "$SECRETS_DIR" "$BACKUP_DIR" "$PROVIDER_DIR" "$INSTALL_DIR" "$BIN_DIR"; do
  [[ "$path" != "$DATA_DIR" && "$path" != "$DATA_DIR"/* && "$DATA_DIR" != "$path"/* ]] ||
    die "The live data directory must not contain or be contained by another installation path"
done
for left in "$SECRETS_DIR" "$BACKUP_DIR" "$PROVIDER_DIR"; do
  for right in "$SECRETS_DIR" "$BACKUP_DIR" "$PROVIDER_DIR"; do
    [[ "$left" == "$right" ]] && continue
    [[ "$left" != "$right"/* ]] || die "Secrets, backups, and provider directories must not contain one another"
  done
done
[[ "$TRUSTED_PROXY_CIDRS" != *$'\n'* ]] || die "Trusted proxy CIDRs must be a single line"
[[ "$TRUSTED_PROXY_CIDRS" =~ ^[0-9A-Fa-f:.,/]*$ ]] || die "Trusted proxy CIDRs are invalid"
if [[ "${REPOPROMPT_SERVER_ACCEPT_NON_UBUNTU:-0}" != "1" ]]; then
  [[ "$(uname -s)" == Linux ]] || die "The standalone installer supports Ubuntu 24.04 only"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] ||
    die "The standalone installer supports Ubuntu 24.04 only"
fi
if [[ "$INSTALL_DIR" == /opt/* || "$BIN_DIR" == /usr/* || "$DATA_DIR" == /var/* || "$SECRETS_DIR" == /etc/* || "$BACKUP_DIR" == /var/* ]]; then
  [[ "$(id -u)" == 0 ]] || die "Default system paths require root; rerun with sudo or choose writable placement paths"
fi
[[ "$HOSTNAME_VALUE" =~ ^[A-Za-z0-9.-]+$ ]] || die "Hostname is invalid"
[[ "$IMAGE" =~ ^[A-Za-z0-9._/@:-]+$ ]] || die "Image reference is invalid"
if ((ALLOW_UNPINNED == 0)); then
  [[ "$IMAGE" =~ @sha256:[a-f0-9]{64}$ ]] || die "Image must be pinned by sha256 digest"
fi
[[ "$BIND_PORT" =~ ^[0-9]+$ && "$HEALTH_PORT" =~ ^[0-9]+$ ]] || die "Ports must be numeric"
((BIND_PORT >= 1 && BIND_PORT <= 65535 && HEALTH_PORT >= 1 && HEALTH_PORT <= 65535)) || die "Ports must be from 1 through 65535"
[[ "$BIND_PORT" != "$HEALTH_PORT" ]] || die "Bind and health ports must differ"
if [[ -z "$PUBLIC_ORIGIN" ]]; then
  if [[ "$BIND_PORT" == 443 ]]; then
    PUBLIC_ORIGIN="https://$HOSTNAME_VALUE"
  else
    PUBLIC_ORIGIN="https://$HOSTNAME_VALUE:$BIND_PORT"
  fi
fi
[[ "$PUBLIC_ORIGIN" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "Public origin must be HTTPS without a path"
origin_authority="${PUBLIC_ORIGIN#https://}"
[[ "${origin_authority%%:*}" == "$HOSTNAME_VALUE" ]] || die "Public origin hostname must match --hostname"

SERVER_PUBLIC_ORIGIN="$PUBLIC_ORIGIN"
SERVER_TRUSTED_ORIGIN=
PORTAL_HOST=127.0.0.1
case "$TOPOLOGY" in
  direct-tls)
    PORTAL_PORT=off
    [[ -z "$TRUSTED_PROXY_CIDRS" ]] || die "Direct TLS does not accept trusted proxy CIDRs"
    if [[ "$BIND_PORT" == 443 ]]; then
      [[ "$PUBLIC_ORIGIN" == "https://$HOSTNAME_VALUE" ]] || die "Direct-TLS public origin must match bind port 443"
    else
      [[ "$PUBLIC_ORIGIN" == "https://$HOSTNAME_VALUE:$BIND_PORT" ]] || die "Direct-TLS public origin must match --bind-port"
    fi
    if [[ "$HOSTNAME_VALUE" != localhost && "$HOSTNAME_VALUE" != repoprompt ]]; then
      [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]] || die "Public direct TLS requires --tls-cert and --tls-key"
    fi
    ;;
  trusted-proxy)
    [[ "$PORTAL_PORT" =~ ^[0-9]+$ ]] && ((PORTAL_PORT >= 1 && PORTAL_PORT <= 65535)) || die "Trusted-proxy portal port is invalid"
    [[ -n "$TRUSTED_PROXY_CIDRS" ]] || die "Trusted-proxy topology requires --trusted-proxy-cidrs"
    SERVER_TRUSTED_ORIGIN="$PUBLIC_ORIGIN"
    ;;
  *) die "Topology must be direct-tls or trusted-proxy" ;;
esac
if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
  [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]] || die "TLS certificate and key must be supplied together"
  [[ -f "$TLS_CERT" && -f "$TLS_KEY" && ! -L "$TLS_CERT" && ! -L "$TLS_KEY" ]] ||
    die "TLS certificate and key must be regular, non-symlink files"
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DATA_DIR" "$SECRETS_DIR" "$BACKUP_DIR" "$PROVIDER_DIR"
install -m 0755 "$SOURCE_DIR/repoprompt-server" "$INSTALL_DIR/repoprompt-server"
install -m 0644 "$SOURCE_DIR/compose.yaml" "$INSTALL_DIR/compose.yaml"
install -m 0644 "$SOURCE_DIR/server.env.example" "$INSTALL_DIR/server.env.example"
if [[ -n "$TLS_CERT" ]]; then
  mkdir -p "$SECRETS_DIR/tls"
  install -m 0644 "$TLS_CERT" "$SECRETS_DIR/tls/server.crt"
  install -m 0600 "$TLS_KEY" "$SECRETS_DIR/tls/server.key"
fi

TLS_CERT_PATH=
TLS_KEY_PATH=
if [[ -n "$TLS_CERT" ]]; then
  TLS_CERT_PATH=/secrets/tls/server.crt
  TLS_KEY_PATH=/secrets/tls/server.key
fi
temporary="$(mktemp "$INSTALL_DIR/.env.tmp.XXXXXX")"
cat > "$temporary" <<EOF
REPOPROMPT_SERVER_IMAGE=$IMAGE
REPOPROMPT_CONTAINER_NAME=repoprompt-server
REPOPROMPT_PROFILE=default
REPOPROMPT_TOPOLOGY=$TOPOLOGY
REPOPROMPT_HOSTNAME=$HOSTNAME_VALUE
REPOPROMPT_SERVER_PUBLIC_ORIGIN=$SERVER_PUBLIC_ORIGIN
REPOPROMPT_BIND_HOST=0.0.0.0
REPOPROMPT_BIND_PORT=$BIND_PORT
REPOPROMPT_HEALTH_PORT=$HEALTH_PORT
REPOPROMPT_PORTAL_HOST=$PORTAL_HOST
REPOPROMPT_PORTAL_PORT=$PORTAL_PORT
REPOPROMPT_PUBLIC_ORIGIN=$SERVER_TRUSTED_ORIGIN
REPOPROMPT_TRUSTED_PROXY_CIDRS=$TRUSTED_PROXY_CIDRS
REPOPROMPT_TLS_CERT_FILE=$TLS_CERT_PATH
REPOPROMPT_TLS_KEY_FILE=$TLS_KEY_PATH
REPOPROMPT_ENABLED_PROVIDERS=
REPOPROMPT_ENABLED_DIRECT_PROVIDERS=
REPOPROMPT_PROVIDER_VAULT_KEY_ID=provider-vault-v1
REPOPROMPT_DATA_DIR=$DATA_DIR
REPOPROMPT_SECRETS_DIR=$SECRETS_DIR
REPOPROMPT_BACKUP_DIR=$BACKUP_DIR
REPOPROMPT_PROVIDER_DIR=$PROVIDER_DIR
EOF
chmod 0600 "$temporary"
if [[ -f "$INSTALL_DIR/.env" ]]; then
  if cmp -s "$temporary" "$INSTALL_DIR/.env"; then
    rm -f "$temporary"
  else
    rm -f "$temporary"
    die "Existing configuration differs; preserve it and use the documented upgrade/configuration procedure"
  fi
else
  mv "$temporary" "$INSTALL_DIR/.env"
fi

link="$BIN_DIR/repoprompt-server"
if [[ -e "$link" || -L "$link" ]]; then
  [[ -L "$link" && "$(readlink "$link")" == "$INSTALL_DIR/repoprompt-server" ]] ||
    die "Refusing to replace unmanaged command: $link"
else
  ln -s "$INSTALL_DIR/repoprompt-server" "$link"
fi

export REPOPROMPT_SERVER_ENV_FILE="$INSTALL_DIR/.env"
if ((ALLOW_UNPINNED)); then
  export REPOPROMPT_ALLOW_UNPINNED_IMAGE=1
fi
"$INSTALL_DIR/repoprompt-server" validate
if ((NO_START)); then
  printf 'RepoPrompt Server bundle installed at %s; data is not initialized or started.\n' "$INSTALL_DIR"
else
  "$INSTALL_DIR/repoprompt-server" up
fi
