# shellcheck shell=bash
# lib/common.sh — shared paths and helpers. Requires platform.sh sourced first.

# Storage root: ~/.claude/context-manager
ccm_storage_root() {
  printf '%s' "$HOME/.claude/context-manager"
}

# Per-project directory under storage root.
ccm_project_dir() {
  printf '%s' "$(ccm_storage_root)/$1"
}

# Ensure project dir + timeline subdir exist.
ccm_init_project_dir() {
  local pid="$1"
  local pdir
  pdir="$(ccm_project_dir "$pid")"
  mkdir -p "$pdir/timeline"
  if [ ! -f "$pdir/meta.json" ]; then
    printf '{"project_id":"%s","created_at":"%s"}\n' "$pid" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$pdir/meta.json"
  fi
}

# Truncate stdin to approximately N tokens. Approximation: 1 token ≈ 0.75 words.
# Used for budget enforcement; not exact.
ccm_truncate_to_tokens() {
  local budget="$1"
  local word_limit=$(( budget * 3 / 4 ))
  awk -v limit="$word_limit" '
    {
      for (i=1; i<=NF; i++) {
        if (count >= limit) { exit }
        printf "%s ", $i
        count++
      }
      printf "\n"
    }
  '
}
