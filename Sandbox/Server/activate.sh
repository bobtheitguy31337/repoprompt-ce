#!/usr/bin/env bash
set -euo pipefail

repo=$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

docker compose \
  --project-directory "$repo/Sandbox/Server" \
  --file "$repo/Sandbox/Server/compose.yml" \
  up -d --wait --no-build
