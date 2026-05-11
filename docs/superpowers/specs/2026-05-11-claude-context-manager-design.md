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
claude-context-manager/
├── bin/
│   └── ccm                      # main entry; dispatches to lib/*.sh
├── lib/
│   ├── id.sh                    # resolve project ID
│   ├── load.sh                  # render injected context block
│   ├── save.sh                  # full save (summarize + write timeline)
│   ├── flush.sh                 # pre-compact lightweight save
│   ├── history.sh               # list/show timeline entries
│   ├── prune.sh                 # interactive cleanup
│   ├── common.sh                # shared helpers (paths, logging, token budget)
│   └── platform.sh              # OS detection + shasum/sha1sum + path conversion
├── commands/                    # Claude Code slash command files
│   └── ccm/
│       ├── load.md              # /ccm:load    → !ccm load
│       ├── save.md              # /ccm:save    → !ccm save
│       ├── history.md           # /ccm:history → !ccm history
│       ├── show.md              # /ccm:show    → !ccm show "$ARGUMENTS"
│       └── prune.md             # /ccm:prune   → !ccm prune
├── prompts/
│   ├── summarize.txt            # prompt for full session summarization
│   └── flush.txt                # prompt for pre-compact in-progress extraction
├── install.sh                   # macOS install (symlink + register hooks)
├── install.bat                  # Windows entry point that calls install.sh under Git Bash
├── uninstall.sh                 # reverse install.sh
├── test/
│   ├── test-id.bats
│   ├── test-load.bats
│   ├── test-save.bats
│   ├── test-flush.bats
│   ├── test-history.bats
│   ├── test-prune.bats
│   ├── test-install.bats
│   ├── test-platform.bats
│   └── fixtures/
│       ├── transcripts/         # sample .jsonl files
│       ├── storage/             # expected post-save storage state
│       └── settings/            # sample ~/.claude/settings.json
├── README.md
└── VERSION
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

## 8. Error handling

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

All errors and warnings are appended to `~/.claude/context-manager/log` with timestamp, OS, project ID, and subcommand.

## 9. Testing strategy

### Unit tests (bats-core)

One `test-<lib>.bats` file per lib. Tests run against fixture data — no real `claude` CLI calls (mocked).

- `test-id.bats`: project ID resolution from various git/non-git directories on both OSes.
- `test-load.bats`: rendering the injected block from various storage states (empty, 1 entry, 10 entries, oversized).
- `test-save.bats`: parsing `claude -p` output, writing timeline + current.md correctly.
- `test-flush.bats`: in-progress extraction only, no timeline entry created.
- `test-history.bats`: listing and showing entries by index and by date.
- `test-prune.bats`: interactive prune flow (driven by `bats` input stubs).
- `test-install.bats`: idempotent install, merge-vs-overwrite logic, uninstall reverses everything.
- `test-platform.bats`: OS detection, SHA1 helper, path conversion no-op on macOS / round-trip on Windows, symlink + shim fallback.

### CI matrix

GitHub Actions running the bats suite on `macos-latest` and `windows-latest` (with Git Bash). Both must pass for a green build.

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
7. **(Windows only)**: verify path-with-spaces works by installing into a user account whose name contains a space (or symlink the test fixture into `~/Documents/My Repos/test`).

## 10. Open questions for the implementation plan

These are decisions to confirm during planning, not blockers for spec approval:

- Exact format/schema of `meta.json` and `transcripts.jsonl` — finalize in plan.
- Whether `/ccm:show` takes an integer index or a date string (or both). Slash command file uses `$ARGUMENTS` placeholder.
- Exact wording of `prompts/summarize.txt` — will iterate during implementation against real transcripts.
- Whether `install.sh` should also offer to update an existing global `bashrc`/`zshrc` to put `~/.local/bin` on PATH, or just print a message.
- Whether Windows install should print a Developer Mode reminder upfront, or only when the first symlink attempt fails.

## 11. Success criteria

The MVP is successful when:

1. After running `./install.sh` once (on either macOS or Windows Git Bash), no further configuration is needed.
2. Running `claude` in a project where a prior session exists results in the agent acknowledging prior work without the user re-explaining.
3. Token cost of injected context on session start is ≤3000 tokens, measured across 10 representative sessions.
4. Zero documented cases of the context manager blocking or breaking a Claude Code session.
5. `/ccm:history`, `/ccm:show`, and `/ccm:prune` all work as documented in the README.
6. The full test suite passes (`bats test/`) on both `macos-latest` and `windows-latest` in CI.

---

*Approved by user 2026-05-11. Next step: implementation plan via `superpowers:writing-plans`.*
