#!/usr/bin/env bash
set -euo pipefail

repo=$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
docker build \
  --file "$repo/Dockerfile.server" \
  --tag degentlemen-repoprompt:sandbox \
  --build-arg "REPOPROMPT_COMMIT=$(git -C "$repo" rev-parse HEAD)" \
  "$repo"
