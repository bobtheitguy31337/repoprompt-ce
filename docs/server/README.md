# RepoPrompt Server

RepoPrompt Server is the standalone Ubuntu 24.04 product built by
`Dockerfile.server`. The RepoPrompt-owned operator bundle lives under
`Distribution/Server`: one image, one Compose service, host-network listeners,
bind-mounted durable state, and a small lifecycle command. It does not depend on
the macOS app and it does not contain chat deployment infrastructure.

Start with [Ubuntu installation and first run](getting-started.md).

Operator documents:

- [Ubuntu installation and first run](getting-started.md)
- [Security and access](private-pilot-security.md)
- [Backup format and custody](backup-format-and-custody.md)
- [Backup, restore, and rotation runbook](backup-restore-runbook.md)
- [Operations runbook](operations-runbook.md)
- [Custody and external-gate record](private-pilot-custody-record.md)
- [Validation evidence and limitations](private-pilot-validation.md)

## Distribution status

The bundle consumes an official digest-pinned image reference; it never builds
from source on an operator host. This repository's current Server Runtime
workflow remains deliberately non-publishing: it builds and exercises the image
but does not log in to a registry or push it. A release owner must separately
publish and sign the official image before clean-Ubuntu installation can be
performed from a released artifact. Do not substitute an unreviewed mutable tag.

Schema V9 remains the security/operations schema. Schema V7 and V8 definitions
and frozen fixtures remain unchanged.
