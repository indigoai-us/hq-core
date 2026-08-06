---
name: domain-modeling
description: |
  Actively build and sharpen a project's domain model — challenge fuzzy or overloaded terms against a glossary, stress-test with edge cases, and maintain CONTEXT.md as the source of truth for a ubiquitous language.
  Use when the user wants to pin down domain terminology, resolve a naming conflict, define a ubiquitous language, or when another skill needs to produce or sharpen the domain model. Triggers on "what should we call this", "domain model", "ubiquitous language", "define these terms", "update CONTEXT.md".
allowed-tools: Read, Write, Edit, Grep, Glob
---

# Domain Modeling

Actively build and sharpen the project's domain model as you design. This is the *active* discipline — challenging terms, inventing edge-case scenarios, and writing the glossary down the moment a term crystallises. Merely *reading* `CONTEXT.md` for vocabulary is a one-line habit any skill can do (and `/architect` and `/diagnose` already do it). This skill is for when you are *changing* the model, not just consuming it — it is the producer that keeps `CONTEXT.md` honest.

Pattern adapted from [mattpocock/skills](https://github.com/mattpocock/skills) (skills/engineering/domain-modeling), upstream commit 391a270; HQ cross-references and delegation to /adr added.

## When this skill vs others

| Situation | Skill |
|---|---|
| Fuzzy, overloaded, or conflicting domain terms; need a ubiquitous language | **`/domain-modeling`** (this) |
| A decision is hard to reverse, surprising, and a real trade-off | hand off to **`/adr`** |
| The architecture (module shape, seams) is the problem, not the vocabulary | **`/architect`** |
| A bug you cannot reliably reproduce or measure | **`/diagnose`** |

This skill never creates ADRs itself. When a decision qualifies, it hands off to `/adr` (see "Offer ADRs sparingly").

## Step 0 — Resolve company + repo context

Same resolution order the other engineering skills use:

1. Honour an explicit `[company]` / `[path]` argument
2. Fall back to `workspace/threads/handoff.json` `.company`
3. Fall back to cwd inference via `companies/manifest.yaml`
4. Last resort: ask the user (one question at a time — see below)

The domain model lives with the code. For a repo under `repos/`, use `<repo>/CONTEXT.md` and `<repo>/docs/adr/`. These conventions are already HQ-adopted: `/architect` and `/diagnose` read `<repo>/CONTEXT.md` for vocabulary and `<repo>/docs/adr/` for decisions.

## File structure

Most repos have a single context:

```
<repo>/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the repo root, the repo has multiple contexts. The map points to where each one lives:

```
<repo>/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/                          ← system-wide decisions
├── src/
│   ├── ordering/
│   │   ├── CONTEXT.md
│   │   └── docs/adr/                 ← context-specific decisions
│   └── billing/
│       ├── CONTEXT.md
│       └── docs/adr/
```

Infer which structure applies:

- If `CONTEXT-MAP.md` exists, read it to find the contexts.
- If only a root `CONTEXT.md` exists, it is a single context.
- If neither exists, create a root `CONTEXT.md` lazily when the first term is resolved.

Create files lazily — only when you have something to write. If no `CONTEXT.md` exists, create one when the first term is resolved. When multiple contexts exist, infer which one the current topic relates to; if it is unclear, ask.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update `CONTEXT.md` right there. Don't batch these up — capture them as they happen. Use the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md).

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### One decision at a time

When a term, boundary, or naming choice needs a human call, ask it as a single, focused question and wait for the answer before moving on — the HQ charter's structured one-question-at-a-time discipline. Don't bundle five naming decisions into one wall of text; resolve them one at a time and write each into `CONTEXT.md` as it lands. If an `AskUserQuestion`-style prompt is available in the harness, use it for the pick.

### Offer ADRs sparingly — then hand off to /adr

Only offer to record a decision when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful.
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons.

If any of the three is missing, skip it. A naming decision with no trade-off belongs in `CONTEXT.md`, not an ADR.

When a decision *does* qualify, **do not write the ADR yourself — hand off to `/adr`.** `/adr` owns the three-condition gate, the numbering, the target-directory resolution (repo vs company scope), and the file format. Frame the hand-off as: _"That's a hard-to-reverse call worth recording — want me to capture it via `/adr`?"_ The [ADR-FORMAT.md](./ADR-FORMAT.md) in this folder is reference only for what an ADR looks like; `/adr` is what produces one.

## Cross-references

- `/adr` — the producer for architectural decisions. This skill detects an ADR-worthy decision and hands off; `/adr` runs the gate and writes the record.
- `/architect` — consumes `CONTEXT.md` vocabulary when scoring architecture candidates, and surfaces new domain terms back into it inline. Reach for it when the *module shape* is the problem, not the vocabulary.
- `/diagnose` — reads `<repo>/CONTEXT.md` and `<repo>/docs/adr/` when framing a bug; a sharper glossary makes its hypotheses sharper.
- `/codebase-design` — pairs a crisp ubiquitous language with the module-design pass.
- Pattern source: [mattpocock/skills](https://github.com/mattpocock/skills) (skills/engineering/domain-modeling), upstream commit 391a270.
