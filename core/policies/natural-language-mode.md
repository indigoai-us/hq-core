---
id: natural-language-mode
title: Natural Language Mode — infer intent, auto-route to the right HQ skill, confirm-then-run
scope: global
trigger: any session — applies to every user prompt that is not already an explicit slash command
enforcement: soft
version: 1
created: 2026-05-22
updated: 2026-05-22
source: user-request
tags: [routing, intent, ux, delight, skills, orchestration]
public: true
---

## Rule

HQ users should not have to know the name of a skill to get its power. When a user expresses a need in plain language, infer the underlying intent, map it to the correct HQ skill or protocol, resolve the context that skill needs, announce the inferred route, and proceed — without making the user type the slash command themselves.

This is **Natural Language Mode**. It is on by default for every session. It does not replace explicit slash commands; it sits in front of them so that `/startwork acme` and "let's pick up acme where we left off" lead to the same place.

The contract has five obligations, in order:

1. **Infer intent.** Read the user's prompt for what they are actually trying to accomplish, not just the literal words. Map it to a skill using the Intent Map below. Generalize beyond the table — it is a starting point, not an exhaustive switch statement.
2. **Resolve context before acting.** Identify the company (from explicit mention, cwd, recent thread state, or `companies/manifest.yaml`), the project (by slug at `companies/{co}/projects/{slug}/`, or via qmd/INDEX), and the repo. Laser in with `qmd` and INDEX rather than broad exploration — honor the Context Diet. Never guess company credentials or cross company boundaries (see `credential-access-protocol`).
3. **Announce the route, then run (confirm-then-run).** State the inferred intent and the skill you are about to invoke in one short line — e.g. "Reading this as a debugging task → running `/investigate`." Then proceed in the same turn. The user can redirect; you do not block waiting for approval on cheap or reversible routes.
4. **Gate heavy and irreversible routes.** For skills that kick off expensive, long-running, or hard-to-reverse work, announce the route AND get an explicit go before running. This composes with — does not weaken — the irreversible-action confirmation rules already in the charter. See the Risk Gate below.
5. **Disambiguate only when genuinely unsure.** If two routes are plausible and the difference matters, ask one tight clarifying question (structured picker, one question at a time per `decision-queue-one-at-a-time`). Do not interrogate when intent is clear — defaulting to action is the delightful path. When in doubt on a *cheap* route, act and let the user correct; when in doubt on a *heavy* route, ask first.

The goal is delight without losing power: everything just works, and the full depth of HQ's skills, workers, policies, and protocols is still doing the work underneath.

## Anchoring (hard prerequisite)

**Before executing any company / project / repo-scoped work, the session MUST be anchored on that company.** This is non-negotiable — it is the "core power" that delight must not erase: company-scoped policy enforcement and credential isolation.

Why this needs explicit handling: `load-policies-for-session.sh` binds the active company **from cwd only** (`companies/{co}/...`, or a repo path → owning company via manifest). When the session starts at the **HQ root** (the common case) and routing sends work straight to a skill, the company digest, manifest infra, and handoff state are **never loaded** — there is no cwd signal and no `/startwork` ran. Routing that skips anchoring silently drops company policies and risks cross-company credential errors.

