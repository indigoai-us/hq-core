---
name: adr
description: Capture qualifying architecture decisions as ADRs in the right HQ or repo location.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, AskUserQuestion
---

# ADR

Architectural Decision Records — minimal, dated, sequentially numbered. The point is recording **that** a decision was made and **why**, not filling out template sections.

Pattern adapted from `mattpocock/skills` (`grill-with-docs/ADR-FORMAT.md`).

## Step 0 — Resolve company + scope

`$ARGUMENTS` may include:

- `[company]` slug — fall back to manifest / handoff / cwd inference if absent
- `[repo|hq]` scope — pick home directory
- `<one-line decision summary>` — used as title and slug seed

If scope is ambiguous, ask via `AskUserQuestion`:

| Choice | Home | When |
|---|---|---|
| `repo` | `<repo>/docs/adr/` | Decision is bound to specific code; reviewers will read it alongside the code |
| `hq` | `companies/{co}/knowledge/adrs/` | Decision is org-level (e.g. "we use Linear, not Jira"; "all auth via Cognito") |

If no company resolves and scope is `hq`, default to `core/knowledge/public/adrs/` (rare — most ADRs have a tenant).

## Step 1 — Three-condition gate (HARD BLOCK)

Ask the user three yes/no questions via a single `AskUserQuestion` call:

1. **Hard to reverse** — would changing your mind later cost meaningful effort? (refactor, migration, contract renegotiation)
2. **Surprising without context** — would a future reader look at the result and wonder "why on earth did they do it this way?"
3. **Result of a real trade-off** — were there genuine alternatives, and did you pick this one for specific reasons?

If **any** answer is no → DO NOT WRITE THE ADR. Offer alternatives:

| Failed condition | Alternative |
|---|---|
| Easy to reverse | Skip — you'll just reverse it later |
| Not surprising | Skip — nobody will wonder |
| No real trade-off | Add to `CONTEXT.md` glossary instead, or skip |

Re-prompt: "Skip ADR / Add to CONTEXT.md / Force-write anyway (rarely correct)". Only `Force-write` proceeds; record reasoning in the ADR body so the override is explicit.

## Step 2 — Locate or create target directory

```bash
# repo scope
mkdir -p <repo>/docs/adr/

# hq scope
mkdir -p companies/{co}/knowledge/adrs/
```

Lazy-create only when the first ADR is needed.

## Step 3 — Compute next number

```bash
ls <target>/[0-9][0-9][0-9][0-9]-*.md 2>/dev/null \
  | sed 's|.*/\([0-9]*\)-.*|\1|' \
  | sort -n \
  | tail -1
```

Increment by 1. Default to `0001` if no existing ADRs. Format: `NNNN` (4-digit zero-padded).

Slug from the user's title:

- Lowercase
- Spaces / underscores → `-`
- Strip non-alphanumeric except `-`
- Cap at 60 chars

Final filename: `NNNN-slug.md`

## Step 4 — Walk the user through 1–3 sentences

Single `AskUserQuestion` (or sequential prompts) collecting:

- **Title** — short noun phrase, sentence case, ≤60 chars
- **Body** — 1–3 sentences answering: what's the context, what did we decide, why this over alternatives

That's the minimum. The value is in *recording* the decision, not in completing a template.

## Step 5 — Optional sections (offer, don't force)

Ask via `AskUserQuestion` (multiSelect) which (if any) to include:

- **Status frontmatter** (`proposed | accepted | deprecated | superseded by ADR-NNNN`) — useful when decisions are likely to be revisited
- **Considered Options** — only when rejected alternatives are worth remembering
- **Consequences** — only when non-obvious downstream effects need calling out

If user picks none, the ADR is just title + 1–3 sentences. Good.

## Step 6 — Write ADR

Template (use only the sections selected in Step 5):

```markdown
---
status: <accepted|proposed|...>          # only if Status was selected
date: <YYYY-MM-DD>
related: []                              # ADR numbers, optional
---

# <Title>

<1-3 sentences: context, decision, why.>

## Considered Options                    <!-- optional -->

- <Option A> — <why rejected>
- <Option B> — <why rejected>

## Consequences                          <!-- optional -->

- <non-obvious downstream effect>
```

## Step 7 — Cross-link

If new domain terms surfaced during the conversation, offer to update `CONTEXT.md` (in the same repo for `repo` scope; in `companies/{co}/knowledge/CONTEXT.md` for `hq` scope).

If this ADR supersedes an earlier one, update the older ADR's frontmatter to `status: superseded by ADR-NNNN` (after asking).

If this ADR is accepting a `/architect` candidate, add a backlink in `workspace/reports/{slug}-architect.md` under that candidate's "Outcome" section.

## Step 8 — Report

Print:

```
✓ ADR written: <target>/NNNN-slug.md
  Title: <title>
  Scope: repo | hq
  Optional sections: <Status / Considered Options / Consequences / none>
  CONTEXT.md updated: yes / no
  Supersedes: ADR-MMMM / none
```

## What qualifies (examples)

- **Architectural shape.** "We're using a monorepo." "Write model is event-sourced; read model projects to Postgres."
- **Integration patterns between contexts.** "Ordering and Billing communicate via domain events, not synchronous HTTP."
- **Technology choices that carry lock-in.** Database, message bus, auth provider, deployment target. Not every library — just the ones that would take a quarter to swap out.
- **Boundary and scope decisions.** "Customer data is owned by the Customer context; other contexts reference it by ID only." Explicit no-s are as valuable as the yes-s.
- **Deliberate deviations from the obvious path.** "We're using manual SQL instead of an ORM because X." Anything where a reasonable reader would assume the opposite. Stops the next engineer from "fixing" something deliberate.
- **Constraints not visible in the code.** "We can't use AWS because of compliance requirements." "Response times must be under 200ms because of the partner API contract."
- **Rejected alternatives when the rejection is non-obvious.** Considered GraphQL, picked REST for subtle reasons → record it, otherwise someone will suggest GraphQL again in six months.

## What does NOT qualify

- Library choices that are easy to swap (date formatter, test runner version, lint rule preference)
- Naming decisions ("we call this thing the X intake") → these go in `CONTEXT.md`, not an ADR
- Implementation details that the code itself makes obvious
- Decisions you're already going to revisit next sprint (use a TODO comment)
- "We did the obvious thing" — there's nothing to record

## Cross-references

- `/out-of-scope` — sibling skill for *rejected feature requests* (vs. this for *accepted technical decisions*).
- `/brainstorm`, `/plan`, `/architect`, `/diagnose` — all hand off here when a decision warrants ADR.
- HQ `/learn` — for cross-tenant knowledge capture (different from per-repo / per-company ADR).
- Pattern source: `mattpocock/skills` `grill-with-docs/ADR-FORMAT.md`.
