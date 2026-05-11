#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  ccm_source_lib "load.sh"
}
teardown() { ccm_teardown_tmphome; }

@test "load: empty storage → empty stdout, exit 0" {
  mkdir -p "$CCM_TMPHOME/empty"
  cd "$CCM_TMPHOME/empty"
  run ccm_load_main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "load: with current.md only → output contains current.md text" {
  mkdir -p "$CCM_TMPHOME/project1"
  cd "$CCM_TMPHOME/project1"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  echo "Working on auth refactor; JWT endpoint half-done" \
    > "$(ccm_project_dir "$pid")/current.md"
  run ccm_load_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored Context"* ]]
  [[ "$output" == *"JWT endpoint half-done"* ]]
}

@test "load: with 5 timeline entries → only 3 most recent rendered" {
  mkdir -p "$CCM_TMPHOME/project2"
  cd "$CCM_TMPHOME/project2"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  for ts in 2026-05-01-1200 2026-05-02-1200 2026-05-03-1200 2026-05-04-1200 2026-05-05-1200; do
    echo "Summary for $ts" > "$pdir/timeline/$ts.md"
  done
  run ccm_load_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-05-05-1200"* ]]
  [[ "$output" == *"2026-05-04-1200"* ]]
  [[ "$output" == *"2026-05-03-1200"* ]]
  [[ "$output" != *"2026-05-02-1200"* ]]
  [[ "$output" != *"2026-05-01-1200"* ]]
}

@test "load: rendered block stays under 3000-token budget" {
  mkdir -p "$CCM_TMPHOME/project3"
  cd "$CCM_TMPHOME/project3"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  # 10 large entries
  for i in $(seq 1 10); do
    printf 'word%.0s ' {1..3000} > "$pdir/timeline/2026-05-${i}-1200.md"
  done
  run ccm_load_main
  [ "$status" -eq 0 ]
  word_count="$(echo "$output" | wc -w | tr -d ' ')"
  # 3000 tokens ≈ 2250 words; allow some headroom for headings
  [ "$word_count" -le 2500 ]
}
