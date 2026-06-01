---
name: hq-cowork-search
description: Hybrid full-text + semantic search across HQ content (policies, skills, knowledge, workers, projects, per-company collections) from a sandboxed Claude Code plugin host (Cowork). Calls the host-side `hq_search` MCP tool, which wraps `qmd query` (hybrid: expansion + RRF + rerank — the recommended search mode). Use when the agent needs to find HQ content but `qmd` isn't reachable from its bash sandbox.
allowed-tools: mcp__hq__hq_search
---

# /hq-cowork-search — Search HQ from a sandboxed agent

Searches indexed HQ content via the host-side `qmd` binary, surfaced as an
MCP tool so a sandboxed agent (Cowork) can use it even though `qmd` isn't
installed inside its Linux VM.

**Args:** `$ARGUMENTS` — query plus optional flags.

| Arg | Meaning |
|---|---|
| `<query>` (positional, required) | Natural-language search query. |
| `-c <collection>` / `--collection <collection>` | Scope to one collection (e.g. `hq-infra`, `hq-knowledge`, `indigo`). |
| `-n <N>` / `--limit <N>` | Number of results (default 10, max 50). |
| `--format json\|md\|files` | Output format. Omit for the default human snippet. |

Collections worth knowing about (varies per HQ install — run `qmd ls` on the
host to enumerate):

- `hq-infra` — skills, policies, hooks
- `hq-knowledge` — `core/knowledge/public/hq-core/`
- `hq-workers`
- `hq-projects`
- `{company-slug}` — per-company knowledge, one collection per company

## When to use this instead of `/search`

- **You're in Cowork or another sandboxed plugin host** — the regular `/search`
  skill (and the `qmd` charter rule that says "qmd first") relies on the
  `qmd` binary on PATH, which isn't true inside the sandbox.
- **You want JSON results for downstream programmatic use** — pass
  `--format json` and parse the response.

On a host-side session, prefer the unprefixed `/search` or `qmd query`
directly — fewer hops, same results.

## What you do

### Step 1 — Parse the query

Extract `<query>` (required) and optional flags. Without a query, ask what
the user is looking for. If the query is vague ("find docs"), ask for a more
specific phrase — qmd hybrid is good but not magic.

### Step 2 — Call the tool

```json
{
  "query": "<query>",
  "collection": "<collection>",   // omit to search all
  "limit": <N>,                   // omit to use default 10
  "format": "cli|json|md|files"   // omit to use default cli
}
```

Call `mcp__hq__hq_search`.

### Step 3 — Surface results

For `cli` / `md` format, render the tool output as-is (already
human-readable). For `json` / `files`, summarize: top 5 paths + scores,
then offer to read the most relevant via the host MCP if the user wants
the body.

If no results, suggest broadening — drop the `collection` filter, try a
synonym, or fall back to `qmd vsearch` (pure semantic) via a follow-up
call with a different query phrasing.

## Why this skill exists

The HQ charter mandates "qmd first" for HQ search — but only a host-side
session can actually shell out to the `qmd` binary. Inside Cowork's
sandbox, neither `qmd` nor the index DB it reads (`~/.qmd/`) is reachable.
The `hq-pack-cowork` MCP server runs `qmd query` (hybrid: expansion + RRF +
rerank) on the host and returns
the formatted result. This skill is the in-session adapter.
