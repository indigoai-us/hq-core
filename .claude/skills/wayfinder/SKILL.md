---
name: wayfinder
description: |
  Plan a chunk of work too big for one agent session with a foggy destination — chart a shared map of investigation tickets and resolve them one per session until the path is clear.
  Use when the effort is too large to hold in one planning pass and the destination is unclear. Triggers on "too big to plan", "chart a map", "investigation tickets", "foggy scope".
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent, AskUserQuestion
---

# Wayfinder

A loose idea has arrived — too big for one agent session, and wrapped in fog: the way from here to the **destination** isn't visible yet. Wayfinding is about finding that way, not charging at the destination. This skill charts the way as a **shared map** of investigation tickets, then resolves them one at a time — one per session — until the route is clear. It sits **upstream** of PRD and deep planning: wayfinder produces the resolved decisions and named destination that a `/prd` or `/deep-plan` session then turns into an execution-ready spec. Reach for it only when the effort is genuinely too big to plan in one pass and the destination is still unclear; for anything you can already scope in one sitting, skip straight to `/brainstorm` or `/prd`.

Pattern adapted from [mattpocock/skills](https://github.com/mattpocock/skills) (skills/engineering/wayfinder), upstream commit 391a270; tracker-agnostic (workspace/ markdown default), HQ company-context and cross-references added.

## Step 0 — Resolve company context

Same pattern as `/diagnose` and `/brainstorm`:

1. Honour explicit `[company]` argument
2. Fall back to `workspace/threads/handoff.json` `.company`
3. Fall back to cwd inference via `companies/manifest.yaml`
4. Last resort: ask via `AskUserQuestion`

Once resolved, derive a `<slug>` for this effort (lowercase, hyphens) and store the map + tickets under `workspace/reports/wayfinder-<slug>/` (see [Where the map lives](#where-the-map-lives)). Load any CONTEXT-style domain glossary the target repo carries (`<repo>/CONTEXT.md`) and note the company's hard-enforcement policies so tickets respect them.

## Plan, don't do

Wayfinder is **planning** by default: each ticket resolves a decision, and the map is done when the way is clear — nothing left to decide before someone goes and does the thing. The pull to just do the work is usually the signal you've reached the edge of the map and it's time to hand off to `/prd` or `/deep-plan`. An effort can override this in its **Notes** — carrying execution into the map itself — but absent that, produce decisions, not deliverables.

The destination varies per effort, and naming it is the first act of charting — it shapes every ticket. It might be a spec to hand off and iterate on, a decision to lock before planning starts, or a change made in place like a data-structure migration. The map is domain-agnostic — engineering work, company knowledge, whatever fits the shape.

## Refer by name

Every map and ticket has a **name** — its title. In everything the human reads — narration, the map's Decisions-so-far — refer to it by that name, never by a bare id, filename, or slug. A wall of `T-001, T-002, T-003` is illegible; names read at a glance. The id and path don't vanish — a name wraps its link — but they ride *inside* the name, never stand in for it.

## Where the map lives

The default tracker is **local markdown files** under `workspace/reports/wayfinder-<slug>/` — no external tracker required. This is the mode to use unless the company has explicitly standardised on GitHub issues for this repo.

```
workspace/reports/wayfinder-<slug>/
  map.md              # the map — the canonical index (see The Map)
  tickets/
    001-<name>.md     # one file per ticket, id = zero-padded ordinal
    002-<name>.md
  assets/             # summaries, prototypes, and other ticket outputs
```

- **Ticket id** is the zero-padded ordinal in the filename (`001`, `002`, …); the name is the ticket's `# Title`.
- **Status** is plain wording in each ticket's frontmatter — `status: open | claimed | closed | out-of-scope` — plus a `blocked_by:` list. No label vocabulary.
- **Claiming** a ticket means setting `status: claimed` and `claimed_by: <driver>` **before** any work, so a concurrent session skips it. An `open`, unassigned ticket is unclaimed.
- **Blocking** is the ticket's `blocked_by: [<id>, …]` list. A ticket is **unblocked** when every ticket it lists is `closed`. The **frontier** is the set of `open`, unblocked, unclaimed tickets — the edge of the known.
- **Assets** created while resolving a ticket are written under `assets/` and linked from the ticket, not pasted into it.

**Optional GitHub alternative.** If the company standardises on GitHub issues for this repo, you may instead express the map as a parent issue and its tickets as child issues, using the tracker's native dependency relationship for blocking and plain status wording (no triage labels) — anchor every `gh` call with `-R owner/repo`. The body shapes below are identical; only the storage medium changes. Default to markdown unless the user asks for issues.

## The Map

The map is a single file, `map.md` — the canonical artifact. It is an **index**, not a store. It lists the decisions made and points at the tickets that hold their detail; a decision lives in exactly one place — its ticket — so the map never restates it, only gists it and links.

### The map body

The whole map at low resolution, loaded once per session. Open tickets are **not** listed here — they live in `tickets/` and are found by scanning frontier status.

```markdown
# <map name>

## Destination

<what reaching the end of this map looks like — the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Notes

<company + domain; skills every session should consult; standing preferences for this effort>

## Decisions so far

<!-- the index — one line per closed ticket: enough to judge relevance, then open the link for the detail the ticket holds -->

- [<closed ticket name>](tickets/001-<name>.md) — <one-line gist of the answer>

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

### Tickets

Each ticket is a file under `tickets/`; its ordinal is its identity. Its body is the question, sized to one ~100K-token agent session:

```markdown
---
status: open        # open | claimed | closed | out-of-scope
type: research      # research | prototype | grilling | task
blocked_by: []      # ticket ids that must close first
claimed_by: null
---

# <ticket name>

## Question

<the decision or investigation this ticket resolves>
```

The answer isn't part of the body — it's recorded on resolution (see [Work through the map](#work-through-the-map)). Assets created while resolving a ticket are linked from the ticket, not pasted in.

## Ticket Types

Every ticket is either **HITL** — human in the loop, worked *with* a human who speaks for themselves — or **AFK**, driven by the agent alone. A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it (a grilling agent that answers its own questions has broken this).

- **Research** (AFK): Reading documentation, third-party APIs, or local resources like knowledge bases. Runs through HQ `/deep-research` for anything that needs multi-source, verified findings; lighter reads can be done inline. Writes a markdown summary under `assets/` as a linked asset. Use when knowledge outside the current working directory is required.
- **Prototype** (HITL): Raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to — an outline, a rough take, a stub, or UI/logic code. Use HQ's `/prototype` skill (from the pocock pack) where it fits, or hand-build the artifact. Links the prototype as an asset under `assets/`. Use when "how should it look" or "how should it behave" is the key question.
- **Grilling** (HITL): Conversation via HQ `/brainstorm` and `/domain-modeling`, one question at a time through `AskUserQuestion`. The default case. The agent asks; the human answers — never both.
- **Task** (HITL or AFK): Manual work that must happen before a *decision* can be made — nothing to decide, prototype, or research, but the discussion is blocked until it's done. Signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. This is the one type that *does* rather than decides — and it earns its place by unblocking a decision, not by delivering the destination. The agent drives it alone where it can (AFK); otherwise it hands the human a precise checklist (HITL). Resolved when the work is done; the answer records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on. For secrets or provisioning, route through HQ paths (`/hq-secrets`, `/new-agent`) — never paste credentials into a ticket.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war** — the dim view of decisions and investigations you can tell are coming but can't yet pin down, because they hang on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets — one at a time, until the way to the destination is clear and no tickets remain.

The map's **Not yet specified** section is where that dim view is written down: the suspected question, the area to revisit later. It's the undiscovered frontier _toward_ the destination — everything here is in scope, just not sharp enough to ticket. Write as loosely or as fully as the view allows; it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** The test is whether you can state the question precisely now — _not_ whether you can answer it now.

- **Ticket when** the question is already sharp — even if it's blocked and you can't act on it yet.
- **Not yet specified when** you can't yet phrase it that sharply. Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none, once the frontier reaches it.

**Not yet specified** excludes what's already decided (Decisions so far), what's already a live ticket, and what's out of scope (the next section).

## Out of scope

Fog only ever gathers _toward_ the destination. The destination fixes the scope, so work beyond it is **out of scope** — it isn't fog, and it doesn't belong in **Not yet specified**. It gets its own **Out of scope** section on the map: work you've consciously ruled out of _this_ effort. Scope, not sharpness, lands it here.

Out-of-scope work never graduates — the frontier stops at the destination — so it returns only if the destination is redrawn, and then as a fresh effort, not a resumption. (HQ's `/out-of-scope` is the durable home for ideas rejected across efforts; the map's section records the ones ruled out of *this* one.)

Ruling something out of scope is a scoping act, not a step on the route. When a ticket that already exists turns out to sit past the destination — mis-scoped in while charting, or exposed by a resolution — set its `status: out-of-scope` (an out-of-scope ticket is unambiguously off the frontier) and leave one line in the map's **Out of scope** section: the gist plus why it's out of scope, linking the ticket. It stays out of **Decisions so far**, which records the route actually walked — a scope boundary isn't a step on it.

## Invocation

Two modes. Either way, **never resolve more than one ticket per session.**

### Chart the map

User invokes with a loose idea.

1. **Resolve company context** (Step 0) and derive `<slug>`.
2. **Name the destination.** Run a `/brainstorm` + `/domain-modeling` session (one question at a time via `AskUserQuestion`) to pin down what this map is finding its way to — the spec, decision, or change. The destination fixes the scope, so it's settled first.
3. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. **If this surfaces no fog** — the way to the destination is already clear, the whole journey small enough for one session — you don't need a map. Stop and tell the user to go straight to `/brainstorm` or `/prd`.
4. **Create the map.** Write `workspace/reports/wayfinder-<slug>/map.md`: Destination and Notes filled in, Decisions-so-far empty, the fog sketched into **Not yet specified**.
5. **Create the tickets you can specify now** as files under `tickets/` — then wire `blocked_by` edges in a **second pass** (tickets need ids before they can reference each other). Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog — the **Not yet specified** section.
6. Stop — charting the map is one session's work; do not also resolve tickets.

### Work through the map

User invokes with a map (slug or path). A ticket is **optional** — without one, you pick the next decision, not the user.

1. **Resolve company context** (Step 0) and load the **map** — the low-res view, `map.md`, not every ticket body.
2. **Choose the ticket.** If the user named one, use it. Otherwise take the first frontier ticket in ordinal order. **Claim it**: set `status: claimed` and `claimed_by` before any work.
3. **Resolve it** — **zoom as needed**: open the full body of any related or closed ticket on demand; invoke the skills the `## Notes` block names. If in doubt, use `/brainstorm` and `/domain-modeling`, one question at a time via `AskUserQuestion`.
4. **Record the resolution:** append the answer to the ticket under a `## Answer` section, set `status: closed`, and **append a one-line context pointer** to the map's Decisions-so-far.
5. **Extend the map:** add newly-surfaced tickets (create-then-wire); graduate any fog the answer has made specifiable, clearing each graduated patch from **Not yet specified** so it lives only as its new ticket. If the answer reveals a ticket — this one or another — sits beyond the destination, **rule it out of scope** rather than resolving it on the route. If the decision invalidates other parts of the map, update or delete those tickets.
6. **Check for the merge point:** if no open tickets remain and the way to the destination is clear, the map is resolved — hand off (see below).

The user may run unblocked tickets in parallel, so expect other sessions to be editing the map concurrently.

## Merge point — hand off to planning

When the map is resolved — the frontier empty and the destination reachable — wayfinder is done. Its output is a set of locked decisions and a named destination, not a spec. Hand off:

- **`/prd`** — for a straightforward effort ready for a lightweight, execution-ready PRD.
- **`/deep-plan`** — for a large or strategically important effort that warrants research subagents and the deep interview.

Point the planning session at `workspace/reports/wayfinder-<slug>/map.md`: its **Destination** becomes the project goal, **Decisions so far** seed the scope and architecture answers, and **Out of scope** seeds the non-goals. Do not carry execution into wayfinder itself unless the effort's **Notes** explicitly override "Plan, don't do".

## Cross-references

- HQ `/prd` — lightweight terminal merge point; turns the resolved map into an execution-ready PRD.
- HQ `/deep-plan` — deep terminal merge point for large or strategically important efforts.
- HQ `/domain-modeling` — the modelling half of every grilling ticket; pins down the domain language the destination is written in.
- HQ `/deep-research` — the engine for research-type tickets.
- HQ `/brainstorm` — one-question-at-a-time grilling for naming the destination and resolving grilling tickets.
- HQ `/out-of-scope` — durable home for ideas ruled out across efforts, beyond this map's Out of scope section.
- Pattern source: [mattpocock/skills](https://github.com/mattpocock/skills) (skills/engineering/wayfinder), upstream commit 391a270.
