---
id: hq-bash-non-subshell-cd-cwd-leak-cross-repo
title: Non-subshell cd in a single Bash call persists across later calls and silently contaminates other repos
scope: global
trigger: Bash tool calls that begin with a bare cd path (no subshell) before further commands, especially when later calls assume HQ-root cwd
when: cd
on: [PreToolUse]
enforcement: hard
public: true
version: 2
created: 2026-05-28
updated: 2026-06-09
source: user-correction
tags: [bash, git, cwd, anchor, hq-discipline]
---

## Rule

NEVER write a Bash tool call that starts with a bare `cd <relative-or-absolute>;` (or `cd ... && ...`) when the call's purpose is to "step into a repo for a moment." The Bash tool's cwd PERSISTS across sequential calls in the same session, so a single `cd repos/private/<some-repo>; <commands>` silently re-roots EVERY later relative-path Bash call into that repo until something else changes cwd. This is a different and more dangerous failure mode than the parallel-Bash cwd-drift problem — it bites sequentially, often many tool calls later, and is invisible at the call site.

The concrete bite: a hot-step into a nested repo was followed (many calls later) by `handoff-finalize.sh`, which runs `git add` / `git commit` using paths relative to cwd. Because cwd was still inside `repos/private/<some-repo>`, the handoff committed HQ-root thread / handoff.json / INDEX files INTO the staging repo — cross-repo contamination that is invisible from HQ root and only surfaces in the wrong repo's history.

ALWAYS use one of:

1. **Subshell** — `( cd /abs/path && <commands> )`. The `cd` is scoped to the subshell; parent shell cwd is untouched.
2. **`git -C /abs/path <subcmd>`** — preferred for git; never touches shell cwd.
3. **Absolute paths in every command** — `bash /abs/path/script.sh`, `cat /abs/path/file`. No `cd` at all.

**Caveat (added 2026-06-09):** the subshell form is fine for scoping cwd, but it is NOT a valid anchor for git/gh *mutations*. The Claude Code harness silently strips a leading `cd <path> && ` (including inside `( … )`) when `<path>` equals the session cwd, so PreToolUse hooks — including `block-hq-root-git-mutation.sh` — never see the cd (verified 2026-06-08, re-verified 2026-06-09). For mutations, anchor with `git -C /abs/path` or `gh -R owner/repo`; regression coverage lives in `core/scripts/tests/block-hq-root-git-mutation.test.sh`.

Do NOT trust an earlier `cd` to "set up" a repo context for later calls. If a later call needs to operate in a repo, it must self-anchor (`git -C /abs`, subshell, or absolute paths) — the same discipline the HQ-root git-mutation hook already enforces for mutations, now extended to ALL repo-scoped Bash work.

This rule also applies inside shell scripts that are themselves invoked from a Bash tool call: a script that does `cd $WORKDIR` without a subshell and then exits leaves the parent Bash tool cwd unchanged (script ran in a subprocess), but a script that's `source`d or whose contents are inlined into the tool call WILL drift parent cwd. Prefer explicit `pushd`/`popd` pairs or subshells inside scripts that change directory.

## Rationale

Session 2026-05-28: a `/handoff` mid-session wrote HQ thread file, handoff.json, and INDEX.md commits INTO `repos/private/<some-repo>` instead of HQ root. Root cause traced to an earlier Bash tool call that started with `cd repos/private/<some-repo>; ...` without a subshell. The Bash tool's persistent cwd meant every subsequent call ran from inside the staging repo, including `handoff-finalize.sh`'s `git add` / `git commit` lines that used cwd-relative resolution.

This is a distinct failure mode from `hq-parallel-bash-cwd-prefix` (parallel calls leaking cwd to siblings) and `hq-anchor-repo-build-cwd` (a later build picking the wrong repo because cwd persisted). Those two policies are correct but did not surface "cross-repo git commit contamination via handoff-finalize" as a concrete bite. Codifying it here so future sessions reject the `cd <path>; ...` pattern at authoring time and reach for `( cd /abs && ... )`, `git -C /abs`, or absolute paths instead.

Mechanical follow-up worth considering separately: a PreToolUse Bash hook that flags any tool call whose first token is `cd ` (without enclosing parens) and either warns or blocks unless the call is wrapped in a subshell. Not part of this policy — captured here as future work.
