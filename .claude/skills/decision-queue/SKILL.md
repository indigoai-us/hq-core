---
name: decision-queue
description: Resolve pending user decisions one at a time, one picker per item. The only owner-facing ask path for /super-conductor.
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
---

# /decision-queue — Sequential Decision Walkthrough

Forces strict compliance with `decision-queue-one-at-a-time.md` (global policy, soft enforcement). When a session has accumulated 2+ user-facing decisions, invoke this command to walk them one at a time with `AskUserQuestion`, updating working state between answers.

**Input:** $ARGUMENTS

## When to Use

- The model is about to surface 2+ decisions and is tempted to batch them into a single `AskUserQuestion` (or a numbered list in text).
- A skill (`/brainstorm`, `/prd`, `/architect`, `/diagnose`, `/run-project`, `/execute-task`, `/strategize`, `/review-plan`) needs to defer to the user on several separable choices.
- Ad-hoc: the user is mid-task, has multiple open questions, and explicitly asks for a decision queue (`decision queue plz`, `walk me through these one at a time`).

## Rule

Each decision = **one** `AskUserQuestion` call with **one** question. Wait for the answer. Update any working state (plan file, brainstorm.md, PRD, in-memory state, or just an explicit acknowledgement). Then proceed to the next decision.

**Never** batch 2+ decisions into a single `AskUserQuestion` invocation, even though the tool accepts up to 4 questions per call. That capacity is for *disambiguating a single decision* (e.g. "Which DB?" + "Which migration tool?" as a tightly-coupled pair), not for stacking unrelated decisions.

## Process

1. **Parse $ARGUMENTS** — either a free-text description of decisions in scope, or a path to a markdown/json file listing them. If neither, infer from session context (most recent assistant message that surfaced decisions).
2. **Enumerate the queue** internally as a numbered list with: title, context, default recommendation (if any), 2-4 options.
3. **Show the queue header** to the user as a transparency block: `Decision queue (N items): 1. …  2. …  3. …` so they know what's coming. Skip it for a single item. Never end the turn on the header: the first picker always follows it in the same turn.
4. **For each decision in order:**
   a. Brief insight block explaining why this decision is foundational / what it unlocks. Skip it in conductor mode.
   b. `AskUserQuestion` with exactly one question, 2-4 options, recommended option first with `(Recommended)` suffix. When an option carries content the user must see to choose (an outbound message draft, a file or asset, a code or config snippet), put it in that option's `preview`, in full for drafts.
   c. Wait for the answer.
   d. Update working state — minimum: state in plain text what was decided and how it shapes the next decision. If a plan file / brainstorm.md / PRD exists, persist the answer there.
   e. **Relay** the answer when the item came from someone else (a child session, a teammate, a bot) before opening the next picker. The caller says how; for `/super-conductor` it is the quoted `OWNER GO` (or hold) sent on the link and by direct message to the owning session.
   f. If the answer materially changes the remaining queue (e.g. user picks "skip the rest", "stop", or an option that obviates downstream questions), re-enumerate before moving on.
5. **After the last decision:** summarize the resolved decisions as a numbered list and confirm next action.

## Conductor mode (`/super-conductor`, `/overnight`)

`/super-conductor` routes everything that needs the owner through this skill, but in conductor mode the conductor does not open pickers itself. The pickers are opened by the link's `/decision-desk` session, fed by the link's decision queue (`workspace/reports/conduct/<link>-decisions.jsonl`), so the conductor's turn is never held by a picker:

