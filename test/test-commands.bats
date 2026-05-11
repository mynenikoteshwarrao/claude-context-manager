#!/usr/bin/env bats
load 'helpers.bash'

@test "commands: all 6 slash command files exist" {
  for name in load save history show prune update; do
    [ -f "$CCM_REPO_ROOT/commands/ccm/$name.md" ]
  done
}

@test "commands: each file has frontmatter description and !ccm line" {
  for name in load save history show prune update; do
    f="$CCM_REPO_ROOT/commands/ccm/$name.md"
    grep -q "^description:" "$f"
    grep -q "^!ccm " "$f"
  done
}
