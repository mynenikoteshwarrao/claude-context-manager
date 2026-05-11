# Zero-step Package Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `brew install mynenikoteshwarrao/ccm/ccm` (or `scoop install ccm`), the user gets the `ccm` CLI, `/ccm:*` slash commands, and auto-save/load/flush hooks with no additional commands. `brew uninstall ccm` reverses everything except saved history.

**Architecture:** Single source of truth stays `install.sh` / `uninstall.sh`. Homebrew formula gains `post_install` + `uninstall` + `post_uninstall` blocks that invoke them. `install.sh` learns a `--from-pkg` flag (skips `~/.local/bin/ccm` since the package manager owns that), makes the `claude` CLI optional in preflight, and switches hook registration to a safe append-and-dedupe `jq` filter. `uninstall.sh` gets a symmetric selective-removal filter and the same `--from-pkg` flag. Scoop manifest gets the same flag and an `uninstaller` block.

**Tech Stack:** Bash, jq, Homebrew formula (Ruby DSL), Scoop manifest (JSON), bats-core for tests.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `install.sh` | Modify | Append-and-dedupe hook filter; optional `claude` preflight; `--from-pkg` flag |
| `uninstall.sh` | Modify | Selective hook removal (keep user's non-ccm hooks); `--from-pkg` flag |
| `dist/homebrew/Formula/ccm.rb` | Modify | `post_install` runs `install.sh`; `uninstall` runs `uninstall.sh`; `post_uninstall` cleans staging dir |
| `dist/scoop/bucket/ccm.json` | Modify | Pass `--from-pkg` to `install.sh`; add `uninstaller` block |
| `README.md` | Modify | Drop manual `install.sh` step from brew/scoop sections |
| `CHANGELOG.md` | Modify | Record the change under `[Unreleased]` |
| `test/fixtures/settings/existing-with-ccm-slot-hooks.json` | Create | Fixture with user-owned `SessionStart` hook (non-ccm) to test data preservation |
| `test/test-install.bats` | Modify | New tests: preserve user's SessionStart hook on install; install succeeds without `claude` on PATH; `--from-pkg` skips `~/.local/bin/ccm` |
| `test/test-uninstall.bats` | Create | New file: uninstall preserves user's SessionStart hook; `--from-pkg` is accepted |

The Homebrew formula and Scoop manifest are not covered by bats (they require their respective package managers). They are verified by manual install/uninstall on the corresponding OS, plus the existing release CI on the tap repo.

---

## Task 1: Append-and-dedupe hook filter in install.sh

**Why first:** `install.sh` currently writes `.hooks.SessionStart = [{...}]`, which **overwrites** any user-owned `SessionStart` hooks. This is a data-loss bug that exists today. Fix it before adding any new install paths that could amplify the impact.

**Files:**
- Create: `test/fixtures/settings/existing-with-ccm-slot-hooks.json`
- Modify: `test/test-install.bats` (add new test cases)
- Modify: `install.sh:65-82` (the `register_hooks` function)

- [ ] **Step 1: Create the fixture with a user-owned SessionStart hook**

Create `test/fixtures/settings/existing-with-ccm-slot-hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {"command": "echo user-owned-session-start"}
    ],
    "SessionEnd": [
      {"command": "echo user-owned-session-end"}
    ]
  },
  "theme": "dark"
}
```

- [ ] **Step 2: Write the failing test**

Append to `test/test-install.bats`:

```bash
@test "install: preserves user's SessionStart/SessionEnd hooks while adding ccm hooks" {
  cp "$CCM_REPO_ROOT/test/fixtures/settings/existing-with-ccm-slot-hooks.json" \
     "$HOME/.claude/settings.json"

  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]

  # User's hook must still be present
  user_ss="$(jq -r '.hooks.SessionStart[] | select(.command | contains("user-owned-session-start")) | .command' "$HOME/.claude/settings.json")"
  [ "$user_ss" = "echo user-owned-session-start" ]

  user_se="$(jq -r '.hooks.SessionEnd[] | select(.command | contains("user-owned-session-end")) | .command' "$HOME/.claude/settings.json")"
  [ "$user_se" = "echo user-owned-session-end" ]

  # ccm hook must be present alongside it
  ccm_ss_count="$(jq -r '[.hooks.SessionStart[] | select(.command | contains("ccm load"))] | length' "$HOME/.claude/settings.json")"
  [ "$ccm_ss_count" -eq 1 ]
}

@test "install: rerunning twice does not duplicate ccm hooks even when user hooks exist" {
  cp "$CCM_REPO_ROOT/test/fixtures/settings/existing-with-ccm-slot-hooks.json" \
     "$HOME/.claude/settings.json"

  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]

  ccm_ss_count="$(jq -r '[.hooks.SessionStart[] | select(.command | contains("ccm load"))] | length' "$HOME/.claude/settings.json")"
  [ "$ccm_ss_count" -eq 1 ]

  user_ss_count="$(jq -r '[.hooks.SessionStart[] | select(.command | contains("user-owned-session-start"))] | length' "$HOME/.claude/settings.json")"
  [ "$user_ss_count" -eq 1 ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-install.bats`

Expected: the two new tests FAIL. The first fails because the existing `.hooks.SessionStart = [{"command": ($bin + " load")}]` line in `install.sh` replaces the user's hook with just the ccm one. The second fails for the same reason on the first install (no need to rerun to surface it).

- [ ] **Step 4: Rewrite `register_hooks` in install.sh with an append-and-dedupe jq filter**

Replace the `register_hooks` function in `install.sh` (currently lines 65-82) with:

```bash
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
      def upsert(arr_path; ccm_marker; new_cmd):
        arr_path = (
          (arr_path // [])
          | map(select(.command | tostring | contains(ccm_marker) | not))
          + [{"command": new_cmd}]
        );

      .hooks //= {}
      | upsert(.hooks.SessionStart; "ccm load";  ($bin + " load"))
      | upsert(.hooks.SessionEnd;   "ccm save";  ($bin + " save \"$CLAUDE_TRANSCRIPT_PATH\""))
      | upsert(.hooks.PreCompact;   "ccm flush"; ($bin + " flush \"$CLAUDE_TRANSCRIPT_PATH\""))
    ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  _say "Registered SessionStart, SessionEnd, PreCompact hooks"
}
```

Key changes:
- `arr_path = ((arr_path // []) | ...)` appends rather than overwrites.
- `map(select(... | not))` strips any prior ccm hook before re-adding it. The marker is the literal substring `"ccm load"` / `"ccm save"` / `"ccm flush"` — these only appear in ccm-installed hooks because they are the literal subcommand names.
- The `def upsert` helper keeps the three hook registrations DRY.

- [ ] **Step 5: Run all install tests to verify they pass and nothing regresses**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-install.bats`

Expected: All tests PASS, including the two new ones and the existing `install: rerunning is idempotent` test.

- [ ] **Step 6: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add install.sh test/test-install.bats test/fixtures/settings/existing-with-ccm-slot-hooks.json
git commit -m "fix: install.sh preserves user-owned Session* hooks

Hook registration previously overwrote the entire SessionStart/SessionEnd/
PreCompact arrays, destroying any non-ccm hooks the user had configured.
Switch to an append-and-dedupe jq filter that strips prior ccm entries
(matched by the literal subcommand name) and appends the new one,
leaving unrelated entries untouched."
```

---

## Task 2: Selective hook removal in uninstall.sh

**Why next:** `uninstall.sh` has the symmetric data-loss bug — it does `del(.hooks.SessionStart, .hooks.SessionEnd, .hooks.PreCompact)` (line 27), which deletes those arrays entirely, taking the user's non-ccm hooks with them. Fix before any package manager starts calling uninstall.sh on real user machines.

**Files:**
- Create: `test/test-uninstall.bats`
- Modify: `uninstall.sh:25-31` (the settings.json cleanup block)

- [ ] **Step 1: Write the failing test**

Create `test/test-uninstall.bats`:

```bash
#!/usr/bin/env bats
load 'helpers.bash'

setup() {
  ccm_setup_tmphome
  ccm_stub_claude "ok"
}
teardown() { ccm_teardown_tmphome; }

@test "uninstall: preserves user's non-ccm SessionStart/SessionEnd hooks" {
  cp "$CCM_REPO_ROOT/test/fixtures/settings/existing-with-ccm-slot-hooks.json" \
     "$HOME/.claude/settings.json"

  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]

  run bash "$CCM_REPO_ROOT/uninstall.sh" --quiet --keep-storage
  [ "$status" -eq 0 ]

  # User's hooks must survive
  user_ss="$(jq -r '.hooks.SessionStart[] | select(.command | contains("user-owned-session-start")) | .command' "$HOME/.claude/settings.json")"
  [ "$user_ss" = "echo user-owned-session-start" ]

  user_se="$(jq -r '.hooks.SessionEnd[] | select(.command | contains("user-owned-session-end")) | .command' "$HOME/.claude/settings.json")"
  [ "$user_se" = "echo user-owned-session-end" ]

  # ccm hooks must be gone
  ccm_ss_count="$(jq -r '[.hooks.SessionStart[]? | select(.command | contains("ccm load"))] | length' "$HOME/.claude/settings.json")"
  [ "$ccm_ss_count" -eq 0 ]
}

@test "uninstall: cleans empty hook arrays" {
  # If the only entries were ccm entries, removing them should leave the array empty
  # but the file should still be valid JSON.
  run bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]

  run bash "$CCM_REPO_ROOT/uninstall.sh" --quiet --keep-storage
  [ "$status" -eq 0 ]

  jq -e '.' "$HOME/.claude/settings.json" >/dev/null

  ccm_ss_count="$(jq -r '[.hooks.SessionStart[]? | select(.command | contains("ccm load"))] | length' "$HOME/.claude/settings.json")"
  [ "$ccm_ss_count" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-uninstall.bats`

Expected: The first test FAILS because `del(.hooks.SessionStart, .hooks.SessionEnd, .hooks.PreCompact)` removes the entire arrays, deleting `user-owned-session-start` along with the ccm entry. The second test may also fail or pass depending on how the legacy `del` interacts with absent keys — verify the failure mode is the first test, not setup noise.

- [ ] **Step 3: Replace the settings.json cleanup block in uninstall.sh**

Replace lines 25-31 of `uninstall.sh` (the `if [ -f "$settings" ]; then` block) with:

```bash
# 2. Remove our hook entries from settings.json (preserve other entries)
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ]; then
  tmp="$(mktemp)"
  jq '
    def strip(arr_path; ccm_marker):
      arr_path = (arr_path // [] | map(select(.command | tostring | contains(ccm_marker) | not)));

    .
    | strip(.hooks.SessionStart; "ccm load")
    | strip(.hooks.SessionEnd;   "ccm save")
    | strip(.hooks.PreCompact;   "ccm flush")
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  _say "Removed ccm hooks from settings.json."
fi
```

Note: this leaves empty arrays in place (`"SessionStart": []`) rather than deleting the key. That is acceptable — Claude Code treats an empty array the same as a missing key, and keeping the array preserves the user's intent if they add a hook back later. The test asserts the file is still valid JSON.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-uninstall.bats test/test-install.bats`

Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add uninstall.sh test/test-uninstall.bats
git commit -m "fix: uninstall.sh preserves user-owned Session* hooks

Previously \`del(.hooks.SessionStart, ...)\` removed entire hook arrays,
including hooks the user owned. Switch to a selective jq filter that
strips only entries whose command contains the ccm subcommand marker."
```

---

## Task 3: Make `claude` CLI optional in install.sh preflight

**Why:** A package-manager install runs at install time, which is before the user has necessarily installed Claude Code. install.sh's current preflight (`install.sh:27`) hard-fails if `claude` is missing, which would break the brew formula's `post_install`. Symlinks and `~/.claude/settings.json` work regardless of whether the `claude` binary is on PATH at install time.

**Files:**
- Modify: `test/test-install.bats` (add new test case)
- Modify: `install.sh:22-41` (the `preflight` function)
- Modify: `test/helpers.bash` (add a helper to scrub `claude` from PATH for a test)

- [ ] **Step 1: Add helper to remove `claude` from PATH**

Append to `test/helpers.bash`:

```bash
# Run a command with `claude` deliberately scrubbed from PATH.
# Use to test installer behavior when Claude Code is not yet installed.
ccm_without_claude() {
  # Rebuild PATH excluding any directory that contains a `claude` binary
  local IFS=':' new_path="" entry
  for entry in $PATH; do
    if [ -x "$entry/claude" ]; then
      continue
    fi
    if [ -z "$new_path" ]; then
      new_path="$entry"
    else
      new_path="$new_path:$entry"
    fi
  done
  PATH="$new_path" "$@"
}
```

- [ ] **Step 2: Write the failing test**

Append to `test/test-install.bats`:

```bash
@test "install: succeeds when claude CLI is not on PATH" {
  # NOTE: setup() calls ccm_stub_claude. Skip that effect by scrubbing PATH for this run.
  run ccm_without_claude bash "$CCM_REPO_ROOT/install.sh" --quiet
  [ "$status" -eq 0 ]
  [ -e "$HOME/.claude/commands/ccm" ]
  jq -e '.hooks.SessionStart' "$HOME/.claude/settings.json" >/dev/null
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-install.bats -f "claude CLI is not on PATH"`

Expected: FAIL. install.sh exits with status 1 and a message like `ccm install: missing tools: claude. Try: brew install claude`.

- [ ] **Step 4: Soften the preflight to warn instead of die when `claude` is missing**

In `install.sh`, replace the `preflight` function (currently lines 22-41) with:

```bash
preflight() {
  local missing=()
  command -v bash    >/dev/null 2>&1 || missing+=("bash")
  command -v jq      >/dev/null 2>&1 || missing+=("jq")
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
  # `claude` CLI is optional at install time. If it is not on PATH, the hooks
  # we register in settings.json will simply activate the next time the user
  # installs and runs Claude Code.
  if ! command -v claude >/dev/null 2>&1; then
    _say "Note: Claude Code CLI not detected on PATH. ccm hooks will activate the next time you install or launch Claude Code."
  fi
}
```

Key change: `claude` is removed from the required-tools list. A non-fatal note is printed in its place.

- [ ] **Step 5: Run all install tests to verify they pass**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-install.bats`

Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add install.sh test/test-install.bats test/helpers.bash
git commit -m "fix: install.sh treats \`claude\` CLI as optional in preflight

Package-manager installs may run before Claude Code itself is installed.
Symlinks and settings.json wiring do not depend on the \`claude\` binary
being present at install time, so demote it from a fatal preflight
requirement to a non-fatal note."
```

---

## Task 4: Add `--from-pkg` flag to install.sh and uninstall.sh

**Why:** Homebrew already symlinks `bin/ccm` into its own prefix; if `install.sh` also drops a symlink at `~/.local/bin/ccm`, the two compete (and the user's PATH ordering decides which wins). `--from-pkg` tells the installer "the package manager already owns the binary path, just wire up Claude Code integration and use `command -v ccm` as the canonical path in hooks."

**Files:**
- Modify: `install.sh:10-17` (arg parsing), `install.sh:52-56` (`do_symlinks`), `install.sh:59-63` (`ccm_bin_path`), `install.sh:85-93` (`path_check`)
- Modify: `uninstall.sh:9-16` (arg parsing), `uninstall.sh:20-21` (binary removal)
- Modify: `test/test-install.bats` (new test for `--from-pkg`)
- Modify: `test/test-uninstall.bats` (new test for `--from-pkg`)

- [ ] **Step 1: Write the failing install test**

Append to `test/test-install.bats`:

```bash
@test "install: --from-pkg skips ~/.local/bin/ccm symlink" {
  # Pretend a package manager has put ccm somewhere on PATH
  local fake_pkg_bin="$CCM_TMPHOME/pkg-bin"
  mkdir -p "$fake_pkg_bin"
  cp "$CCM_REPO_ROOT/bin/ccm" "$fake_pkg_bin/ccm"
  chmod +x "$fake_pkg_bin/ccm"
  export PATH="$fake_pkg_bin:$PATH"

  run bash "$CCM_REPO_ROOT/install.sh" --quiet --from-pkg
  [ "$status" -eq 0 ]

  # ~/.local/bin/ccm must NOT be created
  [ ! -e "$HOME/.local/bin/ccm" ]

  # Slash-command symlink and hooks should still be wired up
  [ -e "$HOME/.claude/commands/ccm" ]
  jq -e '.hooks.SessionStart' "$HOME/.claude/settings.json" >/dev/null

  # The hook command should reference the package-manager path, not ~/.local/bin
  bin_in_hook="$(jq -r '.hooks.SessionStart[0].command' "$HOME/.claude/settings.json")"
  [[ "$bin_in_hook" == "$fake_pkg_bin/ccm load" ]]
}
```

- [ ] **Step 2: Write the failing uninstall test**

Append to `test/test-uninstall.bats`:

```bash
@test "uninstall: --from-pkg leaves any ~/.local/bin/ccm alone" {
  # Simulate a state where a separate, unrelated symlink lives at ~/.local/bin/ccm.
  # uninstall --from-pkg must not touch it (the package manager owns its own bin path).
  mkdir -p "$HOME/.local/bin"
  ln -s /usr/bin/true "$HOME/.local/bin/ccm"

  # Set up the rest of the install state directly (so we don't need install --from-pkg yet)
  mkdir -p "$HOME/.claude/commands"
  ln -s "$CCM_REPO_ROOT/commands/ccm" "$HOME/.claude/commands/ccm"
  echo '{"hooks":{"SessionStart":[{"command":"/opt/homebrew/bin/ccm load"}]}}' > "$HOME/.claude/settings.json"

  run bash "$CCM_REPO_ROOT/uninstall.sh" --quiet --keep-storage --from-pkg
  [ "$status" -eq 0 ]

  # Slash-command symlink should be gone
  [ ! -e "$HOME/.claude/commands/ccm" ]

  # ccm hook should be gone
  ccm_ss_count="$(jq -r '[.hooks.SessionStart[]? | select(.command | contains("ccm load"))] | length' "$HOME/.claude/settings.json")"
  [ "$ccm_ss_count" -eq 0 ]

  # The unrelated ~/.local/bin/ccm symlink must still exist (we didn't put it there)
  [ -L "$HOME/.local/bin/ccm" ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-install.bats test/test-uninstall.bats`

Expected: both new tests FAIL. The install test fails on `install.sh: unknown arg: --from-pkg`. The uninstall test fails on `uninstall.sh: unknown arg: --from-pkg`.

- [ ] **Step 4: Add `--from-pkg` parsing and wiring to install.sh**

In `install.sh`, update the arg-parsing loop (currently lines 11-17). Replace with:

```bash
QUIET=0
FROM_PKG=0
for arg in "$@"; do
  case "$arg" in
    --quiet)    QUIET=1 ;;
    --from-pkg) FROM_PKG=1 ;;
    --force)    ;;  # accepted for backward-compat; reinstall is always idempotent
    *) echo "install.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done
```

Replace `do_symlinks` (currently lines 52-56) with:

```bash
do_symlinks() {
  if [ "$FROM_PKG" -eq 0 ]; then
    ccm_symlink "$REPO_ROOT/bin/ccm" "$HOME/.local/bin/ccm"
  fi
  ccm_symlink "$REPO_ROOT/commands/ccm" "$HOME/.claude/commands/ccm"
  if [ "$FROM_PKG" -eq 1 ]; then
    _say "Linked /ccm:* slash commands into ~/.claude/commands/ccm"
  else
    _say "Linked ccm into ~/.local/bin and ~/.claude/commands/ccm"
  fi
}
```

Replace `ccm_bin_path` (currently lines 59-63) with:

```bash
ccm_bin_path() {
  # Path written into hook commands.
  # --from-pkg: package manager owns the bin path; resolve via PATH.
  # otherwise:  use the ~/.local/bin/ccm symlink we just created.
  local p
  if [ "$FROM_PKG" -eq 1 ]; then
    p="$(command -v ccm || true)"
    if [ -z "$p" ]; then
      _die "--from-pkg set but 'ccm' is not on PATH. The package manager should have installed it."
    fi
  else
    p="$HOME/.local/bin/ccm"
  fi
  ccm_path_posix "$p"
}
```

Replace `path_check` (currently lines 85-93) with:

```bash
path_check() {
  if [ "$FROM_PKG" -eq 1 ]; then
    return 0
  fi
  if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    cat <<EOF
Note: $HOME/.local/bin is not on your PATH.
Add this to your shell rc (.zshrc, .bashrc):
  export PATH="\$HOME/.local/bin:\$PATH"
EOF
  fi
}
```

- [ ] **Step 5: Add `--from-pkg` parsing to uninstall.sh and gate the bin removal**

In `uninstall.sh`, replace the arg loop (currently lines 9-16) with:

```bash
QUIET=0
KEEP_STORAGE=0
FROM_PKG=0
for arg in "$@"; do
  case "$arg" in
    --quiet)         QUIET=1 ;;
    --keep-storage)  KEEP_STORAGE=1 ;;
    --from-pkg)      FROM_PKG=1 ;;
    *) echo "uninstall.sh: unknown arg: $arg" >&2; exit 1 ;;
  esac
done
```

Replace the symlink-removal block (currently lines 20-22) with:

```bash
# 1. Remove symlinks/shims (the package-manager-owned bin is not ours to remove)
if [ "$FROM_PKG" -eq 0 ]; then
  rm -f "$HOME/.local/bin/ccm" 2>/dev/null || true
fi
rm -rf "$HOME/.claude/commands/ccm" 2>/dev/null || true
_say "Removed symlinks."
```

- [ ] **Step 6: Run all install and uninstall tests**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/test-install.bats test/test-uninstall.bats`

Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add install.sh uninstall.sh test/test-install.bats test/test-uninstall.bats
git commit -m "feat: --from-pkg flag for install.sh and uninstall.sh

When invoked from a package manager (Homebrew, Scoop), the bin path is
managed by the package, not by ccm. --from-pkg skips the ~/.local/bin
symlink, resolves the binary via \`command -v ccm\` for hook commands,
and leaves any pre-existing ~/.local/bin/ccm alone on uninstall."
```

---

## Task 5: Homebrew formula auto-wires install on `brew install`

**Why:** The remaining gap from the spec — the formula installs the binary but does not invoke `install.sh`. After this task, `brew install mynenikoteshwarrao/ccm/ccm` is a single command that produces a fully wired install.

**Files:**
- Modify: `dist/homebrew/Formula/ccm.rb`

**Note:** Homebrew formula changes cannot be tested via bats. The verification at the end of this task is a manual `brew install --build-from-source` against the local formula. CI verification happens in the tap repo's release workflow.

- [ ] **Step 1: Update Formula/ccm.rb with post_install, uninstall, post_uninstall blocks**

Replace the entire body of `dist/homebrew/Formula/ccm.rb` with:

```ruby
class Ccm < Formula
  desc "Claude Context Manager — auto-save and restore Claude Code session context"
  homepage "https://github.com/mynenikoteshwarrao/claude-context-manager"
  url "https://github.com/mynenikoteshwarrao/claude-context-manager/releases/download/v0.1.0/claude-context-manager-0.1.0.tar.gz"
  sha256 "REPLACED_BY_RELEASE_WORKFLOW"
  license "MIT"

  depends_on "bash"
  depends_on "jq"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/ccm"
  end

  def post_install
    # Stash a copy of uninstall.sh in a stable location so `brew uninstall`
    # can still find it after libexec is removed.
    share_dir = HOMEBREW_PREFIX/"share/ccm"
    share_dir.mkpath
    cp libexec/"uninstall.sh", share_dir/"uninstall.sh"
    chmod 0755, share_dir/"uninstall.sh"

    # Wire up ~/.claude/commands/ccm + hooks in ~/.claude/settings.json.
    system "bash", libexec/"install.sh", "--from-pkg", "--quiet"
  end

  def uninstall
    uninstall_sh = HOMEBREW_PREFIX/"share/ccm/uninstall.sh"
    if uninstall_sh.exist?
      system "bash", uninstall_sh, "--from-pkg", "--keep-storage", "--quiet"
    end
  end

  def post_uninstall
    share_dir = HOMEBREW_PREFIX/"share/ccm"
    share_dir.rmtree if share_dir.exist?
  end

  def caveats
    <<~EOS
      ccm installed. Restart Claude Code (or open a new session) to see /ccm:* commands.
      To also remove saved history on uninstall, run: ~/.claude/context-manager and remove the directory manually.
    EOS
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/ccm version")
  end
end
```

Key changes:
- `def post_install` copies `uninstall.sh` to `$HOMEBREW_PREFIX/share/ccm/uninstall.sh` (stable across uninstall) and runs `install.sh --from-pkg --quiet`.
- `def uninstall` runs the stashed `uninstall.sh --from-pkg --keep-storage --quiet`. `--keep-storage` preserves the user's saved context — `brew uninstall` should not silently delete user data.
- `def post_uninstall` removes the staging directory.
- `caveats` shrinks to a single actionable line plus a hint about saved data.

- [ ] **Step 2: Manual verification — install from local formula**

Run on macOS:

```bash
cd /Users/koteshwar/personal/claude-context-manager
# Make a local-source copy of the formula that points at the repo, not a release tarball,
# so we can test without pushing a release first.
# (Skip this in plan execution if a release tarball already exists for the current SHA.)
brew install --build-from-source ./dist/homebrew/Formula/ccm.rb
```

Expected outcomes:
- `which ccm` resolves under `$(brew --prefix)/bin/ccm`.
- `test -L ~/.claude/commands/ccm` returns true (symlink exists).
- `jq '.hooks.SessionStart[].command' ~/.claude/settings.json` includes a line containing `ccm load`.
- `test -f $(brew --prefix)/share/ccm/uninstall.sh` returns true.

If `--build-from-source` fails because the `url:` SHA does not exist yet for this branch, defer the manual verification to after the release tarball is published. The unit tests in Tasks 1-4 already cover the install.sh behavior; the formula change is mechanical.

- [ ] **Step 3: Manual verification — uninstall**

```bash
brew uninstall ccm
```

Expected outcomes:
- `which ccm` no longer resolves.
- `test -L ~/.claude/commands/ccm` returns false.
- `jq '[.hooks.SessionStart[]? | select(.command | contains("ccm load"))] | length' ~/.claude/settings.json` returns `0`.
- `test -d $(brew --prefix)/share/ccm` returns false.
- `test -d ~/.claude/context-manager` returns true (saved history preserved).

- [ ] **Step 4: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add dist/homebrew/Formula/ccm.rb
git commit -m "feat(brew): formula auto-wires slash commands and hooks

post_install runs install.sh --from-pkg so /ccm:* commands and
SessionStart/SessionEnd/PreCompact hooks are configured immediately
after brew install. uninstall reverses the wiring (but preserves
saved history). post_uninstall cleans the staging directory."
```

---

## Task 6: Scoop manifest passes --from-pkg and adds uninstaller

**Why:** Scoop already runs `install.sh` from `post_install`, but without `--from-pkg` it tries to symlink `~/.local/bin/ccm`, which competes with the Scoop-managed shim. There is also no `uninstaller` block, so `scoop uninstall ccm` leaves slash commands and hooks behind.

**Files:**
- Modify: `dist/scoop/bucket/ccm.json`

- [ ] **Step 1: Update the manifest**

Replace the entire file `dist/scoop/bucket/ccm.json` with:

```json
{
  "version": "0.1.0",
  "description": "Claude Context Manager — auto-save and restore Claude Code session context",
  "homepage": "https://github.com/mynenikoteshwarrao/claude-context-manager",
  "license": "MIT",
  "depends": ["git", "jq"],
  "url": "https://github.com/mynenikoteshwarrao/claude-context-manager/archive/refs/tags/v0.1.0.tar.gz",
  "hash": "REPLACED_BY_RELEASE_WORKFLOW",
  "extract_dir": "claude-context-manager-0.1.0",
  "bin": "bin/ccm",
  "post_install": [
    "bash \"$dir/install.sh\" --from-pkg --quiet"
  ],
  "uninstaller": {
    "script": "bash \"$dir/uninstall.sh\" --from-pkg --keep-storage --quiet"
  },
  "checkver": {
    "github": "https://github.com/mynenikoteshwarrao/claude-context-manager"
  },
  "autoupdate": {
    "url": "https://github.com/mynenikoteshwarrao/claude-context-manager/archive/refs/tags/v$version.tar.gz",
    "extract_dir": "claude-context-manager-$version"
  }
}
```

Key changes:
- `post_install` now passes `--from-pkg --quiet`.
- New `uninstaller` block calls `uninstall.sh --from-pkg --keep-storage --quiet`.

- [ ] **Step 2: Manual verification on Windows (Git Bash + Scoop)**

If a Windows machine is not available during plan execution, this step is deferred to whoever publishes the next release. Document the procedure here so it can be run when possible:

```powershell
scoop install mynenikoteshwarrao/ccm
# Then in Git Bash:
ls ~/.claude/commands/ccm
jq '.hooks.SessionStart' ~/.claude/settings.json
# Then back in PowerShell:
scoop uninstall ccm
# Then in Git Bash:
test -e ~/.claude/commands/ccm  # should be missing
jq '[.hooks.SessionStart[]? | select(.command | contains("ccm load"))] | length' ~/.claude/settings.json
# should print 0
```

- [ ] **Step 3: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add dist/scoop/bucket/ccm.json
git commit -m "feat(scoop): pass --from-pkg and add uninstaller

post_install now uses --from-pkg so install.sh skips the ~/.local/bin
symlink that would compete with Scoop's shim. Adds an uninstaller block
that calls uninstall.sh --from-pkg --keep-storage so scoop uninstall
reverses the Claude Code wiring while preserving saved history."
```

---

## Task 7: Update README to drop the manual install step

**Why:** README currently tells users to run `install.sh` manually after `brew install` (line 27) and after `scoop install` (line 36), and to run `uninstall.sh` manually before `brew uninstall` (line 153) and before `scoop uninstall` (line 158). Those steps are obsolete after Tasks 5 and 6.

**Files:**
- Modify: `README.md:23-37`, `README.md:148-160`

- [ ] **Step 1: Update the brew install section**

Replace `README.md:23-28`:

```markdown
### macOS — Homebrew

```bash
brew install mynenikoteshwarrao/ccm/ccm
bash "$(brew --prefix)/opt/ccm/libexec/install.sh"
```
```

with:

```markdown
### macOS — Homebrew

```bash
brew install mynenikoteshwarrao/ccm/ccm
```

Slash commands and hooks are wired up automatically. Restart Claude Code (or open a new session) to see `/ccm:*`.
```

- [ ] **Step 2: Update the Scoop install section**

Replace `README.md:30-37`:

```markdown
### Windows — Scoop (PowerShell + Git Bash)

```pwsh
scoop bucket add ccm https://github.com/mynenikoteshwarrao/scoop-ccm
scoop install ccm
# then in Git Bash:
bash "$(scoop which ccm | xargs dirname)/../install.sh"
```
```

with:

```markdown
### Windows — Scoop (PowerShell + Git Bash)

```pwsh
scoop bucket add ccm https://github.com/mynenikoteshwarrao/scoop-ccm
scoop install ccm
```

Slash commands and hooks are wired up automatically. Restart Claude Code (or open a new session) to see `/ccm:*`.
```

- [ ] **Step 3: Update the Uninstall section**

Replace `README.md:148-160`:

```markdown
```bash
# Source clone
./uninstall.sh

# Homebrew
bash "$(brew --prefix)/opt/ccm/libexec/uninstall.sh"
brew uninstall ccm
brew untap mynenikoteshwarrao/ccm

# Scoop
bash "$(scoop which ccm | xargs dirname)/../uninstall.sh"
scoop uninstall ccm
```
```

with:

```markdown
```bash
# Source clone
./uninstall.sh

# Homebrew (reverses slash commands and hooks; preserves saved history)
brew uninstall ccm
brew untap mynenikoteshwarrao/ccm

# Scoop (reverses slash commands and hooks; preserves saved history)
scoop uninstall ccm
```

To also remove saved history at `~/.claude/context-manager/`, delete that directory manually after uninstalling.
```

- [ ] **Step 4: Verify by reading the diff**

Run: `cd /Users/koteshwar/personal/claude-context-manager && git diff README.md`

Confirm:
- No remaining `bash.*install\.sh` lines in the brew/scoop install sections.
- No remaining `bash.*uninstall\.sh` lines in the brew/scoop uninstall sections.
- The source / curl install paths (`README.md:39-50`) are left unchanged — they keep their existing behavior.
- The `# Source clone` uninstall line (`./uninstall.sh`) is left unchanged.

- [ ] **Step 5: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add README.md
git commit -m "docs: drop manual install.sh/uninstall.sh step from brew and scoop sections"
```

---

## Task 8: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add Unreleased entries**

Edit `CHANGELOG.md`. Under the `## [Unreleased]` heading, add:

```markdown
### Changed
- `brew install` and `scoop install` now wire up `/ccm:*` slash commands and
  SessionStart/SessionEnd/PreCompact hooks automatically. No more manual
  `install.sh` step.
- `brew uninstall` and `scoop uninstall` reverse the wiring (saved history
  under `~/.claude/context-manager/` is preserved by default).
- `install.sh` no longer requires the `claude` CLI to be on PATH at install
  time; it prints a note if missing and continues.

### Fixed
- `install.sh` no longer overwrites user-owned `SessionStart`, `SessionEnd`,
  or `PreCompact` hooks in `~/.claude/settings.json`. Hook registration is
  now append-and-dedupe.
- `uninstall.sh` no longer deletes the entire `SessionStart`, `SessionEnd`,
  or `PreCompact` hook arrays. Only ccm-owned entries are removed.

### Added
- `install.sh` and `uninstall.sh` accept `--from-pkg` for invocation from
  package managers (Homebrew, Scoop).

### Upgrade notes
- If you previously ran `bash install.sh` after `brew install`, you can
  safely `brew reinstall ccm` — the new install path is idempotent.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/koteshwar/personal/claude-context-manager
git add CHANGELOG.md
git commit -m "docs: changelog entries for zero-step package install"
```

---

## Task 9: Final cross-cutting verification

- [ ] **Step 1: Run the entire bats suite**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bats test/`

Expected: all tests PASS.

- [ ] **Step 2: Run the integration smoke test**

Run: `cd /Users/koteshwar/personal/claude-context-manager && bash test/integration.sh`

Expected: exit 0.

- [ ] **Step 3: Run shellcheck (CI gate)**

Run: `cd /Users/koteshwar/personal/claude-context-manager && shellcheck -S warning install.sh uninstall.sh bin/ccm lib/*.sh`

Expected: no warnings or errors.

- [ ] **Step 4: Stop and report**

Report to the user:
- All bats tests passing.
- All shellcheck checks passing.
- Homebrew formula and Scoop manifest changes are in; manual `brew install --build-from-source` verification is the next step (and requires a release tarball with a matching SHA).

Suggested next steps for the user (not part of this plan):
1. Tag a release (`v0.1.1` or `v0.2.0`) so the tap workflow builds a tarball with a real SHA.
2. Update the tap repo with the new formula.
3. Smoke-test `brew install mynenikoteshwarrao/ccm/ccm` end-to-end on a clean machine.
