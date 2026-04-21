---
id: regression-gate-lint-fix
title: Fix lint regressions on feature branch before resuming
scope: command
trigger: /run-project
enforcement: soft
---

## Rule

When a regression gate fails due to lint error increase (e.g. "14 errors, baseline 13, +1 new"), fix the new error directly on the feature branch (checkout, fix, commit), then `--resume`. Do not skip the gate. The baseline comparison is strict by design — even 1 new error pauses execution.

