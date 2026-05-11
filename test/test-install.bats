#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  # Provide a fake claude on PATH so preflight passes.
  ccm_stub_claude "ok"
}
teardown() { ccm_teardown_tmphome; }

@test "install: creates symlinks under ~/.local/bin and ~/.claude/commands" {
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  [ -e "$HOME/.local/bin/ccm" ]
  [ -e "$HOME/.claude/commands/ccm" ]
}

@test "install: writes hook entries into ~/.claude/settings.json" {
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/settings.json" ]
  jq -e '.hooks.SessionStart' "$HOME/.claude/settings.json" >/dev/null
  jq -e '.hooks.SessionEnd'   "$HOME/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreCompact'   "$HOME/.claude/settings.json" >/dev/null
}

@test "install: preserves unrelated keys in existing settings.json" {
  cp "$CCM_REPO_ROOT/test/fixtures/settings/existing.json" "$HOME/.claude/settings.json"
  run bash "$CCM_REPO_ROOT/install.sh" --quiet --force
  [ "$status" -eq 0 ]
  # theme key must survive
  theme="$(jq -r '.theme' "$HOME/.claude/settings.json")"
  [ "$theme" = "dark" ]
  # original UserPromptSubmit hook must survive
  count="$(jq -r '.hooks.UserPromptSubmit | length' "$HOME/.claude/settings.json")"
  [ "$count" -ge 1 ]
}

@test "install: rerunning is idempotent" {
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  # Hook count for SessionStart should still be 1
  count="$(jq -r '.hooks.SessionStart | length' "$HOME/.claude/settings.json")"
  [ "$count" -eq 1 ]
}
