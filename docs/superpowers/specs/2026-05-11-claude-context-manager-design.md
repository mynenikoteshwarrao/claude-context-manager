# Claude Context Manager — Design Spec (MVP)

**Date:** 2026-05-11
**Status:** Approved for implementation planning
**Surface:** Claude Code only (macOS and Windows)

---

## 1. Problem

A Claude Code session loses everything when it ends. The next time you `cd` into the same project and run `claude`, the agent has no memory of what you were working on, what got decided, or where you left off. Within a single long session, the same loss happens when Claude Code auto-compacts the context window.

The user works across multiple projects and wants each project's context to:

1. Persist across sessions on the same machine.
2. Survive mid-session compaction.
3. Be project-scoped (no bleed between projects).
4. Auto-load on session start without manual steps.
5. Be controllable manually when needed (re-inject, force-save, browse history).

## 2. Goals and non-goals

### In scope (MVP)

- Resume Claude Code sessions in a project without re-explaining what was being worked on.
- Maintain a per-project timeline of session summaries the user can scroll back through.
- Checkpoint summaries before auto-compaction so early-session decisions are not lost.
- Track multiple projects independently.
- Both automatic (hook-driven) and manual (slash command) load/save.
- Run on **macOS** (native bash) and **Windows** (Git Bash). Single shared codebase.
- Distribute via **Claude Code plugin** (primary), **curl + GitHub Releases** (fallback), and native **Homebrew + Scoop** packages. Self-update via `ccm update`.

### Out of scope (deferred to future specs)

- Linux support (likely "free" via the bash codebase but not in MVP acceptance criteria).
- Claude Desktop integration (no filesystem hooks available).
- Claude API SDK integration (different audience: app builders).
- Cross-machine sync (git-syncable storage or cloud).
- TUI/web viewer for browsing history (slash commands only in MVP).
- Smart relevance ranking of timeline entries (MVP always injects the most recent N).
- Auto-extraction of structured facts into the existing auto-memory directory (deferred to Phase 1.5).
- Search across timeline entries (`ccm search` command).
- Parallel-session conflict handling (two terminals in the same project — MVP is last-writer-wins).
- Native PowerShell implementation on Windows (Git Bash is the only supported Windows shell in MVP).
- npm distribution (would require Node as a runtime dep — explicitly avoided).

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Claude Code session (in any project directory)             │
│                                                             │
│  ┌───────────┐  SessionStart   ┌───────────┐   ┌──────────┐ │
│  │  hook     │ ───────────────►│  ccm load │──►│ injected │ │
│  └───────────┘                 └───────────┘   │ context  │ │
│                                                └──────────┘ │
│  ┌───────────┐  SessionEnd     ┌───────────┐                │
│  │  hook     │ ───────────────►│  ccm save │                │
│  └───────────┘                 └───────────┘                │
│  ┌───────────┐  PreCompact     ┌───────────┐                │
│  │  hook     │ ───────────────►│ ccm flush │                │
│  └───────────┘                 └───────────┘                │
│                                                             │
│  Slash commands (manual control):                           │
│    /ccm:load     → ccm load                                 │
│    /ccm:save     → ccm save                                 │
│    /ccm:history  → ccm history                              │
│    /ccm:show N   → ccm show N                               │
│    /ccm:prune    → ccm prune                                │
│    /ccm:update   → ccm update                               │
└─────────────────────────────────────────────────────────────┘
              │            │            │
              ▼            ▼            ▼
