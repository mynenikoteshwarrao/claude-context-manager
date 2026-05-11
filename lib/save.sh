# lib/save.sh — full save: summarize transcript, write timeline + current.md.
# Requires platform.sh, common.sh, id.sh sourced; CCM_ROOT set.

CCM_SAVE_TIMEOUT="${CCM_SAVE_TIMEOUT:-60}"

# Parse the LLM response into two parts: summary and in-progress.
_ccm_split_response() {
  local response="$1"
  local summary in_progress
  summary="$(printf '%s\n' "$response" | awk '
    /^## SUMMARY/   { capture=1; next }
    /^## IN_PROGRESS/ { capture=0 }
    capture { print }
  ')"
  in_progress="$(printf '%s\n' "$response" | awk '
    /^## IN_PROGRESS/ { capture=1; next }
    capture { print }
  ')"
  printf '%s\n---SPLIT---\n%s' "$summary" "$in_progress"
}

# Stub fallback when claude is unavailable: just head/tail of transcript.
_ccm_stub_summary() {
  local transcript="$1"
  echo "## SUMMARY"
  echo "(claude CLI not available; stub generated from transcript head and tail.)"
  echo ""
  echo "Head:"
  head -50 "$transcript" 2>/dev/null || true
  echo ""
  echo "Tail:"
  tail -50 "$transcript" 2>/dev/null || true
  echo ""
  echo "## IN_PROGRESS"
  echo "none"
}

ccm_save_main() {
  local transcript="${1:-}"
  if [ -z "$transcript" ]; then
    # Fall back to $CLAUDE_SESSION_ID-based path; for MVP, require arg.
    echo "ccm save: usage: ccm save <transcript-path>" >&2
    return 1
  fi
  if [ ! -f "$transcript" ]; then
    ccm_log "save: transcript missing: $transcript"
    return 0  # never fail the hook
  fi

  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  ccm_init_project_dir "$pid"

  local response
  if command -v claude >/dev/null 2>&1; then
    response="$(cat "$transcript" | \
      claude -p "$(cat "$CCM_ROOT/prompts/summarize.txt")" 2>/dev/null || true)"
  fi
  if [ -z "${response:-}" ]; then
    response="$(_ccm_stub_summary "$transcript")"
  fi

  local split summary in_progress
  split="$(_ccm_split_response "$response")"
  summary="${split%---SPLIT---*}"
  in_progress="${split#*---SPLIT---}"

  # Write timeline entry
  local ts entry
  ts="$(date -u +%Y-%m-%d-%H%M)"
  entry="$pdir/timeline/$ts.md"
  printf '%s\n' "$summary" > "$entry"

  # Overwrite current.md with in-progress section
  printf '%s\n' "$in_progress" > "$pdir/current.md"

  # Append to transcripts.jsonl
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc \
    --arg ts "$now" \
    --arg transcript "$transcript" \
    --arg summary "$entry" \
    '{ts:$ts, transcript:$transcript, summary:$summary}' \
    >> "$pdir/transcripts.jsonl"

  # Update meta.json last_save_at
  if [ -f "$pdir/meta.json" ]; then
    tmp="$(mktemp)"
    jq --arg ts "$now" '.last_save_at = $ts' "$pdir/meta.json" > "$tmp" && mv "$tmp" "$pdir/meta.json"
  fi

  ccm_log "save: pid=$pid entry=$ts"
  return 0
}
