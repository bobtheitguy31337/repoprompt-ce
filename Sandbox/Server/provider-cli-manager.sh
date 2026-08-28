#!/bin/bash
set -euo pipefail
umask 077

fail() {
  printf 'ERROR: provider CLI manager: %s\n' "$*" >&2
  exit 1
}

provider_command() {
  case $1 in
    codex) printf 'codex\n' ;;
    claudeCompatible) printf 'claude\n' ;;
    openCodeACP) printf 'opencode\n' ;;
    cursorACP) printf 'cursor-agent\n' ;;
    grokBuildACP) printf 'grok\n' ;;
    *) fail "unsupported provider $1" ;;
  esac
}

export HOME=${HOME:-/home/repoprompt}
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
selection_file=${REPOPROMPT_PROVIDER_CLI_SELECTION_FILE:-/var/lib/repoprompt/state/provider-cli-selection}
install -d -m 0700 "$HOME" "$(dirname "$selection_file")"

record_installed() {
  provider=$1
  temporary=$selection_file.$$
  { test ! -f "$selection_file" || cat "$selection_file"; printf '%s\n' "$provider"; } |
    LC_ALL=C sort -u > "$temporary"
  mv "$temporary" "$selection_file"
}

record_uninstalled() {
  provider=$1
  temporary=$selection_file.$$
  if [ -f "$selection_file" ]; then
    grep -Fvx "$provider" "$selection_file" > "$temporary" || true
    mv "$temporary" "$selection_file"
  fi
}

install_provider() {
  case $1 in
    codex) curl -fsSL https://chatgpt.com/codex/install.sh | sh ;;
    claudeCompatible) curl -fsSL https://claude.ai/install.sh | bash ;;
    openCodeACP) curl -fsSL https://opencode.ai/install | bash ;;
    cursorACP) curl -fsSL https://cursor.com/install | bash ;;
    grokBuildACP) curl -fsSL https://x.ai/cli/install.sh | bash ;;
  esac
}

update_provider() {
  provider=$1
  command_name=$(provider_command "$provider")
  command -v "$command_name" >/dev/null 2>&1 || fail "$provider is not installed"
  case $provider in
    codex) curl -fsSL https://chatgpt.com/codex/install.sh | sh ;;
    claudeCompatible) claude update ;;
    openCodeACP) opencode upgrade ;;
    cursorACP) cursor-agent update ;;
    grokBuildACP) grok update ;;
  esac
}

uninstall_provider() {
  provider=$1
  command_name=$(provider_command "$provider")
  command -v "$command_name" >/dev/null 2>&1 || fail "$provider is not installed"
  case $provider in
    codex) rm -f -- "$HOME/.local/bin/codex" ;;
    claudeCompatible) rm -f -- "$HOME/.local/bin/claude" ;;
    openCodeACP) opencode uninstall --keep-config --keep-data --force ;;
    cursorACP) rm -f -- "$HOME/.local/bin/cursor-agent" ;;
    grokBuildACP) rm -f -- "$HOME/.local/bin/grok" ;;
  esac
}

verify_provider() {
  provider=$1
  command_name=$(provider_command "$provider")
  executable=$(command -v "$command_name" 2>/dev/null) || fail "$provider installer did not put $command_name on PATH"
  version=$($executable --version 2>&1 | head -n 1)
  [ -n "$version" ] || fail "$provider executable did not report a version"
  printf '%s\n' "$version"
}

action=${1:-}
provider=${2:-}
case $action in
  install | update | uninstall | status) [ -n "$provider" ] || fail "provider is required" ;;
  restore) ;;
  *) fail "usage: provider-cli-manager {install|update|uninstall|status} PROVIDER | restore" ;;
esac
[ -z "$provider" ] || provider_command "$provider" >/dev/null

exec 9>"$selection_file.lock"
flock 9

case $action in
  install) install_provider "$provider"; verify_provider "$provider"; record_installed "$provider" ;;
  update) update_provider "$provider"; verify_provider "$provider" ;;
  uninstall) uninstall_provider "$provider"; record_uninstalled "$provider" ;;
  status) verify_provider "$provider" ;;
  restore)
    [ -f "$selection_file" ] || exit 0
    while IFS= read -r provider; do
      [ -n "$provider" ] || continue
      provider_command "$provider" >/dev/null
      install_provider "$provider"
      verify_provider "$provider"
    done < "$selection_file"
    ;;
esac
