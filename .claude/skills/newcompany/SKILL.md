---
name: newcompany
description: Scaffold a new HQ company AND optionally take it all the way to operational — business-discovery interview, seeded knowledge/workers/skills/projects, brand design packs (generated from website/PDF/Drive and bound to deploys via policy), connected integrations, org groups + ACL rules, teammate invites, and optional cloud agents.
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
---

# /newcompany — Company Scaffolding → Operational Setup

Create a new company. **Phase 0 (scaffold) always runs and yields a working local
company in seconds.** Everything after Phase 0 is an optional, skippable, fail-soft
guided path that takes the company from "empty folder" to "operational" — populated
knowledge/workers/skills/projects, connected tools, an org model with streamlined ACL
rules, invited teammates, and (optionally) cloud agents.

**Args:** $ARGUMENTS

## Operating principles

- **Fail-soft after Phase 0.** Reaching a working company never depends on any later
  phase. Each phase is independently skippable; skipped items roll into the closing
  "finish later" checklist (Phase 9).
- **One question at a time.** Use `AskUserQuestion` per decision (policy
  `decision-queue-one-at-a-time`). Offer a "skip"/"not now" choice on every optional phase.
- **Tenant isolation.** Every `hq` call is company-scoped with `--company {slug}`.
- **Reuse, don't reinvent.** This skill orchestrates existing primitives
  (`/designate-team`, `/newworker`, `/idea`, `/plan`, `hq groups`, `hq secrets`,
  `hq files`, `hq members invite`, cloud-agent provisioning). It adds the interview + the
  tool-classification logic, nothing more.
- **Secret hygiene.** Never collect a raw credential in chat. Mint a submission link
  (`hq secrets generate-link`) and render it ONLY as a Markdown inline link at mint time
  (policies `hq-share-session-urls-are-capabilities`, `hq-secure-link-render-as-markdown`).

---

## Phase 0 — Scaffold (ALWAYS runs)

### 0.1 Get Company Slug

If no args, ask: "Company slug (lowercase, hyphens only)?"
Validate: no spaces, lowercase only, hyphens allowed, doesn't already exist in `companies/manifest.yaml`.

### 0.2 Basics (batch)

Ask (batch is fine here — these are simple facts):
1. Company name (human-readable)?
2. GitHub org? (or "none")
3. Existing repos to associate? (paths or "none")
4. Existing workers to assign? (or "none")

(Credentials are NOT collected here — Phase 4 handles them properly via minted links.)

### 0.3 Scaffold Directory

```bash
mkdir -p companies/{slug}/{settings,data}
mkdir -p companies/{slug}/workspace/sessions
printf '# HQ workspace mirror — sessions are gitignored, index.jsonl is committed\nsessions/\n' \
  > companies/{slug}/workspace/.gitignore
: > companies/{slug}/workspace/index.jsonl
# Scaffold company.yaml with cloud-disabled default. /designate-team flips
# cloud: true later (and provisions via `hq cloud provision company`).
printf "slug: %s\ncloud: false\n" "{slug}" > companies/{slug}/company.yaml
# Seed an empty board.json so the company's board EXISTS from day one. The
# board lives at the vault root (key `board.json`) and is synced verbatim from
# this file; without it the desktop/console board lookup 404s every poll
# (HQ-77). /idea, /plan, /goals populate it later. Stamp the slug + a UTC
# timestamp; keep the empty objectives/initiatives/projects arrays.
printf '{\n  "company": "%s",\n  "schema_version": 2,\n  "updated_at": "%s",\n  "objectives": [],\n  "initiatives": [],\n  "projects": []\n}\n' \
  "{slug}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > companies/{slug}/board.json
# Copy Obsidian vault config (dereference symlink in template)
[ -e companies/_template/.obsidian ] && cp -rL companies/_template/.obsidian companies/{slug}/.obsidian
```

The `workspace/` directory is the per-company audit trail of HQ sessions that touch this
company. Sessions are hardlinked here from `workspace/threads/` by the mirror hook
(`mirror-thread-to-company.sh`); `index.jsonl` is committed, individual session JSONs are gitignored.

`company.yaml` is the AppBar / cloud-state marker. `cloud: false` is the local-only
default; `/designate-team {slug}` rewrites it to `cloud: true` and runs
`hq cloud provision company {slug}`. Keep the file even for purely-local companies.

