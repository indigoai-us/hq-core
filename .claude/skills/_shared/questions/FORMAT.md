---
description: File format for grilling question sets consumed by the grilling engine.
---

# Question-Set Format

A question set is a markdown file read by the grilling engine (`.claude/skills/grilling/SKILL.md`). Callers such as /brainstorm, /prd, and grill-me keep their question sets under `.claude/skills/_shared/questions/` or next to their own SKILL.md and pass the path as `question_set`.

## Layout

Each question is a level-2 heading with the question id, a one-line question text, and a bullet list of fields. Text outside question blocks is ignored, so a set can carry an intro paragraph.

```markdown
## Q-scope
What is the scope boundary for v1?

- tier: strategic
- kind: decision
- depends_on: []
- options: Single company | All companies | Personal only
- recommended: Single company
```

## Fields

| Field | Required | Values |
|-------|----------|--------|
| id | yes | The heading text after `## `. Letters, digits, `-`, `_`. Unique within the set. |
| tier | yes | `strategic`, `architecture`, or `quality`. |
| kind | yes | `decision` (the user answers) or `fact` (the engine looks it up and never asks). |
| depends_on | yes | List of ids in brackets, comma separated. `[]` when none. Every id must exist in the set. |
| options | decision only | 2 to 4 options separated by ` \| `. Facts may omit it. |
| recommended | decision only | One of the options. The engine shows it first and marks it (Recommended) when research supports it. |
| prefill | decision only | Optional hint for the caller: a research source or rule that pre-fills the answer as a known fact (for example a brainstorm answer id). The engine skips the question and counts it as skipped_known when the caller resolves it. |

## Rules

- A question is on the frontier when every id in its `depends_on` is resolved. A decision is resolved once answered or pre-known. A fact is resolved once looked up.
- `kind: fact` questions are never put to the user. The engine resolves them from research, the company board, or a subagent lookup.
- Dependencies must not form a cycle. The engine helper reports a cycle as an error.
- Keep options short enough to fit an AskUserQuestion label.

## Validating a set

```bash
bash .claude/skills/grilling/frontier.sh count <question_set> --known <id,id>
```

The command prints the count object the engine would return if every remaining decision were asked, or an error naming the bad field.
