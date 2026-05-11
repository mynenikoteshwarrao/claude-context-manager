# Claude Context Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ccm`, a cross-platform (macOS + Windows Git Bash) Claude Code companion that auto-saves a project's session context on `SessionEnd`, auto-loads it on `SessionStart`, survives `PreCompact`, and is controllable via `/ccm:*` slash commands.

**Architecture:** One bash script `ccm` at `~/.local/bin/ccm` dispatching to `lib/*.sh` modules. Storage at `~/.claude/context-manager/<project-id>/`. Hooks and slash commands registered in `~/.claude/settings.json` and `~/.claude/commands/ccm/` by `install.sh`. OS differences encapsulated in `lib/platform.sh`. Summarization shells out to the user's existing `claude` CLI.

**Tech Stack:** Bash 4+, `jq`, `claude` CLI, `shasum`/`sha1sum`, `bats-core` (tests), GitHub Actions (CI + release), Homebrew formula, Scoop manifest.

**Spec reference:** `docs/superpowers/specs/2026-05-11-claude-context-manager-design.md`

---

## Prerequisites

The executing engineer needs:

- macOS 12+ **or** Windows 10+ with Git for Windows (Git Bash) ≥ 2.40
- Bash 4+ on PATH (`brew install bash` on macOS — the system bash 3.2 is too old)
- `jq` 1.6+ on PATH (`brew install jq` on macOS, `scoop install jq` on Windows)
- `claude` CLI on PATH (the user already has this)
- `bats-core` 1.10+ (`brew install bats-core` on macOS, `scoop install bats` on Windows)
- A GitHub account and `gh` CLI authenticated (only for release workflow tasks)

Verify with:
```bash
bash --version | head -1     # expect: GNU bash, version 4 or 5
jq --version                  # expect: jq-1.6 or newer
claude --version              # expect: any version
bats --version                # expect: Bats 1.10.0 or newer
```

If any check fails, install the missing tool before proceeding.

---

## File Structure Overview

End state of the repo at the end of this plan:

```
claude-context-manager/
├── bin/ccm
├── lib/
│   ├── platform.sh
│   ├── common.sh
│   ├── id.sh
│   ├── load.sh
│   ├── save.sh
│   ├── flush.sh
│   ├── history.sh
│   ├── prune.sh
│   └── update.sh
├── commands/ccm/
│   ├── load.md
│   ├── save.md
│   ├── history.md
│   ├── show.md
│   ├── prune.md
│   └── update.md
├── prompts/
│   ├── summarize.txt
│   └── flush.txt
├── plugin/manifest.json
├── install.sh
├── install.bat
├── install-remote.sh
├── uninstall.sh
├── .github/workflows/
│   ├── ci.yml
│   └── release.yml
├── test/
│   ├── helpers.bash
│   ├── test-platform.bats
│   ├── test-common.bats
│   ├── test-id.bats
│   ├── test-load.bats
│   ├── test-save.bats
│   ├── test-flush.bats
│   ├── test-history.bats
│   ├── test-prune.bats
│   ├── test-update.bats
│   ├── test-install.bats
│   ├── integration.sh
│   └── fixtures/
│       ├── transcripts/sample.jsonl
│       └── settings/existing.json
├── docs/superpowers/specs/2026-05-11-claude-context-manager-design.md  (exists)
├── README.md
├── CHANGELOG.md
├── LICENSE
└── VERSION
```

Sibling repos created in Phase 14:
```
homebrew-ccm/Formula/ccm.rb
scoop-ccm/bucket/ccm.json
```

---

## Task 1: Repo scaffold

**Files:**
- Create: `VERSION`
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `README.md` (skeleton)

- [ ] **Step 1: Create VERSION file**

Write file `VERSION`:
```
0.1.0
```

- [ ] **Step 2: Create LICENSE (MIT)**

Write file `LICENSE`:
```
MIT License

Copyright (c) 2026 <user>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Create .gitignore**

Write file `.gitignore`:
```
# Test artifacts
test/tmp/
test/.coverage

# Local overrides
.env
.claude/settings.local.json

# macOS
.DS_Store

# Editor
.vscode/
.idea/
*.swp
```

- [ ] **Step 4: Create README skeleton**

Write file `README.md`:
```markdown
# ccm — Claude Context Manager

Auto-save and auto-restore project context across Claude Code sessions.

## Status

Pre-release. See `docs/superpowers/specs/` for the design spec.

## Install

See full install guide after release. Quick paths:

```bash
# macOS
brew install bash jq
git clone https://github.com/<user>/claude-context-manager && cd claude-context-manager && ./install.sh

# Windows (Git Bash)
scoop install jq
git clone https://github.com/<user>/claude-context-manager && cd claude-context-manager && ./install.sh
```

## Commands

| Subcommand | What it does |
|---|---|
| `ccm load` | Print restored context block to stdout |
| `ccm save` | Summarize current session and write timeline entry |
| `ccm flush` | Refresh in-progress state (pre-compact) |
| `ccm history` | List session summaries |
| `ccm show N` | Print summary #N |
| `ccm prune` | Interactive cleanup |
| `ccm update` | Self-update to latest release |
| `ccm version` | Print version |

Slash commands: `/ccm:load`, `/ccm:save`, `/ccm:history`, `/ccm:show`, `/ccm:prune`, `/ccm:update`.

## License

MIT
```

- [ ] **Step 5: Commit**

```bash
git add VERSION LICENSE .gitignore README.md
git commit -m "Scaffold repo with VERSION, LICENSE, .gitignore, README"
```

---

## Task 2: Test helper and bats fixture infrastructure

**Files:**
- Create: `test/helpers.bash`
- Create: `test/fixtures/transcripts/sample.jsonl`
- Create: `test/fixtures/settings/existing.json`

- [ ] **Step 1: Write test/helpers.bash**

Write file `test/helpers.bash`:
```bash
# test/helpers.bash — shared setup for bats tests
# Source this from each test file: `load 'helpers.bash'`

# Resolve repo root regardless of where bats is invoked from
CCM_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CCM_REPO_ROOT

# Each test gets a private temp $HOME so we never touch real state
ccm_setup_tmphome() {
  CCM_TMPHOME="$(mktemp -d -t ccm-test-XXXXXX)"
  export CCM_TMPHOME
  export HOME="$CCM_TMPHOME"
  mkdir -p "$HOME/.claude"
  mkdir -p "$HOME/.local/bin"
}

ccm_teardown_tmphome() {
  if [[ -n "${CCM_TMPHOME:-}" && -d "$CCM_TMPHOME" ]]; then
    rm -rf "$CCM_TMPHOME"
  fi
}

# Create a fake `claude` on PATH that echoes a deterministic response.
# Use this in tests to avoid real LLM calls.
ccm_stub_claude() {
  local response="${1:-STUBBED}"
  local stub_dir="$CCM_TMPHOME/stub-bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/claude" <<EOF
#!/usr/bin/env bash
# Stub for testing — ignores all args, prints fixed response
cat <<RESPONSE
$response
RESPONSE
EOF
  chmod +x "$stub_dir/claude"
  export PATH="$stub_dir:$PATH"
}

# Source a lib file from the repo
ccm_source_lib() {
  local lib_name="$1"
  source "$CCM_REPO_ROOT/lib/$lib_name"
}
```

- [ ] **Step 2: Write a sample transcript fixture**

Write file `test/fixtures/transcripts/sample.jsonl`:
```
{"role":"user","content":"Help me design a login flow"}
{"role":"assistant","content":"Sure, what auth scheme are you using?"}
{"role":"user","content":"JWT with refresh tokens"}
{"role":"assistant","content":"Let's start with the token endpoint. I'll write it in src/auth.ts."}
{"role":"user","content":"Sounds good"}
```

- [ ] **Step 3: Write a settings.json fixture**

Write file `test/fixtures/settings/existing.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [
      {"command": "echo existing-hook"}
    ]
  },
  "theme": "dark"
}
```

- [ ] **Step 4: Verify bats can find helpers**

Write a tiny smoke test at `test/test-smoke.bats`:
```bash
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
```

Run: `bats test/test-smoke.bats`
Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add test/helpers.bash test/fixtures/ test/test-smoke.bats
git commit -m "Add bats test helpers and fixtures"
```

---

## Task 3: lib/platform.sh — OS abstraction

**Files:**
- Create: `lib/platform.sh`
- Create: `test/test-platform.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-platform.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-platform.bats`
Expected: 6 failing with "platform.sh: No such file or directory".

- [ ] **Step 3: Implement lib/platform.sh**