So when intent resolves to company/project/repo work, **silently anchor first** (no menu, no banner — this is `/startwork`'s context-gathering minus the interactive surface):

1. **Bind the company.** Resolve from explicit mention → cwd → repo's owning company in `companies/manifest.yaml` → handoff state. If genuinely ambiguous, ask one tight question (structured picker) before proceeding.
2. **Load company-scoped policies.** Read `companies/{co}/policies/_digest.md` if it exists (and the active repo's `repos/{scope}/{repo}/.claude/policies/_digest.md`) so company + repo rules are in context. The cwd-keyed loader will not have done this for an HQ-root start.
3. **Load infra context.** Read the company's `companies/manifest.yaml` entry — `services`, `aws_profile`, `dns_zones`, repos, workers — so credentials and isolation resolve correctly. Never guess or fall back to another company's creds (`credential-access-protocol`).
4. **Read in-flight state.** Check `workspace/threads/handoff.json` (and the thread it references) for where work left off.

Only after anchoring → execute the work skill. Announce the anchor compactly as part of the route line — e.g. "Anchoring on acme → reading this as a debugging task → `/investigate`."

**Carveouts (no company anchor needed):** HQ-core builder work (`/hqwork` and edits to `core/`, `.claude/`, the CLI); global/cross-company tasks; and read-only multi-company search (`/search`, `qmd`). These are not company-scoped, so step 1's bind does not apply.

## Rationale

HQ already routes on explicit tokens: `route-deep-plan-to-skill.sh` detects the literal `/deep-plan` string and pins the agent to that skill; `auto-startwork.sh` bootstraps `/startwork` on single-company installs. Those prove the rail works, but they fire on slash tokens, not on natural phrasing. The result is a power tool that demands the user memorize its command surface — the opposite of delightful for anyone past the first week.

Natural Language Mode generalizes the rail to **intent**. The engine is the model itself (not a regex hook): the model has every skill loaded and is best positioned to read fuzzy phrasing, weigh confidence, and pick the right protocol. The charter carries a compact cheat-table so routing fires with zero extra reads; this policy carries the full map, the risk gate, and the edge cases.

Why confirm-then-run rather than silent auto-run: a misread that silently launches `/run-project` or `/deploy` is expensive and erodes trust. Announcing the inferred route on every turn keeps the user oriented and gives them a one-word veto, while still removing the burden of typing commands. Cheap, reversible routes proceed immediately; heavy ones stop for an explicit go.

## Intent Map

The high-frequency mappings. Group by work phase. Generalize from these — synonyms and paraphrases of each row route the same way.

### Orientation & prioritization

| User says (paraphrased) | Route |
|---|---|
| "start working", "pick up where I left off", "let's work on {company}", "what's the state of {company}" | `/startwork {company}` |
| "what should I work on", "what's next", "prioritize my day", "where should I focus" | `/strategize` |
| "what are my action items", "what's on my plate", "what did I commit to" (Indigo) | `/indigo:signals` |
| "find X", "where is Y", "search for Z" | `/search` (or `qmd` directly) |

### Define & plan

| User says (paraphrased) | Route |
|---|---|
| "I want to build X", "explore approaches", "I'm not sure how to…", "what are the tradeoffs" | `/brainstorm` |
| "spec this out", "create a PRD", "plan this project", "let's plan {feature}" | `/plan` (or `/deep-plan` for large/strategic) |
| "just capture this idea", "park this for later" | `/idea` |
| "review this plan", "stress-test this PRD", "is this plan good enough" | `/review-plan` |

### Build & execute

| User says (paraphrased) | Route — ⚠ = Risk Gate |
|---|---|
| "build it", "run the project", "execute {project}", "make it happen" | ⚠ `/run-project {project}` |
| "do this one story", "knock out US-00X" | ⚠ `/execute-task {project}/US-00X` |
| "let's TDD this", "write the tests first" | `/tdd` |
| "this is hard to change", "let's refactor the architecture" | `/architect` |

### Debug

| User says (paraphrased) | Route |
|---|---|
| "why is X broken", "fix this bug", "root cause this", "trace this" (reproducible) | `/investigate` |
| "I can't reproduce this", "it's flaky", "perf regressed", "intermittent failure" | `/diagnose` |

### Review, ship, deploy

| User says (paraphrased) | Route — ⚠ = Risk Gate |
|---|---|
| "review my code", "check this before I push", "paranoid review" | `/review` |
| "security review", "is this safe" | `/security-review` |
| "ship this PR", "land it", "merge and monitor" | ⚠ `/land` |
| "land all the PRs", "merge everything open" | ⚠ `/land-batch` |
| "deploy this", "share this externally", "put this behind a URL" | ⚠ `/deploy` |
| "share this file", "give {person} access" | ⚠ `/hq-share`, `/hq-files` |

### Capture & wrap

| User says (paraphrased) | Route |
|---|---|
| "remember this rule", "we should always/never…" | `/learn` (`--hard` for hard-enforcement) |
| "capture this decision", "this is architecturally important" | `/adr` |
| "we decided not to do X", "this was rejected because…" | `/out-of-scope` |
| "save progress", "I'm running low on context" | `/checkpoint` |
| "hand this off", "wrap up for a fresh session" | `/handoff` |
| "what did we ship", "retro this", "lessons learned" | `/retro` |
| "update the docs", "docs are stale" | `/document-release` |

### Infrastructure & membership

| User says (paraphrased) | Route — ⚠ = Risk Gate |
|---|---|
| "new company", "set up {co}" | ⚠ `/newcompany {slug}` |
| "new worker", "scaffold an agent for…" | `/newworker` |
| "onboard", "join a company", "accept this invite" | `/onboard`, `/accept` |
| "invite {person}", "add {person} to {co}" | ⚠ `/personal:invite` |
| "make {co} a team", "cloud-back {co}" | ⚠ `/designate-team` |
| "change {person}'s role", "promote {person}" | ⚠ `/promote` |
| "sync", "push state across machines" | `/hq-sync` |

### Builder (HQ-core itself)

| User says (paraphrased) | Route |
|---|---|
| "work on HQ itself", "edit a policy/hook/skill/the CLI" | `/hqwork` |
| "upgrade HQ", "pull the latest HQ" | `/update-hq` |
| "audit my HQ setup" | `/harness-audit` |
| "clean up HQ", "garden the knowledge" | `/garden` |

Company-scoped skills (e.g. `/indigo:*`) route the same way when the active company matches.

## Risk Gate

Routes marked ⚠ above launch expensive, long-running, or hard-to-reverse work. For these: **announce the route AND get an explicit go before running.** Do not auto-proceed on a ⚠ route, even when intent is unambiguous.

| Tier | Routes | Behavior |
|---|---|---|
| **Cheap / reversible** | startwork, strategize, search, brainstorm, plan, idea, review-plan, investigate, diagnose, review, learn, adr, out-of-scope, checkpoint, handoff, retro, document-release, newworker, onboard, sync, hqwork, harness-audit, garden, journal | Announce route, proceed same turn. |
| **Heavy / irreversible (⚠)** | run-project, execute-task, land, land-batch, deploy, hq-share, hq-files, newcompany, invite, designate-team, promote, accept, update-hq | Announce route, then **stop for explicit go.** |

The ⚠ gate is additive to — never a replacement for — the charter's irreversible-action confirmation rules and the cross-company credential isolation rules. When both apply, the stricter one wins.

## Mechanism

Two surfaces deliver this mode; neither requires the user to type a command.

1. **First-touch nudge** — `personal/hooks/UserPromptSubmit/natural-language-router.sh` (auto-loaded by `master-hook.sh`, personal layer). Fires once, on the **first prompt of a session**, and only when the user did **not** open with an explicit slash command (startwork, goals, idea, brainstorm, prd, run-project, or any `/command`). It injects a `<natural-language-routing>` reminder so a cold "I want to…" gets routed instead of stalling. Idempotent via a per-session marker at `workspace/orchestrator/policy-trigger-state/{session_id}.nl-router-fired`. Disable with `HQ_NL_ROUTER=0` or `HQ_DISABLED_HOOKS=natural-language-router`.
2. **This policy** — rides the session-start digest (one-line summary) and is the full reference (intent map, risk gate, examples). It governs routing for the whole session, not just the first turn.

The first-touch hook is intentionally narrow: it solves the cold-start problem (a user who doesn't know the command surface). Once the session is underway, routing is the model's standing obligation under this policy — it does not depend on a per-turn hook.

## Mid-session: durable memory

Natural Language Mode is not only about the first turn. Once work is underway, "everything just works" means the work also **survives** — context compaction, session death, and handoff to a fresh session must not lose critical state. Throughout a session, keep durable memory alive without being asked:

- **Journal findings continuously.** Write structured entries to `workspace/threads/journal/<date>/` (the `journal` skill) so autocompact can discard raw tool-results while preserving findings, decisions, and dead ends. This is the working-memory log.
- **Keep a work-session / project folder current.** For non-trivial work, ensure there is a durable home — a project folder under `companies/{co}/projects/{slug}/` (or a session thread) — and write the research, knowledge, and artifacts learned along the way into it as you go, not only at handoff. The `auto-session-project` hook bootstraps the folder; this policy is the obligation to actually populate it.
- **Log decisions and new knowledge as they happen.** Architectural decisions → `/adr`; reusable rules → `/learn`; rejected directions → `/out-of-scope`. Capture at the moment of decision so the rationale is not reconstructed later from a lossy summary.
- **Checkpoint on the standing triggers.** Honor the auto-checkpoint banners (50% Stop, PreCompact) immediately — write the thread file and continue. Do not wait to be told.

The test: if this session died right now, a fresh session reading `workspace/threads/`, the journal, and the project folder could pick up the thread without re-deriving what was learned. That is the durable-memory bar Natural Language Mode holds itself to.

## Relationship to other rules

| Rule | Relationship |
|---|---|
| `natural-language-router.sh` (UserPromptSubmit, personal layer) | **Implements the first-touch nudge.** Fires once on the first non-slash prompt of a session; see Mechanism. |
| `route-deep-plan-to-skill.sh` (UserPromptSubmit hook) | **Composes.** The hook still hard-pins `/deep-plan` on the literal token. Natural Language Mode adds the fuzzy-phrasing path ("plan this big initiative" → `/deep-plan` / `/plan`). |
| `journal` / `auto-session-project` / auto-checkpoint hooks | **Implements mid-session durable memory.** This policy is the obligation; those are the mechanisms. See Mid-session: durable memory. |
| `auto-startwork.sh` (SessionStart) | **Composes.** Single-company bootstrap still fires; this policy handles the in-session phrasing. |
| `quiet-by-default-narration` | **Composes.** The route announcement is a substantive, surface-worthy line (the user must know which protocol is running). It is not progress chatter. |
| `decision-queue-one-at-a-time` | **Inherited.** Disambiguation questions use the structured picker, one question per call. |
| `credential-access-protocol` | **Inherited and strict.** Context resolution never guesses or crosses company credentials. |
| Charter irreversible-action rules | **Strictly inherited.** The ⚠ gate never weakens them. |
| Explicit slash commands typed by the user | **Honored literally.** Do not re-infer or override an explicit command. |

## Examples

**Clear cheap route — proceed**

User: "why does the acme checkout 500 sometimes?"
> Reading this as a debugging task → running `/diagnose` (intermittent, so diagnose not investigate). Resolving acme context now.

*(proceeds)*

**Clear heavy route — announce then stop**

User: "ok ship the acme cart PR"
> Reading this as a land request → `/land` on the acme cart PR. This merges and monitors production. Confirm and I'll start.

*(waits for go)*

**Context resolution then route**

User: "let's keep going on the thing from yesterday"
> Checking `workspace/threads/handoff.json` for the last project… picking up the `northwind/scheduling-v2` story. Reading this as resume-work → `/startwork northwind`, then continuing US-003.

**Genuine ambiguity — one tight question**

User: "plan the new onboarding flow"
> "Plan" could be a quick PRD or a full deep-plan. Which fits?
>   1. `/plan` — lightweight, batched interview
>   2. `/deep-plan` — research subagents + 3-tier interview (large/strategic)

**Explicit command — honored, not re-inferred**

User: "/review"
> *(runs `/review` directly — no intent inference, no re-routing)*

**Builder intent**

User: "I want to tweak the secrets-handling policy"
> HQ-core edit → `/hqwork policies`. Narrowing to the secrets policies now.

## Verification

After this policy lands, the following session behavior holds (observation, not blocking gate):

1. **Fuzzy-to-skill.** A plain-language need ("debug this", "ship the PR", "plan a feature") routes to the correct skill without the user typing the slash command.
2. **Announcement present.** Each routed turn states the inferred intent + skill in one line before proceeding.
3. **Cheap routes proceed; ⚠ routes stop.** A `/diagnose` route proceeds same turn; a `/deploy` or `/run-project` route stops for explicit go.
4. **Explicit commands untouched.** A typed `/review` runs literally with no re-inference.
5. **Context resolved, not guessed.** Company/project/repo resolved from manifest/handoff/qmd; no cross-company credential use.
6. **Digest entry.** `grep natural-language-mode core/policies/_digest.md` returns a hit after the auto-rebuild.
