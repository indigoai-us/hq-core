---
name: new-agent
description: Provision a fleet agent end-to-end — identity, membership, vault join, secrets, file access, MCP/runtime bootstrap, mission brief, and a verified capability probe. Use when standing up a new HQ agent (Slack bot, reporting agent, ops agent) or when an existing agent reports it is blocked on access.
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# /new-agent — Provision a Fleet Agent

Take an agent from "exists somewhere" to "fully capable for a defined job" in
one flow. The failure mode this skill kills: an agent is invited to a company,
everyone assumes it can work, and days later it posts "I'm blocked on access,
not analysis" because nobody mounted its credentials, joined its vault, or
registered its MCPs.

**Provisioning is not done when grants are issued. It is done when the agent
confirms, from its own runtime, that every capability mounts.**

**Usage:**
```
/new-agent                      # interview from scratch
/new-agent {agent-name}         # provision or repair a specific agent
/new-agent {agent-name} {co}    # skip company resolution
```

## Mental Model

An agent needs five layers, granted in order. A miss at any layer makes every
layer above it silently useless:

| Layer | What it is | Granted by | Verified by |
|---|---|---|---|
| 1. Identity | Cognito principal + agent email (`agt-<ulid>@agents.{your-domain}.ai`) | hq-pro provisioning / `hq members invite` | `hq whoami` on the agent runtime |
| 2. Membership | Row in the company's member list | `hq members invite` + `/accept` on the agent runtime | `hq members list --company {co}` |
| 3. Team vault | Company directory synced into the agent's HQ | company is cloud-backed (`/designate-team`) + `hq team-sync` on the agent runtime | agent sees `companies/{co}/` locally |
| 4. Secrets & files | Read grants on vault secrets + file ACLs | `hq secrets share`, `hq files` | `hq secrets list --company {co}` on the agent runtime |
| 5. Runtime config | MCP servers, Slack tokens, model creds registered in the agent's own `.mcp.json`/settings | paste-ready bootstrap block (this skill generates it) | agent runs its probe checklist |

Layers 1–2 and 4 are grantable from the operator's HQ. Layers 3 and 5 require
action **on the agent's runtime** — this skill cannot do them remotely; it
produces the exact bootstrap block and verifies via probe instead.

## Process

### 1. Resolve agent + company

- If an agent name was given, look it up: `hq members list --company {co}` for
  each candidate company (or the given one). Agent members have `agt_`-prefixed
  ids in the EMAIL column.
- If the agent exists → **repair mode**: diff what it has against what it
  needs, grant only the gaps.
- If not → **create mode**: the identity comes from hq-pro agent provisioning
  (or invite an agent email directly if one was already issued).
- Company must resolve to a slug in `companies/manifest.yaml` **and** be
  cloud-backed (`cloud_uid` present). If it is not cloud-backed, stop and route
  to `/designate-team` first — without a cloud entity there is no team vault to
  join and `hq team-sync` on the agent side will report "no team directories
  found" no matter what else is granted.

### 2. Interview — define the job before the grants

Ask (batched, one AskUserQuestion call, skip anything already known):

1. **Job**: what must this agent do/report, where (Slack channel, DM, dashboard),
   and on what cadence?
2. **Data sources**: which systems does the job require? (databases, Stripe,
   Shopify, ad platforms, card/expense feeds, internal MCPs…)
3. **Facts the agent cannot derive**: targets, budgets, rate tables, plan
   numbers. These are *briefing content*, not credentials — they go in the
   mission brief (Step 6), never in chat replies the agent may not see.
4. **Runtime**: where does the agent run (HQ cloud fleet, a teammate's machine,
   a server)? Determines who executes the bootstrap block.

### 3. Derive the capability manifest

Map the job to concrete grants. For each data source, prefer what already
exists in the company vault (`hq secrets list --company {co}`) over minting new
credentials. Build a table:

```
| Capability             | Vault key / path                | Status  |
|------------------------|---------------------------------|---------|
| Prod read-only DB      | DATABASE_RO_URL                 | grant   |
| Stripe (read)          | STRIPE_API_KEY (rk_)            | grant   |
| Rate tables            | companies/{co}/knowledge/...    | vault   |
| Monthly revenue target | (mission brief)                 | brief   |
| Accounting system      | (not in vault)                  | blocked |
```

Rules while building the manifest:

- **Read-only by default.** Reporting agents get `--permission read`, never
  write/admin, unless the job explicitly requires mutation.
- **Verify payment-key scope before sharing.** Check a Stripe key's prefix
  without exposing it:
  `hq secrets exec --company {co} --only KEY -- sh -c 'printf %s "$KEY" | cut -c1-3'`
  — `rk_` is restricted, `sk_` is a full secret key. Never hand an `sk_` key to
  a read-only agent without flagging it to the user first.
- **Missing sources are "blocked", not silently dropped.** Anything the job
  needs that the vault lacks goes in the final report with an owner.

### 4. Grant layers 1–2 and 4

**Membership** (if not already a member):
```bash
hq members invite <agent-email> --company {slug} --role member --no-send-email
```
Surface any claim link per `core/policies/hq-secure-link-render-as-markdown.md`
— markdown inline link only, token never in the visible label.