┌──────────────────────────────────────────────────────────────┐
│ Storage layout (paths shown POSIX-style; resolved per-OS)    │
│                                                              │
│ ~/.claude/context-manager/<project-id>/                      │
│   current.md           ← in-progress state (overwritten)     │
│   timeline/                                                  │
│     2026-05-11-1340.md ← session summary                     │
│     2026-05-11-1820.md                                       │
│     ...                                                      │
│   transcripts.jsonl    ← pointers to convo files             │
│   meta.json            ← project ID, git remote, created_at  │
│                                                              │
│ ~/.claude/projects/<hash>/memory/   (existing, reused)       │
│   MEMORY.md, *.md      ← structured facts                    │
│                                                              │
│ ~/.claude/context-manager/log       ← all ccm operations     │
└──────────────────────────────────────────────────────────────┘
```

### Single binary: `ccm`

A bash script installed at `~/.local/bin/ccm` (symlinked from the repo on macOS; symlink-equivalent on Git Bash Windows — see §6). Subcommands:

| Subcommand | Purpose |
|---|---|
| `ccm id` | Print the resolved project ID for the cwd |
| `ccm load` | Read storage and emit the injected context block to stdout |
| `ccm save` | Read latest session transcript, summarize, write timeline entry + update `current.md` |
| `ccm flush` | Light pre-compact save: regenerate `current.md` only |
| `ccm history` | List timeline entries with timestamps |
| `ccm show N` | Print timeline entry #N to stdout |
| `ccm prune` | Interactively delete old timeline entries or orphaned projects |
| `ccm update` | Check for a newer release and reinstall in-place |
| `ccm version` | Print current version (read from VERSION file) |

### Hooks

Registered in `~/.claude/settings.json` at user level (not project level), so every project benefits from the same install. Each hook is a thin shell-out to `ccm`. Hook command strings use POSIX absolute paths (`/c/Users/<name>/.local/bin/ccm` on Windows Git Bash, `/Users/<name>/.local/bin/ccm` on macOS) — `install.sh` writes the correct form for the host.

### Slash commands

Installed at `~/.claude/commands/ccm/<name>.md`. Each file is a short markdown stub with a `!ccm <subcommand>` line so Claude Code's slash command system executes the binary and injects stdout.

## 4. Data flow

### 4.1 Load (SessionStart hook fires)

1. Resolve project ID:
   - Run `git remote get-url origin 2>/dev/null`. If non-empty, that is the ID (URL-encoded).
   - Otherwise, compute `printf '%s' "$PWD" | shasum -a 1 | cut -d' ' -f1` (macOS) or `printf '%s' "$PWD" | sha1sum | cut -d' ' -f1` (Windows Git Bash) and use that hash. `ccm` detects which is available at runtime.
2. Storage dir = `~/.claude/context-manager/<project-id>/`. If it does not exist, exit 0 silently (first run in this project).
3. Read `current.md` (the "where we left off" bookmark).
4. Read the most recent 3 entries from `timeline/` in reverse chronological order.
5. Format into a single markdown block with this structure:
   ```markdown
   # Claude Context Manager — Restored Context

   ## In progress (from last session)
   <contents of current.md>

   ## Recent session summaries
   ### <timestamp 1>
   <summary 1>
   ### <timestamp 2>
   <summary 2>
   ### <timestamp 3>
   <summary 3>

   ---
   *Older summaries: `/ccm:history`. Full transcripts: `/ccm:show N`.*
   ```
6. Emit this block to stdout. The SessionStart hook's `additionalContext` field (or equivalent stdout-capture mechanism) prepends it to the system prompt for the session.
7. Hard cap: 3000 tokens. If the rendered block exceeds the cap, truncate from the oldest timeline entry inward; `current.md` is never truncated.

### 4.2 Save (SessionEnd hook fires)

1. Resolve project ID (same as load).
2. Locate the just-ended session's transcript at `~/.claude/projects/<dir-hash>/<session-id>.jsonl`. Use the `$CLAUDE_SESSION_ID` environment variable that hooks receive; fall back to "most recently modified `.jsonl` in the project dir."
3. Pipe the transcript into `claude -p` with the prompt at `prompts/summarize.txt`. The prompt asks for:
   - A ≤200-word summary of what was worked on, what got decided, what's left open.
   - A separate "in progress" section: the specific things actively being worked on at session end.
   - (Phase 1.5, not MVP) Any new facts to write into auto-memory.
4. Parse the response into two parts (summary, in-progress).
5. Write the summary to `timeline/YYYY-MM-DD-HHMM.md`.
6. Overwrite `current.md` with the in-progress section.
7. Append a pointer line to `transcripts.jsonl`:
   ```json
   {"ts":"2026-05-11T18:20:00Z","transcript":"/path/to/session.jsonl","summary":"timeline/2026-05-11-1820.md"}
   ```
8. Update `meta.json` with `last_save_at`.

### 4.3 Flush (PreCompact hook fires)

Lighter than save. Goal: do not lose pre-compaction state.

1. Resolve project ID, locate transcript.
2. Run a shorter `claude -p` prompt asking only for the current in-progress state (no full summary).
3. Overwrite `current.md`.
4. **Do not** write a new timeline entry (avoids duplicates — the eventual SessionEnd save will produce the canonical entry).

### 4.4 Stop hook — unused in MVP

The Stop hook fires after every assistant turn. Too noisy and expensive for summarization. Reserved for a future "live in-progress tracker" feature.

## 5. Components and files we ship

```
claude-context-manager/                  # main repo
├── bin/
│   └── ccm                              # main entry; dispatches to lib/*.sh
├── lib/
│   ├── id.sh                            # resolve project ID
│   ├── load.sh                          # render injected context block
│   ├── save.sh                          # full save (summarize + write timeline)
│   ├── flush.sh                         # pre-compact lightweight save
│   ├── history.sh                       # list/show timeline entries
│   ├── prune.sh                         # interactive cleanup
│   ├── update.sh                        # self-update logic
│   ├── common.sh                        # shared helpers (paths, logging, token budget)
│   └── platform.sh                      # OS detection + shasum/sha1sum + path conversion
├── commands/                            # Claude Code slash command files
│   └── ccm/
│       ├── load.md                      # /ccm:load    → !ccm load
│       ├── save.md                      # /ccm:save    → !ccm save
│       ├── history.md                   # /ccm:history → !ccm history
│       ├── show.md                      # /ccm:show    → !ccm show "$ARGUMENTS"
│       ├── prune.md                     # /ccm:prune   → !ccm prune
│       └── update.md                    # /ccm:update  → !ccm update
├── prompts/
│   ├── summarize.txt                    # prompt for full session summarization
│   └── flush.txt                        # prompt for pre-compact in-progress extraction
├── plugin/
│   └── manifest.json                    # Claude Code plugin manifest (hooks + commands)
├── install.sh                           # macOS/Linux install (also runs under Git Bash)
├── install.bat                          # Windows entry point that calls install.sh under Git Bash
├── uninstall.sh                         # reverse install.sh
├── .github/
│   └── workflows/
│       ├── ci.yml                       # bats test matrix on macos + windows
│       └── release.yml                  # tag-triggered release pipeline
├── test/
│   ├── test-id.bats
│   ├── test-load.bats
│   ├── test-save.bats
│   ├── test-flush.bats
│   ├── test-history.bats
│   ├── test-prune.bats
│   ├── test-update.bats
│   ├── test-install.bats
│   ├── test-platform.bats
│   └── fixtures/
│       ├── transcripts/                 # sample .jsonl files
│       ├── storage/                     # expected post-save storage state
│       └── settings/                    # sample ~/.claude/settings.json
├── README.md
└── VERSION                              # SemVer string, e.g. "0.1.0"

