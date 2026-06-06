---
id: hook-macos-case-paths
title: Hooks must use case-insensitive path matching on macOS
scope: global
trigger: writing hooks that check file paths
when: .sh || hook
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 1
created: 2026-03-18
updated: 2026-03-18
source: debugging
public: true
---

## Rule

When writing bash hooks that compare file paths (e.g. checking if a path is inside `repos/`), always use case-insensitive matching or pattern-based checks (e.g. `*/repos/private/*`) instead of prefix matching against a hardcoded `HQ_ROOT`.

macOS is case-insensitive but `pwd` may return a different casing than the hardcoded path. Example: `pwd` returns `/Users/{your-name}/Documents/hq` but `HQ_ROOT` is set to `/Users/{your-name}/Documents/HQ` — string comparison fails silently.

**Safe pattern:** lowercase both sides with `tr '[:upper:]' '[:lower:]'` before comparing, or match on a case-stable segment like `*/repos/private/*`.

## Rationale

Discovered when `block-inline-story-impl.sh` silently passed all repo files because the resolved path had lowercase `hq` from `pwd` while the check used uppercase `HQ`. Took debug tracing (`bash -x`) to spot the mismatch.
