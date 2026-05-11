# Claude Context Manager — Design Spec (MVP)

**Date:** 2026-05-11
**Status:** Approved for implementation planning
**Surface:** Claude Code only (single Mac)

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

### Out of scope (deferred to future specs)

- Claude Desktop integration (no filesystem hooks available).
- Claude API SDK integration (different audience: app builders).
- Cross-machine sync (git-syncable storage or cloud).
- TUI/web viewer for browsing history (slash commands only in MVP).
- Smart relevance ranking of timeline entries (MVP always injects the most recent N).
- Auto-extraction of structured facts into the existing auto-memory directory (deferred to Phase 1.5).
- Search across timeline entries (`ccm search` command).
- Parallel-session conflict handling (two terminals in the same project — MVP is last-writer-wins).

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
│ Storage layout                                               │
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

A bash script installed at `~/.local/bin/ccm` (symlinked from the repo). Subcommands:

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

Registered in `~/.claude/settings.json` at user level (not project level), so every project benefits from the same install. Each hook is a thin shell-out to `ccm`.

### Slash commands

Installed at `~/.claude/commands/ccm/<name>.md`. Each file is a 3-line markdown stub with `!ccm <subcommand>` so Claude Code's slash command system executes the binary and injects stdout.

## 4. Data flow

### 4.1 Load (SessionStart hook fires)

1. Resolve project ID:
   - Run `git remote get-url origin 2>/dev/null`. If non-empty, that is the ID (URL-encoded).
   - Otherwise, compute `printf '%s' "$PWD" | shasum -a 1 | cut -d' ' -f1` and use that hash.
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
2. Locate the just-ended session's transcript: `~/.claude/projects/<dir-hash>/<session-id>.jsonl`. (Claude Code already writes these.) Use the `$CLAUDE_SESSION_ID` environment variable that hooks receive, or fall back to "most recently modified `.jsonl` in the project dir."
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
│   └── common.sh                # shared helpers (paths, logging, token budget)
├── commands/                    # Claude Code slash command files
│   ├── ccm/
│   │   ├── load.md              # /ccm:load    → !ccm load
│   │   ├── save.md              # /ccm:save    → !ccm save
│   │   ├── history.md           # /ccm:history → !ccm history
│   │   ├── show.md              # /ccm:show    → !ccm show "$@"
│   │   └── prune.md             # /ccm:prune   → !ccm prune
├── prompts/
│   ├── summarize.txt            # prompt for full session summarization
│   └── flush.txt                # prompt for pre-compact in-progress extraction
├── install.sh                   # symlink ccm + commands, register hooks in settings.json
├── uninstall.sh                 # reverse install.sh
├── test/
│   ├── test-id.bats
│   ├── test-load.bats
│   ├── test-save.bats
│   ├── test-flush.bats
│   ├── test-history.bats
│   ├── test-prune.bats
│   ├── test-install.bats
│   └── fixtures/
│       ├── transcripts/         # sample .jsonl files
│       ├── storage/             # expected post-save storage state
│       └── settings/            # sample ~/.claude/settings.json
├── README.md
└── VERSION
```

### Dependencies

- `bash` ≥ 4 (macOS 14+ ships bash 3.2 by default; install via homebrew, document in README)
- `jq` (for JSON manipulation in hooks/transcripts)
- `shasum` (in coreutils, standard on macOS)
- `claude` CLI (already present for the target user)
- `bats-core` (test-only; install via homebrew)

### Install behavior

`./install.sh` does:

1. Verify `bash`, `jq`, and `claude` are on PATH; abort with a clear error if not.
2. Symlink `./bin/ccm` → `~/.local/bin/ccm` (create `~/.local/bin` if missing; warn if not on PATH).
3. Symlink `./commands/ccm/` → `~/.claude/commands/ccm/`.
4. Read `~/.claude/settings.json` (create if missing). Diff the existing `hooks` block against ours; if there are conflicting entries, print a unified diff and ask `[y/N]` before overwriting. Otherwise merge silently.
5. Create `~/.claude/context-manager/` and `~/.claude/context-manager/log`.
6. Print a verification command: `cd <some git repo> && claude -p "hi" && ccm history`.

`./uninstall.sh` reverses each step, prompting before deleting any storage.

## 6. Error handling

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

All errors and warnings are appended to `~/.claude/context-manager/log` with timestamp, project ID, and subcommand.

## 7. Testing strategy

### Unit tests (bats-core)

One `test-<lib>.bats` file per lib. Tests run against fixture data — no real `claude` CLI calls (mocked).

- `test-id.bats`: project ID resolution from various git/non-git directories.
- `test-load.bats`: rendering the injected block from various storage states (empty, 1 entry, 10 entries, oversized).
- `test-save.bats`: parsing `claude -p` output, writing timeline + current.md correctly.
- `test-flush.bats`: in-progress extraction only, no timeline entry created.
- `test-history.bats`: listing and showing entries by index and by date.
- `test-prune.bats`: interactive prune flow (driven by `bats` input stubs).
- `test-install.bats`: idempotent install, merge-vs-overwrite logic, uninstall reverses everything.

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

After local install:

1. **Cold start**: in a new project, run `claude -p "what's in the context manager?"` — verify the response says "no prior context" (graceful empty state).
2. **First save**: run `claude` in this repo, ask a question, exit. Verify a new file appears in `~/.claude/context-manager/<id>/timeline/`.
3. **Restore**: run `claude` again — verify the assistant's first response references the prior session's summary.
4. **Mid-session compaction**: run a session long enough to trigger compaction. Verify `current.md` updated mid-session without a duplicate timeline entry.
5. **Slash command**: in a session, type `/ccm:history` — verify the list renders.
6. **Multiple projects**: switch to a different repo, run `claude`, verify no bleed.

## 8. Open questions for the implementation plan

These are decisions to confirm during planning, not blockers for spec approval:

- Exact format/schema of `meta.json` and `transcripts.jsonl` — finalize in plan.
- Whether `/ccm:show` takes an integer index or a date string (or both).
- Exact wording of `prompts/summarize.txt` — will iterate during implementation against real transcripts.
- Whether `install.sh` should also offer to update an existing global `bashrc`/`zshrc` to put `~/.local/bin` on PATH, or just print a message.

## 9. Success criteria

The MVP is successful when:

1. After running `./install.sh` once, no further configuration is needed.
2. Running `claude` in a project where a prior session exists results in the agent acknowledging prior work without the user re-explaining.
3. Token cost of injected context on session start is ≤3000 tokens, measured across 10 representative sessions.
4. Zero documented cases of the context manager blocking or breaking a Claude Code session.
5. `/ccm:history`, `/ccm:show`, and `/ccm:prune` all work as documented in the README.
6. The full test suite passes (`bats test/`).

---

*Approved by user 2026-05-11. Next step: implementation plan via `superpowers:writing-plans`.*
