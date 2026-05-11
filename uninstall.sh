#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/lib/platform.sh"

QUIET=0
KEEP_STORAGE=0
for arg in "$@"; do
  case "$arg" in
    --quiet)         QUIET=1 ;;
    --keep-storage)  KEEP_STORAGE=1 ;;
    *) echo "uninstall.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

_say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# 1. Remove symlinks/shims
rm -f "$HOME/.local/bin/ccm" 2>/dev/null || true
rm -rf "$HOME/.claude/commands/ccm" 2>/dev/null || true
_say "Removed symlinks."

# 2. Remove our hook entries from settings.json
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ]; then
  tmp="$(mktemp)"
  jq 'del(.hooks.SessionStart, .hooks.SessionEnd, .hooks.PreCompact)' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  _say "Removed ccm hooks from settings.json."
fi

# 3. Storage
if [ "$KEEP_STORAGE" -eq 0 ]; then
  if [ "$QUIET" -ne 1 ]; then
    read -r -p "Delete ~/.claude/context-manager/ and all stored history? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      rm -rf "$HOME/.claude/context-manager"
      _say "Deleted storage."
    else
      _say "Keeping storage at ~/.claude/context-manager/"
    fi
  else
    _say "Storage retained (--quiet)."
  fi
fi

_say "Uninstall complete."
