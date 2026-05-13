---
name: journal
description: Session-level working-memory journal — write structured entries to workspace/threads/journal/<date>/ so autocompact can discard raw tool-results while preserving findings/decisions.
---

# Session Journal

Use when the user asks to "journal", "write a journal entry", "log this finding", or proactively after a coherent slice of work completes (commit lands, tests pass, story done, before /handoff).

## Canonical Source

Read `.claude/commands/journal.md` first. Treat it as the source of truth for the entry shape, lifecycle, and writing protocol.

## Codex Adaptation

- **Write**: shell out to `scripts/session-journal.sh write "<title>" --body-file <tmpfile>` after synthesizing the body in the entry template (Goal / Findings / Decisions / Next).
- **List**: `scripts/session-journal.sh list` prints today's INDEX. Pass `--date YYYY-MM-DD` for other days.
- **Read**: `scripts/session-journal.sh read <NNN>` prints a specific entry.

## Spec

`knowledge/public/hq-core/journal-spec.md` — full spec covering the two-pattern coexistence with the task journal (`.claude/skills/_shared/journal.sh`).

## Constraints

- Never include secrets, share-session URLs, or credentials in entries.
- Don't write trivial entries — the bar is "would future-me want this back after autocompact?"
- One entry per coherent slice. Multiple unrelated findings → multiple entries.
- Entry body ≤200 lines / ~5KB.

## Related

- `.claude/hooks/journal-due.sh` — PostToolUse trigger (after every 10 edits, after git commit, after test pass)
- `.claude/hooks/journal-precompact.sh` — PreCompact reminder
- `.claude/hooks/load-journal-index-on-start.sh` — SessionStart INDEX injector
- `projects/hq-token-economy/prd.json` US-007 (this), US-008/009/010 (the surrounding hooks)
