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
