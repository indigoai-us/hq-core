---
name: grilling
description: Shared interview engine for /brainstorm, /prd, and grill-me. Asks only the open frontier of a question set, looks up facts instead of asking them, and returns a question count. Engine only; not invoked on its own.
user-invocable: false
allowed-tools: Read, Grep, Glob, AskUserQuestion, Task, Bash(bash .claude/skills/grilling/frontier.sh:*), Bash(bash .claude/skills/_shared/journal.sh:*), Bash
---

# Grilling Engine

Engine skill. Caller skills (/brainstorm, /prd, grill-me) load this file and run it with an input contract. Users do not run it directly. If a user types `/grilling`, tell them to use /brainstorm, /prd, or grill-me instead.

Pattern source: mattpocock/skills `skills/productivity/grilling` (design tree, frontier rounds, facts are the agent's job). HQ changes the default: one question per AskUserQuestion call, with rounds available only on request.

## Input contract

| Input | Required | Meaning |
|-------|----------|---------|
| question_set | yes | Path to a question-set file. Format: `.claude/skills/_shared/questions/FORMAT.md`. |
| known_facts | no | Map of question id to answer, already settled by the caller (from the brief, a brainstorm, the board, or earlier answers). These ids are never asked. |
| mode | no | `one-at-a-time` (default) or `rounds`. |
| max_questions | no | Upper bound on questions put to the user. Default: no limit. When reached, remaining decisions take their recommended option and are logged as assumed. |

`mode: rounds` is set only when the user explicitly asks for rounds in this session or the caller received a `--rounds` argument. Never infer it from the size of the set, the user's tone, or time pressure.

## Helper

`.claude/skills/grilling/frontier.sh` parses the set and computes the frontier. Use it rather than computing dependencies by hand.

```bash
bash .claude/skills/grilling/frontier.sh frontier <question_set> --known <ids> --answered <ids>
bash .claude/skills/grilling/frontier.sh count <question_set> --known <ids>
```

`frontier` prints the open decision ids in file order. `count` validates the set and prints the count object for a full run. Exit 2 means the set is malformed or has a dependency cycle; stop and report the error to the caller.

## Procedure

1. **Validate.** Run `frontier.sh count` with the known ids. On exit 2, return the error to the caller without asking anything.
2. **Resolve facts.** For every `kind: fact` question whose `depends_on` are resolved, find the answer yourself: caller research, the company board, repo files, or a Task subagent lookup. Never put a fact question to the user. A pending lookup blocks only the questions that depend on it; keep asking the rest of the frontier.
3. **Compute the frontier.** Run `frontier.sh frontier` with known ids plus everything answered so far. A question whose dependency is still open waits for a later pass.
4. **Ask.**
   - **one-at-a-time (default):** one AskUserQuestion call per frontier question. Offer 2 to 4 options from the question's `options`. When research or known facts support the `recommended` option, put it first and append ` (Recommended)` to its label. Wait for the answer before the next call.
   - **rounds:** present the whole frontier as one numbered block, then wait for the reply.

     ```
     Q1 - <question text>
     Options: A) <opt> B) <opt> C) <opt>
     Recommended: A) <opt>

     Q2 - ...
     ```

     Word each question so "yes" accepts the recommendation. Accept shorthand replies: `yes` or `y` (accept all recommendations), `1A 2C`, `2: <free text>`, or `all recommended except 3B`. Questions not mentioned in a reply take the recommendation only when the reply was `yes`; otherwise ask about them again in the next round.
5. **Record.** After each answer, append it to the active journal:

   ```bash
   bash .claude/skills/_shared/journal.sh append <project_dir> decisions "<question id>: <answer>"
   ```

   Facts found in step 2 go under `findings` with their id and source.
6. **Repeat** steps 2 to 5 until the frontier is empty or `max_questions` is reached.
7. **Return** the answers map and the count object to the caller.

## Headless

When `CLAUDE_HEADLESS=1`, do not call AskUserQuestion. Take the recommended option for each decision, log it under `decisions` with the suffix `(assumed, headless)`, and count it under `asked`.

## Count object

```json
{"asked": 7, "skipped_known": 3, "skipped_fact": 2,
 "by_tier": {"strategic": 1, "architecture": 3, "quality": 3}}
```

- `asked`: decisions put to the user (or assumed under headless or `max_questions`).
- `skipped_known`: ids supplied in `known_facts`.
- `skipped_fact`: fact questions resolved by lookup.
- `by_tier`: `asked` split by tier.

Test: `bash core/scripts/tests/grilling-count.test.sh`.
