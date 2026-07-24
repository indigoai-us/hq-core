---
type: reference
domain: [engineering, product]
status: draft
public: true
tags: [grok, grok-build, message-canvas, markdown, callouts, charts, swarm, desktop]
relates_to:
  - quick-reference.md
  - desktop-claude-code-integration.md
---

# Grok Build — Message Canvas & Swarm Sidepane

**Audience:** Grok Build (CLI / Desktop) agents working inside HQ.  
**Goal:** Emit reply markdown that the Grok Build Desktop **message canvas** renders as rich UI (callouts, tables, chart/stats fences), and structure subagent work so the **swarm sidepane** shows useful rows (name, status, summary, files).

This is Grok-facing guidance. Claude Code does not need these fences; do not inject this into Claude hooks or the shared root `AGENTS.md` charter.

---

## 1. Message canvas — default formatting

Desktop renders assistant text as GFM (CommonMark + tables/task lists). Prefer:

| Prefer | Avoid |
|--------|--------|
| Short headers + bullets | Walls of prose for enumerations |
| GFM tables for 2+ parallel attributes | ASCII tables in code fences |
| Callouts for caveats / decisions | ALL-CAPS WARNING lines |
| `chart` / `stats` fences for quantitative data | Pasted screenshots of numbers |
| Absolute-path markdown links | Bare paths without links |

Match structure to the task: a one-line answer stays prose; multi-file / multi-status results use tables.

---

## 2. Callouts — GitHub alert syntax

Desktop upgrades blockquotes that start with a GitHub-style alert tag into colored callout cards.

### Supported kinds

| Tag | Renders as | Use when |
|-----|------------|----------|
| `[!NOTE]` | Note | Neutral context, skim-worthy info |
| `[!TIP]` | Tip | Optional better path / shortcut |
| `[!IMPORTANT]` | Important | Must-succeed requirement |
| `[!WARNING]` | Warning | Risk, irreversible step, security |
| `[!CAUTION]` | Warning (same style as WARNING) | Same as warning |

Also accepted (plain prefix inside a blockquote): `Note:`, `Tip:`, `Warning:`, `Important:`, `Caution:`.

### Syntax

Every line of the callout is a blockquote line. Tag alone on the first line, body after:

```markdown
> [!NOTE]
> HQ reads `personal/knowledge/` directly (the reindex symlink mirror into
> `core/knowledge/` was retired). Personal never overwrites a real core file.

> [!WARNING]
> Do not push the HQ root. Only repos under `repos/` get pushed.
```

Inline form (tag + body on first line) is also accepted:

```markdown
> [!TIP] Prefer `hq secrets exec` over pasting tokens into the shell.
```

### Rules of use

- One callout per concern; do not nest callouts.
- Keep body to 1–4 short lines.
- Use WARNING/IMPORTANT sparingly — if everything is a callout, nothing is.

---

## 3. Tables

Use standard GFM pipe tables for status grids, before/after, and file inventories:

```markdown
| Path | Change | Status |
|------|--------|--------|
| `src/lib/rightRail.ts` | swarm contract | done |
| `src/components/SwarmPanel.tsx` | sidepane UI | done |
```

Keep cells short (labels, paths, enums). Put explanation above or below the table, not inside cells.

---

## 4. Chart fences — `chart` JSON

Fenced blocks with language `chart`, `chart-bar`, or `chart-line` render as pure-SVG charts when the body is valid JSON.

### Schema

```json
{
  "type": "bar",
  "title": "Optional title",
  "labels": ["Mon", "Tue", "Wed"],
  "values": [12, 18, 9]
}
```

| Field | Type | Required | Notes |
|-------|------|----------|--------|
| `labels` | `string[]` | yes | Category labels; length must match `values` |
| `values` | `number[]` | yes | Finite numbers only |
| `type` | `"bar"` \| `"line"` | no | Default `bar`. Fence lang can force type |
| `title` | `string` | no | Chart caption |

### Fence languages