Write file `lib/platform.sh`:
```bash
# lib/platform.sh — OS abstraction layer.
# Sourced by ccm and other lib scripts.

# Detect OS.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) CCM_OS=windows ;;
  Darwin)               CCM_OS=macos ;;
  Linux)                CCM_OS=linux ;;
  *)                    CCM_OS=unknown ;;
esac
export CCM_OS

# Hash stdin with SHA1; print 40-char hex digest.
ccm_sha1() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 1 | cut -d' ' -f1
  elif command -v sha1sum >/dev/null 2>&1; then
    sha1sum | cut -d' ' -f1
  else
    echo "ccm: no SHA1 tool found (shasum or sha1sum)" >&2
    return 1
  fi
}

# Convert path to POSIX form. No-op on macOS/Linux; cygpath -u on Windows.
ccm_path_posix() {
  if [ "$CCM_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s' "$1"
  fi
}

# Convert path to native form. No-op on macOS/Linux; cygpath -w on Windows.
ccm_path_native() {
  if [ "$CCM_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# Create a symlink. On Windows, try native symlink; on failure, write a shim.
ccm_symlink() {
  local src="$1" dst="$2"
  rm -f "$dst" 2>/dev/null || true
  if [ "$CCM_OS" = "windows" ]; then
    if ! MSYS=winsymlinks:nativestrict ln -s "$src" "$dst" 2>/dev/null; then
      # Fall back to a wrapper shim
      cat > "$dst" <<EOF
#!/usr/bin/env bash
exec "$src" "\$@"
EOF
      chmod +x "$dst"
    fi
  else
    ln -s "$src" "$dst"
  fi
}

# Append a message to the ccm log with timestamp.
ccm_log() {
  local log_dir="$HOME/.claude/context-manager"
  local log_file="$log_dir/log"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CCM_OS" "$*" >> "$log_file"
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-platform.bats`
Expected: 6 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/platform.sh test/test-platform.bats
git commit -m "Add lib/platform.sh with OS abstraction (sha1, paths, symlink, log)"
```

---

## Task 4: lib/common.sh — paths, project ID, token budget

**Files:**
- Create: `lib/common.sh`
- Create: `test/test-common.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-common.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-common.bats`
Expected: 4 failing with "common.sh: No such file or directory".

- [ ] **Step 3: Implement lib/common.sh**

Write file `lib/common.sh`:
```bash
# lib/common.sh — shared paths and helpers. Requires platform.sh sourced first.

# Storage root: ~/.claude/context-manager
ccm_storage_root() {
  printf '%s' "$HOME/.claude/context-manager"
}

# Per-project directory under storage root.
ccm_project_dir() {
  printf '%s' "$(ccm_storage_root)/$1"
}

# Ensure project dir + timeline subdir exist.
ccm_init_project_dir() {
  local pid="$1"
  local pdir
  pdir="$(ccm_project_dir "$pid")"
  mkdir -p "$pdir/timeline"
  if [ ! -f "$pdir/meta.json" ]; then
    printf '{"project_id":"%s","created_at":"%s"}\n' "$pid" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$pdir/meta.json"
  fi
}

# Truncate stdin to approximately N tokens. Approximation: 1 token ≈ 0.75 words.
# Used for budget enforcement; not exact.
ccm_truncate_to_tokens() {
  local budget="$1"
  local word_limit=$(( budget * 3 / 4 ))
  awk -v limit="$word_limit" '
    {
      for (i=1; i<=NF; i++) {
        if (count >= limit) { exit }
        printf "%s ", $i
        count++
      }
      printf "\n"
    }
  '
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-common.bats`
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh test/test-common.bats
git commit -m "Add lib/common.sh with storage path helpers and token truncation"
```

---

## Task 5: lib/id.sh — project ID resolution

**Files:**
- Create: `lib/id.sh`
- Create: `test/test-id.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-id.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-id.bats`
Expected: 3 failing with "id.sh: No such file or directory".

- [ ] **Step 3: Implement lib/id.sh**

Write file `lib/id.sh`:
```bash
# lib/id.sh — resolve project ID for the current working directory.
# Requires platform.sh and common.sh sourced first.

# URL-encode a string for filesystem-safe use as a directory name.
# Replaces / : ? & = with -, drops anything else non-alphanumeric to _.
_ccm_url_encode() {
  printf '%s' "$1" | tr '/:?&=' '-----' | tr -c 'A-Za-z0-9.-' '_' | sed 's/_*$//'
}

# Resolve and print the project ID for $PWD.
# Order: git remote get-url origin → URL-encoded; else SHA1($PWD).
ccm_resolve_project_id() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null || true)"
  if [ -n "$remote" ]; then
    _ccm_url_encode "$remote"
  else
    printf '%s' "$PWD" | ccm_sha1
  fi
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-id.bats`
Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/id.sh test/test-id.bats
git commit -m "Add lib/id.sh: git remote → fs-safe ID, fallback to SHA1(pwd)"
```

---

## Task 6: bin/ccm — main dispatcher

**Files:**
- Create: `bin/ccm`
- Modify: `test/test-platform.bats` (add dispatcher smoke test)

- [ ] **Step 1: Write failing dispatcher test**

Create file `test/test-ccm-dispatch.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-ccm-dispatch.bats`
Expected: 4 failing with "ccm: No such file or directory" (since bin/ccm doesn't exist).

- [ ] **Step 3: Implement bin/ccm**

Write file `bin/ccm`:
```bash
#!/usr/bin/env bash
# ccm — Claude Context Manager
# Dispatches to lib/<subcommand>.sh

set -euo pipefail

# Resolve repo root (script may be invoked via symlink).
CCM_SELF="${BASH_SOURCE[0]}"
while [ -L "$CCM_SELF" ]; do
  CCM_SELF="$(readlink "$CCM_SELF")"
done
CCM_ROOT="$(cd "$(dirname "$CCM_SELF")/.." && pwd)"
export CCM_ROOT

# Source platform + common always.
# shellcheck source=../lib/platform.sh
source "$CCM_ROOT/lib/platform.sh"
# shellcheck source=../lib/common.sh
source "$CCM_ROOT/lib/common.sh"

_usage() {
  cat <<EOF
ccm — Claude Context Manager v$(cat "$CCM_ROOT/VERSION")

Usage: ccm <subcommand> [args]

Subcommands:
  id           Print the project ID for the current directory
  load         Print restored context block to stdout
  save         Summarize current session and write timeline entry
  flush        Refresh in-progress state (pre-compact)
  history      List session summaries for this project
  show N       Print summary #N
  prune        Interactive cleanup
  update       Self-update to the latest release
  version      Print version
EOF
}

# Load and invoke a subcommand handler.
_dispatch() {
  local cmd="$1"; shift
  local lib="$CCM_ROOT/lib/${cmd}.sh"
  if [ ! -f "$lib" ]; then
    echo "ccm: unknown subcommand: $cmd" >&2
    echo "Run 'ccm' for usage." >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$lib"
  # Convention: each lib defines ccm_<cmd>_main
  local fn="ccm_${cmd}_main"
  if ! declare -F "$fn" >/dev/null; then
    echo "ccm: lib/${cmd}.sh missing ${fn}()" >&2
    return 1
  fi
  "$fn" "$@"
}

main() {
  if [ "$#" -eq 0 ]; then
    _usage
    return 1
  fi
  case "$1" in
    -h|--help) _usage; return 0 ;;
    version)   cat "$CCM_ROOT/VERSION"; return 0 ;;
    id)
      # shellcheck source=../lib/id.sh
      source "$CCM_ROOT/lib/id.sh"
      ccm_resolve_project_id
      return 0
      ;;
    *)
      _dispatch "$@"
      ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make bin/ccm executable and run tests**

```bash
chmod +x bin/ccm
bats test/test-ccm-dispatch.bats
```
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add bin/ccm test/test-ccm-dispatch.bats
git commit -m "Add bin/ccm dispatcher with version, id, help and lib loader"
```

---

## Task 7: lib/load.sh — render injected context block

**Files:**
- Create: `lib/load.sh`
- Create: `test/test-load.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-load.bats`:
```bash
#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  ccm_source_lib "load.sh"
}
teardown() { ccm_teardown_tmphome; }