- Run for any number of items, including one.
- Each item comes with its source (child session, channel, CI) and its relay target. Append every owner item to the queue the moment it is found, in the same turn: `node core/scripts/super-conductor-decisions.mjs add --file <queue> --source ledger|ask|conductor --ref <id> --question "<who asked and what happens on each answer>" --option "<label>::<description>"... [--recommended <label>] --priority critical|normal --relay-session <local_ id> --relay-child <child> --relay-link <link> [--company <slug>] [--asked-by <who>]`. `add` exits 3 with the existing id when the same source and ref is already queued; the same question is never queued twice.
- One picker per item, asked by `/decision-desk`, not here. A pick between several candidates (A/B assets, copy or sound variants) is one item with the candidates as options; with more than four, queue a first item to narrow, then a second to choose. Two to four options, recommended first.
- Arrival order, critical first: `next` returns the oldest open row with critical rows ahead of normal ones, so set `--priority critical` on merges, deploys, sends, money, and deletes that are blocking a child.
- An item the owner already answered in the source session (the open-ask checker no longer lists it, or the child's last message shows the owner's reply) is dropped, not asked: `super-conductor-decisions.mjs drop --id <id> --note "answered in source" --by conductor`. `drop` always needs a reason; a row is never dropped without one, and never because it is inconvenient to relay.
- A child session's ask is relayed by the desk itself the moment the owner picks (`/decision-desk` Step 3b); the conductor sees no ANSWER line for it unless the desk's relay failed. Relay every other answer when its `SUPER-CONDUCTOR ANSWER` line arrives on the heartbeat: write the ledger row `answered` (and `hq lanes questions answer` for a lane question), send the quoted `OWNER GO` (or hold) on the link and by direct `send_message` to the relay session in the same turn, update the conductor's save file (`open_decisions`), then `super-conductor-decisions.mjs relayed --file <queue> --id <id> --by conductor`. A relay that fails leaves the row `answered` and the next wakeup retries it; the owner is never asked twice.
- Standing answers: a row that matches one of the owner's standing rules (`super-conductor-decisions.mjs standing list`) is answered at `add` time and never reaches the desk. Its ANSWER line says "answered by standing <id>, never asked"; relay it exactly like a desk answer, quoting the rule rather than an OWNER GO from today. Only the desk writes rules (`standing add --by desk`), and only on the owner's explicit "from now on" words. In code, a rule needs an expiry (at most 30 days), never answers a merge, deploy, send, delete or money row without the owner's `--irreversible`, and never answers a teammate's request without `--from`.
- New items found while the desk is draining are appended to the queue and the desk asks them in the same drain.
- Never end the turn with unasked items listed in prose ("still to come", "next I'll ask about"), and never open an `AskUserQuestion` for an owner item in the conductor, except a `priority: critical` row the conductor has claimed first (`claim --id <id> --desk conductor`; see /super-conductor "Critical cards interrupt"). `answer` always needs `--desk <name>` holding the row's fresh claim. The item goes to the queue; the turn ends after the last relay or the last `add`.

## Examples

**Correct (sequential):**

```
Decision queue (3 items):
  1. Branching strategy
  2. PR splitting
  3. Test coverage scope

[Insight: branching strategy is foundational because…]
AskUserQuestion(Q1) → user picks "new branch off main"
[Update: working on indigo/hq-sync-… off latest main]

[Insight: PR splitting depends on Q1 because…]
AskUserQuestion(Q2) → user picks "single PR"
[Update: one PR for both yellow-removal + copy-prompt]

[Insight: test scope follows from Q2 because…]
AskUserQuestion(Q3) → user picks "vitest only"
[Update: no Playwright; local units + manual UAT]

Resolved:
  1. Branch off main → indigo/hq-sync-no-yellow-copy-prompt
  2. Single PR
  3. vitest + manual UAT
```

**Incorrect (batched):**

```
AskUserQuestion([Q1, Q2, Q3])  ← never do this; even though the schema allows it
```

## Rules

- One `AskUserQuestion` call per decision.
- Recommended option goes first with `(Recommended)` in the label, per `AskUserQuestion` tool conventions.
- Never reference "the plan" if you are in plan mode — the user can't see it. Use `ExitPlanMode` for plan approval, not `AskUserQuestion`.
- If only **one** decision is in scope outside conductor mode, asking it directly with one `AskUserQuestion` is fine. In conductor mode every item, even a single one, goes through this skill.
- If the user says "stop", "I'll figure it out", or picks an option that ends the queue, stop. Do not force the remaining decisions.
- Persist resolutions in the appropriate working file (plan / PRD / brainstorm.md) when one exists; otherwise just state the resolution in text.

## Related

- Global policy: [`decision-queue-one-at-a-time`](../../../core/policies/decision-queue-one-at-a-time.md)
- Counterpart for accepted technical decisions worth not re-litigating: `/adr`
- Counterpart for rejected ideas: `/out-of-scope`
