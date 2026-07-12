# Grok Build — message canvas & swarm sidepane

Grok-only project rule. Do not mirror into Claude hooks or the shared root charter.

When replying in this HQ tree, prefer **message-canvas-friendly** markdown so Grok Build Desktop renders rich UI:

1. **Callouts** — GitHub alert blockquotes:
   - `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`
2. **Tables** — GFM pipe tables for multi-attribute status / file grids.
3. **Charts** — fenced JSON with language `chart`, `chart-bar`, or `chart-line`:
   - Body: `{ "type": "bar"|"line", "title"?: string, "labels": string[], "values": number[] }`
4. **Stats / cards** — fenced JSON with language `stats` or `card`:
   - Body: `[{ "label", "value", "delta"? }, ...]` or `[["Label","Value"], ...]`

## Swarm / subagent sidepane

When spawning or finishing subagents (Task / `spawn_subagent` / agent-team):

- **name** — short 3–6 word `description` on spawn (sidepane title).
- **status** — let tool status drive `pending|running|done|error|cancelled`.
- **summary** — final reply leads with ≤ ~280 char outcome summary.
- **files** — list touched paths (`files` / `paths` / path fields on result).

Prefer **worker-backed durable swarms** for background research/dev/review (not
only pretty sidepane rows). See `.grok/rules/prefer-swarms.md`.

Full schema, examples, and promote-to-hq-core path:

- `personal/knowledge/public/hq-core/grok-build-message-canvas.md`
- After reindex: `core/knowledge/public/hq-core/grok-build-message-canvas.md`
- Swarm + workers + FS memory: `personal/knowledge/public/hq-core/grok-build-swarm-workers.md`
