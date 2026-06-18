# Ontology Gardener

The **ontology gardener** is a Claude-powered entity-extraction pipeline that runs in the HQ cloud backend against each company's per-entity vault bucket. It treats `knowledge/`, `sources/`, and `signals/` as three first-class corpuses and produces:

1. An entity graph at `ontology/entities/{type}/{slug}.md` (person, project, company, concept)
2. A situational-awareness brief at `company-brief.md` (bucket root)
3. Entity-ref enrichment (frontmatter + inline wiki-links) on knowledge and source files

Canonical implementation lives in the HQ cloud backend (internal). · Per-company knowledge bases should reference this doc rather than re-describing the pipeline.

## When to use this from an agent

Read the gardener's output when you need:

- **Situational awareness** about a company — what's been decided/discussed/risked recently → `company-brief.md`
- **Entity context** — what's known about a person/project/company → `ontology/entities/{type}/{slug}.md`
- **Activity signal** — which entities are "hot" right now → `signal_count` on each entity file
- **Cross-reference resolution** — what signals/sources reference this entity → entity Relationships section + `entity_refs[]` in signal frontmatter

Do NOT read raw `knowledge/`, `sources/`, or `signals/` files to answer broad "what's going on" questions — read the brief first; it's compressed and ranked.

## Trigger model

- **EventBridge schedule** every 4 hours per company
- **S3 PUT notifications** on `knowledge/`, `sources/`, `signals/` prefixes — gardener invoked within seconds of the write
- **Direct invoke** for ad-hoc runs (see "Forcing a fresh run" below)

Change detection uses a single watermark at `ontology/.last-run` (ms since epoch). Only files modified after the watermark are processed. Watermark is bumped only when changes are detected (no-change runs keep the previous value).

## Three corpus branches

| Corpus | Model (default) | Trigger condition | Cost ceiling |
|---|---|---|---|
| `knowledge/` | Sonnet 4.6 | Any modified file | Existing per-run budget |
| `signals/` cheap path | none (no LLM) | Always — reads `entity_refs[]` frontmatter, increments `signal_count` + appends back-refs on existing entities | $0 |
| `signals/` LLM path | Haiku 4.5 | Only when a signal has unresolved `entity_refs[]` OR no refs at all | `signals.max_cost_usd` (default $0.50/run) |
| `sources/` | Haiku 4.5 | Modified source files; chunked at `sources.chunk_token_budget` (12k tokens); skipped if `sources.skip_if_signaled=true` (default) and a covering signal already exists for that day | `sources.max_cost_usd` (default $1.00/run) |

Per-corpus sub-budgets prevent a flood of one corpus from starving the others.

## Outputs

### `ontology/entities/{type}/{slug}.md`

```yaml
---
type: person | project | company | concept
canonical_name: ...
slug: ...
signal_count: 12           # bumped by signal-refs ingester
last_updated: 2026-05-26T...
first_seen: 2026-05-22T...
enriched_by: ontology-gardener
---

# {Canonical Name}

{Body — short description, relationships, attributes...}

## Relationships
- Referenced in [decision: Switch to Haiku for signals](../../signals/decision/abc.md)
- Referenced in [risk: VPC NAT cost overrun](../../signals/risk/def.md)
...
```

### `company-brief.md` (bucket root)

```
## Recent Signals              <- top N per type, per brief.max_signals_per_type (default 5)
  - {decision: ...}
  - {risk: ...}
  - {question: ...}

## Source Channels             <- last-7d count per channel from sources/_index/<date>.json
  - meeting: 12
  - email: 47
  - slack: 0
  - linear: 3
  - notion: 1

## {Top entities by signal_count}
  ...
```

Sections are truncated in this order when `brief.max_tokens` is tight: signals → sources → entities. Signals and sources go first so the brief is small enough to inline in agent contexts.

### Annotated sources