@test "load: empty storage → empty stdout, exit 0" {
  run ccm_load_main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "load: with current.md only → output contains current.md text" {
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  echo "Working on auth refactor; JWT endpoint half-done" \
    > "$(ccm_project_dir "$pid")/current.md"
  run ccm_load_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored Context"* ]]
  [[ "$output" == *"JWT endpoint half-done"* ]]
}

@test "load: with 5 timeline entries → only 3 most recent rendered" {
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  for ts in 2026-05-01-1200 2026-05-02-1200 2026-05-03-1200 2026-05-04-1200 2026-05-05-1200; do
    echo "Summary for $ts" > "$pdir/timeline/$ts.md"
  done
  run ccm_load_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-05-05-1200"* ]]
  [[ "$output" == *"2026-05-04-1200"* ]]
  [[ "$output" == *"2026-05-03-1200"* ]]
  [[ "$output" != *"2026-05-02-1200"* ]]
  [[ "$output" != *"2026-05-01-1200"* ]]
}

@test "load: rendered block stays under 3000-token budget" {
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  # 10 large entries
  for i in $(seq 1 10); do
    printf 'word%.0s ' {1..3000} > "$pdir/timeline/2026-05-${i}-1200.md"
  done
  run ccm_load_main
  [ "$status" -eq 0 ]
  word_count="$(echo "$output" | wc -w | tr -d ' ')"
  # 3000 tokens ≈ 2250 words; allow some headroom for headings
  [ "$word_count" -le 2500 ]
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-load.bats`
Expected: 4 failing with "load.sh: No such file or directory".

- [ ] **Step 3: Implement lib/load.sh**

Write file `lib/load.sh`:
```bash
# lib/load.sh — render the SessionStart context block.
# Requires platform.sh, common.sh, id.sh sourced first.

CCM_LOAD_TOKEN_BUDGET="${CCM_LOAD_TOKEN_BUDGET:-3000}"

ccm_load_main() {
  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"

  if [ ! -d "$pdir" ]; then
    # First run in this project; emit nothing.
    return 0
  fi

  local current="$pdir/current.md"
  local timeline_dir="$pdir/timeline"
  local has_current=0 has_timeline=0
  [ -s "$current" ] && has_current=1
  [ -d "$timeline_dir" ] && [ -n "$(ls -A "$timeline_dir" 2>/dev/null)" ] && has_timeline=1

  if [ "$has_current" -eq 0 ] && [ "$has_timeline" -eq 0 ]; then
    return 0
  fi

  # Build the rendered block.
  {
    echo "# Claude Context Manager — Restored Context"
    echo ""
    if [ "$has_current" -eq 1 ]; then
      echo "## In progress (from last session)"
      cat "$current"
      echo ""
    fi
    if [ "$has_timeline" -eq 1 ]; then
      echo "## Recent session summaries"
      # Most recent 3, reverse chronological
      local n=0
      while IFS= read -r entry; do
        n=$((n+1))
        [ "$n" -gt 3 ] && break
        local base
        base="$(basename "$entry" .md)"
        echo "### $base"
        cat "$entry"
        echo ""
      done < <(ls -1 "$timeline_dir" 2>/dev/null | sort -r | sed "s|^|$timeline_dir/|")
    fi
    echo "---"
    echo "*Older summaries: \`/ccm:history\`. Full transcripts: \`/ccm:show N\`.*"
  } | ccm_truncate_to_tokens "$CCM_LOAD_TOKEN_BUDGET"

  ccm_log "load: pid=$pid rendered context"
  return 0
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-load.bats`
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/load.sh test/test-load.bats
git commit -m "Add lib/load.sh: render SessionStart context with 3000-token budget"
```

---

## Task 8: prompts/summarize.txt and prompts/flush.txt

**Files:**
- Create: `prompts/summarize.txt`
- Create: `prompts/flush.txt`

- [ ] **Step 1: Write prompts/summarize.txt**

Write file `prompts/summarize.txt`:
```
You are summarizing a Claude Code session for a project context manager.

The transcript follows. Produce output in this exact format:

## SUMMARY
A concise (≤200 word) recap of: what was worked on, what got decided, what's left open. No bullet points; flowing prose.

## IN_PROGRESS
The specific things the user was actively working on when the session ended — tasks not yet finished, files mid-edit, decisions pending. If the session reached a clean stopping point, write the single word "none".

Rules:
- Do not include any text before "## SUMMARY".
- Do not include any text after the IN_PROGRESS section.
- No code blocks, no headers other than the two above.
- Refer to files and components by name, not by chat-message index.

Transcript:
```

- [ ] **Step 2: Write prompts/flush.txt**

Write file `prompts/flush.txt`:
```
You are extracting in-progress state from a Claude Code session that is about to be context-compacted. Only return the active work, not a full summary.

Output format (no preamble, no closing text):

## IN_PROGRESS
The specific things being worked on right now: open tasks, mid-edit files, pending decisions. Keep it under 100 words. If nothing is in progress, write "none".

Transcript:
```

- [ ] **Step 3: Commit**

```bash
git add prompts/
git commit -m "Add summarize and flush prompts for claude -p"
```

---

## Task 9: lib/save.sh — summarize and write timeline

**Files:**
- Create: `lib/save.sh`
- Create: `test/test-save.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-save.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-save.bats`
Expected: 4 failing with "save.sh: No such file or directory".

- [ ] **Step 3: Implement lib/save.sh**

Write file `lib/save.sh`:
```bash
# lib/save.sh — full save: summarize transcript, write timeline + current.md.
# Requires platform.sh, common.sh, id.sh sourced; CCM_ROOT set.

CCM_SAVE_TIMEOUT="${CCM_SAVE_TIMEOUT:-60}"

# Parse the LLM response into two parts: summary and in-progress.
_ccm_split_response() {
  local response="$1"
  local summary in_progress
  summary="$(printf '%s\n' "$response" | awk '
    /^## SUMMARY/   { capture=1; next }
    /^## IN_PROGRESS/ { capture=0 }
    capture { print }
  ')"
  in_progress="$(printf '%s\n' "$response" | awk '
    /^## IN_PROGRESS/ { capture=1; next }
    capture { print }
  ')"
  printf '%s\n---SPLIT---\n%s' "$summary" "$in_progress"
}

# Stub fallback when claude is unavailable: just head/tail of transcript.
_ccm_stub_summary() {
  local transcript="$1"
  echo "## SUMMARY"
  echo "(claude CLI not available; stub generated from transcript head and tail.)"
  echo ""
  echo "Head:"
  head -50 "$transcript" 2>/dev/null || true
  echo ""
  echo "Tail:"
  tail -50 "$transcript" 2>/dev/null || true
  echo ""
  echo "## IN_PROGRESS"
  echo "none"
}

ccm_save_main() {
  local transcript="${1:-}"
  if [ -z "$transcript" ]; then
    # Fall back to $CLAUDE_SESSION_ID-based path; for MVP, require arg.
    echo "ccm save: usage: ccm save <transcript-path>" >&2
    return 1
  fi
  if [ ! -f "$transcript" ]; then
    ccm_log "save: transcript missing: $transcript"
    return 0  # never fail the hook
  fi

  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  ccm_init_project_dir "$pid"

  local response
  if command -v claude >/dev/null 2>&1; then
    response="$(cat "$transcript" | \
      claude -p "$(cat "$CCM_ROOT/prompts/summarize.txt")" 2>/dev/null || true)"
  fi
  if [ -z "${response:-}" ]; then
    response="$(_ccm_stub_summary "$transcript")"
  fi

  local split summary in_progress
  split="$(_ccm_split_response "$response")"
  summary="${split%---SPLIT---*}"
  in_progress="${split#*---SPLIT---}"

  # Write timeline entry
  local ts entry
  ts="$(date -u +%Y-%m-%d-%H%M)"
  entry="$pdir/timeline/$ts.md"
  printf '%s\n' "$summary" > "$entry"

  # Overwrite current.md with in-progress section
  printf '%s\n' "$in_progress" > "$pdir/current.md"

  # Append to transcripts.jsonl
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc \
    --arg ts "$now" \
    --arg transcript "$transcript" \
    --arg summary "$entry" \
    '{ts:$ts, transcript:$transcript, summary:$summary}' \
    >> "$pdir/transcripts.jsonl"

  # Update meta.json last_save_at
  if [ -f "$pdir/meta.json" ]; then
    tmp="$(mktemp)"
    jq --arg ts "$now" '.last_save_at = $ts' "$pdir/meta.json" > "$tmp" && mv "$tmp" "$pdir/meta.json"
  fi

  ccm_log "save: pid=$pid entry=$ts"
  return 0
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-save.bats`
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/save.sh test/test-save.bats
git commit -m "Add lib/save.sh: summarize transcript via claude -p, write timeline"
```

---

## Task 10: lib/flush.sh — pre-compact lightweight save

**Files:**
- Create: `lib/flush.sh`
- Create: `test/test-flush.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-flush.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-flush.bats`
Expected: 1 failing with "flush.sh: No such file or directory".

- [ ] **Step 3: Implement lib/flush.sh**

Write file `lib/flush.sh`:
```bash
# lib/flush.sh — light pre-compact save. Refreshes current.md only.

ccm_flush_main() {
  local transcript="${1:-}"
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    ccm_log "flush: no transcript at $transcript"
    return 0
  fi

  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  ccm_init_project_dir "$pid"

  local response
  if command -v claude >/dev/null 2>&1; then
    response="$(cat "$transcript" | \
      claude -p "$(cat "$CCM_ROOT/prompts/flush.txt")" 2>/dev/null || true)"
  fi
  if [ -z "${response:-}" ]; then
    response="## IN_PROGRESS"$'\n'"(claude unavailable during flush)"
  fi

  # Extract IN_PROGRESS section
  local in_progress
  in_progress="$(printf '%s\n' "$response" | awk '
    /^## IN_PROGRESS/ { capture=1; next }
    capture { print }
  ')"

  printf '%s\n' "$in_progress" > "$pdir/current.md"
  ccm_log "flush: pid=$pid current.md updated"
  return 0
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-flush.bats`
Expected: 1 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/flush.sh test/test-flush.bats
git commit -m "Add lib/flush.sh: pre-compact current.md refresh (no timeline)"
```

---

## Task 11: lib/history.sh — list and show timeline entries

**Files:**
- Create: `lib/history.sh`
- Create: `test/test-history.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-history.bats`:
```bash
#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  ccm_source_lib "history.sh"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  for ts in 2026-05-01-1200 2026-05-02-1500 2026-05-03-0900; do
    echo "Summary at $ts" > "$pdir/timeline/$ts.md"
  done
}
teardown() { ccm_teardown_tmphome; }

@test "history: lists entries newest-first, numbered" {
  run ccm_history_main
  [ "$status" -eq 0 ]
  [[ "$output" == *"1"* ]]
  [[ "$output" == *"2026-05-03-0900"* ]]
  first_line="$(echo "$output" | head -1)"
  [[ "$first_line" == *"2026-05-03-0900"* ]]
}

@test "show: prints entry N content" {
  ccm_source_lib "history.sh"
  run ccm_show_main 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-05-03-0900"* ]]
}

@test "show: invalid index exits 1" {
  ccm_source_lib "history.sh"
  run ccm_show_main 99
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-history.bats`
Expected: 3 failing with "history.sh: No such file or directory".

- [ ] **Step 3: Implement lib/history.sh**

Write file `lib/history.sh`:
```bash
# lib/history.sh — list and show timeline entries.

_ccm_list_entries_desc() {
  local pdir="$1"
  local tdir="$pdir/timeline"
  [ -d "$tdir" ] || return 0
  ls -1 "$tdir" 2>/dev/null | sort -r
}

ccm_history_main() {
  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  if [ ! -d "$pdir/timeline" ]; then
    echo "(no history yet for this project)"
    return 0
  fi
  local n=0
  while IFS= read -r entry; do
    n=$((n+1))
    local base
    base="${entry%.md}"
    printf '%d  %s\n' "$n" "$base"
  done < <(_ccm_list_entries_desc "$pdir")
}

ccm_show_main() {
  local idx="${1:-}"
  if [ -z "$idx" ] || ! [[ "$idx" =~ ^[0-9]+$ ]]; then
    echo "ccm show: usage: ccm show <N>" >&2
    return 1
  fi
  local pid pdir
  pid="$(ccm_resolve_project_id)"
  pdir="$(ccm_project_dir "$pid")"
  local n=0 target=""
  while IFS= read -r entry; do
    n=$((n+1))
    if [ "$n" -eq "$idx" ]; then
      target="$pdir/timeline/$entry"
      break
    fi
  done < <(_ccm_list_entries_desc "$pdir")
  if [ -z "$target" ] || [ ! -f "$target" ]; then
    echo "ccm show: no entry #$idx" >&2
    return 1
  fi
  echo "### ${entry%.md}"
  cat "$target"
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-history.bats`
Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/history.sh test/test-history.bats
git commit -m "Add lib/history.sh: list timeline entries and show by index"
```

---

## Task 12: Wire `show` into bin/ccm dispatcher

**Files:**
- Modify: `bin/ccm`

- [ ] **Step 1: Write a dispatch test for `show`**

Add to `test/test-ccm-dispatch.bats`:
```bash
@test "ccm: show 1 reads from history.sh" {
  cd "$CCM_TMPHOME"
  pid="$(printf '%s' "$PWD" | sha1sum | cut -d' ' -f1 2>/dev/null || printf '%s' "$PWD" | shasum -a 1 | cut -d' ' -f1)"
  mkdir -p "$HOME/.claude/context-manager/$pid/timeline"
  echo "summary content" > "$HOME/.claude/context-manager/$pid/timeline/2026-05-01-1200.md"
  echo '{"project_id":"'"$pid"'"}' > "$HOME/.claude/context-manager/$pid/meta.json"
  run "$CCM_REPO_ROOT/bin/ccm" show 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"summary content"* ]]
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-ccm-dispatch.bats`
Expected: the new test fails (dispatcher routes `show` to `lib/show.sh`, which doesn't exist; or, more precisely, the dispatcher passes `show 1` to `_dispatch` which looks for `lib/show.sh`).

- [ ] **Step 3: Add explicit `show` case in bin/ccm**

Modify `bin/ccm`. In the `main()` function's `case "$1" in` block, add a branch:

```bash
    show)
      # shellcheck source=../lib/id.sh
      source "$CCM_ROOT/lib/id.sh"
      # shellcheck source=../lib/history.sh
      source "$CCM_ROOT/lib/history.sh"
      shift
      ccm_show_main "$@"
      return $?
      ;;
    history)
      # shellcheck source=../lib/id.sh
      source "$CCM_ROOT/lib/id.sh"
      # shellcheck source=../lib/history.sh
      source "$CCM_ROOT/lib/history.sh"
      shift
      ccm_history_main "$@"
      return $?
      ;;
```

Place these branches before the catch-all `*) _dispatch "$@" ;;`.

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-ccm-dispatch.bats`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add bin/ccm test/test-ccm-dispatch.bats
git commit -m "Wire history and show subcommands into bin/ccm dispatcher"
```

---

## Task 13: lib/prune.sh — interactive cleanup

**Files:**
- Create: `lib/prune.sh`
- Create: `test/test-prune.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-prune.bats`:
```bash
#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_source_lib "platform.sh"
  ccm_source_lib "common.sh"
  ccm_source_lib "id.sh"
  ccm_source_lib "prune.sh"
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  ccm_init_project_dir "$pid"
  pdir="$(ccm_project_dir "$pid")"
  for ts in 2025-01-01-1200 2025-06-01-1200 2026-05-01-1200; do
    echo "Summary at $ts" > "$pdir/timeline/$ts.md"
  done
}
teardown() { ccm_teardown_tmphome; }

