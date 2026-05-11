#!/usr/bin/env bash
# install.sh — install ccm into ~/.local/bin and ~/.claude/.
# Idempotent. Run from the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/lib/platform.sh"

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --force) ;;  # accepted for backward-compat; reinstall is always idempotent
    *) echo "install.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

_say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
_die() { echo "ccm install: $*" >&2; exit 1; }

# --- 1. Preflight: required tools ----------------------------------------
preflight() {
  local missing=()
  command -v bash    >/dev/null 2>&1 || missing+=("bash")
  command -v jq      >/dev/null 2>&1 || missing+=("jq")
  command -v claude  >/dev/null 2>&1 || missing+=("claude")
  if command -v shasum >/dev/null 2>&1 || command -v sha1sum >/dev/null 2>&1; then
    :
  else
    missing+=("shasum or sha1sum")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    local hint=""
    case "$CCM_OS" in
      macos)   hint="Try: brew install ${missing[*]}" ;;
      windows) hint="Try: scoop install ${missing[*]}" ;;
    esac
    _die "missing tools: ${missing[*]}. $hint"
  fi
}

# --- 2. Create directories -----------------------------------------------
mkdirs() {
  mkdir -p "$HOME/.local/bin"
  mkdir -p "$HOME/.claude"
  mkdir -p "$HOME/.claude/commands"
  mkdir -p "$HOME/.claude/context-manager"
}

# --- 3. Symlinks ---------------------------------------------------------
do_symlinks() {
  ccm_symlink "$REPO_ROOT/bin/ccm"      "$HOME/.local/bin/ccm"
  ccm_symlink "$REPO_ROOT/commands/ccm" "$HOME/.claude/commands/ccm"
  _say "Linked ccm into ~/.local/bin and ~/.claude/commands/ccm"
}

# --- 4. Hook registration in settings.json -------------------------------
ccm_bin_path() {
  # Path used in hook commands. POSIX absolute so it works in Git Bash too.
  local p="$HOME/.local/bin/ccm"
  ccm_path_posix "$p"
}

register_hooks() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"
  local bin_path
  bin_path="$(ccm_bin_path)"
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg bin "$bin_path" \
    '
      .hooks //= {}
      | .hooks.SessionStart = [{"command": ($bin + " load")}]
      | .hooks.SessionEnd   = [{"command": ($bin + " save \"$CLAUDE_TRANSCRIPT_PATH\"")}]
      | .hooks.PreCompact   = [{"command": ($bin + " flush \"$CLAUDE_TRANSCRIPT_PATH\"")}]
    ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  _say "Registered SessionStart, SessionEnd, PreCompact hooks"
}

# --- 5. PATH check -------------------------------------------------------
path_check() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    cat <<EOF
Note: $HOME/.local/bin is not on your PATH.
Add this to your shell rc (.zshrc, .bashrc):
  export PATH="\$HOME/.local/bin:\$PATH"
EOF
  fi
}

main() {
  preflight
  mkdirs
  do_symlinks
  register_hooks
  path_check
  _say "Done. Verify with: ccm version && ccm history"
}
main
