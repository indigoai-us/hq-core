# Goals and Tasks Board

A pattern for recording intent on an HQ board — long-range goals, the projects
that serve them, and the loose tasks that belong to no project at all — so that
a person and an agent can look at the same structure and agree on what matters,
what is in flight, and what is finished.

## The board file

A board is `board.json`. The owner's own board is `personal/board.json`; a
company's is `companies/{co}/board.json`. It holds two kinds of thing:

**Objectives and key results** (`objectives[]`) — durable statements of what
should be different, each with key results that make progress observable rather
than asserted. A key result may be updated by hand (`source: "manual"`) or
computed from linked project completion (`source: "derived"`). Manage these with
`/goals`.

**Tasks** (`tasks[]`) — the global task list. Discrete work with no project
around it.

Projects are registered separately (`companies/{co}/board.json` `projects[]` for
a company, `personal/projects/board.json` for the owner) and each points at a
`prd.json`. A project's own work is broken into user stories inside that
`prd.json`. Setting a project's `objective_id` links it to a goal.

## Why tasks are not projects

Most work is not big enough to deserve a project. Booking an appointment,
renewing a registration, chasing a reply — these have no natural project around
them, and a `prd.json` is the wrong container for one. It carries `branchName`,
`e2eTests`, `files`, and `dependsOn`, none of which mean anything for "renew the
registration", and a standing bucket project pollutes the project registry with
an entry that never completes.

So tasks live directly on the board, in their own small shape:

```json
{
  "id": "T-001",
  "title": "Renew the car registration",
  "description": "Longer context, including anything already tried.",
  "status": "open",
  "priority": 2,
  "objective_id": "pe-obj-005",
  "criteria": ["New tags are on the car."],
  "contacts": [{ "name": "Jane Doe", "email": "jane@example.com", "role": "…" }],
  "createdAt": "2026-09-09"
}
```

`status` is `open`, `blocked`, or `done` — `blocked` is a real state for an
errand waiting on somebody else, and carries `blockedReason`. `criteria` are the
observable done conditions. `contacts[]` records the people involved inline, so
whoever picks the task up can act without going back to the original
conversation. `objective_id` is optional; an unlinked task is fine.

If a task grows past a handful of steps, promote it to a project and link that
project to a key result.

## Working the board

Use `core/scripts/hq-task.sh` rather than editing `board.json` by hand. It
assigns ids, keeps the task shape consistent, and defaults to the personal
board:

```
hq-task.sh list   [--company <slug>] [--all] [--goal <objective-id>]
hq-task.sh add    --title "<short title>" [--description "<context>"] \
                  [--criteria "<one done-criterion>"]... \
                  [--contact "Name <email>|role"]... \
                  [--goal <objective-id>] [--priority <1-3>]
hq-task.sh done   --id T-002
hq-task.sh block  --id T-002 --reason "<what is in the way>"
hq-task.sh reopen --id T-002
hq-task.sh goals
```

## The contract for agents

An agent working a board should be able to operate from the files alone:

1. Read `board.json` for goals and the task list.
2. Treat a task with `status: "open"` as available work; `blocked` means
   something outside the board must move first.
3. Treat `criteria` as the definition of done — do not close a task until every
   criterion is observably satisfied.
4. Write outcomes back to the same file, and update a derived key result when a
   linked project's status changes.
5. Read a project's `prd.json` when the work is project-scoped rather than a
   loose task.

Decisions that spend money, send messages to other people, or commit the owner
to a time remain human decisions. The board is where an agent reads intent and
records results; it is not a grant of authority to act unilaterally.

## Where a personal board lives

`personal/board.json`, in the overlay at the HQ root — not
`companies/personal/`. That path exists, but it is a reserved scope with no
roster, and, decisively, the personal vault's `.hqinclude` allowlist does not
cover it: browsing the vault there returns nothing while other companies' boards
are present. A board kept under it is invisible to anything reading the vault.

`personal/board.json` must itself be listed in `.hqinclude` for the same reason.
A path outside the allowlist does not reach the vault, whatever its directory.

## Access

A board in a cloud-backed company is reachable the ordinary way: grant a
teammate or fleet agent read or write on the board path with `hq files share`,
scoped as narrowly as the work requires.

A personal board is reached by identity rather than by grant. The owner's
personal vault mirrors the allowlisted parts of the HQ tree, and an agent
running under the owner's own identity inherits that vault with no grant issued
against anything. This is what makes the personal overlay the right home: a
personal agent picks the board up for free.

Two things follow. First, confirm a board is actually in the vault before
relying on an agent reaching it — `hq files browse --personal personal` — since
a path outside the allowlist is unreadable no matter whose identity the agent
runs under. Second, identity-based access does not extend to a second person; an
agent that must be reachable by someone other than the owner needs a
cloud-backed company.

## See also

- `/goals` — manage objectives and key results
- `/startwork` — orientation, including board status