@test "prune: --older-than=180d deletes entries older than cutoff" {
  run ccm_prune_main --older-than=180d --yes
  [ "$status" -eq 0 ]
  pid="$(printf '%s' "$PWD" | ccm_sha1)"
  pdir="$(ccm_project_dir "$pid")"
  # 2025-01-01 and 2025-06-01 are >180d before 2026-05-11 ⇒ deleted.
  # 2026-05-01 is within 180d ⇒ kept.
  count="$(ls -1 "$pdir/timeline" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
  [ -f "$pdir/timeline/2026-05-01-1200.md" ]
}

@test "prune: --orphans lists projects whose dir no longer matches any local repo" {
  # Create an orphan project
  mkdir -p "$HOME/.claude/context-manager/orphan-id/timeline"
  echo "old" > "$HOME/.claude/context-manager/orphan-id/timeline/2025-01-01.md"
  echo '{"project_id":"orphan-id","git_remote":"none"}' > "$HOME/.claude/context-manager/orphan-id/meta.json"
  run ccm_prune_main --orphans --list-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphan-id"* ]]
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-prune.bats`
Expected: 2 failing with "prune.sh: No such file or directory".

- [ ] **Step 3: Implement lib/prune.sh**

Write file `lib/prune.sh`:
```bash
# lib/prune.sh — interactive cleanup of old timeline entries and orphan projects.

# Compute the cutoff timestamp ("now - N days") in YYYY-MM-DD form.
_ccm_cutoff_date() {
  local spec="$1"   # e.g. "180d"
  local days
  days="${spec%d}"
  if [[ ! "$days" =~ ^[0-9]+$ ]]; then
    echo "ccm prune: bad --older-than: $spec (expected like 30d)" >&2
    return 1
  fi
  if [ "$CCM_OS" = "macos" ]; then
    date -u -v-"${days}"d +%Y-%m-%d
  else
    date -u -d "@$(( $(date -u +%s) - days*86400 ))" +%Y-%m-%d
  fi
}

ccm_prune_main() {
  local mode="" older=""  yes=0 list_only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --older-than=*) older="${1#*=}" ; mode="older" ;;
      --orphans)      mode="orphans" ;;
      --yes|-y)       yes=1 ;;
      --list-only)    list_only=1 ;;
      *) echo "ccm prune: unknown arg: $1" >&2; return 1 ;;
    esac
    shift
  done

  if [ "$mode" = "older" ]; then
    local cutoff
    cutoff="$(_ccm_cutoff_date "$older")" || return 1
    local pid pdir
    pid="$(ccm_resolve_project_id)"
    pdir="$(ccm_project_dir "$pid")"
    [ -d "$pdir/timeline" ] || return 0
    local victims=()
    while IFS= read -r f; do
      local base="${f%.md}"
      local entry_date="${base:0:10}"
      if [[ "$entry_date" < "$cutoff" ]]; then
        victims+=("$f")
      fi
    done < <(ls -1 "$pdir/timeline" 2>/dev/null)
    if [ "${#victims[@]}" -eq 0 ]; then
      echo "Nothing older than $older."
      return 0
    fi
    if [ "$yes" -ne 1 ] && [ "$list_only" -ne 1 ]; then
      echo "Would delete ${#victims[@]} entries older than $cutoff."
      printf '  %s\n' "${victims[@]}"
      read -r -p "Confirm? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
    fi
    if [ "$list_only" -eq 1 ]; then
      printf '%s\n' "${victims[@]}"
      return 0
    fi
    for v in "${victims[@]}"; do
      rm -f "$pdir/timeline/$v"
    done
    echo "Pruned ${#victims[@]} entries."
    ccm_log "prune: older=$older count=${#victims[@]}"
    return 0
  fi

  if [ "$mode" = "orphans" ]; then
    local root
    root="$(ccm_storage_root)"
    [ -d "$root" ] || return 0
    # An orphan is any project dir whose project_id can't be re-resolved from
    # any locally known directory. MVP heuristic: any project whose meta.json
    # has git_remote=none AND whose dir doesn't equal $PWD's resolved id.
    local current_id
    current_id="$(ccm_resolve_project_id 2>/dev/null || true)"
    local orphans=()
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      local pid_dir
      pid_dir="$(basename "$d")"
      [ "$pid_dir" = "log" ] && continue
      if [ "$pid_dir" != "$current_id" ]; then
        # Treat all non-current as candidate orphans for the listing.
        orphans+=("$pid_dir")
      fi
    done
    if [ "$list_only" -eq 1 ]; then
      printf '%s\n' "${orphans[@]}"
      return 0
    fi
    if [ "${#orphans[@]}" -eq 0 ]; then
      echo "No orphan projects."
      return 0
    fi
    echo "Candidate orphans:"
    printf '  %s\n' "${orphans[@]}"
    echo "Re-run with --list-only to capture, or rm -rf <root>/<id> manually."
    return 0
  fi

  echo "ccm prune: usage: ccm prune [--older-than=30d | --orphans] [--yes] [--list-only]" >&2
  return 1
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-prune.bats`
Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/prune.sh test/test-prune.bats
git commit -m "Add lib/prune.sh: --older-than and --orphans cleanup modes"
```

