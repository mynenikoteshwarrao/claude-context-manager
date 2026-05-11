# Zero-step Package Install — Design Spec

**Date:** 2026-05-11
**Status:** Approved for implementation planning
**Surface:** Homebrew (macOS) + Scoop (Windows) installer flows
**Related:** `2026-05-11-claude-context-manager-design.md` (parent ccm MVP spec)

---

## 1. Problem

A user who installs ccm via `brew install mynenikoteshwarrao/ccm/ccm` ends up with the `ccm` binary on PATH but no Claude Code integration. The `/` menu inside Claude Code does not list any `/ccm:*` commands, and no auto-save / auto-restore hooks are registered. The user has no signal that anything is missing beyond a one-line `caveats` message they likely scrolled past.

Reproduced on 2026-05-11: after `brew install`, `ls ~/.claude/commands/` returned "No such file or directory" and the `/` menu showed nothing ccm-related. The `ccm` CLI worked fine from the shell.

The root cause is in `dist/homebrew/Formula/ccm.rb:11-24`:

```ruby
def install
  libexec.install Dir["*"]
  bin.install_symlink libexec/"bin/ccm"   # only the binary
end

def caveats
  # tells the user to run install.sh manually — easy to miss
end
```

The formula installs the binary but does not invoke the project's `install.sh`, which is what symlinks slash commands into `~/.claude/commands/ccm/` and registers `SessionStart` / `SessionEnd` / `PreCompact` hooks in `~/.claude/settings.json`.

The `curl | bash` installer (`install-remote.sh:48`) calls `install.sh` automatically and works end-to-end. The Scoop manifest (`dist/scoop/bucket/ccm.json:11-13`) also wires `install.sh` into `post_install`, so Scoop users get zero-step UX in principle (unverified end-to-end on Windows). Only the Homebrew path is broken.

## 2. Goals and non-goals

### In scope

- After `brew install mynenikoteshwarrao/ccm/ccm`, the user opens Claude Code in any project and `/` lists `/ccm:load`, `/ccm:save`, `/ccm:history`, `/ccm:show`, `/ccm:prune`, `/ccm:update`.
- The `ccm` binary remains on the shell PATH (no regression).
- Auto-save (SessionEnd), auto-restore (SessionStart), and pre-compact flush (PreCompact) hooks are active immediately after install.
- After `brew uninstall ccm`, the slash-command symlink and ccm hook entries are removed. The user's saved context data (`~/.claude/context-manager/`) is preserved unless they pass an explicit purge flag.
- Reinstalling (`brew reinstall ccm`) does not double-register hooks.
- `install.sh` becomes safe to run when the `claude` CLI is not yet on PATH.
- Scoop parity: same robustness fixes apply, and the Scoop post_install path is verified end-to-end on Windows (Git Bash).

### Out of scope

- Linux package manager support (apt, dnf, pacman) — deferred.
- Native PowerShell installer for Windows (still relies on Git Bash bash for `install.sh`).
- Migrating ccm to a Claude Code plugin (the `plugin/manifest.json` lives in the repo but is "best-effort v0.1" and not part of this change).
- `ccm doctor` subcommand — useful for support, deferred to a follow-up.
- Honoring a `CLAUDE_CONFIG_DIR` env var instead of hardcoded `$HOME/.claude` — noted as future work; install.sh keeps the current behavior.
- Changing what the slash commands do or how the hooks behave — pure install-flow work.

## 3. Architecture

Single source of truth stays `install.sh` / `uninstall.sh`. The Homebrew formula gets a `post_install` block that invokes `install.sh`, and an `uninstall` block that invokes `uninstall.sh`. The Scoop manifest already does the equivalent; this spec only adds verification and the shared robustness fixes.

```
brew install ccm
  └─ formula def install     → bin/ccm symlinked into Homebrew prefix
  └─ formula def post_install → bash libexec/install.sh --from-brew --quiet
                                  ├─ mkdir -p ~/.claude/commands ~/.claude/context-manager
                                  ├─ symlink commands/ccm → ~/.claude/commands/ccm
                                  └─ jq-merge ccm hooks into ~/.claude/settings.json

brew uninstall ccm
  └─ formula def uninstall   → bash <stable-path>/uninstall.sh --from-brew --quiet
                                  ├─ remove ~/.claude/commands/ccm symlink
                                  └─ jq-strip ccm hook entries from settings.json
  └─ formula default cleanup → removes binary + libexec contents
```

