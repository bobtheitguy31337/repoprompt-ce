# Install RepoPrompt Server on Ubuntu 24.04

This guide covers the standalone RepoPrompt-owned Docker Compose bundle. It
installs no chat service and has no chat deployment dependency.

## 1. Prerequisites

- A dedicated Ubuntu Server 24.04 host with DNS already pointing at it.
- Docker Engine with the Compose v2 plugin (`docker compose version`).
- An official RepoPrompt Server image reference pinned by digest, for example
  `ghcr.io/repoprompt/repoprompt-server@sha256:…`.
- For a public direct-TLS host, an existing PEM certificate and unencrypted PEM
  private key for the hostname. The installer does not obtain certificates.
- Enough capacity for durable state, project checkouts, worktrees, artifacts,
  provider homes, backups, and image upgrades.

The repository does not currently publish the image. Release-owner image
publication/signing is therefore a clean-host blocker, not something the
installer works around by compiling on the operator machine.

Copy the released `Distribution/Server` bundle onto the host, verify its release
provenance, and run the installer as root for the default filesystem layout.

## 2. Install and start

### Local-only evaluation

The built-in certificate is self-signed for `localhost` and `repoprompt` only:

```bash
sudo ./install.sh \
  --image 'ghcr.io/repoprompt/repoprompt-server@sha256:<release-digest>' \
  --hostname localhost
```

Open `https://localhost:9443/portal/` on the host. Browsers will not trust the
self-signed certificate until an operator explicitly trusts it.

### Public direct TLS

```bash
sudo ./install.sh \
  --image 'ghcr.io/repoprompt/repoprompt-server@sha256:<release-digest>' \
  --hostname repoprompt.example.com \
  --public-origin https://repoprompt.example.com \
  --bind-port 443 \
  --tls-cert /secure/repoprompt.example.com.crt \
  --tls-key /secure/repoprompt.example.com.key
```

The installer copies the TLS material into the owner-only Server secrets
directory. Direct TLS rejects forwarded headers and does not configure the
Server's trusted-proxy origin.

### Existing trusted reverse proxy

The bundle does not invent a proxy tier. If the Ubuntu host already has a
reviewed TLS proxy, use the Server's supported loopback backend:

```bash
sudo ./install.sh \
  --image 'ghcr.io/repoprompt/repoprompt-server@sha256:<release-digest>' \
  --hostname repoprompt.example.com \
  --public-origin https://repoprompt.example.com \
  --topology trusted-proxy \
  --portal-port 9081 \
  --trusted-proxy-cidrs 127.0.0.1/32
```

Configure the host proxy to send exactly one `X-Forwarded-For`,
`X-Forwarded-Proto: https`, and the matching `X-Forwarded-Host` to
`127.0.0.1:9081`. The internal API remains TLS on port 9443. Review
[Security and access](private-pilot-security.md) before changing the CIDR.

The installer performs strict Ubuntu, Docker, path, topology, port, origin,
certificate, and immutable-image validation. It then:

1. Writes non-secret configuration under `/opt/repoprompt-server`.
2. Creates separate data, secrets, backup, and provider directories.
3. Pulls the pinned image.
4. Generates a 256-bit provider-vault key and age backup identity inside a
   no-network initialization container. Secret values are never printed.
5. Starts the non-root Server and waits on loopback `/health/ready`.

Running the exact installer command again is idempotent. It refuses to overwrite
a different existing configuration; use the explicit upgrade/configuration
procedure instead.

## 3. Complete first-run setup

The Server creates one setup token in its owner-only state directory. Export it
to a new owner-only file rather than printing it into terminal history:

```bash
sudo install -d -m 0700 /root/repoprompt-setup
sudo repoprompt-server setup-token \
  --output /root/repoprompt-setup/operator-setup-token
```

Open the portal, create the operator password, paste the token, and immediately
delete the exported copy. The Server atomically consumes the token and deletes
its internal token file after successful setup.

Useful commands:

```bash
sudo repoprompt-server status
sudo repoprompt-server logs --tail 200
sudo repoprompt-server validate
```

`status` includes the authoritative readiness JSON. Do not expose the loopback
health port through a firewall or reverse proxy.

## 4. Configure a provider

The base Server image intentionally does not claim provider readiness. Mount
reviewed provider executables under `/opt/repoprompt-server/providers`, admit
only their canonical IDs in `/opt/repoprompt-server/.env`, then restart:

```text
REPOPROMPT_ENABLED_PROVIDERS=codex,claudeCompatible
```

Run:

```bash
sudo repoprompt-server up
sudo repoprompt-server provider-check
```

The command verifies core readiness and that every admitted executable exists.
Executable presence is only the deployment gate. In Portal → Settings →
Providers, complete authentication and use **Test Connection** for the live
provider/account readiness check. Provider binaries and their versioned release
provenance are separate release inputs; do not download arbitrary CLIs into a
running container.

## 5. Add a project

```bash
sudo repoprompt-server project-onboarding
```

For host-managed sources, place reviewed checkouts below
`/var/lib/repoprompt-server/projects` with service UID/GID 65532 access, then add
the project in the portal. Server-managed Git cloning remains disabled until an
operator explicitly mounts a source-policy file and reviewed SSH credentials.
Confirm one bounded project read before agent work.

## 6. Back up before changes

```bash
sudo repoprompt-server backup
sudo repoprompt-server verify repoprompt-<timestamp>.age
```

`backup` stops serving, acquires the namespace maintenance lease, creates the
encrypted archive, performs a leased verification, and returns the prior service
to readiness. Archive and sidecar files are written under
`/var/backups/repoprompt-server`.

The encrypted archive deliberately does **not** replace custody of
`/etc/repoprompt-server/secrets`. Preserve that directory separately: it contains
the age identity, provider-vault key, and any installed TLS key. Restore requires
the original matching custody material. Never copy it into tickets or logs.

See [Backup, restore, and rotation](backup-restore-runbook.md) before a restore.

## 7. Upgrade and rollback boundary

```bash
sudo repoprompt-server upgrade \
  'ghcr.io/repoprompt/repoprompt-server@sha256:<new-release-digest>'
sudo repoprompt-server rollback-info
```

Upgrade takes and verifies a pre-upgrade backup, records the previous immutable
image, pulls the new image, and waits for readiness. It does not automatically
downgrade the image if new startup fails: startup may already have committed a
forward-only schema migration. Rollback means a fresh empty installation pinned
to the compatible prior image plus restore of the recorded pre-upgrade archive
and original custody secrets. Never point an older image at possibly migrated
live data.

## 8. Uninstall

Safe default—remove containers, preserve everything:

```bash
sudo repoprompt-server uninstall
```

Explicitly destroy live data while preserving the custody secrets needed to
decrypt backups, backup archives, provider binaries, and installation
configuration:

```bash
sudo repoprompt-server uninstall \
  --destroy-data --confirm DESTROY-REPOPROMPT-DATA
```

Deleting backup archives or the remaining installation bundle is a separate
operator action. This prevents a routine uninstall from also deleting the last
recovery copy.
