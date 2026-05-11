#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  ccm_source_lib "history.sh"
  mkdir -p "$CCM_TMPHOME/project1"
  cd "$CCM_TMPHOME/project1"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  for ts in 2026-05-01-1200 2026-05-02-1500 2026-05-03-0900; do
    echo "Summary at $ts" > "$pdir/timeline/$ts.md"
  done
}
teardown() { ccm_teardown_tmphome; }

@test "history: lists entries newest-first, numbered" {
  run ccm_history_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
  [[ "$output" == *"2026-05-03-0900"* ]]
  first_line="$(echo "$output" | head -1)"
  [[ "$first_line" == *"2026-05-03-0900"* ]]
}

@test "show: prints entry N content" {
  ccm_source_lib "history.sh"
  run ccm_show_main 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-05-03-0900"* ]]
}

@test "show: invalid index exits 1" {
  ccm_source_lib "history.sh"
  run ccm_show_main 99
  [ "$status" -eq 1 ]
}
