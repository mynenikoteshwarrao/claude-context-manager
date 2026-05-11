#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "update.sh"
}
teardown() { ccm_teardown_tmphome; }

@test "update: detects git-clone install when .git exists at root" {
  result="$(ccm_detect_install_channel "$CCM_REPO_ROOT")"
  [ "$result" = "clone" ]
}

@test "update: detects tarball install when no .git at root" {
  tdir="$CCM_TMPHOME/tarball-install"
  mkdir -p "$tdir/bin"
  echo "0.1.0" > "$tdir/VERSION"
  touch "$tdir/bin/ccm"
  result="$(ccm_detect_install_channel "$tdir")"
  [ "$result" = "tarball" ]
}

@test "update: --check exits 0 when local equals remote" {
  # Stub gh API to return same version
  ccm_stub_remote_version "$(cat "$CCM_REPO_ROOT/VERSION")"
  run ccm_update_main --check --root "$CCM_REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "update: --check reports newer version when remote is ahead" {
  ccm_stub_remote_version "99.0.0"
  run ccm_update_main --check --root "$CCM_REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"99.0.0"* ]]
}
