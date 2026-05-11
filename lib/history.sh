# shellcheck shell=bash
# lib/history.sh — list and show timeline entries.

_ccm_list_entries_desc() {
  local pdir="$1"
  local tdir="$pdir/timeline"
  [ -d "$tdir" ] || return 0
  ls -1 "$tdir" 2>/dev/null | sort -r
}

ccm_history_main() {
  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  if [ ! -d "$pdir/timeline" ]; then
    echo "(no history yet for this project)"
    return 0
  fi
  local n=0
  while IFS= read -r entry; do
    n=$((n+1))
    local base
    base="${entry%.md}"
    printf '%d  %s\n' "$n" "$base"
  done < <(_ccm_list_entries_desc "$pdir")
}

ccm_show_main() {
  local idx="${1:-}"
  if [ -z "$idx" ] || ! [[ "$idx" =~ ^[0-9]+$ ]]; then
    echo "ccm show: usage: ccm show <N>" >&2
    return 1
  fi
  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  local n=0 target=""
  while IFS= read -r entry; do
    n=$((n+1))
    if [ "$n" -eq "$idx" ]; then
      target="$pdir/timeline/$entry"
      break
    fi
  done < <(_ccm_list_entries_desc "$pdir")
  if [ -z "$target" ] || [ ! -f "$target" ]; then
    echo "ccm show: no entry #$idx" >&2
    return 1
  fi
  echo "### ${entry%.md}"
  cat "$target"
}
