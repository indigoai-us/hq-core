---
name: ontology
description: Read a company ontology brief, entity graph, and freshness signals for context.
---

# Ontology (HQ-shared)

Read the ontology gardener's output for the active company. Background on the gardener pipeline lives at `core/knowledge/public/hq-core/ontology-gardener.md` — read that ONCE per session if you need mechanism details; this skill is the runtime API.

## When to use

Use this skill when an agent needs:

- **Situational snapshot** of a company → read `company-brief.md` (gardener-generated, ranked + token-budgeted)
- **Entity context** for a known person/project/company/concept → read `ontology/entities/{type}/{slug}.md`
- **Activity signal** — which entities are hot recently → sort by `signal_count` (frontmatter)
- **Cross-references** — what signals/sources mention an entity → entity's Relationships section
- **Manual run** — to refresh the brief or process new files immediately rather than waiting for the 4h tick

Do NOT use this for:
- Querying the indigo-signals-mcp MongoDB collections (that's a different store; use the MCP server / `/indigo:signals` skill)
- Triaging action items / commitments (use `/indigo:signals` or `/indigo:action-items`)
- Reading raw `knowledge/`, `sources/`, or `signals/` files individually (slow + noisy — read the brief)

## Step 0 — resolve active company

The gardener output lives in the company's per-entity vault bucket. Resolve:

- Active company slug from session context (e.g. `companies/manifest.yaml` company anchor, `~/.hq/active-company`, or ask the user if ambiguous)
- That company's vault bucket — look up via `companies/{co}/manifest.yaml` `vault_bucket` field OR derive from the gardener Lambda env (`S3_BUCKET`) if the user is operating hq-pro
- That company's gardener Lambda — `hq-pro-hq-prod-OntologyGardenerFnFunction-*` if deployed; check `aws lambda list-functions --query "Functions[?contains(FunctionName,'OntologyGardener') && contains(FunctionName,'hq-prod')].FunctionName" --output text`

Announce: `Ontology context: {company} · bucket {bucket} · gardener {fn-name}`

If the active company has no gardener deployed yet (multi-tenant rollout still in progress), say so and stop — there's nothing to read.

## Step 1 — Read the brief (default action)

```bash
aws s3 cp s3://{bucket}/company-brief.md - 2>&1
```

The brief is the **first thing** to read for any "what's going on" question. Sections in order:

1. `## Recent Signals` — top N decisions/risks/questions (per `brief.max_signals_per_type`, default 5)
2. `## Source Channels` — last-7d count per channel (meeting/email/slack/linear/notion)
3. Entity sections — top entities by `signal_count`

If the brief is empty / missing, the gardener has either never run or never had ≥3 entities. In that case, fall back to listing recent signals directly: `aws s3 ls s3://{bucket}/signals/ --recursive | tail -20`.

## Step 2 — Targeted entity lookup

If the user asks about a specific person/project/company/concept:

```bash
# Find the entity slug — try canonical name → slug deterministically
SLUG=$(echo "{Name}" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g' | sed 's/[^a-z0-9-]//g')

# Try each type until one resolves (or query the entity index if available)
for TYPE in person project company concept; do
  aws s3 cp "s3://{bucket}/ontology/entities/$TYPE/$SLUG.md" - 2>/dev/null && echo "found in $TYPE" && break
done
```

Read the frontmatter for `signal_count`, `last_updated`, `first_seen`. Read the body for description + Relationships section.

## Step 3 — "What's hot recently"

Sort entities by `signal_count`:

```bash
aws s3 sync s3://{bucket}/ontology/entities/ /tmp/entities-{co}/ --quiet
for f in /tmp/entities-{co}/**/*.md; do
  count=$(grep -m1 '^signal_count:' "$f" | awk '{print $2}')
  echo "$count $f"
done | sort -rn | head -10
```

Returns the top-10 most-referenced entities. Useful for "who/what is dominating recent activity".

## Step 4 — Manual gardener run

Trigger an ad-hoc gardener invocation (don't wait for the 4h tick):

```bash
GARDENER_FN=$(aws lambda list-functions \
  --query "Functions[?contains(FunctionName,'OntologyGardener') && contains(FunctionName,'hq-prod')].FunctionName | [0]" \
  --output text)

aws lambda invoke --function-name "$GARDENER_FN" \
  --invocation-type RequestResponse --cli-binary-format raw-in-base64-out \
  --payload '{"version":"0","detail-type":"Scheduled Event","source":"aws.events","detail":{}}' \
  --log-type Tail /tmp/gardener-response.json 2>&1 | jq -r '.LogResult' | base64 -d | tail -20
```

Limitations:
- Uses **AWS S3 Files** mount at `/mnt/s3-{company}/`. Files PUT via `aws s3 cp` may not appear in the mount immediately. Production writers (signals-agent, transcript ingester, source-writer in `infra/meeting-storage.ts`) DO write through the mount and ARE immediately visible. Use those for end-to-end tests.
- One company per Lambda today. Multi-tenant rollout to other companies is a separate PRD.

## Step 5 — Inspect cheap-path hit rate

The gardener emits `SignalRefsResolved` + `SignalRefsUnresolved` counters. High resolved/unresolved ratio = the signals agent is doing a good job of pre-linking entities (no LLM needed for ingestion).

```bash
NOW=$(date -u +%FT%TZ)
ONE_DAY_AGO=$(date -u -v-1d +%FT%TZ 2>/dev/null || date -u -d '1 day ago' +%FT%TZ)

aws cloudwatch get-metric-statistics \
  --namespace HQPro/OntologyGardener \
  --metric-name SignalRefsResolved \
  --dimensions Name=CompanyId,Value={company} Name=Prefix,Value=signals \
  --start-time "$ONE_DAY_AGO" --end-time "$NOW" \
  --period 3600 --statistics Sum --output text

aws cloudwatch get-metric-statistics \
  --namespace HQPro/OntologyGardener \
  --metric-name SignalRefsUnresolved \
  --dimensions Name=CompanyId,Value={company} Name=Prefix,Value=signals \
  --start-time "$ONE_DAY_AGO" --end-time "$NOW" \
  --period 3600 --statistics Sum --output text
```

If unresolved >> resolved, either (a) the signals agent is producing signals for entities not yet in the graph (gardener will LLM-extract them on the next run, capped by `signals.max_cost_usd`), or (b) the entity files were renamed and `entityIdFromPath` no longer resolves the refs.

## Step 6 — Inspect logs / metrics dashboards

- Logs: `aws logs tail /aws/lambda/{GARDENER_FN} --follow --since 5m --format short`
- Dashboard: CloudWatch `HQ-OntologyGardener-hq-prod` — per-prefix invocation graphs, cheap-path hit rate, cost
- Cost alarms: `ontology-signals-run-cost-{stage}`, `ontology-sources-run-cost-{stage}`, `ontology-daily-cost-ceiling-{stage}`, `ontology-stale-gardener-{stage}`

## Multi-tenant note

Today the gardener is single-tenant — there's one Lambda instance bound to indigo (`COMPANY_ID=indigo`, mount `/mnt/s3-indigo`). For another company to benefit from this skill, hq-pro infra needs to provision a per-company Lambda OR rewrite the single Lambda to loop over companies. Track in a future PRD; until then this skill is functionally indigo-only even though its design is multi-tenant.

## Rules

- Read the brief FIRST. Don't iterate entity files until you've checked the ranked summary.
- Don't write to the vault from this skill — gardener writes are authoritative. To force a re-run, invoke the Lambda (Step 4), don't touch entity files directly.
- Don't synthesize signal_count or other counters — read the real values from the vault.
- Respect company isolation: the skill operates on the resolved active company's vault only. Never reach into another company's bucket.
- If a question can be answered without a gardener call (e.g. read `company-brief.md` directly), skip Step 4.