`sources/*.md` files (meetings, email, slack, linear, notion) get enriched in-place with `entities[]` frontmatter + inline `[[ontology/entities/...]]` wiki-links. Signals are NOT annotated (they're hash-named extracted artifacts).

## Per-company configuration

Config at `ontology/config.yaml` in each company's vault bucket:

```yaml
signals:
  enabled: true                # opt out per-corpus
  model: haiku-4.5
  max_cost_usd: 0.50
sources:
  enabled: true
  model: haiku-4.5
  max_cost_usd: 1.00
  chunk_token_budget: 12000
  skip_if_signaled: true
annotator:
  sources:
    max_cost_usd: 0.50
brief:
  max_tokens: 2000
  max_sections: 8
  max_signals_per_type: 5
```

No config = default applied silently on first run.

## Observability

CloudWatch namespace: the gardener's published namespace (set per HQ cloud backend deploy). Dimensions:
- `CompanyId` (primary) — partition per tenant
- `Prefix` ∈ {`knowledge`, `sources`, `signals`} — partition per corpus

Counters published per run:
- `filesScanned`, `filesChanged`, `entitiesExtracted`, `entitiesCreated`, `entitiesUpdated`, `tokensUsed`, `costEstimate`
- `SignalRefsResolved` / `SignalRefsUnresolved` — cheap-path hit rate (under `Prefix=signals`)

Alarms:
- `ontology-signals-run-cost-{stage}` fires at $0.50/run
- `ontology-sources-run-cost-{stage}` fires at $1.00/run
- `ontology-stale-gardener-{stage}` fires if no successful run in N hours
- `ontology-daily-cost-ceiling-{stage}` fires at $10/day (cumulative)

Dashboard: `HQ-OntologyGardener-{stage}` — per-prefix invocation graphs + cheap-path resolved/unresolved ratio.

Metric publish is best-effort: errors are caught and logged, never thrown.

## Forcing a fresh run

For verification or ad-hoc processing:

```bash
# Manual invoke with synthetic scheduled event
aws lambda invoke --function-name <gardener-lambda-name> \
  --invocation-type RequestResponse --cli-binary-format raw-in-base64-out \
  --payload '{"version":"0","detail-type":"Scheduled Event","source":"aws.events","detail":{}}' \
  /tmp/response.json
```

Caveats:
- The gardener Lambda uses **AWS S3 Files** mounted at `/mnt/s3-{company}/`. Direct `aws s3 cp` PUTs to the bucket may not appear in the mount immediately. Production paths (signals-agent, transcript ingester, source writers in `infra/meeting-storage.ts`) write THROUGH the mount and are immediately visible. Use those for end-to-end tests.
- Watermark at `ontology/.last-run` can be read via S3 API directly (`aws s3 cp s3://{bucket}/ontology/.last-run -`). Editing it forces a re-scan window.

## Gotchas

- S3 keys have NO `company_` prefix — the per-entity vault bucket is already company-scoped.
- Entity IDs are deterministic: `sha256(type:canonicalName)`. Renaming the canonical name = new entity.
- ECS Fargate fallback exists gated by `OntologyEcsFallbackEnabled` secret (default off). Use it for buckets larger than Lambda's 15-min timeout.
- Brief generation requires ≥3 entities; skipped silently below that threshold.
- The `S3_BUCKET` env var on the gardener Lambda is the operating company's vault bucket today. The Lambda is single-tenant per deploy — multi-tenant rollout to other companies requires per-company Lambda instances OR a multi-tenant rewrite (separate PRD).

## Related

- Skill: `.claude/skills/ontology/SKILL.md` — agent-facing API for consuming gardener output
- Per-company knowledge: companies SHOULD have a short `companies/{co}/knowledge/integrations/ontology.md` pointing here, NOT a duplicate description
- ADR: the HQ cloud backend's ADR-0005 (internal) covers per-corpus sub-budgets, skip_if_signaled gate, Haiku default, annotator-on-sources, single-watermark rationale
- Code: the HQ cloud backend's ontology Lambda + SST infra (internal)