| Fence | Chart type |
|-------|------------|
| ` ```chart ` | Uses JSON `type`, else bar |
| ` ```chart-bar ` | Always bar |
| ` ```chart-line ` | Always line |

### Example

````markdown
```chart
{
  "type": "bar",
  "title": "Stories closed this week",
  "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"],
  "values": [2, 5, 3, 4, 6]
}
```
````

Malformed JSON falls back to a normal code block (no crash). Prefer charts for 3–12 categories; use a table for sparse one-off numbers.

---

## 5. Stats / card fences — `stats` and `card`

Fenced blocks with language `stats` or `card` render as a row of metric cards.

### Accepted JSON shapes

**Array of objects:**

```json
[
  { "label": "Open PRs", "value": "12", "delta": "+3" },
  { "label": "Pass rate", "value": "94%", "delta": "-1%" }
]
```

**Array of pairs:**

```json
[["Open PRs", "12"], ["Pass rate", "94%"]]
```

**Wrapped object** (uses first of `items` / `metrics` / `stats`):

```json
{
  "items": [
    { "label": "Companies", "value": "14" },
    { "label": "Open projects", "value": "7", "delta": "+2" }
  ]
}
```

| Field | Type | Required | Notes |
|-------|------|----------|--------|
| `label` | string | yes | Metric name |
| `value` | string \| number | yes | Displayed large |
| `delta` | string | no | `+` prefix → positive style; `-` → negative |

### Example

````markdown
```stats
[
  { "label": "Agents", "value": "4", "delta": "+2" },
  { "label": "Files touched", "value": "18" },
  { "label": "Duration", "value": "6m 12s" }
]
```
````

`card` is an alias of `stats` (same parser).

---

## 6. Swarm / subagent sidepane contract

Grok Build Desktop’s right-rail **Swarms** tab builds rows from subagent tool calls (`spawn_subagent`, Task, agent-team, etc.). Agents should make those rows scannable by how they **spawn** and **finish**.

### Sidepane fields (what the UI shows)

| Field | Source | Agent guidance |
|-------|--------|----------------|
| **name** | `description` arg, or `name` / `subagent_type` / `role` in input; else first ~48 chars of prompt | Pass a short human name (3–6 words) in `description` (spawn tool) — e.g. `Explore auth module`, not a paragraph |
| **status** | tool status mapped to `pending` \| `running` \| `done` \| `error` \| `cancelled` | Let the harness drive status; do not fake completion in prose while tools still run |
| **summary** | completion result: prefer `summary` / `message` / `text` / `output` fields (≤ ~280 chars in UI) | End subagent work with a **one-paragraph summary first**; optional detail after |
| **files** | `files` / `paths` / `touched` arrays, or `path` / `file_path` / `target_file` scalars on input or result | List concrete paths the subagent edited or key-read (cap ~24 shown) |
| **tools** (detail) | `tools` / `tool_names` arrays | Optional; list major tools only if useful |

### Recommended subagent return shape

When a subagent finishes (final message or structured result), lead with:

```markdown
## Summary
Auth middleware now rejects expired JWTs; added regression tests.

### Files
- `src/middleware/auth.ts`
- `src/middleware/auth.test.ts`

### Status
done
```

Or a compact JSON result the parent / UI can parse:

```json
{
  "summary": "Auth middleware rejects expired JWTs; tests green.",
  "status": "done",
  "files": [
    "src/middleware/auth.ts",
    "src/middleware/auth.test.ts"
  ]
}
```

### Spawn hygiene (parent agent)

When calling `spawn_subagent` / Task:

1. **`description`** — short sidepane title (required for a good name).
2. **`prompt`** — full task; include “return a Summary + Files list when done.”
3. Prefer parallel independent spawns over serial narration.
4. On aggregate, parent message can use a table of agent → status → summary, plus callouts for blockers.

### Example parent rollup (message canvas)

```markdown
## Swarm result

| Agent | Status | Summary |
|-------|--------|---------|
| Explore auth module | done | Found JWT expiry gap in middleware |
| Fix + tests | done | Patch + 3 tests green |
| Docs pass | cancelled | Superseded by fix summary |

> [!NOTE]
> Two files changed under `src/middleware/`. No public API break.
```

---

## 7. Promote to public hq-core

This doc is authored under the personal knowledge overlay so it survives `/update-hq` and can be scrubbed before shipping.

### Staging path (this worktree / HQ)

| Role | Path |
|------|------|
| **Authoring (now)** | `personal/knowledge/public/hq-core/grok-build-message-canvas.md` |
| **Runtime symlink (after reindex)** | `core/knowledge/public/hq-core/grok-build-message-canvas.md` |
| **Grok-only always-on pointer** | `.grok/rules/message-canvas.md` |

Frontmatter already sets `public: true` so promote-scan treats it as push-eligible knowledge (not hook/script opt-in).

### Promote / stage flow

1. **Reindex (optional local visibility)** — master-sync / reindex so personal knowledge appears under `core/knowledge/…` without clobbering real core files.
2. **Stage kit (no PR)** — `/stage-kit --item personal/knowledge/public/hq-core/grok-build-message-canvas.md` (or the remapped core path once linked). Stages a scrubbed copy into the public kit working tree per stage-kit allowlist rules.
3. **Promote HQ core (staging buffer)** — `/promote-hq-core` (or `--scan-only` first):
   - Scans HQ ↔ `repos/private/hq-core-staging`
   - Uses frontmatter `public: true` / `# hq-core: public` for eligibility
   - Deterministic PII gate; triage LOCAL_ONLY / DIFFERENT rows
   - Apply push into staging, then open/land PR staging → public `hq-core`
4. **Do not** hand-edit `repos/public/hq-core/` for knowledge unless following the same scrub + allowlist path as stage-kit.

### Grok-only inject (do not break Claude)

| Mechanism | Claude impact | Notes |
|-----------|---------------|--------|
| `.grok/rules/*.md` | None | Grok always scans `.grok/rules/`; safe for canvas guidance |
| `.grok/README.md` pointer | None | Human + agent discoverability |
| Root `AGENTS.md` / `.claude/` hooks | **Would affect Claude** | Do **not** put canvas rules there |
| `personal/knowledge/...` | None by itself | Loaded when agents read/search knowledge |

---

## 8. Quick checklist for Grok replies

- [ ] Multi-status data → GFM **table**
- [ ] Caveats / risks → `> [!NOTE]` / `> [!WARNING]`
- [ ] Trends / comparisons → ` ```chart ` JSON
- [ ] KPI strip → ` ```stats ` JSON
- [ ] Subagents → short **description** name; final **summary** + **files**
- [ ] No canvas guidance written into Claude hooks or shared charter

# hq-core: public