### 0.4 Create Knowledge Repo

```bash
mkdir -p repos/private/knowledge-{slug}
cd repos/private/knowledge-{slug}
git init
echo "# {Name} Knowledge\n\nKnowledge base for {Name}." > README.md
mkdir -p design-styles/packs
: > design-styles/packs/.gitkeep
git add -A && git commit -m "init: knowledge base"
```

The `design-styles/packs/` subdir is where company-scoped brand packs live. Create the symlink:
```bash
ln -s ../../repos/private/knowledge-{slug} companies/{slug}/knowledge
```

### 0.5 Update Registries

**manifest.yaml**: Add entry with ALL fields populated (no nulls):
```yaml
{slug}:
  prefix: {auto-computed}
  github_org: {org or omit}
  repos: [{repo paths or empty array}]
  settings: [{setting names or empty array}]
  knowledge: companies/{slug}/knowledge/
  deploy: []
  vercel_projects: []
  qmd_collections: [{slug}]
```

> Company workers are discovered automatically from `worker.company:` inside each
> `companies/{slug}/workers/*/worker.yaml`. No `workers:` array in the manifest —
> `core/workers/registry.yaml` is the regenerated index.

**Compute `prefix`** before writing the entry:
1. Strip hyphens from `{slug}`, lowercase, take first 3 chars (e.g. `acme-corp` → `acm`).
2. Read existing prefixes: `python3 -c "import yaml; d=yaml.safe_load(open('companies/manifest.yaml')); print('\n'.join(v.get('prefix','') for v in d['companies'].values()))"`.
3. If your candidate collides, fall back to first 4 chars (no hyphens). If still collides, append `-2`, `-3`, ….
4. Surface the chosen prefix in the final report.
5. The `auto-mirror-company-skill` PostToolUse hook uses this prefix to bridge top-level
   skills/commands at `.claude/skills/{prefix}-{name}/` and `.claude/commands/{prefix}-{name}.md`.

### 0.6 qmd Collection

```bash
qmd collection add companies/{slug}/knowledge --name {slug} --mask "**/*.md"
qmd update 2>/dev/null || true
```

### 0.7 README + Companies List

- Write `companies/{slug}/README.md` (name, purpose, repos, workers).
- If CLAUDE.md `## Companies` line doesn't include the new slug, update it.

**Checkpoint — the company now works locally.** Announce it, then offer the operational
path: "Want me to set **{Name}** up the rest of the way — learn your business, seed
knowledge, model your team, and connect your tools? (You can stop at any step.)" If they
decline, jump to Phase 9 (finish + report).

---

## Phase 1 — Business Discovery (NEW, optional)

The interview that drives every downstream phase. One question at a time
(`AskUserQuestion`), pattern adapted from `/personal-interview`. Keep it tight (~6–8 Qs);
take a position on vague answers, don't flatter.

Ask, in order:
1. **What does {Name} do?** One-paragraph description of the business + stage/size.
2. **Departments / functions.** Which functions exist or matter (e.g. sales, marketing,
   product/eng, finance, ops, support, HR)? Offer multi-select + free text.
3. **Source-of-truth tool per function.** For each named function, what tool is the
   system of record (e.g. Sales→HubSpot/Salesforce, Finance→QuickBooks/Stripe,
   Eng→GitHub, Docs→Notion/Google Drive, Comms→Slack)?
4. **Top priorities.** The 2–3 things they most want HQ to help with first.
5. **Existing knowledge/assets.** Website, brand docs, existing wikis, repos.
6. **Team.** Who's on the team (names/emails) and rough roles/groupings.

**Write the results** (so downstream phases + future sessions can use them):
- `companies/{slug}/knowledge/company-info.md` — frontmatter (`type: overview`,
  `domain: [operations]`, `status: canonical`, `tags: [company-info, {slug}]`,
  `generated_at: <ISO>`, `source: newcompany`) + the business description, functions,
  priorities. Follow `core/knowledge/public/hq-core/knowledge-taxonomy.md`.
- `companies/{slug}/data/business-model.json` — machine-readable:
  `{ domain, functions:[{name, sourceOfTruthTool}], priorities:[], team:[{name,email,role,group}] }`.
  Phases 2–7 read this.

Skip → company stays scaffold-only; later phases that need this prompt for it inline.

---

## Phase 2 — Seed Knowledge / Projects (NEW, optional)