### Stable uninstall path

`libexec` may be removed before `def uninstall` runs on some Homebrew versions. To guarantee `uninstall.sh` is available at uninstall time, `post_install` copies it to a stable location (`#{HOMEBREW_PREFIX}/share/ccm/uninstall.sh`) during install, and `def uninstall` reads it from there. `def post_uninstall` then removes that copy.

## 4. Components and changes

### 4.1 `dist/homebrew/Formula/ccm.rb`

Add:

```ruby
def post_install
  share_dir = HOMEBREW_PREFIX/"share/ccm"
  share_dir.mkpath
  cp libexec/"uninstall.sh", share_dir/"uninstall.sh"
  system "bash", libexec/"install.sh", "--from-brew", "--quiet"
end

def uninstall
  uninstall_sh = HOMEBREW_PREFIX/"share/ccm/uninstall.sh"
  system "bash", uninstall_sh, "--from-brew", "--quiet" if uninstall_sh.exist?
end

def post_uninstall
  (HOMEBREW_PREFIX/"share/ccm").rmtree if (HOMEBREW_PREFIX/"share/ccm").exist?
end
```

Shrink `caveats` to a single line: `"Restart Claude Code (or open a new session) to see /ccm:* commands."`

Keep `depends_on "bash"` and `depends_on "jq"` (install.sh and uninstall.sh need them).

### 4.2 `install.sh`

Three changes:

1. **Add `--from-brew` flag.** When set:
   - Skip the `~/.local/bin/ccm` symlink step. Brew already symlinks the binary into its own prefix.
   - In `ccm_bin_path()`, return the Homebrew-installed path (`#{HOMEBREW_PREFIX}/bin/ccm` resolved via `command -v ccm`) instead of `$HOME/.local/bin/ccm`. This is what gets written into `settings.json` hook commands.
   - Suppress the "add ~/.local/bin to PATH" notice.

2. **Make `claude` CLI optional.** Today line 27 hard-fails preflight if `claude` is not on PATH. Brew may install ccm before the user installs Claude Code, or `claude` may live in a non-standard path. Symlinks and `~/.claude/settings.json` work regardless of whether the `claude` binary is currently on PATH. Change preflight to warn (not exit) when `claude` is missing:

   ```
   Note: Claude Code CLI not detected on PATH.
   ccm hooks will activate the next time you install or launch Claude Code.
   ```

3. **Make hook registration safely append-and-dedupe.** The current `jq` filter (lines 72-79) uses `.hooks.SessionStart = [{...}]`, which **overwrites** any existing array — destroying other hooks the user has. Replace with an append + dedupe filter:

   ```jq
   .hooks //= {}
   | .hooks.SessionStart = (
       (.hooks.SessionStart // [])
       | map(select(.command | contains("ccm load") | not))
       + [{"command": ($bin + " load")}]
     )
   ```

   Same shape for `SessionEnd` and `PreCompact`. The `contains("ccm ...") | not` filter removes any prior ccm entry before re-adding, making the operation idempotent across `brew reinstall`.

### 4.3 `uninstall.sh`

Verify it:

