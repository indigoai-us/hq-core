---
id: hq-no-in-turn-qmd-model-download
title: Never download qmd GGUF models in a user-facing turn
when: vsearch || (qmd && embed) || (qmd && query) || (qmd && pull)
on: [PreToolUse, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-09-15
updated: 2026-09-15
source: user-correction
public: true
---

## Rule

NEVER run `qmd vsearch`, `qmd query`, `qmd embed`, or `qmd pull` in the foreground of a user-facing turn when `~/.cache/qmd/models/` (or `QMD_MODELS_DIR`) does not already contain a GGUF of at least 1 MiB.

ALWAYS use `qmd search` (BM25) for in-turn HQ search and `/learn` dedup.

To build embeddings: `hq index background`, or the same qmd subcommand with `run_in_background: true`. Escape hatch: `HQ_ALLOW_QMD_MODEL_DOWNLOAD=1`.

On Windows, batch independent shell work into one Bash tool call. Each Git Bash spawn is expensive; do not chain dozens of sequential console commands to do work that Read/Grep/Write or one batched script can do.

Hard-enforced by `.claude/hooks/block-qmd-model-download.sh`.

## Rationale

A Windows Git Bash session (cli 5.114.0, core 15.0.136) spent more than two hours on one HQ prompt. `/learn` ran `qmd vsearch` for policy dedup, which auto-downloaded a ~1.28GB GGUF, on top of dozens of sequential Bash/PowerShell and browser calls. `qmd search` would have answered the same dedup question without pulling a model. The last failing tool call in that report (`hq feedback --body-file /tmp/...`) was a separate MSYS-path bug; this rule covers the download stall.
