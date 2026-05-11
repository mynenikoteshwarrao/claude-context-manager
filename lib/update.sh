# lib/update.sh — self-update dispatcher.

CCM_RELEASE_REPO="${CCM_RELEASE_REPO:-mynenikoteshwarrao/claude-context-manager}"

# Detect how ccm was installed by inspecting the directory layout.
# Args: $1 = install root (where bin/ccm + VERSION live).
ccm_detect_install_channel() {
  local root="$1"
  if [ -d "$root/.git" ]; then
    echo "clone"; return 0
  fi
  # Tarball install: no .git, but has VERSION + bin/
  if [ -f "$root/VERSION" ] && [ -f "$root/bin/ccm" ]; then
    echo "tarball"; return 0
  fi
  echo "unknown"
  return 0
}

# Fetch the latest release tag from GitHub. Overridable via stub in tests.
_ccm_remote_version() {
  curl -fsSL "https://api.github.com/repos/$CCM_RELEASE_REPO/releases/latest" 2>/dev/null \
    | jq -r '.tag_name' \
    | sed 's/^v//'
}

ccm_update_main() {
  local check=0 root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) check=1 ;;
      --root)  shift; root="$1" ;;
      *) echo "ccm update: unknown arg: $1" >&2; return 1 ;;
    esac
    shift
  done
  [ -z "$root" ] && root="$CCM_ROOT"

  local local_v remote_v
  local_v="$(cat "$root/VERSION" 2>/dev/null || echo "unknown")"
  remote_v="$(_ccm_remote_version || echo "")"

  if [ -z "$remote_v" ]; then
    echo "ccm update: couldn't reach GitHub" >&2
    return 1
  fi

  if [ "$local_v" = "$remote_v" ]; then
    echo "ccm is up to date ($local_v)"
    return 0
  fi

  echo "Update available: $local_v → $remote_v"
  if [ "$check" -eq 1 ]; then
    return 0
  fi

  local channel
  channel="$(ccm_detect_install_channel "$root")"
  case "$channel" in
    clone)
      ( cd "$root" && git pull --ff-only && bash ./install.sh --quiet )
      ;;
    tarball)
      echo "Re-run: curl -fsSL https://raw.githubusercontent.com/$CCM_RELEASE_REPO/main/install-remote.sh | bash"
      ;;
    *)
      echo "Couldn't detect install channel. Reinstall manually."
      return 1
      ;;
  esac
  echo "Update complete. Restart Claude Code for hooks to reload."
}