- Removes `~/.claude/commands/ccm` symlink (only if it's a symlink to the expected target — never delete a real directory).
- Strips ccm hook entries from `~/.claude/settings.json` using the inverse of the install jq filter (keep entries whose `command` does NOT contain `ccm load`/`ccm save`/`ccm flush`).
- Leaves `~/.claude/context-manager/` untouched by default.
- Add `--purge` flag that also removes `~/.claude/context-manager/` (saved history).
- Accepts `--from-brew --quiet` flags symmetrically with install.sh.

If the existing file does not do these things, update it. (Implementation plan will inspect and report.)

### 4.4 `dist/scoop/bucket/ccm.json`

Update `post_install` to pass `--from-brew`'s Scoop equivalent — proposed flag name: `--from-pkg` to keep it generic (or `--from-scoop`). Pick one in the implementation plan. The flag's behavior is identical to `--from-brew`: skip the `~/.local/bin/ccm` symlink (Scoop manages the bin shim), use the Scoop-installed binary path for hooks.

Add `uninstaller` to the manifest:

```json
"uninstaller": {
  "script": "bash \"$dir/uninstall.sh\" --from-pkg --quiet"
}
```

### 4.5 README

Drop the "then run `bash install.sh`" step from the brew install section. The brew install path becomes a single command. Same for Scoop.

## 5. Edge cases

| Case | Handling |
|---|---|
| `jq` not installed | Already a brew/scoop dependency. Safe. |
| `claude` CLI not installed | install.sh warns and continues. Hooks register; they will fire when Claude Code is later installed. |
| User has existing `SessionStart` hooks (non-ccm) | New append-and-dedupe jq filter preserves them. |
| `brew reinstall ccm` | jq filter dedupes; no double-registration. |
| Uninstall while Claude Code is running | Symlink removal is safe; hook removal takes effect on next Claude session. |
| Saved context data on uninstall | Preserved by default. `--purge` flag opts into full removal. |
| `~/.claude/commands/ccm` exists as a real directory (not a symlink) | install.sh refuses to overwrite; prints an error pointing the user to manually resolve. uninstall.sh likewise refuses to delete. |
| `~/.claude/settings.json` malformed JSON | jq fails. install.sh aborts with a clear error and leaves settings untouched. |
| `HOMEBREW_PREFIX` differs from `/opt/homebrew` (Intel Mac, custom prefix) | Formula uses `HOMEBREW_PREFIX` token, not a hardcoded path. Safe. |
| Custom tap rename | Formula path / install instructions in README update together. |

## 6. Testing

### Automated (CI on tap repo)

- `brew install --build-from-source` then assert:
  - `test -L ~/.claude/commands/ccm`
  - `jq '.hooks.SessionStart[].command' ~/.claude/settings.json | grep -q "ccm load"`
- `brew reinstall ccm` then assert hook count is still 1 (no duplication).
- `brew uninstall ccm` then assert `~/.claude/commands/ccm` is gone and ccm hooks are gone from settings.json, but `~/.claude/context-manager/` (if present) is preserved.
- Run install.sh in a container without `claude` on PATH; assert exit 0 and warning printed.

### Manual

- macOS arm64: install on a clean `~/.claude` and on one with pre-existing user hooks; verify both work.
- Windows / Git Bash: `scoop install ccm` end-to-end (this is the verification step the original Scoop manifest skipped).
- `brew install` on a machine where `claude` is not yet installed; install Claude Code afterward; confirm hooks fire on first Claude session.

## 7. Rollout

- Single PR to the main repo containing the install.sh, uninstall.sh, and manifest edits.
- Followed by a release (`v0.2.0` or `v0.1.1` per maintainer preference) that produces a new tarball and SHA.
- Tap PR updates `Formula/ccm.rb` with the new URL, SHA, and the `post_install` / `uninstall` / `post_uninstall` blocks.
- README PR updates install instructions to drop the manual step.
- Announce in CHANGELOG: "Homebrew install now wires up slash commands and hooks automatically. Run `brew reinstall ccm` if you previously installed and ran `install.sh` manually — it is idempotent."

## 8. Open questions (for implementation plan to resolve)

- Exact flag name: `--from-brew` vs a shared `--from-pkg`. Recommend `--from-pkg` since the behavior is identical for brew and scoop.
- Whether to also update the Linux/curl path to use `--from-pkg`. Currently `install-remote.sh` calls `install.sh` with no flags, treating `~/.local/bin/ccm` as canonical. Probably leave unchanged — this design only addresses package-manager installs.
- Whether `def uninstall` in Homebrew formulas requires special handling for the case where the user has already deleted `share/ccm/uninstall.sh` manually. Defensive `if File.exist?` guard is in the design above.