From Phase 1, populate the folder so it isn't empty:

- **Knowledge:** create taxonomy subdirs only for functions that have content
  (threshold rule: a subdir per domain with ≥1 doc). Seed e.g.
  `knowledge/market/competitive-landscape.md`, `knowledge/operations/workflows.md`,
  `knowledge/<function>/overview.md` from the interview — each with standard frontmatter.
  Keep seeds short and clearly marked `status: draft` where synthesized.
- **Projects:** for each stated priority, create a board idea via the `/idea` shape
  (append to `companies/{slug}/board.json`, id `{prefix}-proj-{NNN}`, `status: idea`).
  Offer to `/plan` the top one into a full PRD (skippable — that's a heavier flow).

Skip → leave knowledge/projects empty (still valid).

---

## Phase 2.5 — Brand & Design Packs (NEW, optional)

Turn the company's existing brand into one or more **design packs** so every downstream
surface (deploy reports, landing pages, decks, project summaries, worker-generated UI)
ships on-brand from day one. Governing policies: `hq-company-brand-pack-location`,
`hq-bind-company-brand-pack-as-deploy-default`, `hq-worker-dynamic-context-company-packs`.

### 2.5.1 Pick the brand source

Ask (`AskUserQuestion`): "Where's the best source to learn {Name}'s brand from?"
- **Website** — ask for the URL; fetch key pages, extract palette, type, spacing, voice,
  imagery style from live CSS + rendered pages.
- **Brand guide PDF** — ask for the file path (or drop path `companies/{slug}/data/imports/`);
  read via the pdf skill and extract the codified system.
- **Google Drive / Notion / Figma doc** — ask for a link or an export; if not directly
  readable, give export instructions + the drop path and record a finish-later task.
- **Existing repo** — point at a repo with a `design.md` / tokens / component library and
  extract from source.
- **No brand yet** — offer to synthesize a starter brand from the Phase 1 business
  description (industry, audience, positioning), clearly marked `status: draft`.
- **Skip** — no packs; note "run brand-pack creation later" in the finish checklist.

If the source is only partially readable (e.g. Drive link without access), fail soft:
extract what you can, record the gap as a finish-later task. Never block the phase.

### 2.5.2 Decide pack count

Default is **one** brand pack (`{slug}-brand`). Offer more only when the interview or
source reveals genuinely distinct visual systems (e.g. separate product brands, or a
"marketing" vs "internal docs" split). One pack per distinct system, each with its own id.

### 2.5.3 Build each pack

Create `companies/{slug}/knowledge/design-styles/packs/{pack-id}/` with the five required
files (schema: `core/knowledge/public/design-styles/PACK-SCHEMA.md`; reference example:
any existing pack under `companies/{co}/knowledge/design-styles/packs/`):

- `pack.yaml` — `type: brand`, `scope` implied company; fill `aesthetic`, `origin`
  (cite the source used), `contents`, `compatibility`, `context_paths` (required:
  `implementation.md`, `design-tokens.css`).
- `style-guide.md` — the visual reference: palette with hex values, type roles, spacing,
  imagery/voice notes extracted from the source.
- `implementation.md` — code-level system: component patterns, layout rules, do/don't.
- `design-tokens.css` — CSS custom properties.
- `design-tokens.json` — same tokens in DTCG format.

NEVER place company packs under `knowledge/public/design-styles/packs/` — that's shared
packs only.

### 2.5.4 Register the pack

Add each pack to `repos/public/knowledge-design-styles/registry.yaml` under Brand Packs:
`type: brand`, `status: active`, `scope: company`, `company: {slug}`,
`path: companies/{slug}/knowledge/design-styles/packs/{pack-id}/`, plus the one-line
`aesthetic`. Consumers reference packs by `id` only — the registry resolves the path.

### 2.5.5 Wire packs to use cases via policies

Ask which surfaces should default to the pack (multi-select; pre-select deploy):
- **Deploy artifacts** (reports, dashboards, share pages) — write a company-scoped
  **hard** policy at `companies/{slug}/policies/{slug}-deploy-report-brand-pack.md`
  binding the pack path as the `/deploy` default (pattern:
  `hq-bind-company-brand-pack-as-deploy-default`). The global
  Midnight Editorial default already cedes to a bound company pack — no core edits.
- **Marketing / landing pages** — extend the same policy (or a sibling) to cover
  landing-page and public-site artifacts, naming the marketing pack if distinct.
- **Repos** — for each associated repo that ships UI, offer to add/update the repo's
  `design.md` with `style-pack: {pack-id}`.
- **Project summaries / decks** — note in the policy that `/project-summary` and deck
  artifacts use the pack.

One policy file per pack-binding decision, company-scoped, standard policy frontmatter
(`scope: company`, `enforcement: hard`, `when: deploy || design`).

Skip → no packs; deploy artifacts fall back to HQ Midnight Editorial.

---

## Phase 3 — Synthesize Workers + Skills (NEW, optional)

Cluster the functions/workflows from Phase 1 into proposed workers, reusing the
`import-claude` cluster pattern + `/newworker`:

1. Propose 1 worker per high-value function (e.g. a "growth" worker, a "finance-reporting"
   worker). Present the proposed set via `AskUserQuestion` — create / edit / skip each.
2. For each accepted worker, inline-invoke `/newworker` with pre-filled fields (name,
   `worker.company: {slug}`, candidate skills, knowledge paths, description). It writes
   `companies/{slug}/workers/{name}/worker.yaml`; `core/workers/registry.yaml`
   regenerates automatically on reindex.
3. Propose any function-specific **skills** → write to `companies/{slug}/skills/{name}/SKILL.md`.
   The `auto-mirror-company-skill` hook bridges them to `.claude/skills/{prefix}-{name}/`
   so they're callable as `/{prefix}-{name}`. Do NOT write the mirror symlink yourself —
   the hook does it (and `route-company-skill-creation.sh` blocks direct prefix writes).
4. **Design-pack wiring:** if Phase 2.5 created packs, any pack-consuming worker
   (frontend-designer-style roles) MUST get a `dynamic` context entry pointing to
   `companies/{slug}/knowledge/design-styles/packs/` in its worker.yaml — without it the
   registry resolves the pack but the worker can't load it (policy
   `hq-worker-dynamic-context-company-packs`).

