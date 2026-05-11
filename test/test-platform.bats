#!/usr/bin/env bats
load 'helpers.bash'

setup() { ccm_setup_tmphome; }
teardown() { ccm_teardown_tmphome; }

@test "platform: CCM_OS is macos or windows or linux" {
  ccm_source_lib "platform.sh"
  [[ "$CCM_OS" =~ ^(macos|windows|linux)$ ]]
}

@test "platform: ccm_sha1 hashes stdin to 40 hex chars" {
  ccm_source_lib "platform.sh"
  result="$(printf '%s' "hello" | ccm_sha1)"
  [[ "$result" =~ ^[a-f0-9]{40}$ ]]
}

@test "platform: ccm_sha1 of 'hello' is aaf4c61d..." {
  ccm_source_lib "platform.sh"
  result="$(printf '%s' "hello" | ccm_sha1)"
  [ "$result" = "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d" ]
}

@test "platform: ccm_path_posix is identity on macos" {
  ccm_source_lib "platform.sh"
  if [ "$CCM_OS" = "macos" ]; then
    result="$(ccm_path_posix /Users/foo/bar)"
    [ "$result" = "/Users/foo/bar" ]
  else
    skip "macos-only check"
  fi
}

@test "platform: ccm_symlink creates a working link" {
  ccm_source_lib "platform.sh"
  src="$CCM_TMPHOME/src"
  dst="$CCM_TMPHOME/dst"
  echo "hello" > "$src"
  ccm_symlink "$src" "$dst"
  [ -e "$dst" ]
  [ "$(cat "$dst")" = "hello" ]
}

@test "platform: ccm_log appends to log file" {
  mkdir -p "$HOME/.claude/context-manager"
  ccm_source_lib "platform.sh"
  ccm_log "test message"
  grep -q "test message" "$HOME/.claude/context-manager/log"
}
