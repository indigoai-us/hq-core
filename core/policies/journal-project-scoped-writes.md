---
id: hq-journal-project-scoped-writes
title: Journal writes stay inside the project folder
when: /journal
on: [UserPromptSubmit]
enforcement: hard
tier: 1
version: 1
created: 2026-05-11
updated: 2026-05-11
source: hardening
introduced_in: hq-core 14.0.1
spec: core/knowledge/public/hq-core/journal-spec.md
public: true
---

## Rule

Every file written *because of* a journal capture lives under `{project_dir}/`. No exceptions.

Permitted destinations:

- `{project_dir}/journal/{YYYY-MM-DD-HHMM}-{skill}-{thread-short}.md` — the journal file itself
- `{project_dir}/journal/attachments/{ts}-{tool}-{hash6}.{ext}` — auto-capture overflow + curated attachments
- `{project_dir}/research/{ts}-research-{hash6}.{ext}` or `research/{descriptive-slug}.md` — reference material the journal links to

Forbidden destinations:

- `/tmp/*` — wiped on reboot, does not travel with HQ Sync
- `workspace/*` — global, not project-scoped (the only exceptions are `.claude/state/active-journal` and `.claude/state/active-journal.d/*`, which are runtime pointers, not journal artifacts)
- Any HQ-root path outside the three permitted subpaths above

Use `journal.sh attach <project_dir> <research|attachment>` for non-trivial reference material. The caller project must match the active journal's normalized `project:` frontmatter. Do not hand-write paths into `journal/attachments/` or `research/` — the helper enforces the naming convention and cross-references the file from the journal.

## Rationale

- **Sync coherence.** Project folders travel with HQ Sync; `workspace/` and `/tmp` don't. A future reader resuming the workstream must get the full trail in one tree.
- **Drift prevention.** Seven skills participate in the journal subsystem (`brainstorm`, `deep-plan`, `prd`, `plan`, `startwork`, `handoff`, `checkpoint`). Centralizing the write path in `journal.sh attach` keeps callers dumb and prevents per-skill drift.
- **Audit trail.** When a session ends abandoned (compaction, crash), the project folder is the canonical recovery point. Anything that lived in `/tmp` or `workspace/` is unrecoverable.

## Violations

Hard-block. Reviewer fixes by either:
1. Relocating the write under `{project_dir}/` via direct path, or
2. Replacing the hand-written path with `journal.sh attach <project_dir> <kind>` and letting the helper place it.

Acceptable adjacent writes that are NOT journal artifacts (and thus NOT covered by this policy):
- `.claude/state/active-journal` and `.claude/state/active-journal.d/<session-key>` — legacy and session-scoped runtime pointers (single line, gitignored)
- `/tmp/hq-journal*.log` — debug logs for the journal subsystem itself
- `workspace/threads/*.json`, `workspace/checkpoints/*.json` — handoff/checkpoint state (separate subsystem)

If you're unsure whether a write is a "journal artifact," ask: *would a reader resuming this workstream want to see this file?* If yes → project folder. If no → it's runtime/debug state, exempt.