**Secrets** — share each manifest key:
```bash
hq secrets share KEY --company {slug} \
  --with agt-<ulid-lowercase>@agents.{your-domain}.ai --permission read
```

Hard-won syntax rules (each of these failed in the field):
- The principal is the **agent email form** `agt-<ulid-lowercase>@agents.{your-domain}.ai`.
  The raw `agt_<ULID>` shown in `hq members list` is rejected with
  "Invalid principal".
- `--permission` is required (`read` | `write` | `admin`).
- `hq secrets share` needs the FULL key path (`SHOPIFY/CLIENT_ID`, not `SHOPIFY`).
- Idempotent: re-sharing an already-shared key is safe; repair mode just re-runs
  the loop.

**File ACLs** — for knowledge paths the agent needs (rate tables, policies,
benchmarks), grant via `/hq-files` (or `hq files`) rather than pasting content
into chat.

### 5. Generate the runtime bootstrap block

Layers 3 and 5 happen on the agent's runtime. Emit one copy-paste block,
addressed to whoever operates that runtime (often the agent itself via DM):

```bash
# --- HQ agent bootstrap: {agent} @ {co} ---
hq login                      # or hq auth status if already authenticated
# /accept <token>             # only if membership is still pending
hq team-sync                  # pulls companies/{co}/ into this HQ
hq secrets list --company {co}   # must show the granted keys
# Mount secrets per-invocation — never export or paste values:
#   hq secrets exec --company {co} --only KEY1,KEY2 -- <command>
```

If the job needs MCP servers, append a config template that sources
credentials through `hq secrets exec` / `hq run` wrappers. **Never inline a
secret value in an MCP config block.** Respect
`core/policies/hq-shared-user-global-config-safe-write-core.md` when the block
edits shared user-global config files.

### 6. Write the mission brief

Create `companies/{co}/knowledge/agents/{agent-name}-brief.md` and push it with
`hq sync push <path> --company {co}`.

> Path matters: the sync engine only ships known company subdirs (`knowledge/`,
> `projects/`, `policies/`, …). A file under an unrecognized top-level dir like
> `companies/{co}/agents/` is EXCLUDED by a built-in ignore rule and silently
> never reaches the vault — the push output says "Pushed 0 file(s)". Always
> check the push output line for the ✓ before assuming the brief shipped.

The brief contains:

- Role, reporting cadence, and destination (channel/DM).
- The facts from Step 2.3 (targets, rate tables, budgets) — or, when a fact is
  genuinely unset, an explicit instruction ("no July target is set; propose one
  from June actuals and get owner approval").
- Data-source rules: link the company's hard policies (e.g. which DB is the
  source of truth, which MCP metrics to distrust, replica batching rules).
- What is intentionally NOT granted and why (e.g. "QuickBooks excluded — live
  QBO stays a human-side monthly reconciliation").

The brief syncs to the agent on its next `hq team-sync` — it is the durable
answer to "what am I supposed to do and with what," surviving any chat history.

### 7. Verification probe — the done gate

DM the agent (via `hq dm` or its Slack channel) the bootstrap block plus a
probe checklist:

1. `hq whoami` → correct identity
2. `hq team-sync` → `companies/{co}/` present
3. `hq secrets list --company {co}` → every granted key visible
4. One end-to-end read per data source (e.g. `SELECT 1` through the RO URL, a
   Stripe balance read) via `hq secrets exec`
5. Read back the mission brief

**Do not report the agent as provisioned until it confirms the probe.** Grants
that succeed on the operator side routinely still leave the agent blocked
(vault not joined, runtime not logged in, MCP unregistered). If the probe
fails, the agent's error output tells you which layer to repair — match it to
the table in §Mental Model.

### 8. Report

```
Agent: {name} ({agent-email})
Company: {co}

Granted:   {n} secrets (read), {m} file paths, membership {status}
Briefed:   companies/{co}/agents/{name}/brief.md
Pending:   bootstrap on agent runtime (sent via {channel})
Blocked:   {list, each with an owner — or "none"}

Done when: agent confirms probe checklist in {channel}.
```

## Rules

- Least privilege: `--permission read` unless the job requires writes; flag any
  full-scope payment key before sharing it.
- Never paste secret values into chat, briefs, or MCP config blocks — grants
  and `hq secrets exec` wrappers only.
- Facts go in the mission brief file, not in a chat message to the agent.
- Provisioning is complete only after the agent-side probe passes (§7).
- Company not cloud-backed → stop, route to `/designate-team`; do not grant
  into a vault that cannot sync.
- Repair mode is the common case — always diff existing access first and grant
  only gaps.
- Tenant isolation: one company per invocation. Cross-company grants route
  through `hq group-grants` with explicit user sign-off.

## See also

- `/new-hire` — the human-teammate equivalent of this flow
- `/designate-team` — make a company cloud-backed (prerequisite for layer 3)
- `/accept` — how the agent's runtime claims a pending membership
- `/hq-secrets`, `/hq-files` — the underlying grant primitives
