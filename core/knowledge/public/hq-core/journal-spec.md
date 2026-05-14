---
title: Session Journal Spec
status: draft
applies_to: [brainstorm, deep-plan, prd, plan, startwork, handoff, checkpoint]
introduced_in: hq-core 12.2.0
---

# Session Journal

A per-session, append-only thinking trail attached to a project (or plan-level workstream). Captures the research, premise challenges, rejected approaches, and mid-build learnings that otherwise evaporate when context is compacted or a session ends.

## Why

`brainstorm.md`, `prd.json`, and `README.md` capture the **final** product. They don't capture the path: which approaches were rejected and why, which agent findings shaped the framing, which open questions resolved which way during the interview. When a future session resumes the workstream — or a different person picks it up — that path is lost.

The journal preserves it without bloating the canonical artifacts.

## Where

```
{project_dir}/journal/{YYYY-MM-DD-HHMM}-{skill}-{thread-short}.md
```

`{project_dir}` is whatever directory the originating skill writes to:

| Scope | Path |
|---|---|
| Company project | `companies/{co}/projects/{slug}/` |
| Personal / HQ project | `personal/projects/{slug}/` |
| Plan-level workstream | wherever `/plan` resolves the workstream dir |

`{skill}` is the lowercase skill name (`brainstorm`, `deep-plan`, `prd`, `startwork`, `plan`).

`{thread-short}` is the last 6 chars of the active thread ID (from `workspace/threads/handoff.json`), or `adhoc` if no thread is active.

One file per session per workstream. A long session that touches multiple skills (brainstorm → deep-plan in one sitting) creates one file per skill — they share the project_dir but stay separate so future readers can see which skill owned which thinking.

## Format

```yaml
---
skill: deep-plan
started_at: 2026-05-07T09:15:00Z
thread_id: T-20260507-091500-foo-bar
project: companies/example-co/projects/messaging-shortlink-reliability
status: active           # active | closed | abandoned
auto_capture: true       # opt out per-file
summary: ""              # filled at close
---

## Decisions
- 2026-05-07T09:18:00Z chose hybrid retry + circuit-breaker over pure retry. Reason: Twilio 5xx clusters by region, so unbounded retry amplifies the outage.

## Open threads
- 2026-05-07T09:22:00Z unresolved: do we need per-tenant rate limits, or is the global Twilio limit sufficient? Affects scope cut.

## Findings
- 2026-05-07T09:30:00Z agent-codebase-scanner: existing `RetryQueue` in `apps/web/lib/retry/` already supports exponential backoff. Reuse, don't rebuild.
- 2026-05-07T09:31:00Z agent-hq-context: prior project `messaging-shortlink-v1` shipped with a 3-retry cap. No retro found explaining why.

## Rejected
- 2026-05-07T09:25:00Z ruled out queue-based async retry. Reason: latency budget is 200ms p99 — async adds at minimum 50ms cold-start.

## Auto-capture
- 2026-05-07T09:30:12Z [Agent] codebase-scanner: 47 files matched, top: apps/web/lib/retry/queue.ts ...
- 2026-05-07T09:31:45Z [AskUserQuestion] "Latency budget?" → "200ms p99"
- 2026-05-07T09:34:02Z [WebFetch] https://www.twilio.com/docs/api/errors → "5xx errors should be retried with exponential backoff up to 3 attempts."
```

Section invariants:
- All five section headers always present, even if empty (consistent shape for the reader skill).
- Entries timestamped ISO8601, prefixed at the start of the bullet.
- One bullet per decision/finding — no nested lists, no multi-paragraph entries. If an entry would be longer than 3 lines, persist it via `journal.sh attach research` (see "## Reference material" below) and let the helper cross-reference it.

## Reference material

**Invariant**: every file written *because of* a journal capture lives under `{project_dir}/`. No exceptions for the journal file, attachments, research excerpts, or hook-spilled overflow. Enforced by `.claude/policies/journal-project-scoped-writes.md` (hard).

Permitted subpaths:

| Path | Written by | Purpose |
|---|---|---|
| `journal/{YYYY-MM-DD-HHMM}-{skill}-{thread-short}.md` | `journal.sh open` | The journal itself. |
| `journal/attachments/{ts}-{tool}-{hash6}.{ext}` | `journal-autocapture.sh` (hook) or `journal.sh attach attachment` | Overflow from auto-capture (>1 KB agent/WebFetch/WebSearch output) and other hook-captured raw material. |
| `research/{ts}-research-{hash6}.{ext}` or `research/{descriptive-slug}.md` | `journal.sh attach research` or curated by the skill | Reference docs that the journal links to. Curated, not hook-captured. |

