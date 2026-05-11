# shellcheck shell=bash
# lib/id.sh — resolve project ID for the current working directory.
# Requires platform.sh and common.sh sourced first.

# URL-encode a string for filesystem-safe use as a directory name.
# Replaces / : ? & = with -, drops anything else non-alphanumeric to _.
_ccm_url_encode() {
  printf '%s' "$1" | tr '/:?&=' '-----' | tr -c 'A-Za-z0-9.-' '_' | sed 's/_*$//'
}

# Resolve and print the project ID for $PWD.
# Order: git remote get-url origin → URL-encoded; else SHA1($PWD).
ccm_resolve_project_id() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [ -n "$remote" ]; then
    _ccm_url_encode "$remote"
  else
    printf '%s' "$PWD" | ccm_sha1
  fi
}
