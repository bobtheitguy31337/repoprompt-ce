# Private-pilot operations runbook

For the standalone Ubuntu bundle, use `repoprompt-server status`, `logs`,
`provider-check`, `backup`, `verify`, `restore`, `upgrade`, and `uninstall`
rather than assembling raw Docker commands. The wrapper delegates database work
to the Server-owned maintenance commands and preserves the namespace lease.
See [Ubuntu installation and first run](getting-started.md).

## Deployment boundary

`Dockerfile.server` builds a non-root image under UID/GID 65532 with `tini`, persistent state/artifact/project/worktree/cache volumes, a loopback readiness probe, pinned age binaries, and Schema V9 labels. The Server Runtime workflow builds and tests macOS and Linux packages and builds the image. It has read-only repository permissions and contains no registry login or push step. Publishing and distribution remain disabled.

## Observe

- `GET /health/live` checks process liveness.
- `GET /health/ready` checks the migration ledger, SQLite integrity, activation state, storage capacity, providers, outbox/transition health, and drain admission.
- The authenticated Operations portal shows the same readiness state plus backup receipts and secret-free security audit entries.
- Authenticated `/metrics` exposes low-cardinality gauges, including active operator sessions, blocked throttle buckets, audit/receipt counts, last successful backup time, outbox, transitions, providers, storage, and drain state. Never add usernames, project IDs, client addresses, correlation IDs, or digests as metric labels.
- Server lifecycle/security logs are single-line JSON with timestamp, level, event, outcome, and an allowlisted string field map. Error logs include the error type, not an error description that may contain a credential path.

The Compose bundle uses host networking on its Ubuntu-only boundary so direct
TLS and the supported loopback trusted-proxy backend share the host's real
listener identity. Keep the health listener on loopback and do not publish it.

## Routine pilot checks

1. Confirm readiness before admitting operators.
2. Confirm the latest scheduled backup has both a creation and leased-verification receipt.
3. Review blocked authentication buckets and failed security outcomes.
4. Confirm event outbox pending age and nonfinal transitions are bounded.
5. Run the documented restore drill after recipient/tool rotation and before pilot expansion.

## Incident actions

- Suspected session theft: run `operator revoke-all-sessions`, then rotate the password offline if required.
- Lost password: stop serving, use maintenance-leased `operator reset-password`, restart, and confirm all old sessions are revoked.
- Setup-token exposure: stop serving and issue a replacement setup token to a new owner-only output before account creation.
- Repeated auth failures: preserve V9 audit/throttle rows and proxy logs, verify trusted-proxy CIDRs/headers, and do not clear buckets manually.
- Readiness failure or interrupted restore: stop admission, retain structured logs and receipts, follow the restore runbook, and do not delete fencing files.

Human security review, operations review, release-owner review, custody acceptance, and private-pilot approval/soak are external gates. Repository evidence can support those decisions but cannot satisfy or fabricate them.
