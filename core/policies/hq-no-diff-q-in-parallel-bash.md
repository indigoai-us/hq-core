---
id: hq-no-diff-q-in-parallel-bash
title: Never run diff -q in a parallel bash batch — nonzero exits cancel siblings
scope: global
trigger: issuing multiple Bash tool calls in a single message that include a diff
when: diff
on: [AssistantIntent, PreToolUse]
enforcement: soft
public: true
version: 2
created: 2026-04-17
updated: 2026-04-29
source: session-learning
---

## Rule

NEVER: Issue `diff -q` (or any command whose non-match exit is nonzero) in a parallel bash batch alongside sibling commands you need to complete. When one tool call returns a nonzero exit, the harness cancels all pending siblings. If you need to compare files while doing other work in parallel, either run the diff sequentially, wrap it with `|| true`, or use a wrapper that normalizes the exit code (`diff -q a b; echo "$?"`).

## Rationale

During a `/promote-hq-core` run, a parallel batch that included `diff -q HQ-file template-file` alongside other unrelated bash calls aborted the whole batch when the files differed (exit 1 — expected for differing files, but the harness treated it as a failure). Other siblings that would have completed cleanly were cancelled. `diff -q` returns 0 for identical files and 1 for any difference — any difference is a normal "information" outcome, not a failure, so the command's default exit semantics are a trap in parallel contexts.