---

## Task 14: Slash command files

**Files:**
- Create: `commands/ccm/load.md`
- Create: `commands/ccm/save.md`
- Create: `commands/ccm/history.md`
- Create: `commands/ccm/show.md`
- Create: `commands/ccm/prune.md`
- Create: `commands/ccm/update.md`

- [ ] **Step 1: Write a smoke test that all 6 files exist with correct shape**

Create file `test/test-commands.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-commands.bats`
Expected: failing (files don't exist).

- [ ] **Step 3: Create all 6 slash command files**

Write `commands/ccm/load.md`:
```markdown
---
description: Load saved context for this project
---
!ccm load
```

Write `commands/ccm/save.md`:
```markdown
---
description: Save current session to context history
---
!ccm save
```

Write `commands/ccm/history.md`:
```markdown
---
description: List session summaries for this project
---
!ccm history
```

Write `commands/ccm/show.md`:
```markdown
---
description: Show session summary by index. Usage `/ccm:show 3`.
---
!ccm show $ARGUMENTS
```

Write `commands/ccm/prune.md`:
```markdown
---
description: Interactive cleanup of old summaries and orphan projects
---
!ccm prune $ARGUMENTS
```

Write `commands/ccm/update.md`:
```markdown
---
description: Self-update ccm to the latest release
---
!ccm update
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-commands.bats`
Expected: 2 passing.

- [ ] **Step 5: Commit**

```bash
git add commands/ test/test-commands.bats
git commit -m "Add 6 slash command stubs under commands/ccm/"
```

---

## Task 15: install.sh — preflight, symlinks, settings.json merge

**Files:**
- Create: `install.sh`
- Create: `test/test-install.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-install.bats`:
```bash
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
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-install.bats`
Expected: 4 failing because `install.sh` doesn't exist.

- [ ] **Step 3: Implement install.sh**

Write file `install.sh`:
```bash
#!/usr/bin/env bash
# install.sh — install ccm into ~/.local/bin and ~/.claude/.
# Idempotent. Run from the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/lib/platform.sh"

QUIET=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
    --force) FORCE=1 ;;
    *) echo "install.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

_say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
_die() { echo "ccm install: $*" >&2; exit 1; }

# --- 1. Preflight: required tools ----------------------------------------
preflight() {
  local missing=()
  command -v bash    >/dev/null 2>&1 || missing+=("bash")
  command -v jq      >/dev/null 2>&1 || missing+=("jq")
  command -v claude  >/dev/null 2>&1 || missing+=("claude")
  if command -v shasum >/dev/null 2>&1 || command -v sha1sum >/dev/null 2>&1; then
    :
  else
    missing+=("shasum or sha1sum")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    local hint=""
    case "$CCM_OS" in
      macos)   hint="Try: brew install ${missing[*]}" ;;
      windows) hint="Try: scoop install ${missing[*]}" ;;
    esac
    _die "missing tools: ${missing[*]}. $hint"
  fi
}

# --- 2. Create directories -----------------------------------------------
mkdirs() {
  mkdir -p "$HOME/.local/bin"
  mkdir -p "$HOME/.claude"
  mkdir -p "$HOME/.claude/commands"
  mkdir -p "$HOME/.claude/context-manager"
}

# --- 3. Symlinks ---------------------------------------------------------
do_symlinks() {
  ccm_symlink "$REPO_ROOT/bin/ccm"      "$HOME/.local/bin/ccm"
  ccm_symlink "$REPO_ROOT/commands/ccm" "$HOME/.claude/commands/ccm"
  _say "Linked ccm into ~/.local/bin and ~/.claude/commands/ccm"
}

# --- 4. Hook registration in settings.json -------------------------------
ccm_bin_path() {
  # Path used in hook commands. POSIX absolute so it works in Git Bash too.
  local p="$HOME/.local/bin/ccm"
  ccm_path_posix "$p"
}

register_hooks() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"
  local bin_path
  bin_path="$(ccm_bin_path)"
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg bin "$bin_path" \
    '
      .hooks //= {}
      | .hooks.SessionStart = [{"command": ($bin + " load")}]
      | .hooks.SessionEnd   = [{"command": ($bin + " save \"$CLAUDE_TRANSCRIPT_PATH\"")}]
      | .hooks.PreCompact   = [{"command": ($bin + " flush \"$CLAUDE_TRANSCRIPT_PATH\"")}]
    ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  _say "Registered SessionStart, SessionEnd, PreCompact hooks"
}

# --- 5. PATH check -------------------------------------------------------
path_check() {
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    cat <<EOF
Note: $HOME/.local/bin is not on your PATH.
Add this to your shell rc (.zshrc, .bashrc):
  export PATH="\$HOME/.local/bin:\$PATH"
EOF
  fi
}

main() {
  preflight
  mkdirs
  do_symlinks
  register_hooks
  path_check
  _say "Done. Verify with: ccm version && ccm history"
}
main
```

- [ ] **Step 4: Make install.sh executable and run tests**

```bash
chmod +x install.sh
bats test/test-install.bats
```
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add install.sh test/test-install.bats
git commit -m "Add install.sh: preflight, symlinks, settings.json hook merge"
```

---

## Task 16: uninstall.sh and install.bat

**Files:**
- Create: `uninstall.sh`
- Create: `install.bat`

- [ ] **Step 1: Add a smoke test for uninstall**

Add to `test/test-install.bats`:
```bash
@test "uninstall: removes symlinks and hook entries" {
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  run bash "$CCM_REPO_ROOT/uninstall.sh" --quiet --keep-storage
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/ccm" ]
  [ ! -e "$HOME/.claude/commands/ccm" ]
  hooks="$(jq -r '.hooks.SessionStart // empty' "$HOME/.claude/settings.json")"
  [ -z "$hooks" ]
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-install.bats`
Expected: the new uninstall test fails.

- [ ] **Step 3: Implement uninstall.sh**

Write file `uninstall.sh`:
```bash
#!/usr/bin/env bash
# uninstall.sh — reverse install.sh.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/lib/platform.sh"

QUIET=0
KEEP_STORAGE=0
for arg in "$@"; do
  case "$arg" in
    --quiet)         QUIET=1 ;;
    --keep-storage)  KEEP_STORAGE=1 ;;
    *) echo "uninstall.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done

