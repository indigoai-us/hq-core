---
id: bulk-sed-exception-ordering
title: Bulk sed with exceptions — run sweep first, fix exceptions last
scope: global
trigger: bulk file edits, sed, find + sed, mass replace with exceptions
when: sed
on: [PreToolUse, UserPromptSubmit]
enforcement: soft
public: true
---

## Rule

When doing a bulk `find + sed` sweep across many files with specific exceptions, ALWAYS:
1. Run the bulk sweep first (changes all files)
2. Then fix the exceptions afterwards

NEVER do exceptions first then sweep — the sweep will overwrite the exception changes.

Alternative: Use `find ... -not -path "*exception-pattern*"` to exclude exception files from the sweep.

## Rationale

In the 2026-03-27 model routing upgrade, Gemini workers were first set to `sonnet` (exception), then the bulk sweep changed all `sonnet → opus`, overwriting the Gemini exception. Required a third pass to fix them back. Running the sweep first would have required only a single two-step process: sweep all → fix exceptions.
