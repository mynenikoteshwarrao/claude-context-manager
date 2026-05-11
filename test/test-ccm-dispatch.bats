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
