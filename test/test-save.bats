#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  # save.sh resolves CCM_ROOT for prompts; set it.
  export CCM_ROOT="$CCM_REPO_ROOT"
  ccm_source_lib "save.sh"
}
teardown() { ccm_teardown_tmphome; }

_mk_transcript() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cp "$CCM_REPO_ROOT/test/fixtures/transcripts/sample.jsonl" "$target"
}

@test "save: with stubbed claude writes a timeline file" {
  mkdir -p "$CCM_TMPHOME/project1"
  cd "$CCM_TMPHOME/project1"
  ccm_stub_claude "## SUMMARY
Worked on login flow. Decided JWT with refresh tokens.

## IN_PROGRESS
Implementing token endpoint in src/auth.ts."
  _mk_transcript "$CCM_TMPHOME/transcript.jsonl"
  run ccm_save_main "$CCM_TMPHOME/transcript.jsonl"
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  pdir="$HOME/.claude/context-manager/$pid"
  [ -d "$pdir/timeline" ]
  count="$(ls -1 "$pdir/timeline" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "save: writes current.md with IN_PROGRESS section" {
  mkdir -p "$CCM_TMPHOME/project2"
  cd "$CCM_TMPHOME/project2"
  ccm_stub_claude "## SUMMARY
Test summary text.

## IN_PROGRESS
Mid-edit on src/login.ts; debugging refresh token race."
  _mk_transcript "$CCM_TMPHOME/t.jsonl"
  run ccm_save_main "$CCM_TMPHOME/t.jsonl"
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  current="$HOME/.claude/context-manager/$pid/current.md"
  [ -f "$current" ]
  grep -q "refresh token race" "$current"
}

@test "save: appends to transcripts.jsonl with ts + paths" {
  mkdir -p "$CCM_TMPHOME/project3"
  cd "$CCM_TMPHOME/project3"
  ccm_stub_claude "## SUMMARY
ok

## IN_PROGRESS
none"
  _mk_transcript "$CCM_TMPHOME/t.jsonl"
  run ccm_save_main "$CCM_TMPHOME/t.jsonl"
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  log="$HOME/.claude/context-manager/$pid/transcripts.jsonl"
  [ -f "$log" ]
  line="$(cat "$log")"
  echo "$line" | jq -e '.ts and .transcript and .summary' >/dev/null
}

@test "save: missing claude → stub timeline entry with transcript head/tail" {
  mkdir -p "$CCM_TMPHOME/project4"
  cd "$CCM_TMPHOME/project4"
  # Don't stub claude; PATH won't find it.
  export PATH="$CCM_TMPHOME/no-claude:$PATH"
  mkdir -p "$CCM_TMPHOME/no-claude"
  _mk_transcript "$CCM_TMPHOME/t.jsonl"
  run ccm_save_main "$CCM_TMPHOME/t.jsonl"
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  count="$(ls -1 "$HOME/.claude/context-manager/$pid/timeline" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}
