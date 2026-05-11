#!/usr/bin/env bats
load 'helpers.bash'

@test "smoke: helpers.bash loads and CCM_REPO_ROOT is set" {
  [ -n "$CCM_REPO_ROOT" ]
  [ -d "$CCM_REPO_ROOT" ]
}

@test "smoke: ccm_setup_tmphome creates isolated home" {
  ccm_setup_tmphome
  [ -d "$HOME/.claude" ]
  [ "$HOME" = "$CCM_TMPHOME" ]
  ccm_teardown_tmphome
  [ ! -d "$CCM_TMPHOME" ]
}
