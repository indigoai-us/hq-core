---
name: journal
description: Session-level working-memory journal — write structured entries to workspace/threads/journal/<date>/ so autocompact can discard raw tool-results while preserving findings/decisions.
allowed-tools: Bash, Read, Write
---

# /journal

Write a structured working-memory entry for the current Claude session. Entries land at `workspace/threads/journal/<YYYY-MM-DD>/<NNN>-<slug>.md` and the day's `INDEX.md` is auto-updated.

**Spec:** `core/knowledge/public/hq-core/journal-spec.md`.

## Usage

| Form | Effect |
|---|---|
| `/journal "<title>"` | Write a new entry inferring body from recent context |
| `/journal --list` | Print today's INDEX |
| `/journal --read <NNN>` | Print a specific entry |

## Behavior

### Writing an entry

1. **Synthesize the body** from the current conversation context. The entry captures what's *useful to recover* if the prefix gets compacted away — not everything that happened.
2. Use this template (50–200 lines, ≤5KB hard):

```markdown
## Goal
<one sentence: what this slice of work is about>

## Findings
<bullets — non-obvious things learned, file paths discovered, behaviors observed>

## Decisions
<numbered — what was chosen, including rejected alternatives if instructive>

## Next
<what the next entry will pick up: story id, file, or open question>
```

3. Pass the synthesized body via `--body-file` to `core/scripts/session-journal.sh write`:

```bash
mktemp_body=$(mktemp -t journal-body.XXXXXX.md)
cat > "$mktemp_body" <<'EOF'
## Goal
...

## Findings
...

## Decisions
...

## Next
...
EOF

core/scripts/session-journal.sh write "<title>" \
  --files "<comma-separated relative paths touched, optional>" \
  --body-file "$mktemp_body"

rm -f "$mktemp_body"
```

4. Confirm the path returned by the helper. Print the entry's relative path back to the user — that's the receipt.

### `--list`

```bash
core/scripts/session-journal.sh list
```

Prints today's `INDEX.md`. If the user wants a different day, pass `--date YYYY-MM-DD` through.

### `--read <NNN>`

```bash
core/scripts/session-journal.sh read <NNN>
```

Prints a specific entry. Useful after `/handoff` continuation when the SessionStart hook surfaced the INDEX and you need a specific entry's detail.

## When to write an entry

You don't need to wait for the auto-trigger hook. Write proactively after:

- Finishing a coherent slice of work (one story, one investigation, one cluster of related edits).
- A commit lands.
- A test pass / typecheck pass.
- A user direction change ("now let's do X instead").
- Right before `/handoff` or `/checkpoint`.
- When you notice you've made non-obvious findings that wouldn't survive a compaction.

## Constraints

- **Never** include secrets, share-session URLs, or other capabilities in entries (per `.claude/policies/hq-share-session-urls-are-capabilities.md` and the rest of the credential-isolation rule set).
- Don't write trivial entries ("read a file"). The bar is: *would future-me want this back after compaction?*
- One entry per coherent slice. If you have three unrelated findings, write three entries.

## Related

- `core/knowledge/public/hq-core/journal-spec.md` — full spec, two-pattern coexistence with task journals
- `.claude/hooks/journal-due.sh` — PostToolUse auto-trigger
- `.claude/hooks/journal-precompact.sh` — PreCompact reminder
- `.claude/hooks/load-journal-index-on-start.sh` — SessionStart auto-load
- `core/scripts/session-journal.sh` — helper script
- `.claude/skills/_shared/journal.sh` — task journal (different pattern, doesn't conflict)