_say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# 1. Remove symlinks/shims
rm -f "$HOME/.local/bin/ccm" 2>/dev/null || true
rm -rf "$HOME/.claude/commands/ccm" 2>/dev/null || true
_say "Removed symlinks."

# 2. Remove our hook entries from settings.json
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ]; then
  tmp="$(mktemp)"
  jq 'del(.hooks.SessionStart, .hooks.SessionEnd, .hooks.PreCompact)' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  _say "Removed ccm hooks from settings.json."
fi

# 3. Storage
if [ "$KEEP_STORAGE" -eq 0 ]; then
  if [ "$QUIET" -ne 1 ]; then
    read -r -p "Delete ~/.claude/context-manager/ and all stored history? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      rm -rf "$HOME/.claude/context-manager"
      _say "Deleted storage."
    else
      _say "Keeping storage at ~/.claude/context-manager/"
    fi
  else
    _say "Storage retained (--quiet)."
  fi
fi

_say "Uninstall complete."
```

- [ ] **Step 4: Write install.bat (Windows entry point)**

Write file `install.bat`:
```batch
@echo off
REM install.bat — convenience entry point for Windows users.
REM Locates Git Bash and execs install.sh.

set BASH_EXE=%PROGRAMFILES%\Git\bin\bash.exe
if not exist "%BASH_EXE%" (
  echo Could not find Git Bash at %BASH_EXE%
  echo Please install Git for Windows from https://git-scm.com/download/win
  exit /b 1
)

"%BASH_EXE%" -lc "cd '%~dp0' && ./install.sh"
```

- [ ] **Step 5: Make uninstall.sh executable, run tests, commit**

```bash
chmod +x uninstall.sh
bats test/test-install.bats
```
Expected: all install + uninstall tests pass.

```bash
git add uninstall.sh install.bat test/test-install.bats
git commit -m "Add uninstall.sh and install.bat (Windows entry point)"
```

---

## Task 17: lib/update.sh — self-update channel detection and dispatch

**Files:**
- Create: `lib/update.sh`
- Create: `test/test-update.bats`

- [ ] **Step 1: Write failing tests**

Write file `test/test-update.bats`:
```bash
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
  mkdir -p "$tdir"
  echo "0.1.0" > "$tdir/VERSION"
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
```

Add to `test/helpers.bash`:
```bash
# Stub the remote version checker by overriding _ccm_remote_version
ccm_stub_remote_version() {
  local v="$1"
  eval "_ccm_remote_version() { echo '$v'; }"
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `bats test/test-update.bats`
Expected: 4 failing.

- [ ] **Step 3: Implement lib/update.sh**

Write file `lib/update.sh`:
```bash
# lib/update.sh — self-update dispatcher.

CCM_RELEASE_REPO="${CCM_RELEASE_REPO:-<user>/claude-context-manager}"

# Detect how ccm was installed by inspecting the directory layout.
# Args: $1 = install root (where bin/ccm + VERSION live).
ccm_detect_install_channel() {
  local root="$1"
  if [ -d "$root/.git" ]; then
    echo "clone"; return 0
  fi
  # Tarball install: no .git, but has VERSION + bin/
  if [ -f "$root/VERSION" ] && [ -f "$root/bin/ccm" ]; then
    echo "tarball"; return 0
  fi
  echo "unknown"
  return 0
}

# Fetch the latest release tag from GitHub. Overridable via stub in tests.
_ccm_remote_version() {
  curl -fsSL "https://api.github.com/repos/$CCM_RELEASE_REPO/releases/latest" 2>/dev/null \
    | jq -r '.tag_name' \
    | sed 's/^v//'
}

ccm_update_main() {
  local check=0 root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) check=1 ;;
      --root)  shift; root="$1" ;;
      *) echo "ccm update: unknown arg: $1" >&2; return 1 ;;
    esac
    shift
  done
  [ -z "$root" ] && root="$CCM_ROOT"

  local local_v remote_v
  local_v="$(cat "$root/VERSION" 2>/dev/null || echo "unknown")"
  remote_v="$(_ccm_remote_version || echo "")"

  if [ -z "$remote_v" ]; then
    echo "ccm update: couldn't reach GitHub" >&2
    return 1
  fi

  if [ "$local_v" = "$remote_v" ]; then
    echo "ccm is up to date ($local_v)"
    return 0
  fi

  echo "Update available: $local_v → $remote_v"
  if [ "$check" -eq 1 ]; then
    return 0
  fi

  local channel
  channel="$(ccm_detect_install_channel "$root")"
  case "$channel" in
    clone)
      ( cd "$root" && git pull --ff-only && bash ./install.sh --quiet )
      ;;
    tarball)
      echo "Re-run: curl -fsSL https://raw.githubusercontent.com/$CCM_RELEASE_REPO/main/install-remote.sh | bash"
      ;;
    *)
      echo "Couldn't detect install channel. Reinstall manually."
      return 1
      ;;
  esac
  echo "Update complete. Restart Claude Code for hooks to reload."
}
```

- [ ] **Step 4: Run test, verify it passes**

Run: `bats test/test-update.bats`
Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add lib/update.sh test/test-update.bats test/helpers.bash
git commit -m "Add lib/update.sh: channel detection + version diff + dispatch"
```

---

## Task 18: install-remote.sh — curl-pipe-bash bootstrap

**Files:**
- Create: `install-remote.sh`

- [ ] **Step 1: Write install-remote.sh**

Write file `install-remote.sh`:
```bash
#!/usr/bin/env bash
# install-remote.sh — bootstrap installer fetched via curl.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<user>/claude-context-manager/main/install-remote.sh | bash

set -euo pipefail

REPO="${CCM_RELEASE_REPO:-<user>/claude-context-manager}"
INSTALL_DIR="${CCM_INSTALL_DIR:-$HOME/.local/share/ccm}"

echo "ccm bootstrap installer"
echo "  repo:   $REPO"
echo "  target: $INSTALL_DIR"

for tool in curl jq tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing: $tool"; exit 1; }
done

# Resolve latest release tag.
tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | jq -r '.tag_name')"
if [ -z "$tag" ] || [ "$tag" = "null" ]; then
  echo "Could not resolve latest tag." >&2
  exit 1
fi
echo "  tag:    $tag"

# Download tarball.
tmp="$(mktemp -d -t ccm-bootstrap-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
tarball="$tmp/ccm.tar.gz"
url="https://github.com/$REPO/releases/download/$tag/claude-context-manager-${tag#v}.tar.gz"
echo "Downloading $url"
curl -fsSL "$url" -o "$tarball"

# Verify SHA256 if available.
if curl -fsSL "https://github.com/$REPO/releases/download/$tag/SHA256SUMS" -o "$tmp/SHA256SUMS" 2>/dev/null; then
  ( cd "$tmp" && shasum -a 256 -c SHA256SUMS 2>/dev/null \
                 || sha256sum -c SHA256SUMS ) || { echo "Checksum failed."; exit 1; }
fi

# Extract.
mkdir -p "$INSTALL_DIR"
tar -xzf "$tarball" -C "$INSTALL_DIR" --strip-components=1

# Run the bundled install.
bash "$INSTALL_DIR/install.sh"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x install-remote.sh
```

- [ ] **Step 3: Lint with shellcheck (if available)**

Run: `shellcheck install-remote.sh || true`
Treat warnings as advisory; fix critical issues (SC2086, SC2046) if any.

- [ ] **Step 4: Commit**

```bash
git add install-remote.sh
git commit -m "Add install-remote.sh: curl-pipe-bash bootstrap to fetch + install latest release"
```

---

## Task 19: plugin/manifest.json (Claude Code plugin, best-effort)

**Files:**
- Create: `plugin/manifest.json`
- Create: `plugin/README.md`

- [ ] **Step 1: Write plugin/manifest.json**

Write file `plugin/manifest.json`:
```json
{
  "name": "claude-context-manager",
  "version": "0.1.0",
  "description": "Auto-save and auto-restore project context across Claude Code sessions.",
  "author": "<user>",
  "license": "MIT",
  "commands": [
    {"name": "ccm:load",    "file": "commands/ccm/load.md"},
    {"name": "ccm:save",    "file": "commands/ccm/save.md"},
    {"name": "ccm:history", "file": "commands/ccm/history.md"},
    {"name": "ccm:show",    "file": "commands/ccm/show.md"},
    {"name": "ccm:prune",   "file": "commands/ccm/prune.md"},
    {"name": "ccm:update",  "file": "commands/ccm/update.md"}
  ],
  "hooks": {
    "SessionStart": "bin/ccm load",
    "SessionEnd":   "bin/ccm save \"$CLAUDE_TRANSCRIPT_PATH\"",
    "PreCompact":   "bin/ccm flush \"$CLAUDE_TRANSCRIPT_PATH\""
  },
  "post_install": "install.sh"
}
```

- [ ] **Step 2: Write plugin/README.md**

Write file `plugin/README.md`:
```markdown
# ccm as a Claude Code plugin (best-effort, v0.1)

