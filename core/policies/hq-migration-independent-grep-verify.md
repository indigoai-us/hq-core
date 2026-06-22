---
id: hq-migration-independent-grep-verify
title: Independently grep the repo before claiming a code migration complete
scope: global
trigger: any in-repo migration that replaces a string, model name, version, API path, or config token across multiple files
when: migrate || migration || schema
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

NEVER trust a migration plan's named-file list as proof of completeness. Before reporting a code migration done, run an independent repo-wide grep for the OLD pattern (the one being replaced) and confirm zero matches outside expected locations (tests asserting the absence, archive folders, vendored dependencies).

Concretely:

1. Identify the unique substring(s) of the old pattern (e.g. the literal model id, the deprecated CLI flag, the old import path).
2. Run `grep -r` (or `Grep` tool) across the repo with that substring — no `--include` filter narrower than the migration scope. Do not pre-filter by file extension unless you're sure the pattern can only appear in one filetype.
3. If matches remain, the migration is not done. Update those files (or document each remaining match with an explicit reason) before claiming completion.
4. Cross-check the named-file list from the plan against the grep result set. Any plan-listed file with no match means the plan was wrong about that file; any grep-matched file not in the plan means the plan missed it.

This applies equally whether the migration was authored by a human, a sub-agent, or a planning command — the named-file list is a hypothesis, not evidence.

## Rationale

A recent dev-team codex model migration plan listed 10 `worker.yaml` files but missed 13 skill markdown files containing the same stale `-c model="gpt-5.4" --reasoning high --fast` strings. The plan was thorough about its named scope and silent about the rest of the repo; the migration "completed" against the plan while leaving 13 stale files in production. A 2-second `grep -rn 'gpt-5.4' .` would have caught all 13 immediately.

Migration plans bias toward the surfaces their author was already thinking about. Grep is a cheap, comprehensive sanity check that doesn't share that bias — it sees every file in the repo equally. Run it before declaring the migration complete; the cost is one shell command and the upside is catching the entire missed-file class of bugs in a single pass.
