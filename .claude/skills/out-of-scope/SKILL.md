---
name: out-of-scope
description: Record rejected ideas so future planning does not revisit them.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, AskUserQuestion
---

# Out of Scope

Pattern adapted from `mattpocock/skills` `.out-of-scope/` directory. Used to *stop* re-suggesting features that have been deliberately rejected.

## When `/out-of-scope` vs `/adr` vs `/learn`

| Surface | What it captures | Consulted when |
|---|---|---|
| `/out-of-scope` | Rejected feature request + reasoning + escape hatches | Future feature triage / brainstorm sessions |
| `/adr` | Accepted technical decision + alternatives | Future architecture reviews |
| `/learn` | Cross-tenant pattern (failure mode, fix recipe) | Any session in any company on a similar problem |

A request that becomes "we'll never build this for these reasons" → `/out-of-scope`.
A decision that becomes "we picked X over Y because" → `/adr`.
A failure mode that crystallized into "always check Z first" → `/learn`.

## Step 0 — Resolve company + scope

`$ARGUMENTS` may include:

- `[company]` slug
- `[scope=repo|co|hq]`
- `<one-line rejected request>` — used as title and slug seed

Pick scope via `AskUserQuestion` if ambiguous:

| Scope | Target dir | When |
|---|---|---|
| `repo` | `<repo>/.out-of-scope/` | Rejection only applies to that codebase |
| `co` | `companies/{co}/knowledge/out-of-scope/` | Rejection applies across the company's repos |
| `hq` | `core/knowledge/public/out-of-scope/` | Rejection is HQ-wide policy ("we will never adopt X") |

Hidden `.out-of-scope/` (with leading dot) for repo scope mirrors Matt's convention. The plain `out-of-scope/` for `co` and `hq` because those are inside `core/knowledge/`, not at repo root, and hiddenness is unnecessary.

## Step 1 — Check for duplicates

Before writing, search the target dir + parent scopes for an existing entry with a similar title:

```bash
ls <target>/*.md 2>/dev/null
grep -li "<keyword>" <target>/*.md <target-parent>/*.md 2>/dev/null
```

If a matching entry exists:

| Option | Action |
|---|---|
| **Append** | Add a new "Prior requests" line to the existing file with today's date and a short quote |
| **Update** | Edit the existing file to refine reasoning (rare) |
| **New entry** | The existing entry is genuinely about a different idea — proceed to write |

Present via `AskUserQuestion`.

## Step 2 — Compute slug + filename

Title comes from `$ARGUMENTS` or via prompt. Slug rules:

- Lowercase
- Spaces / underscores → `-`
- Strip non-alphanumeric except `-`
- Cap at 60 chars
- Verb-first when possible (e.g., `disable-batched-questions-in-grill`, not `grill-batched-question-disable`)

Filename: `<slug>.md`. No numeric prefix (unlike ADRs — these aren't ordered).

## Step 3 — Walk the user through the four sections

Use up to two `AskUserQuestion` calls (HQ batched-question policy: ≤4 questions per call) to collect:

1. **Title** — short noun phrase, sentence case
2. **Rejection statement** — one paragraph: what is being rejected and the boundary of the rejection
3. **Why this is out of scope** — reasoning, often citing existing escape hatches (the user's natural-language steering, an alternate skill that handles this, a manual workaround)
4. **Prior requests** — issue/PR/conversation refs if any (`#<n>`, Linear `<co>-<n>`, conversation date)

## Step 4 — Write the markdown

Template:

```markdown
# <Title>

<One-paragraph rejection statement: what's out of scope, and the boundary of the rejection.>

## Why this is out of scope

<Reasoning. Often points to escape hatches:
- The user can already steer this naturally
- Skill X already handles this surface
- The fix belongs at level Y, not in scope here>

<Optional: explain why the obvious-looking fix is wrong>

## Prior requests

- <issue/PR ref> — "<short quote>"
- <conversation date> — "<short quote>"
```

If no prior requests yet, the section can read `(this is the first time we've considered + rejected this)`.

## Step 5 — Cross-link

If the rejection relates to an accepted ADR, add a link in the ADR's `Considered Options` or `Consequences` section pointing to this out-of-scope file.

If the rejection emerged from a `/brainstorm` session, link the brainstorm artifact (`personal/projects/{slug}/brainstorm.md` or `companies/{co}/projects/{slug}/brainstorm.md`) in the rejection's "Prior requests" section.

## Step 6 — Report

Print:

```
✓ Out-of-scope entry written: <target>/<slug>.md
  Title: <title>
  Scope: repo | co | hq
  Prior request count: <N>
  Linked ADRs: <list / none>
```

## Consultation pattern (for other skills)

When `/brainstorm`, `/prd`, or any feature-triage skill receives a feature request, it should grep all three out-of-scope dirs (most-specific first):

```bash
# in repo scope
grep -li "<keyword>" \
  <repo>/.out-of-scope/*.md \
  companies/{co}/knowledge/out-of-scope/*.md \
  core/knowledge/public/out-of-scope/*.md \
  2>/dev/null
```

Match → surface the rejection summary + ask the user "is this different from <existing>, or are you re-litigating?" before proceeding.

This is the *whole point* of the graveyard. A graveyard nobody reads is just a folder.

## Examples (copy from Matt's repo for shape)

- `repos/public/skills/.out-of-scope/question-limits.md` — rejecting a configurable cap on grill-me question count
- `repos/public/skills/.out-of-scope/mainstream-issue-trackers-only.md` — rejecting support for esoteric trackers
- `repos/public/skills/.out-of-scope/setup-skill-verify-mode.md` — rejecting a verify-mode for setup skills

## Cross-references

- `/adr` — sibling for accepted decisions.
- `/brainstorm`, `/prd` — should consult `/out-of-scope` before adding ideas.
- `/learn` — for cross-tenant failure-mode patterns (different surface).
- Pattern source: `mattpocock/skills` `.out-of-scope/` directory.
