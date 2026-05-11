#!/usr/bin/env bats
load 'helpers.bash'

setup() { ccm_setup_tmphome; }
teardown() { ccm_teardown_tmphome; }

@test "ccm: version prints VERSION file contents" {
  run "$CCM_REPO_ROOT/bin/ccm" version
  [ "$status" -eq 0 ]
  expected="$(cat "$CCM_REPO_ROOT/VERSION")"
  [ "$output" = "$expected" ]
}

@test "ccm: no args prints help and exits 1" {
  run "$CCM_REPO_ROOT/bin/ccm"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "ccm: unknown subcommand exits 1 with hint" {
  run "$CCM_REPO_ROOT/bin/ccm" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown"* ]]
}

@test "ccm: id prints a non-empty project id" {
  mkdir -p "$CCM_TMPHOME/repo"
  cd "$CCM_TMPHOME/repo"
  git init -q
  run "$CCM_REPO_ROOT/bin/ccm" id
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "ccm: show 1 reads from history.sh" {
  cd "$CCM_TMPHOME"
  pid="$(printf '%s' "$PWD" | sha1sum | cut -d' ' -f1 2>/dev/null || printf '%s' "$PWD" | shasum -a 1 | cut -d' ' -f1)"
  mkdir -p "$HOME/.claude/context-manager/$pid/timeline"
  echo "summary content" > "$HOME/.claude/context-manager/$pid/timeline/2026-05-01-1200.md"
  echo '{"project_id":"'"$pid"'"}' > "$HOME/.claude/context-manager/$pid/meta.json"
  run "$CCM_REPO_ROOT/bin/ccm" show 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"summary content"* ]]
}