Forbidden destinations for any journal-adjacent write:
- `/tmp/*` — wiped on reboot, does not travel with HQ Sync.
- `workspace/*` — global, not project-scoped; loses the trail when the workstream moves.
- `.claude/state/*` — runtime pointers only; the sole permitted file here is `active-journal` (the single-line absolute path to the current journal).
- Any HQ-root path outside the three permitted subpaths above.

### Helper API

Skills do **not** hand-write paths into `journal/attachments/` or `research/`. They call:

```bash
journal.sh attach <kind> [<source_path>|-] [--ext <ext>]
```

- `<kind>` ∈ `{research, attachment}`. `research` → `{project_dir}/research/`, cross-references appear under `## Findings`. `attachment` → `{project_dir}/journal/attachments/`, cross-references appear under `## Auto-capture`.
- Source: a file path, or `-`/omitted to read from stdin.
- `--ext` is optional; inferred from the source filename when present, else `txt` for stdin.
- The helper reads `project:` from the active journal's frontmatter — callers do not pass it.
- Prints the absolute path of the written file. Fail-soft: warns to stderr and exits 0 on any error.

### Overflow handling

When the auto-capture hook records a tool result whose body exceeds **1024 bytes**, it spills the full content to `journal/attachments/{ts}-{tool}-{hash6}.txt` and appends `(full: journal/attachments/...)` to the inline digest line. Applies to `Agent`, `WebFetch`, and `WebSearch` results. `AskUserQuestion` answers are always short — no spill.

## Lifecycle

### Open

Skill creates the journal file as soon as `{project_dir}` is known (typically the first step that resolves the write target). Frontmatter is initialized with `status: active`, `auto_capture: true`, `summary: ""`. The skill writes the absolute path to `.claude/state/active-journal` (single line, no newline).

If the file already exists for the same `(date, skill, thread)` triple — appending continues (unusual — only happens if the skill is re-invoked within the same session).

### Append (curated)

Skills append at decision points listed in their SKILL.md. Each append writes to one of the five sections under a timestamped bullet.

### Append (auto)

The hook `.claude/hooks/journal-autocapture.sh` (PostToolUse) reads `.claude/state/active-journal`, opens the target file, checks `auto_capture: true` in its frontmatter, then appends to the `## Auto-capture` section if the just-finished tool is one of:

- `Agent` — record description + first 200 chars of result
- `AskUserQuestion` — record question header + chosen answer label
- `WebFetch` — record URL + 1-line summary (best-effort, may be empty)
- `WebSearch` — record query + top hit title

All other tools (`Bash`, `Read`, `Edit`, `Write`, `Grep`, `Glob`, anything else) are skipped — too noisy or too risky for secrets.

The hook never reads the tool result for content beyond what's needed to record those fields. It does not store full agent output, full Bash output, or any file contents.

### Close

`/handoff` and `/checkpoint` close the active journal:
- Read the file, set `status: closed`
- Fill `summary` with a one-line synthesis of the session (caller-provided)
- Clear `.claude/state/active-journal`

If a session ends without `/handoff` or `/checkpoint` (compaction, crash, user kills the process), the file is left at `status: active`. A reader skill that finds an `active` file older than 24h should treat it as abandoned and visually flag it.

## Read

`/startwork` reads journals **only when the arg matches an existing project or workstream**. It does NOT read journals for fresh greenfield arguments.

Read pattern:
1. Glob `{project_dir}/journal/*.md`, sort by mtime desc.
2. Take the most recent 2 files. If one is `status: active`, treat it as the in-flight session and surface its open threads in the orientation block.
3. From the `closed` files, surface the `summary` line and any unresolved bullets in `## Open threads`.
4. Do NOT load the full content of `## Auto-capture` into context — it's reference material, not orientation. Show file paths instead so the user can pull the detail explicitly.

A meta/research-level reader (e.g. a `/journal-survey` skill, future) can crawl multiple project dirs at once and produce a workstream-level digest. Out of scope for the initial rollout.

## State pointer

`.claude/state/active-journal` is a single file containing the absolute path to the currently-active journal. Gitignored. Cleared on close.

If the hook reads the pointer and the target file's mtime is more than 2 hours old AND `status: active`, the hook treats it as stale and skips appending — better to lose an entry than to write to a journal whose owner is gone.

## Promotion / sharing

Journal files travel with the project dir. They go through normal HQ Sync. Auto-capture entries may include WebFetch URLs and AskUserQuestion answers — treat them as project-scope content (not secrets, but not necessarily public either). Apply the same publish rules as `brainstorm.md` and `README.md`.

## What this is NOT

- Not a replacement for `brainstorm.md` / `prd.json` / `README.md`. Those are the canonical artifacts; the journal is the trail.
- Not a transcript. Don't dump full tool outputs, full conversation history, or full agent results.
- Not a TODO list. Open threads are *unresolved questions that affect the framing*, not implementation tasks (those go in `prd.json`).
- Not a daily log. One file per session per skill, not per day.