homebrew-ccm/                            # separate repo (Mac users)
└── Formula/
    └── ccm.rb                           # Homebrew formula

scoop-ccm/                               # separate repo (Windows users)
└── bucket/
    └── ccm.json                         # Scoop manifest
```

## 6. Technology stack

### 6.1 Shared across platforms

| Tech | Purpose | Version |
|---|---|---|
| Bash | Primary language for `ccm` and all lib scripts | 4+ |
| `jq` | JSON read/write (`transcripts.jsonl`, `meta.json`, `settings.json` merges) | 1.6+ |
| `claude` CLI | Summarization via `claude -p`; already installed by user | latest |
| SHA1 hashing | Project ID fallback when no git remote | `shasum -a 1` (macOS) / `sha1sum` (Git Bash) |
| `bats-core` | Test framework (dev-only) | 1.10+ |
| POSIX coreutils | `cat`, `cut`, `sed`, `awk`, `find`, `mkdir`, `date`, `ln` | system |

### 6.2 macOS

- **OS:** macOS 12 (Monterey) or newer.
- **Default bash is 3.2** — `install.sh` checks `bash --version` and aborts with a Homebrew install hint if bash 4+ is not found.
- **Install paths:**
  - Binary: symlink `<repo>/bin/ccm` → `/Users/<user>/.local/bin/ccm`
  - Commands: symlink `<repo>/commands/ccm` → `/Users/<user>/.claude/commands/ccm`
  - Settings: merge into `/Users/<user>/.claude/settings.json`
- **User install instructions** (documented in README):
  ```sh
  brew install bash jq
  brew install bats-core   # only needed to run tests
  ./install.sh
  ```
- **Hashing:** `shasum -a 1` (preinstalled).
- **No path translation needed** — POSIX absolute paths are native.

### 6.3 Windows

- **OS:** Windows 10 (build 19041+) or Windows 11.
- **Shell:** Git Bash, bundled with **Git for Windows** ≥ 2.40. Provides bash 5+, `sha1sum`, coreutils, and `cygpath` for path conversion. This is the only supported Windows shell in MVP — PowerShell and cmd.exe are not.
- **Package manager:** Scoop (preferred) or Chocolatey, for installing `jq` and `bats-core`.
- **Install paths** (resolved by `lib/platform.sh`):
  - Binary: symlink `<repo>/bin/ccm` → `~/.local/bin/ccm` (POSIX path `/c/Users/<user>/.local/bin/ccm`). Git Bash supports symlinks when Developer Mode is enabled, or via `MSYS=winsymlinks:nativestrict`. `install.sh` sets this env var inline before symlinking; if it still fails (e.g., older Git Bash without symlink support), it falls back to a small wrapper shim that calls the repo's `bin/ccm` directly.
  - Commands: same symlink/shim approach for `~/.claude/commands/ccm`.
  - Settings: merge into `~/.claude/settings.json` (resolves to `C:\Users\<user>\.claude\settings.json`).
- **Hook command strings in `settings.json`** are written as POSIX paths (`/c/Users/<user>/.local/bin/ccm load`) — Claude Code on Windows executes them via the configured shell, and Git Bash interprets POSIX paths correctly.
- **Path translation:** `lib/platform.sh` wraps `cygpath -u` (Windows-to-POSIX) and `cygpath -w` (POSIX-to-Windows) when crossing the boundary — specifically when reading the `transcript_path` from Claude Code's transcripts (which may be Windows-style) or when emitting paths consumed by tools that need Windows form. On macOS, the wrappers are no-ops.
- **User install instructions** (documented in README):
  ```sh
  # In Git Bash:
  scoop install jq
  scoop install bats          # only needed to run tests
  ./install.sh
  ```
- **Hashing:** `sha1sum` (provided by Git Bash coreutils).

### 6.4 Platform abstraction layer (`lib/platform.sh`)

A thin layer all other lib scripts source. Exports:

| Function / var | macOS | Windows (Git Bash) |
|---|---|---|
| `CCM_OS` | `macos` | `windows` |
| `ccm_sha1 <stdin>` | `shasum -a 1` | `sha1sum` |
| `ccm_path_posix <path>` | identity | `cygpath -u <path>` |
| `ccm_path_native <path>` | identity | `cygpath -w <path>` |
| `ccm_home` | `$HOME` | `$HOME` (Git Bash already normalizes) |
| `ccm_symlink <src> <dest>` | `ln -s` | `MSYS=winsymlinks:nativestrict ln -s`, fall back to shim |
| `ccm_log <msg>` | `>> ~/.claude/context-manager/log` | same |

OS detection is a single line at script top: `case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) CCM_OS=windows ;; Darwin) CCM_OS=macos ;; *) CCM_OS=linux ;; esac`. Linux falls through with `shasum`/`sha1sum` autodetect and is expected to work but isn't an MVP acceptance criterion.

### 6.5 Why not Python / Node / Go

Considered and rejected for MVP:

- **Python (uv single-file):** would eliminate shell quirks, but doubles install footprint and adds a Python runtime dependency our users may not want. Bash + Git Bash covers both platforms cleanly enough.
- **Node/TypeScript:** Claude Code's stack, but installing Node just for ccm is heavy. No need for a TUI yet.
- **Go (static binary):** appealing for distribution, but means two binaries (mac/windows) to build and sign per release. Premature for MVP.

If future scope adds Linux as a first-class target, or if Windows path/symlink edge cases multiply, **migrating to Python via `uv` is the most likely Phase 2 move**. The bash code is small enough that a rewrite is cheap.

## 7. Install and uninstall behavior

`./install.sh` (cross-platform, runs under bash on macOS and Git Bash on Windows):

1. Detect OS via `lib/platform.sh`. Verify `bash` (≥ 4), `jq`, `claude`, and the platform's SHA1 tool are on PATH. Abort with platform-specific install hints if not.
2. Create `~/.local/bin/`, `~/.claude/`, `~/.claude/commands/`, `~/.claude/context-manager/` if missing.
3. Symlink `<repo>/bin/ccm` → `~/.local/bin/ccm` (via `ccm_symlink`).
4. Symlink `<repo>/commands/ccm` → `~/.claude/commands/ccm`.
5. Read `~/.claude/settings.json` (create if missing). Diff the existing `hooks` block against ours; if there are conflicting entries, print a unified diff and ask `[y/N]` before overwriting. Otherwise merge silently. Hook command strings use POSIX absolute paths so they work identically on both OSes.
6. Verify `~/.local/bin` is on PATH; warn and print the appropriate `.zshrc` / `.bashrc` snippet if not.
7. Print a verification command: `cd <some git repo> && claude -p "hi" && ccm history`.

`./install.bat` (Windows convenience entry point):

- Single-line wrapper that locates `bash.exe` from a Git for Windows install (`%PROGRAMFILES%\Git\bin\bash.exe`) and execs `install.sh`. Lets Windows users double-click to install if they prefer not to open Git Bash manually.

`./uninstall.sh` reverses each step, prompting before deleting any storage in `~/.claude/context-manager/`.

## 8. Distribution

Four channels, ranked by recommended user preference. All resolve to the same source — the same `<repo>` is the source of truth; each channel is a different way to put it on the user's machine.

### 8.1 Channel A — Claude Code plugin (primary)

`plugin/manifest.json` registers hooks and slash commands declaratively. Users install with one command:

```
/plugin install <you>/claude-context-manager
```

Claude Code's plugin system clones the repo to its plugin directory, reads the manifest, and registers the hooks + slash commands automatically. No `./install.sh` needed in this path — the plugin manifest *is* the install descriptor.

**Caveats to verify during planning:**

- Whether the plugin system supports user-level hooks (vs. only per-project).
- Whether plugin slash commands can shell out via `!ccm` syntax with our exact path conventions.
- Whether plugin install honors our cross-platform symlink requirements (or whether the plugin runtime handles binary linkage itself).

If any of these gate fail, channel A is documented as "not yet supported" in v0.1 and reintroduced in a later release. Channels B/C/D cover the full user base in the meantime.

### 8.2 Channel B — curl-pipe-bash + GitHub Releases (fallback, universal)

The universal one-liner. Works identically on macOS and Windows Git Bash:

```sh
curl -fsSL https://raw.githubusercontent.com/<you>/claude-context-manager/main/install-remote.sh | bash
```

`install-remote.sh` is a tiny bootstrap (≤ 50 lines) that:

1. Detects OS.
2. Determines the latest release tag from GitHub's API.
3. Downloads the `.tar.gz` asset to `~/.local/share/ccm/`.
4. Extracts it.
5. Runs the bundled `install.sh`.

**For security-conscious users**, the README documents the alternative:

```sh
git clone https://github.com/<you>/claude-context-manager
cd claude-context-manager
./install.sh
```

GitHub Releases hosts the canonical artifacts:

- `claude-context-manager-<version>.tar.gz` — source tree, includes `install.sh`.
- `SHA256SUMS` — checksum file for verification.
- `SHA256SUMS.asc` — GPG signature (if/when we set up signing; deferred decision).

### 8.3 Channel C — Homebrew tap (macOS) and Scoop bucket (Windows)

For users who prefer native package managers.

**Homebrew (separate `homebrew-ccm` repo):**

```sh
brew tap <you>/ccm
brew install ccm
brew upgrade ccm
```

`Formula/ccm.rb` declares dependencies (`bash`, `jq`) and points at the latest GitHub Release tarball. The formula's `install` block runs `./install.sh --no-deps` (skipping the dep checks Homebrew already enforced).

**Scoop (separate `scoop-ccm` repo):**

```sh
scoop bucket add ccm https://github.com/<you>/scoop-ccm
scoop install ccm
scoop update ccm
```

`bucket/ccm.json` declares dependencies (`jq`, `git`) and uses Scoop's `post_install` hook to run `install.sh` against the user's `$HOME`.

Both Formula and manifest are updated automatically by the release workflow (§9).

### 8.4 Channel D — Self-update via `ccm update`

Independent of how the user first installed. Run anytime:

```sh
ccm update
```

Behavior:

1. Read installed version from VERSION file at the install location.
2. Detect install channel by inspecting paths: a `.git/` directory in the install root → clone install; absence of `.git/` but presence of `~/.local/share/ccm/` → tarball install; install location under Homebrew's prefix → Homebrew install; under Scoop's apps dir → Scoop install; install location under Claude Code's plugin dir → plugin install.
3. Dispatch the right update:
   - **Clone:** `git pull` in the repo, then re-run `./install.sh`.
   - **Tarball:** re-run the curl-pipe-bash bootstrap.
   - **Homebrew:** print `brew upgrade ccm` and exit (do not call brew from inside ccm — that's a layering violation).
   - **Scoop:** print `scoop update ccm` and exit.
   - **Plugin:** print the appropriate `/plugin update ccm` command for Claude Code and exit.
4. Print before/after version, ask the user to restart Claude Code so hooks reload.

`ccm update --check` is a no-op variant: just prints "Update available: 0.1.2 → 0.2.0" if newer, exits 0. Used by an optional `SessionStart` hook line to nudge users (off by default; opt-in via `~/.claude/context-manager/config`).

## 9. Versioning and release process

### 9.1 Versioning

Strict [SemVer 2.0](https://semver.org). Single source of truth: the `VERSION` file at repo root, format `MAJOR.MINOR.PATCH` (no `v` prefix). `ccm version` reads this file.

- **MAJOR** bump: storage layout change requiring migration, breaking subcommand change, breaking hook contract change.
- **MINOR** bump: new subcommand, new slash command, new optional config knob.
- **PATCH** bump: bug fix, doc fix, no user-visible behavior change.

`v0.x.y` series is pre-1.0 — minor bumps may include small breaking changes if necessary (documented in CHANGELOG).

### 9.2 Release workflow (`.github/workflows/release.yml`)

Triggered on push of a tag matching `v*.*.*`:

1. Validate tag matches `VERSION` file contents (fail fast if drift).
2. Run the full bats suite on `macos-latest` and `windows-latest`. Abort on any failure.
3. Build the source tarball: `git archive --format=tar.gz --prefix=claude-context-manager-${VERSION}/ ${TAG}`.
4. Compute `SHA256SUMS`.
5. Create a GitHub Release with the tarball + checksums attached. Body is auto-extracted from CHANGELOG.md section matching the version.
6. **Update Homebrew tap:** clone `homebrew-ccm`, regenerate `Formula/ccm.rb` with new URL + sha256, commit + push.
7. **Update Scoop bucket:** clone `scoop-ccm`, regenerate `bucket/ccm.json` with new URL + hash, commit + push.
8. **(Future) Update Claude Code plugin registry:** if a plugin registry exists, publish the manifest. Otherwise no-op for now.

### 9.3 CHANGELOG

`CHANGELOG.md` at repo root, [Keep a Changelog](https://keepachangelog.com/) format. Each release section is generated from PR labels (`feat:`, `fix:`, `docs:`, `chore:`). Manually editable before tagging.

### 9.4 Release authority

In v0.x, only the repo maintainer (you) holds the release token. The release workflow uses a dedicated `GITHUB_TOKEN` with `contents: write` on the main repo and `contents: write` on both the homebrew-ccm and scoop-ccm repos. Token scope is the narrowest that works.

## 10. Error handling

The iron rule: **the context manager never blocks or breaks a Claude Code session.** Every failure path degrades to "no-op + write to `~/.claude/context-manager/log`".

| Failure | Behavior |
|---|---|
| `claude` CLI not on PATH | `save`/`flush` skip LLM summarization. `save` writes a stub timeline entry containing the transcript's first 50 and last 50 lines. User sees a one-line warning on next session load. |
| Summarization fails or times out (>60s) | Same fallback: stub entry. Log the error. |
| Storage dir not writable | Hook exits 0 to stderr with a log line. Session proceeds normally. |
| Project ID changes (new git remote added) | Old storage becomes orphaned, not deleted. `ccm prune` lists orphans interactively. New ID starts fresh on next save. |
| Token budget exceeded on load | Truncate timeline entries from oldest inward. `current.md` is preserved. If even `current.md` alone exceeds the budget, truncate `current.md` to the budget with a `[truncated]` marker. |
| `settings.json` hook merge conflict | `install.sh` shows a unified diff and prompts before overwriting. Never silent. |
| Transcript not found (race with cleanup) | Write a minimal `current.md` containing only the timestamp and a `"no transcript available"` note. No timeline entry. |
| Parallel sessions in same project | Last write wins. Documented as a known limitation. No locking in MVP. |
| `jq` not installed | Install script aborts with a clear message; ccm runtime checks and emits a one-line warning, then runs in degraded mode (no JSON ops, skip transcripts.jsonl updates). |
| **Windows: symlink fails** | `install.sh` falls back to a wrapper shim at the target location that execs the real script. User is told once. |
| **Windows: `cygpath` missing** | Detect at runtime; abort install with a "your Git Bash is too old, please update Git for Windows" message. |
| **Windows: path crosses Git Bash boundary unexpectedly** | `lib/platform.sh` normalizes; if normalization fails, log the raw value and continue with best-effort. |
| **Windows: file path contains spaces** (e.g., `C:\Program Files\...`) | All path handling quotes consistently; covered by `test-platform.bats`. |
| **Update: GitHub API rate-limited or offline** | `ccm update` prints "couldn't reach GitHub" and exits non-zero. Never partially upgrades. |
| **Update: SHA256 mismatch on downloaded tarball** | Abort, leave existing install untouched, surface the mismatch. |

All errors and warnings are appended to `~/.claude/context-manager/log` with timestamp, OS, project ID, and subcommand.

## 11. Testing strategy

### Unit tests (bats-core)

One `test-<lib>.bats` file per lib. Tests run against fixture data — no real `claude` CLI calls (mocked).

- `test-id.bats`: project ID resolution from various git/non-git directories on both OSes.
- `test-load.bats`: rendering the injected block from various storage states (empty, 1 entry, 10 entries, oversized).
- `test-save.bats`: parsing `claude -p` output, writing timeline + current.md correctly.
- `test-flush.bats`: in-progress extraction only, no timeline entry created.
- `test-history.bats`: listing and showing entries by index and by date.
- `test-prune.bats`: interactive prune flow (driven by `bats` input stubs).
- `test-update.bats`: install-channel detection, version-comparison logic, dry-run dispatch for each channel (no real network calls).
- `test-install.bats`: idempotent install, merge-vs-overwrite logic, uninstall reverses everything.
- `test-platform.bats`: OS detection, SHA1 helper, path conversion no-op on macOS / round-trip on Windows, symlink + shim fallback.

### CI matrix (`.github/workflows/ci.yml`)

The bats suite runs on `macos-latest` and `windows-latest` (with Git Bash) on every PR. Both must pass for a green build.

### Integration test

Run `./test/integration.sh` which:

1. Creates a temp `$HOME` and `$PWD` (a fake git repo).
2. Runs `./install.sh` with the temp `$HOME`.
3. Drops a canned transcript fixture into the expected location.
4. Invokes `ccm save` directly (skipping the hook for determinism).
5. Asserts: `timeline/` has one entry, `current.md` exists, `transcripts.jsonl` has one line, `meta.json` is well-formed.
6. Invokes `ccm load`, captures stdout, asserts it contains the expected sections.
7. Tears down the temp `$HOME`.

### Manual acceptance

After local install (run on **each** target OS):

1. **Cold start**: in a new project, run `claude -p "what's in the context manager?"` — verify the response says "no prior context" (graceful empty state).
2. **First save**: run `claude` in this repo, ask a question, exit. Verify a new file appears in `~/.claude/context-manager/<id>/timeline/`.
3. **Restore**: run `claude` again — verify the assistant's first response references the prior session's summary.
4. **Mid-session compaction**: run a session long enough to trigger compaction. Verify `current.md` updated mid-session without a duplicate timeline entry.
5. **Slash command**: in a session, type `/ccm:history` — verify the list renders.
6. **Multiple projects**: switch to a different repo, run `claude`, verify no bleed.
7. **Self-update**: from one version, tag the next, watch the release workflow publish, then run `ccm update` and verify the new version is active.
8. **(Windows only)**: verify path-with-spaces works by installing into a user account whose name contains a space (or symlink the test fixture into `~/Documents/My Repos/test`).

## 12. Open questions for the implementation plan

These are decisions to confirm during planning, not blockers for spec approval:

- Exact format/schema of `meta.json` and `transcripts.jsonl` — finalize in plan.
- Whether `/ccm:show` takes an integer index or a date string (or both). Slash command file uses `$ARGUMENTS` placeholder.
- Exact wording of `prompts/summarize.txt` — will iterate during implementation against real transcripts.
- Whether `install.sh` should also offer to update an existing global `bashrc`/`zshrc` to put `~/.local/bin` on PATH, or just print a message.
- Whether Windows install should print a Developer Mode reminder upfront, or only when the first symlink attempt fails.
- **Claude Code plugin system constraints** (the §8.1 caveats): what exactly the plugin manifest supports for hooks, slash commands, and cross-platform paths. If gaps exist, channel A ships in a later release.
- Whether GPG-signing release artifacts is in v0.1 or deferred.

## 13. Success criteria

The MVP is successful when:

1. After running `./install.sh` once (on either macOS or Windows Git Bash), no further configuration is needed.
2. Running `claude` in a project where a prior session exists results in the agent acknowledging prior work without the user re-explaining.
3. Token cost of injected context on session start is ≤3000 tokens, measured across 10 representative sessions.
4. Zero documented cases of the context manager blocking or breaking a Claude Code session.
5. `/ccm:history`, `/ccm:show`, and `/ccm:prune` all work as documented in the README.
6. The full test suite passes (`bats test/`) on both `macos-latest` and `windows-latest` in CI.
7. A user can install via **at least three** of {Claude Code plugin, curl one-liner, Homebrew tap, Scoop bucket} (channel A is best-effort; B, C-Mac, and C-Win must all work for v0.1).
8. Tagging a release pushes updated Formula and Scoop manifest automatically; `ccm update` upgrades a running install in-place.

---

*Approved by user 2026-05-11. Next step: implementation plan via `superpowers:writing-plans`.*
