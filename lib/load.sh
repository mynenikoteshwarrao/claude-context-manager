# lib/load.sh — render the SessionStart context block.
# Requires platform.sh, common.sh, id.sh sourced first.

CCM_LOAD_TOKEN_BUDGET="${CCM_LOAD_TOKEN_BUDGET:-3000}"

ccm_load_main() {
  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"

  if [ ! -d "$pdir" ]; then
    # First run in this project; emit nothing.
    return 0
  fi

  local current="$pdir/current.md"
  local timeline_dir="$pdir/timeline"
  local has_current=0 has_timeline=0
  [ -s "$current" ] && has_current=1
  [ -d "$timeline_dir" ] && [ -n "$(ls -A "$timeline_dir" 2>/dev/null)" ] && has_timeline=1

  if [ "$has_current" -eq 0 ] && [ "$has_timeline" -eq 0 ]; then
    return 0
  fi

  # Build the rendered block and output it.
  local output
  output="$({
    echo "# Claude Context Manager — Restored Context"
    echo ""
    if [ "$has_current" -eq 1 ]; then
      echo "## In progress (from last session)"
      cat "$current"
      echo ""
    fi
    if [ "$has_timeline" -eq 1 ]; then
      echo "## Recent session summaries"
      # Most recent 3, reverse chronological
      local n=0
      while IFS= read -r entry; do
        n=$((n+1))
        [ "$n" -gt 3 ] && break
        local base
        base="$(basename "$entry" .md)"
        echo "### $base"
        cat "$entry"
        echo ""
      done < <(ls -1 "$timeline_dir" 2>/dev/null | sort -r | sed "s|^|$timeline_dir/|")
    fi
    echo "---"
    echo "*Older summaries: \`/ccm:history\`. Full transcripts: \`/ccm:show N\`.*"
  } | ccm_truncate_to_tokens "$CCM_LOAD_TOKEN_BUDGET")"

  printf '%s\n' "$output"
  ccm_log "load: pid=$pid rendered context"
  return 0
}
