#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  ccm_source_lib "prune.sh"
  mkdir -p "$CCM_TMPHOME/project1"
  cd "$CCM_TMPHOME/project1"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  for ts in 2025-01-01-1200 2025-06-01-1200 2026-05-01-1200; do
    echo "Summary at $ts" > "$pdir/timeline/$ts.md"
  done
}
teardown() { ccm_teardown_tmphome; }

@test "prune: --older-than=180d deletes entries older than cutoff" {
  run ccm_prune_main --older-than=180d --yes
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  pdir="$(ccm_project_dir "$pid")"
  # 2025-01-01 and 2025-06-01 are >180d before 2026-05-11 ⇒ deleted.
  # 2026-05-01 is within 180d ⇒ kept.
  count="$(ls -1 "$pdir/timeline" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
  [ -f "$pdir/timeline/2026-05-01-1200.md" ]
}

@test "prune: --orphans lists projects whose dir no longer matches any local repo" {
  # Create an orphan project
  mkdir -p "$HOME/.claude/context-manager/orphan-id/timeline"
  echo "old" > "$HOME/.claude/context-manager/orphan-id/timeline/2025-01-01.md"
  echo '{"project_id":"orphan-id","git_remote":"none"}' > "$HOME/.claude/context-manager/orphan-id/meta.json"
  run ccm_prune_main --orphans --list-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphan-id"* ]]
}
