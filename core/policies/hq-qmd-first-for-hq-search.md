---
id: hq-qmd-first-for-hq-search
title: Use qmd First for HQ Search
when: grep || vsearch || (qmd && embed) || (qmd && query) || (qmd && pull)
on: [PreToolUse]
enforcement: soft
tier: 1
version: 4
created: 2026-05-14
updated: 2026-10-13
source: user-correction
public: true
---

## Rule

ALWAYS use `qmd` first for HQ search across content, indexed repos, projects, workers, policies, and knowledge.

In a user-facing turn, use **`qmd search` (BM25)** by default. It needs no local GGUF model.

Use `qmd vsearch` or `qmd query` only when `~/.cache/qmd/models/` already contains a GGUF (or `QMD_MODELS_DIR` does). NEVER run `qmd vsearch`, `qmd query`, `qmd embed`, or `qmd pull` in the foreground when that cache is empty — first use auto-downloads ~300MB–2GB and has stalled a single Windows HQ prompt for more than two hours. Build embeddings out of band with `hq index background`, or with `run_in_background: true`.

Fall back to Grep, shell search, or direct file listing only when `qmd` is unavailable, errors, or the task is exact pattern matching in already-scoped code.

A BM25 search that runs but returns zero results is not a reason to fall back. BM25 matches only words that appear in the indexed text, so a query phrased differently from the source returns nothing even when the content exists. On an empty BM25 result, first retry with `qmd query` (or `qmd vsearch`) when the model cache is present; otherwise retry `qmd search` with 2–3 rephrasings (synonyms, the likely title, the artifact type). Fall back to Grep only after those also return nothing.

When piping a CLI through `grep`, check the command's own output first. `cmd | grep x` printing nothing can mean the command failed (for example an unknown subcommand), not that nothing matched.

On Windows, batch independent shell work into one Bash tool call. Each Git Bash spawn is expensive; dozens of sequential console calls plus a cold model download is how a prompt blows past two hours.

## Rationale

HQ is indexed with qmd so searches stay scoped, fast, and aligned with the workspace's semantic collections. Broad Grep or shell search from HQ root is noisy, can traverse irrelevant generated data, and misses the intended collection model.

`qmd vsearch` / `qmd query` / `qmd embed` / `qmd pull` auto-download GGUF models into `~/.cache/qmd/models/` on first use (~300MB embedding, ~640MB reranker, ~1.1GB query expansion). A Windows Git Bash session (cli 5.114.0, core 15.0.136) spent more than two hours on one prompt after `/learn` ran an in-turn `qmd vsearch` dedup that pulled ~1.28GB, on top of dozens of sequential Bash/PowerShell calls. BM25 (`qmd search`) does not pull models and is the in-turn default.

Empty-result escalation (2026-10-13): a session asked to find an existing deployed document ran one BM25 query worded differently from the document, got zero results, and switched to grep. The grep pipeline also hid a failed CLI subcommand. The session needed several user corrections and never found the document. One `qmd query` with similar wording returned it as the top hit.
