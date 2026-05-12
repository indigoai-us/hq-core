---
id: hq-ggshield-recursive-for-dirs
title: Pass --recursive --yes when scanning directories with ggshield
scope: global
trigger: invoking ggshield secret scan path <target> where target is a directory
enforcement: soft
public: true
version: 2
created: 2026-04-17
updated: 2026-04-29
source: session-learning
---

## Rule

ALWAYS: When invoking `ggshield secret scan path <target>` on a directory, pass `--recursive --yes`. Plain `ggshield secret scan path <dir>` exits with `is a directory. Use --recursive to scan directories.` The `--yes` flag auto-confirms the recursive prompt so the scan runs non-interactively in a bash tool call.

## Rationale

During a `/promote-hq-core` scoped secret scan, `ggshield secret scan path .claude/skills/learn` failed because the target was a directory. The ggshield CLI requires explicit opt-in for recursive directory walks — a safety measure against accidentally scanning huge trees — but in scripted contexts the `--recursive --yes` pair is always correct. Omitting them aborts the scan and leaves staged content un-verified, which is worse than a slow scan.
