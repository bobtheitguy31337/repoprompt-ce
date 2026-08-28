#!/usr/bin/env bash
set -euo pipefail

repo=$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

git -C "$repo" fetch origin sandbox
git -C "$repo" checkout --detach origin/sandbox

"$repo/Sandbox/Server/build.sh"
"$repo/Sandbox/Server/activate.sh"
