# shellcheck shell=bash
# lib/prune.sh — interactive cleanup of old timeline entries and orphan projects.

# Compute the cutoff timestamp ("now - N days") in YYYY-MM-DD form.
_ccm_cutoff_date() {
  local spec="$1"   # e.g. "180d"
  local days
  days="${spec%d}"
  if [[ ! "$days" =~ ^[0-9]+$ ]]; then
    echo "ccm prune: bad --older-than: $spec (expected like 30d)" >&2
    return 1
  fi
  if [ "$CCM_OS" = "macos" ]; then
    date -u -v-"${days}"d +%Y-%m-%d
  else
    date -u -d "@$(( $(date -u +%s) - days*86400 ))" +%Y-%m-%d
  fi
}

ccm_prune_main() {
  local mode="" older=""  yes=0 list_only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --older-than=*) older="${1#*=}" ; mode="older" ;;
      --orphans)      mode="orphans" ;;
      --yes|-y)       yes=1 ;;
      --list-only)    list_only=1 ;;
      *) echo "ccm prune: unknown arg: $1" >&2; return 1 ;;
    esac
    shift
  done

  if [ "$mode" = "older" ]; then
    local cutoff
    cutoff="$(_ccm_cutoff_date "$older")" || return 1
    local pid pdir
    pid="$(ccm_resolve_project_id)"
    pdir="$(ccm_project_dir "$pid")"
    [ -d "$pdir/timeline" ] || return 0
    local victims=()
    while IFS= read -r f; do
      local base="${f%.md}"
      local entry_date="${base:0:10}"
      if [[ "$entry_date" < "$cutoff" ]]; then
        victims+=("$f")
      fi
    done < <(ls -1 "$pdir/timeline" 2>/dev/null)
    if [ "${#victims[@]}" -eq 0 ]; then
      echo "Nothing older than $older."
      return 0
    fi
    if [ "$yes" -ne 1 ] && [ "$list_only" -ne 1 ]; then
      echo "Would delete ${#victims[@]} entries older than $cutoff."
      printf '  %s\n' "${victims[@]}"
      read -r -p "Confirm? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
    fi
    if [ "$list_only" -eq 1 ]; then
      printf '%s\n' "${victims[@]}"
      return 0
    fi
    for v in "${victims[@]}"; do
      rm -f "$pdir/timeline/$v"
    done
    echo "Pruned ${#victims[@]} entries."
    ccm_log "prune: older=$older count=${#victims[@]}"
    return 0
  fi

  if [ "$mode" = "orphans" ]; then
    local root
    root="$(ccm_storage_root)"
    [ -d "$root" ] || return 0
    # An orphan is any project dir whose project_id can't be re-resolved from
    # any locally known directory. MVP heuristic: any project whose meta.json
    # has git_remote=none AND whose dir doesn't equal $PWD's resolved id.
    local current_id
    current_id="$(ccm_resolve_project_id 2>/dev/null || true)"
    local orphans=()
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      local pid_dir
      pid_dir="$(basename "$d")"
      [ "$pid_dir" = "log" ] && continue
      if [ "$pid_dir" != "$current_id" ]; then
        # Treat all non-current as candidate orphans for the listing.
        orphans+=("$pid_dir")
      fi
    done
    if [ "$list_only" -eq 1 ]; then
      printf '%s\n' "${orphans[@]}"
      return 0
    fi
    if [ "${#orphans[@]}" -eq 0 ]; then
      echo "No orphan projects."
      return 0
    fi
    echo "Candidate orphans:"
    printf '  %s\n' "${orphans[@]}"
    echo "Re-run with --list-only to capture, or rm -rf <root>/<id> manually."
    return 0
  fi

  echo "ccm prune: usage: ccm prune [--older-than=30d | --orphans] [--yes] [--list-only]" >&2
  return 1
}
