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
