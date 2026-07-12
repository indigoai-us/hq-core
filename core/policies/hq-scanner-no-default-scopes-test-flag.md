---
id: hq-scanner-no-default-scopes-test-flag
title: Scanner scripts must expose a `--no-default-scopes` test flag
when: scanner
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

ALWAYS: Scanner scripts that auto-expand to default parent dirs MUST offer a `--no-default-scopes` (or equivalent) test flag. Without it, fixture tests drag the full filesystem into every smoke run, amplifying unrelated bugs (arg-list limits, slow scans, cross-company data contamination) and making failures hard to diagnose.

```bash
# Script default: scan $HOME + HQ
# Test mode: only scan paths explicitly passed on CLI
if [ "$NO_DEFAULT_SCOPES" = "1" ] || [ "$1" = "--no-default-scopes" ]; then
  scopes=()
else
  scopes=("$HOME" "$HQ_ROOT")
fi
```

## Rationale

Discovered while building `.claude/skills/import-claude/scan.sh`. A 2-file fixture test was failing intermittently with `Argument list too long` — the scanner was correctly honoring its default scopes (scanning `$HOME` on top of the fixture) and producing a 400KB JSON blob. The fixture had nothing to do with the failure, but debugging was painful because the real bug (missing `--slurpfile`) was hidden behind unrelated noise. A test-scope flag isolates the fixture surface and makes failures crisp.