This manifest is provided so users can install via:

```
/plugin install <user>/claude-context-manager
```

**Status:** Best-effort. The Claude Code plugin system's exact contract for shell-based hooks and slash commands may differ from what this manifest declares. If `/plugin install` fails or behaves unexpectedly, use one of the supported channels instead:

- `curl -fsSL .../install-remote.sh | bash`
- `brew install <user>/ccm/ccm` (macOS)
- `scoop install ccm` (Windows, via the `ccm` bucket)

Track plugin-system support progress in the v0.2 milestone.
```

- [ ] **Step 3: Commit**

```bash
git add plugin/
git commit -m "Add plugin/manifest.json (Claude Code plugin, best-effort for v0.1)"
```

---

## Task 20: Homebrew formula and Scoop manifest (sibling-repo content)

**Files:**
- Create: `dist/homebrew/Formula/ccm.rb`
- Create: `dist/scoop/bucket/ccm.json`
- Create: `dist/README.md`

Note: these live under `dist/` in this repo but are *templates* that the release workflow copies into the sibling `homebrew-ccm` and `scoop-ccm` repos.

- [ ] **Step 1: Write the Homebrew formula**

Write file `dist/homebrew/Formula/ccm.rb`:
```ruby
class Ccm < Formula
  desc "Claude Context Manager — auto-save and restore Claude Code session context"
  homepage "https://github.com/<user>/claude-context-manager"
  url "https://github.com/<user>/claude-context-manager/releases/download/v0.1.0/claude-context-manager-0.1.0.tar.gz"
  sha256 "REPLACED_BY_RELEASE_WORKFLOW"
  license "MIT"

  depends_on "bash"
  depends_on "jq"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/ccm"
  end

  def caveats
    <<~EOS
      After installing, register hooks and slash commands with:
        #{libexec}/install.sh

      Or run it from this command:
        bash "#{libexec}/install.sh"
    EOS
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/ccm version")
  end
end
```

- [ ] **Step 2: Write the Scoop manifest**

Write file `dist/scoop/bucket/ccm.json`:
```json
{
  "version": "0.1.0",
  "description": "Claude Context Manager — auto-save and restore Claude Code session context",
  "homepage": "https://github.com/<user>/claude-context-manager",
  "license": "MIT",
  "depends": ["git", "jq"],
  "url": "https://github.com/<user>/claude-context-manager/archive/refs/tags/v0.1.0.tar.gz",
  "hash": "REPLACED_BY_RELEASE_WORKFLOW",
  "extract_dir": "claude-context-manager-0.1.0",
  "bin": "bin/ccm",
  "post_install": [
    "bash $dir/install.sh"
  ],
  "checkver": {
    "github": "https://github.com/<user>/claude-context-manager"
  },
  "autoupdate": {
    "url": "https://github.com/<user>/claude-context-manager/archive/refs/tags/v$version.tar.gz",
    "extract_dir": "claude-context-manager-$version"
  }
}
```

- [ ] **Step 3: Write dist/README.md**

Write file `dist/README.md`:
```markdown
# dist/ — package-manager templates

These files are committed here so they version with the main repo. The release workflow (`.github/workflows/release.yml`) copies them into the sibling repos `homebrew-ccm` and `scoop-ccm` and rewrites the `sha256` / `hash` and `version` fields.

