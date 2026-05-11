# shellcheck shell=bash
# lib/flush.sh — light pre-compact save. Refreshes current.md only.

ccm_flush_main() {
  local transcript="${1:-}"
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    ccm_log "flush: no transcript at $transcript"
    return 0
  fi

  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  ccm_init_project_dir "$pid"

  local response
  if command -v claude >/dev/null 2>&1; then
    response="$(cat "$transcript" | \
      claude -p "$(cat "$CCM_ROOT/prompts/flush.txt")" 2>/dev/null || true)"
  fi
  if [ -z "${response:-}" ]; then
    response="## IN_PROGRESS"$'\n'"(claude unavailable during flush)"
  fi

  # Extract IN_PROGRESS section
  local in_progress
  in_progress="$(printf '%s\n' "$response" | awk '
    /^## IN_PROGRESS/ { capture=1; next }
    capture { print }
  ')"

  printf '%s\n' "$in_progress" > "$pdir/current.md"
  ccm_log "flush: pid=$pid current.md updated"
  return 0
}
