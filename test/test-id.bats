#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
}
teardown() { ccm_teardown_tmphome; }

@test "id: git remote URL becomes the project ID" {
  mkdir -p "$CCM_TMPHOME/repo"
  cd "$CCM_TMPHOME/repo"
  git init -q
  git remote add origin "https://github.com/example/foo.git"
  result="$(ccm_resolve_project_id)"
  # URL-encoded
  [[ "$result" == *"github.com"* ]]
  [[ "$result" == *"example"* ]]
  [[ "$result" == *"foo"* ]]
}

@test "id: no git → SHA1 of cwd" {
  mkdir -p "$CCM_TMPHOME/nogit"
  cd "$CCM_TMPHOME/nogit"
  result="$(ccm_resolve_project_id)"
  [[ "$result" =~ ^[a-f0-9]{40}$ ]]
}

@test "id: git but no remote → SHA1 of cwd" {
  mkdir -p "$CCM_TMPHOME/noremote"
  cd "$CCM_TMPHOME/noremote"
  git init -q
  result="$(ccm_resolve_project_id)"
  [[ "$result" =~ ^[a-f0-9]{40}$ ]]
}
