#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  export CCM_ROOT="$CCM_REPO_ROOT"
  ccm_source_lib "flush.sh"
}
teardown() { ccm_teardown_tmphome; }

@test "flush: writes current.md, no timeline entry" {
  mkdir -p "$CCM_TMPHOME/project1"
  cd "$CCM_TMPHOME/project1"
  ccm_stub_claude "## IN_PROGRESS
Investigating cache invalidation in src/cache.ts"
  mkdir -p "$CCM_TMPHOME/t"
  cp "$CCM_REPO_ROOT/test/fixtures/transcripts/sample.jsonl" "$CCM_TMPHOME/t/t.jsonl"
  run ccm_flush_main "$CCM_TMPHOME/t/t.jsonl"
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  pdir="$HOME/.claude/context-manager/$pid"
  [ -f "$pdir/current.md" ]
  grep -q "cache invalidation" "$pdir/current.md"
  count="$(ls -1 "$pdir/timeline" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ]
}
