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
