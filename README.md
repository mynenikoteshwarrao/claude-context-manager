# ccm — Claude Context Manager

> Auto-save and auto-restore project context across [Claude Code](https://docs.claude.com/claude-code) sessions. macOS and Windows (Git Bash).

[![CI](https://github.com/mynenikoteshwarrao/claude-context-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/mynenikoteshwarrao/claude-context-manager/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/mynenikoteshwarrao/claude-context-manager)](https://github.com/mynenikoteshwarrao/claude-context-manager/releases) [![License](https://img.shields.io/github/license/mynenikoteshwarrao/claude-context-manager)](LICENSE)

## What it does

Claude Code sessions are stateless: when one ends, the next has no idea what came before. `ccm` fixes that by hooking into three lifecycle events:

| When | What `ccm` does |
|---|---|
| **`SessionStart`** | Injects a "Restored Context" block: what you were working on last time + the 3 most recent session summaries for this project. |
| **`SessionEnd`** | Summarizes the just-finished session via `claude -p` and writes a timeline entry. |
| **`PreCompact`** | Refreshes the in-progress state so early-session decisions survive auto-compaction. |

The injected context is capped at ~3000 tokens so it doesn't crowd out the working session.

## Install

Pick one:

### macOS — Homebrew

```bash
brew install mynenikoteshwarrao/ccm/ccm
bash "$(brew --prefix)/opt/ccm/libexec/install.sh"
```

### Windows — Scoop (PowerShell + Git Bash)

```pwsh
scoop bucket add ccm https://github.com/mynenikoteshwarrao/scoop-ccm
scoop install ccm
# then in Git Bash:
bash "$(scoop which ccm | xargs dirname)/../install.sh"
```

### Universal — curl pipe bash

```bash
curl -fsSL https://raw.githubusercontent.com/mynenikoteshwarrao/claude-context-manager/main/install-remote.sh | bash
```

### From source

```bash
git clone https://github.com/mynenikoteshwarrao/claude-context-manager
cd claude-context-manager && ./install.sh
```

### Claude Code plugin (best-effort)

```
/plugin install mynenikoteshwarrao/claude-context-manager
```

The plugin path follows whatever Claude Code's current plugin contract is and may change. If it doesn't work, use any of the four channels above.

### After install

1. Make sure `~/.local/bin` is on `PATH`. The installer prints a reminder if it isn't.
   ```bash
   export PATH="$HOME/.local/bin:$PATH"   # add to ~/.zshrc or ~/.bashrc
   ```
2. **Restart Claude Code** so the new hooks load.

That's it. From the next session onward, `ccm` runs automatically.

## CLI reference

| Subcommand | What it does |
|---|---|
| `ccm version` | Print version. |
| `ccm id` | Print the project ID for the current dir. |
| `ccm load` | Print the restored-context block to stdout (debugging). |
| `ccm save <transcript>` | Summarize a transcript JSONL, write a timeline entry, update `current.md`. |
| `ccm flush <transcript>` | Refresh `current.md` only — used by the `PreCompact` hook. |
| `ccm history` | List session summaries, newest first. |
| `ccm show N` | Print full text of summary `#N`. |
| `ccm prune --older-than=30d` | Delete summaries older than the cutoff. |
| `ccm prune --orphans --list-only` | List project dirs whose source repo no longer exists locally. |
| `ccm update` | Self-update; detects install channel (brew/scoop/git/tarball) and dispatches. |

## Slash commands

Inside a Claude Code session:

- `/ccm:load` — print restored context
- `/ccm:save` — save the current session manually
- `/ccm:history` — list summaries
- `/ccm:show N` — show summary N
- `/ccm:prune` — interactive cleanup
- `/ccm:update` — self-update

## How project identity works

`ccm` groups sessions by *project*. Project ID is, in order:

1. Your `git remote get-url origin`, URL-encoded for filesystem safety. → Same repo cloned to two paths shares context.
2. Otherwise `SHA1(absolute path)`. → A non-git scratch dir is unique per path.

Run `ccm id` in any directory to see what it resolves to.

## Storage layout

```
~/.claude/context-manager/
  <project-id>/
    current.md            # what you were working on at last session end
    timeline/
      2026-05-11-1820.md  # one markdown file per saved session
      ...
    transcripts.jsonl     # pointers to the raw Claude Code transcripts
    meta.json             # project metadata
  log                     # ccm's own operational log
```

Storage is local-only. Nothing is uploaded anywhere.

## Configuration

A few environment variables tune behavior. Set them before launching Claude Code.

| Variable | Default | Meaning |
|---|---|---|
| `CCM_LOAD_TOKEN_BUDGET` | `3000` | Soft cap on the size of the injected context block. |
| `CCM_SAVE_TIMEOUT` | `60` | Seconds to wait for `claude -p` summarization before falling back to a head/tail stub. |
| `CCM_RELEASE_REPO` | `mynenikoteshwarrao/claude-context-manager` | Override the upstream repo used by `ccm update`. |

## Upgrading

```bash
ccm update     # detects channel and dispatches
```

If that fails for any reason, the channel-native upgrade always works:

```bash
brew upgrade ccm                                    # Homebrew
scoop update ccm                                    # Scoop
git -C <clone> pull && <clone>/install.sh           # source clone
curl -fsSL https://raw.githubusercontent.com/mynenikoteshwarrao/claude-context-manager/main/install-remote.sh | bash   # tarball/curl
```

## Uninstall

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

The uninstaller will ask whether to keep `~/.claude/context-manager/` (your stored history). Pass `--keep-storage` to skip the prompt and retain it.

## Troubleshooting

**`ccm: command not found` after install**
`~/.local/bin` isn't on `PATH`. Add `export PATH="$HOME/.local/bin:$PATH"` to your shell rc and reopen.

**No "Restored Context" block on session start**
Check the hook is wired:
```bash
jq '.hooks.SessionStart' ~/.claude/settings.json
```
If empty, rerun the installer (or the post-install hook step for brew/scoop).

**Sessions aren't being saved**
Check `~/.claude/context-manager/log` for errors. The most common cause is `claude` CLI being missing or unauthenticated — `ccm` falls back to a head/tail stub in that case, so saves never silently drop but quality drops.

**Summaries are crowding the session context**
Lower the budget or prune old summaries:
```bash
export CCM_LOAD_TOKEN_BUDGET=1500
ccm prune --older-than=30d --yes
```

## Development

```bash
# macOS prereqs
brew install bash jq bats-core

# Windows (Git Bash) prereqs
scoop install jq bats

# Run tests
bats test/                       # unit tests
./test/integration.sh            # end-to-end smoke

# CI runs the same on macos-latest and windows-latest via GitHub Actions.
```

Contributions welcome. Open an issue first for anything non-trivial.

## License

MIT — see [`LICENSE`](LICENSE).