Do not edit the live files in those sibling repos by hand — edit here, and the next tag push will regenerate them.
```

- [ ] **Step 4: Commit**

```bash
git add dist/
git commit -m "Add Homebrew formula and Scoop manifest templates under dist/"
```

---

## Task 21: CI workflow (.github/workflows/ci.yml)

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write ci.yml**

Write file `.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4

      - name: Install deps (macOS)
        if: runner.os == 'macOS'
        run: |
          brew install bash jq bats-core
          echo "/opt/homebrew/bin" >> "$GITHUB_PATH"

      - name: Install deps (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          choco install jq -y
          # bats-core via npm to avoid scoop on CI
          npm install -g bats

      - name: Verify tool versions
        run: |
          bash --version | head -1
          jq --version
          bats --version

      - name: Run bats suite
        run: bats test/

  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          scandir: '.'
          ignore_paths: 'test'
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add CI workflow: bats matrix on macos+windows, shellcheck on ubuntu"
```

---

## Task 22: Release workflow (.github/workflows/release.yml)

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write release.yml**

Write file `.github/workflows/release.yml`:
```yaml
name: Release

on:
  push:
    tags: ['v*.*.*']

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Validate tag matches VERSION
        run: |
          TAG="${GITHUB_REF#refs/tags/}"
          VERSION="v$(cat VERSION)"
          if [ "$TAG" != "$VERSION" ]; then
            echo "Tag $TAG does not match VERSION file ($VERSION)" >&2
            exit 1
          fi

      - name: Build source tarball
        run: |
          VERSION="$(cat VERSION)"
          PREFIX="claude-context-manager-${VERSION}"
          git archive --format=tar.gz --prefix="${PREFIX}/" -o "${PREFIX}.tar.gz" "${GITHUB_REF#refs/tags/}"
          shasum -a 256 "${PREFIX}.tar.gz" > SHA256SUMS

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="$(cat VERSION)"
          gh release create "v${VERSION}" \
            "claude-context-manager-${VERSION}.tar.gz" \
            SHA256SUMS \
            --title "v${VERSION}" \
            --notes-file <(awk "/^## \\[?${VERSION}\\]?/{flag=1; next} /^## /{flag=0} flag" CHANGELOG.md)

      - name: Update Homebrew tap
        env:
          TAP_TOKEN: ${{ secrets.TAP_TOKEN }}
        run: |
          VERSION="$(cat VERSION)"
          SHA="$(awk '{print $1}' SHA256SUMS)"
          git clone "https://x-access-token:${TAP_TOKEN}@github.com/<user>/homebrew-ccm.git" tap
          cp dist/homebrew/Formula/ccm.rb tap/Formula/ccm.rb
          sed -i "s|v[0-9]\\+\\.[0-9]\\+\\.[0-9]\\+/claude-context-manager-[0-9]\\+\\.[0-9]\\+\\.[0-9]\\+|v${VERSION}/claude-context-manager-${VERSION}|" tap/Formula/ccm.rb
          sed -i "s/REPLACED_BY_RELEASE_WORKFLOW/${SHA}/" tap/Formula/ccm.rb
          ( cd tap && git config user.email "bot@example.com" && git config user.name "ccm release bot" \
            && git add Formula/ccm.rb && git commit -m "ccm v${VERSION}" && git push )

      - name: Update Scoop bucket
        env:
          BUCKET_TOKEN: ${{ secrets.BUCKET_TOKEN }}
        run: |
          VERSION="$(cat VERSION)"
          SHA="$(awk '{print $1}' SHA256SUMS)"
          git clone "https://x-access-token:${BUCKET_TOKEN}@github.com/<user>/scoop-ccm.git" bucket
          cp dist/scoop/bucket/ccm.json bucket/bucket/ccm.json
          sed -i "s/REPLACED_BY_RELEASE_WORKFLOW/${SHA}/" bucket/bucket/ccm.json
          sed -i "s/0.1.0/${VERSION}/g" bucket/bucket/ccm.json
          ( cd bucket && git config user.email "bot@example.com" && git config user.name "ccm release bot" \
            && git add bucket/ccm.json && git commit -m "ccm v${VERSION}" && git push )
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add release workflow: build tarball, publish, update Homebrew + Scoop"
```

---

## Task 23: Integration test (test/integration.sh)

**Files:**
- Create: `test/integration.sh`

- [ ] **Step 1: Write the integration test**

Write file `test/integration.sh`:
```bash
#!/usr/bin/env bash
# test/integration.sh — end-to-end install + save + load cycle.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t ccm-int-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.claude"

# Stub claude on PATH
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
cat <<R
## SUMMARY
Integration test session.

## IN_PROGRESS
Verifying integration.
R
EOF
chmod +x "$STUB/claude"
export PATH="$STUB:$PATH"

# Fake project dir
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cd "$PROJ"
git init -q
git remote add origin https://github.com/example/foo.git

# Install
bash "$REPO_ROOT/install.sh" --quiet

# Save with the fixture transcript
TRANSCRIPT="$TMP/transcript.jsonl"
cp "$REPO_ROOT/test/fixtures/transcripts/sample.jsonl" "$TRANSCRIPT"
"$REPO_ROOT/bin/ccm" save "$TRANSCRIPT"

# Verify timeline entry exists
PID="$("$REPO_ROOT/bin/ccm" id)"
PDIR="$HOME/.claude/context-manager/$PID"
test -d "$PDIR/timeline" || { echo "FAIL: no timeline dir"; exit 1; }
COUNT="$(ls -1 "$PDIR/timeline" | wc -l | tr -d ' ')"
test "$COUNT" -eq 1 || { echo "FAIL: expected 1 timeline entry, got $COUNT"; exit 1; }

# Load
OUT="$("$REPO_ROOT/bin/ccm" load)"
echo "$OUT" | grep -q "Restored Context" || { echo "FAIL: load output missing header"; exit 1; }
echo "$OUT" | grep -q "Verifying integration" || { echo "FAIL: load output missing in-progress"; exit 1; }

echo "integration: PASS"
```

- [ ] **Step 2: Run it**

```bash
chmod +x test/integration.sh
./test/integration.sh
```
Expected: `integration: PASS`

- [ ] **Step 3: Commit**

```bash
git add test/integration.sh
git commit -m "Add integration.sh: end-to-end install + save + load smoke"
```

---

## Task 24: Complete README, CHANGELOG, final polish

**Files:**
- Modify: `README.md`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Rewrite README.md with full install + usage**

Write file `README.md`:
```markdown
# ccm — Claude Context Manager

> Auto-save and auto-restore project context across Claude Code sessions, on macOS and Windows (Git Bash).

[![CI](https://github.com/<user>/claude-context-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/<user>/claude-context-manager/actions/workflows/ci.yml)

## What it does

When you start Claude Code in a project, `ccm` injects a context block showing what you were working on last time. When the session ends, it summarizes the transcript and writes a timeline entry. When the context window auto-compacts mid-session, it refreshes the in-progress state so early-session decisions aren't lost.

## Install

### macOS (Homebrew)

```bash
brew install <user>/ccm/ccm
$(brew --prefix)/opt/ccm/libexec/install.sh
```

### Windows (Scoop)

```pwsh
scoop bucket add ccm https://github.com/<user>/scoop-ccm
scoop install ccm
# Then in Git Bash:
bash "$(scoop which ccm | xargs dirname)/../install.sh"
```

### Universal (curl)

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/claude-context-manager/main/install-remote.sh | bash
```

### From source

```bash
git clone https://github.com/<user>/claude-context-manager
cd claude-context-manager
./install.sh
```

After install, restart Claude Code so the new hooks load.

## Commands

| Subcommand | What it does |
|---|---|
| `ccm version` | Print version |
| `ccm id` | Print the project ID for the current dir |
| `ccm load` | Print restored context block to stdout |
| `ccm save <transcript>` | Summarize and write timeline entry |
| `ccm flush <transcript>` | Refresh in-progress state only (pre-compact) |
| `ccm history` | List session summaries |
| `ccm show N` | Print summary #N |
| `ccm prune --older-than=30d` | Delete old summaries |
| `ccm prune --orphans` | List unmatched project dirs |
| `ccm update` | Self-update to the latest release |

Slash commands inside a Claude Code session: `/ccm:load`, `/ccm:save`, `/ccm:history`, `/ccm:show`, `/ccm:prune`, `/ccm:update`.

## Storage layout

```
~/.claude/context-manager/
  <project-id>/
    current.md           # what you were working on
    timeline/
      2026-05-11-1820.md
      ...
    transcripts.jsonl    # pointers to original conversation logs
    meta.json
  log                    # ccm's own operational log
```

Each project's ID is its git remote URL (URL-encoded) if there is one, otherwise a SHA1 of the absolute path.

## Uninstall

```bash
cd <repo>
./uninstall.sh
```

You'll be asked whether to keep `~/.claude/context-manager/` storage.

## Development

```bash
brew install bash jq bats-core   # macOS
scoop install jq bats            # Windows (Git Bash)
bats test/                       # run unit tests
./test/integration.sh            # end-to-end smoke
```

## License

MIT — see `LICENSE`.
```

- [ ] **Step 2: Write CHANGELOG.md**

Write file `CHANGELOG.md`:
```markdown
# Changelog

All notable changes to ccm will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-05-11

### Added
- Initial release.
- `ccm` CLI with subcommands: `version`, `id`, `load`, `save`, `flush`, `history`, `show`, `prune`, `update`.
- Claude Code hooks: `SessionStart` (auto-load), `SessionEnd` (auto-save), `PreCompact` (refresh in-progress).
- Slash commands: `/ccm:load`, `/ccm:save`, `/ccm:history`, `/ccm:show`, `/ccm:prune`, `/ccm:update`.
- macOS + Windows (Git Bash) support via `lib/platform.sh`.
- Install paths: source, curl-pipe-bash bootstrap, Homebrew tap, Scoop bucket.
- Self-update via `ccm update` with channel detection.
- bats-core unit test suite + integration smoke test.
- GitHub Actions CI on macos-latest and windows-latest.
- Release workflow that publishes tarballs and updates Homebrew + Scoop on tag push.
```

- [ ] **Step 3: Verify the full suite still passes**

```bash
bats test/
./test/integration.sh
```
Expected: all bats tests pass, integration prints `integration: PASS`.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "Complete README with install paths and CHANGELOG for v0.1.0"
```

---

## Task 25: Final spec-coverage sweep and tag v0.1.0

**Files:** (no edits — verification only)

- [ ] **Step 1: Verify every spec requirement maps to a task**

Open `docs/superpowers/specs/2026-05-11-claude-context-manager-design.md`. For each numbered section, confirm there is at least one task in this plan that implements it:

- §3 architecture (bin/ccm, lib/*.sh, hooks, slash commands) → Tasks 3-14, 19
- §4.1 load → Task 7
- §4.2 save → Task 9
- §4.3 flush → Task 10
- §5 file tree → Tasks 1-22
- §6 technology stack → Task 3 (`lib/platform.sh`)
- §7 install / uninstall → Tasks 15, 16
- §8 distribution (4 channels) → Tasks 18 (curl), 19 (plugin), 20 (brew+scoop), 17 (self-update)
- §9 versioning + release → Tasks 1 (VERSION), 22 (release.yml), 24 (CHANGELOG)
- §10 error handling → covered inline in tasks 7, 9, 10, 15, 17
- §11 testing → Tasks 2, 3-14, 21, 23

If a spec requirement has no mapping, add a task before tagging.

- [ ] **Step 2: Run the full check**

```bash
bats test/
./test/integration.sh
shellcheck bin/ccm lib/*.sh install.sh uninstall.sh install-remote.sh
```
All must pass.

- [ ] **Step 3: Tag the release**

```bash
git tag -a v0.1.0 -m "v0.1.0 — first release"
git push origin v0.1.0
```

The release workflow takes over from here.

- [ ] **Step 4: Manual acceptance (see spec §11)**

Run through each step in spec §11 "Manual acceptance" on whichever OS you're on. Document any deviations in CHANGELOG before announcing the release.

---

## Plan self-review

I read this plan against the spec:

**Spec coverage.** Every numbered section of the spec maps to at least one task above (verified in Task 25 Step 1).

**Placeholder scan.** No "TBD" / "TODO" / "fill in later". Every step has either complete code, an exact command, or a verification check.

**Type / name consistency.** Function names line up across tasks: `ccm_resolve_project_id` defined in Task 5 used in Tasks 7, 9, 10, 11, 13. `ccm_storage_root` / `ccm_project_dir` / `ccm_init_project_dir` defined in Task 4 used everywhere. Subcommand entry points all follow `ccm_<cmd>_main(...)` convention.

**Known accepted gaps** (spec §12 open questions):
- `prompts/summarize.txt` exact wording is the starting point in Task 8; iterate after first real-traffic run.
- Plugin manifest (Task 19) is shipped as best-effort per spec §8.1.
- `--list-only` flag on `ccm prune --orphans` is the MVP affordance for orphan cleanup; full interactive deletion is deferred.

---

## Execution Handoff

Plan complete and saved to `implementation.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
