---
name: search
description: Search across HQ and indexed repos (qmd-powered semantic + full-text). Falls back to Grep if qmd is unavailable.
allowed-tools: Read, Grep, Bash(qmd:*), Bash(grep:*), Bash(ls:*)
---

# Search - HQ + Codebase Search

Semantic + full-text search across HQ and indexed codebases using qmd. Falls back to Grep if qmd is unavailable.

**Input:** The user's search query, with optional flags.

## Parse Arguments

Extract from the user's input:
- `query` — search text (everything except flags)
- `--mode` — `search` (BM25), `vsearch` (semantic), `query` (hybrid). Default: `search`
- `-n` — result count (default: 10)
- `-c` — collection name (e.g. `hq-infra`, `hq-workers`, `{product}`). Default: auto-detect or all collections
- `--full` — show full content of top result

## Company Auto-Detection

If `-c` was NOT explicitly provided, infer the active company from context:

1. **cwd**: If inside `companies/{name}/` or `repos/private/` matching a company repo per `companies/manifest.yaml` → use that company's collection
2. **Active worker**: If `/run {worker}` is active and worker has `company:` field → use that company's collection
3. **Recent files**: If recent file access is scoped to a single company → use that company's collection
4. **Fallback**: No collection flag (search all)

Available collections: `hq-infra` (commands/skills/policies), `hq-workers` (worker defs), `hq-knowledge` (shared knowledge), `hq-projects` (PRDs), `{product}` ({PRODUCT} codebase), + one per company. Omit `-c` to search all.

When auto-detected, display: `(auto: {company})` in results header.

## Check qmd Availability

```bash
which qmd 2>/dev/null && qmd --version 2>/dev/null
```

If qmd is not available, skip to **Fallback** section.

## Execute Search

Run the matching qmd command. Add `-c $COLLECTION` if a collection was specified or auto-detected:

**Default (BM25 full-text):**
```bash
qmd search "$QUERY" -n $N --json [-c $COLLECTION]
```

**Semantic (conceptual match):**
```bash
qmd vsearch "$QUERY" -n $N --json [-c $COLLECTION]
```

**Hybrid (BM25 + vector + re-rank — best quality, slower):**
```bash
qmd query "$QUERY" -n $N --json [-c $COLLECTION]
```

## Display Results

Parse JSON output. Display:

```
Search: "{query}" (mode: {mode}, collection: {collection or "all"})

Results:
  1. [0.92] hq: knowledge/public/Ralph/02-core-concepts.md
     "Ralph methodology emphasizes small loops with human checkpoints..."

  2. [0.84] {product}: libs/core/src/auth/middleware.ts
     "export function authMiddleware..."

  3. [0.71] hq: workers/public/dev-team/architect/skills/design-review.md
     "Architecture review following Ralph back-pressure patterns..."

{n} results. Use --full to show top result content.
```

- Score in brackets
- Collection prefix + relative path (strip `qmd://{collection}/` prefix)
- Snippet truncated to ~100 chars

## Full Content

If `--full` flag, after listing results, read the top result file with the Read tool.

## Fallback

If qmd is unavailable or errors:

Use the Grep tool to search file contents:
- Search pattern: the query text
- Search directories: `knowledge/`, `companies/`, `workers/`, `.claude/commands/`, `workspace/`
- Show matching file paths

Display: "qmd unavailable, falling back to Grep"

If Grep is also unavailable, run:
```bash
grep -rl "$QUERY" ~/HQ/knowledge/ \
  ~/HQ/companies/ \
  ~/HQ/workers/ \
  ~/HQ/.claude/commands/ \
  ~/HQ/workspace/ 2>/dev/null | head -20
```

## Examples

```
search ralph                                    # BM25 keyword search (default, all collections)
search "how do workers execute" --mode vsearch  # Semantic across all
search auth middleware -c {product}                   # Search {PRODUCT} codebase only
search "webhook handler" -c {product} --mode vsearch  # Semantic search in {PRODUCT}
search {company} brand --mode query            # Hybrid with re-ranking
search stripe -n 20                             # More results
search authentication --full                    # Show top match content
search "brand guidelines" -c {company}         # Search {company} knowledge only
search "recovery metrics" -c {company}        # Search {Product} knowledge only
# If cwd is companies/{company}/:
search "case study"                             # Auto-detects → -c {company}
```

## Notes

- Default `search` mode is fastest — use for exact keywords
- Use `--mode vsearch` for conceptual/semantic queries
- Use `--mode query` for highest quality (slower, uses LLM re-ranking)
- Use `-c` to scope to a collection: `hq-infra`, `hq-workers`, `hq-knowledge`, `hq-projects`, `{product}`, + company collections (run `qmd status` for full list)
- Without `-c`, auto-detects company from context; falls back to all collections
- Scores 0.0–1.0; above 0.5 is a good match
- Run `/search-reindex` after adding new content
- For exact pattern matching in code (imports, function names), use Grep directly
