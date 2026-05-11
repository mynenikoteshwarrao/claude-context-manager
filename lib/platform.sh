# shellcheck shell=bash
# lib/platform.sh — OS abstraction layer.
# Sourced by ccm and other lib scripts.

# Detect OS.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) CCM_OS=windows ;;
  Darwin)               CCM_OS=macos ;;
  Linux)                CCM_OS=linux ;;
  *)                    CCM_OS=unknown ;;
esac
export CCM_OS

# Hash stdin with SHA1; print 40-char hex digest.
ccm_sha1() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 1 | cut -d' ' -f1
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum | cut -d' ' -f1
  else
    echo "ccm: no SHA1 tool found (shasum or sha1sum)" >&2
    return 1
  fi
}

# Convert path to POSIX form. No-op on macOS/Linux; cygpath -u on Windows.
ccm_path_posix() {
  if [ "$CCM_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s' "$1"
  fi
}

# Convert path to native form. No-op on macOS/Linux; cygpath -w on Windows.
ccm_path_native() {
  if [ "$CCM_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# Create a symlink. On Windows, try native symlink; on failure, write a shim.
ccm_symlink() {
  local src="$1" dst="$2"
  rm -f "$dst" 2>/dev/null || true
  if [ "$CCM_OS" = "windows" ]; then
    if ! MSYS=winsymlinks:nativestrict ln -s "$src" "$dst" 2>/dev/null; then
      # Fall back to a wrapper shim
      cat > "$dst" <<EOF
#!/usr/bin/env bash
exec "$src" "\$@"
EOF
      chmod +x "$dst"
    fi
  else
    ln -s "$src" "$dst"
  fi
}

# Append a message to the ccm log with timestamp.
ccm_log() {
  local log_dir="$HOME/.claude/context-manager"
  local log_file="$log_dir/log"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CCM_OS" "$*" >> "$log_file"
}
