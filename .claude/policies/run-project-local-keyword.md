---
id: run-project-local-keyword
title: "run-project.sh: no `local` in top-level loop bodies"
scope: command
trigger: editing scripts/run-project.sh
enforcement: hard
---

## Rule

Never use `local` keyword in the top-level swarm or sequential mode loop bodies of `run-project.sh`. These loops are NOT inside functions — `local` only works inside bash functions and crashes the script at runtime.

Affected regions:
- Sequential mode loop (~line 2745 `while true`)
- Swarm mode loop (~line 2500 `while true`)
- Safe: function `process_swarm_completion()` (~line 2246) — `local` is valid here

Use plain variable assignment (`var=""`) instead of `local var` in loop bodies.

