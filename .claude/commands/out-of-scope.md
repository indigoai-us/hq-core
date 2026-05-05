---
description: Record a rejected feature or change request with reasoning. Future sessions consult this graveyard before re-litigating the same idea.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit, AskUserQuestion
argument-hint: "[company] [scope=co|repo] <one-line rejected request>"
visibility: public
---

# /out-of-scope — Rejected-Feature Graveyard

Record *what we decided not to build, and why.* Different from `/adr`:

| | `/adr` | `/out-of-scope` |
|---|---|---|
| Captures | Accepted technical decisions | Rejected feature requests |
| Trigger | We chose A over B for code-shape reasons | Someone asked for X and we said no |
| Consulted by | Future architecture reviews | Future feature triage / brainstorm sessions |

**Input:** $ARGUMENTS

## When to use

- A feature request was rejected and the reasoning is non-obvious
- The same request has come up >1 time and you want to stop re-litigating
- A `/brainstorm` or `/prd` session bounded an idea that future sessions might reopen

## Steps

1. Load the out-of-scope skill from `.claude/skills/out-of-scope/SKILL.md`.
2. Resolve company + scope (`repo` for code-bound; `co` for company-wide; `hq` for HQ-wide cross-tenant).
3. Pick target directory:
   - `repo` → `<repo>/.out-of-scope/`
   - `co` → `companies/{co}/knowledge/out-of-scope/`
   - `hq` → `knowledge/public/out-of-scope/`
4. Compute slug from the request title.
5. Walk the user through: what was rejected, why it's out of scope, what escape hatches exist instead, prior request links if any.
6. Write the markdown file. Cross-link to relevant ADRs.

## Cross-references

- `/adr` — sibling for accepted decisions.
- `/brainstorm`, `/prd` — consult `/out-of-scope` before adding ideas.
- `/learn` — for cross-tenant pattern capture (different surface).
- Pattern source: `mattpocock/skills` `.out-of-scope/` directory (`repos/public/skills/.out-of-scope/`).