Skip → no workers/skills synthesized.

---

## Phase 4 — Team & Cloud (NEW, opt-in gate for Phases 5–8)

Shared secrets, group ACLs, invites, and cloud agents require a provisioned vault. Ask once:

> "Set **{Name}** up for your team now? This provisions a cloud vault so you can connect
> tools, share access by group, invite teammates, and add AI agents."

- **Yes** → run `/designate-team {slug}` inline (writes `cloud: true`, runs
  `hq cloud provision company {slug}`, self-checks `GET /membership/me`). Gate Phases 5–8
  on exit 0. On failure, report and continue to Phase 9 (don't loop).
- **Not now** → skip Phases 5–8; note "run `/designate-team {slug}` later to enable team
  features" in the finish checklist.

---

## Phase 5 — Connect Integrations (NEW, business-discovery-driven, fail-soft)

For each function's source-of-truth tool from Phase 1, **classify the connection method**
and route accordingly — do NOT assume any specific tool list:

| Class | Signal | Action |
|-------|--------|--------|
| **Personal API key** | user-scoped token (Notion personal key, GitHub PAT, Slack user token) | Mint `hq secrets generate-link <TOOL>/<KEY> --company {slug}` → present Markdown link + 1-line "how to get the key" instructions. |
| **Org / admin API key** | workspace/admin token (Google Workspace, Slack bot, Stripe restricted key) | Same minted link, but flag "needs an admin of {tool}" and who to ask. |
| **Manual export** | no usable API for their plan (some CRMs, spreadsheets) | Give export instructions + the drop path (`companies/{slug}/data/imports/`); record a finish-later task. |
| **Ingestion script / process** | recurring/custom pull needed | Create a board idea (`{prefix}-proj-NNN`, label `ingestion`) so it's tracked as real work; do not fake it. |

Process: for each tool, ask "how do you connect this?" with the four classes as options
(pre-fill the likely class). Mint links for the API-key classes; write instructions/tasks
for the others. Every tool is skippable.

**Link rules (hard):** show each minted URL only at mint time, as `[Connect {Tool} ›](url)`.
Never persist it to disk, journal, board, or git.

---

## Phase 6 — Org Model + ACL Rules (NEW, optional)

Turn the team/functions into **groups with streamlined, rule-based access** — not one-off grants.

1. **Groups:** one per function/role from Phase 1 (presets: admins, ops, finance, eng,
   contractor; editable). `hq groups create grp_<name> --name "<Human>" --company {slug}`
   (ids must match `grp_*`).
2. **ACL rules (prefix-based, streamlined):** grant by prefix tree, not file-by-file:
   - `hq files share <function>/ --with grp_<function> --permission read --company {slug}`
   - `hq secrets share <FUNCTION>/<FULL/PATH> --with grp_<function> --permission read --company {slug}`
     (full key path required — policy `hq-secrets-share-needs-full-key-path`).
   - Company-wide baseline: `hq files share <prefix>/ --with @all --permission read --company {slug}`
     for things everyone should see (`--with @all` shares with the whole company team).
   - Wildcards (`reports/*`, `*`) cover current + future keys, so new files inherit the rule.
3. **Role reminder (hybrid ACL split):** owners/admins get role-bypass on files; **secrets
   are owner-only** (admins do NOT bypass secrets). Don't promise admins secret-grant power —
   this files/secrets asymmetry is intentional.

Skip → no groups/rules (owner still has full access).

---

## Phase 7 — Invite Teammates (NEW, optional)

For each teammate from Phase 1 (or ask): email + role + group.
- `hq members --company {slug} invite <email> --role <admin|member>` (owner is provisioning-only; not via CLI).
- If a group was chosen: `hq groups add grp_<name> <email> --company {slug}`.
- They accept via `/accept` on first sign-in. Surface pending vs joined state.

Skip → invite later.

---

## Phase 8 — Cloud Agents (NEW, optional — "invite an agent")

Team Agents are GA (hq-pro vault-service). Offer: "Want to add an AI teammate (agent) that
lives in the cloud and can work in Slack/email?"

- Provision via the vault-service agent flow (`hq cloud provision company {slug}` must have
  run in Phase 4; then the agent provisioning endpoints `POST /agents`, status via
  `GET /agents/{uid}/status`). Prefer any `hq` CLI agent subcommand if present; otherwise
  follow the cloud-agents provisioning path. Route agent/vault work to the vault-service backend.
- The agent becomes a first-class team member (appears in the team list with an `Agent` tag;
  assignable in ACL pickers). Guardrail: agents cannot hold owner/admin in v1.
- Assign the agent to a group (Phase 6) so its access is scoped like a person's.

Skip → no agents (the most likely default; it's a deliberate step).

---

## Phase 9 — Explain + Finish

1. **Plain-language explainer** (always, even on the scaffold-only path):
   > "There's a file on your computer, with a **company** folder and a **personal** folder.
   > It stores your business context — and that's what HQ works from."
2. **Reindex:** `qmd update 2>/dev/null || true`
3. **Report** what was set up + a **finish-later checklist** of skipped items:

```
{Name} is ready ✓
  Directory: companies/{slug}/  (prefix: {prefix})
  Cloud: {provisioned | local-only — run /designate-team {slug} to enable team features}
  Knowledge: {N seeded docs | empty}
  Design packs: {pack ids + bound surfaces | none — deploy falls back to HQ Midnight Editorial}
  Workers/Skills: {list | none}
  Projects: {N ideas on the board | none}
  Integrations: {connected list | none} · Finish later: {classified manual/script items}
  Team: {N invited} · Groups: {list} · Agents: {N | none}
```

---

## Rules

- Phase 0 always runs and must leave a working local company; everything else is fail-soft/skippable.
- All manifest.yaml fields non-null (empty arrays, not `null`). Knowledge repo is mandatory.
- Never create a company that already exists. Validate slug: lowercase, hyphens only, no spaces.
- Always write `company.yaml` with `cloud: false`; only `/designate-team` flips it. Never default to `cloud: true`.
- Every `hq` call carries `--company {slug}`. Never collect raw secrets in chat — mint links.
- Don't fake integrations: tools without an easy key become tracked tasks (manual export / ingestion script), not silent no-ops.
- Design packs go in `companies/{slug}/knowledge/design-styles/packs/` (never the shared public packs dir), get registered in `repos/public/knowledge-design-styles/registry.yaml`, and bind to surfaces via company-scoped policies — never by editing core deploy infra.
- Reuse `/designate-team`, `/newworker`, `/idea`, `/plan`, `hq groups|secrets|files|members invite`, and the cloud-agent provisioning path — don't reimplement them.

## See also

- `/onboard` — provision the vault for it
- `/designate-team` — turn on cloud/team sync
