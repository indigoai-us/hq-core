---
name: grill-me
description: Interview the user about any topic one question at a time, using the grilling engine with a question set generated from the prompt. Use for "grill me on X" outside of planning. Pass --rounds for batched rounds.
allowed-tools: Read, Write, Bash, Grep, Glob, AskUserQuestion, Task
argument-hint: "<topic> [--rounds]"
---

# /grill-me

Thin entry to the grilling engine (`.claude/skills/grilling/SKILL.md`). This skill builds the question set; the engine asks it.

## Arguments

- `<topic>`: what to grill the user on. If empty, ask for it in one AskUserQuestion call.
- `--rounds`: pass `mode: rounds` to the engine. Without it, pass `mode: one-at-a-time`. Never switch modes on your own.

## Procedure

1. **Anchor.** Resolve the company: explicit mention in the topic, then the cwd's company folder, then the repo's owner in `companies/manifest.yaml`, then the session's `company_slug`. When a company resolves, read its policies folder. If none resolves, run unscoped and read no company files. Set `project_dir` when the topic or cwd names a project folder of that company; otherwise leave it unset.
2. **Research facts.** Read what the topic points to (board, repo, knowledge) so known answers are not asked. Record settled answers as `known_facts`.
3. **Generate the question set.** Write `workspace/tmp/grill-me/{date}-{topic-slug}.md` in the format in `.claude/skills/_shared/questions/FORMAT.md`:
   - 4 to 12 questions. At least 4 must be `kind: decision`.
   - Cover tiers in order: strategic (goal, scope, audience), architecture (approach, boundaries), quality (risks, success measure).
   - Each decision has 2 to 4 short options and a `recommended` option.
   - Use `depends_on` where one answer changes the next question. Use `kind: fact` for anything you can look up.
4. **Validate.** `bash .claude/skills/grilling/frontier.sh count <set> --known <ids>`. On exit 2, fix the set and validate again.
5. **Open a journal** when `project_dir` is set: `bash .claude/skills/_shared/journal.sh open grill-me <project_dir>`.
6. **Run the engine** with `question_set`, `known_facts`, and `mode`. Follow its procedure exactly.
7. **Summarize.** Write a short summary: topic, each decision and its answer, assumed answers, open items, and the count object.
   - Always write it to the journal: `journal.sh append <project_dir> decisions "summary: ..."` when a project journal is open, otherwise a `/journal` session entry.
   - When `project_dir` is set, also write it to `{project_dir}/grill-{YYYY-MM-DD}.md`, then run `journal.sh close <project_dir> "<one-line summary>"`.
8. **Report** in chat: the decisions in plain words and where the summary was saved. When the topic is a project, suggest `/brainstorm` or `/prd` as the next step.

## Rules

- One AskUserQuestion call per question unless `--rounds` was passed.
- Never answer your own decision questions, except under `CLAUDE_HEADLESS=1` as the engine defines.
- Do not read another company's files or credentials.
