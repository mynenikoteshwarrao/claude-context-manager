#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
}
teardown() { ccm_teardown_tmphome; }

@test "common: ccm_storage_root returns ~/.claude/context-manager" {
  result="$(ccm_storage_root)"
  [ "$result" = "$HOME/.claude/context-manager" ]
}

@test "common: ccm_project_dir returns storage_root + project id" {
  result="$(ccm_project_dir "abc123")"
  [ "$result" = "$HOME/.claude/context-manager/abc123" ]
}

@test "common: ccm_init_project_dir creates dir and timeline subdir" {
  ccm_init_project_dir "test-project"
  [ -d "$HOME/.claude/context-manager/test-project" ]
  [ -d "$HOME/.claude/context-manager/test-project/timeline" ]
}

@test "common: ccm_truncate_to_tokens drops content beyond budget" {
  # Token budget is approximated as words/0.75; 100 tokens ≈ 75 words
  long_text="$(printf 'word%.0s ' {1..500})"
  result="$(echo "$long_text" | ccm_truncate_to_tokens 100)"
  word_count="$(echo "$result" | wc -w | tr -d ' ')"
  [ "$word_count" -le 80 ]
}
