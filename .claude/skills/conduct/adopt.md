# Conduct — adopt sessions that are already running

Loaded by `/conduct adopt`, `/conduct tell` and `/conduct status` when the
session has adopted children. `SKILL.md` Step 7 points here.

Lanes are processes this session launched. The operator often also has other
sessions open — a Claude desktop session mid-refactor, a Codex or Grok session
in a terminal. Those can be **adopted**: each joins this session's link with
`/conduct-join`, and from then on this session instructs them and receives their
reports. The operator talks to one session instead of visiting each.

Adopted sessions are not pool lanes. They take no pool slot, this session did
not start them and must not stop them, and the pool cap does not count them.
What they share with lanes is the mailbox and the delivery hook.

### Open the link

```bash
bash core/scripts/conduct-link.sh open --engine "{this session's engine}" \
  --host-session "{this session's desktop id, when the host exposes one}"
# {"link":"cl-20260918-a1b2c3","join":"/conduct-join cl-20260918-a1b2c3"}
```

`open` is idempotent: a second call returns the same link. Then get the join
line into each session to adopt:

- **Claude desktop app** — find the session with
  `mcp__ccd_session_mgmt__list_sessions`, confirm with the operator which ones to
  adopt (one `AskUserQuestion`, multi-select), and send each the join line with
  `SendMessage` / `mcp__ccd_session_mgmt__send_message`. The target runs
  `/conduct-join` as its next turn. Never adopt a session the operator did not
  pick.
- **Anywhere else** — give the operator the join line to paste into that
  session. A Codex or Grok session in a terminal joins the same way.

Then start the waiter in the background, so a report wakes this session when it
is idle:

```bash
bash core/scripts/conduct-link.sh wait --timeout 3600   # run_in_background
```

It exits 0 when a report is pending and 3 on timeout. Either way, restart it
after handling what arrived, for as long as the link has children.

### Send an instruction

```bash
bash core/scripts/conduct-link.sh send --child "{name}" --text "{instruction}"
bash core/scripts/conduct-link.sh send --child all --text-file "{path}"
```

Delivery follows the child's engine exactly as in Step 5b: a Claude or Codex
child receives it as context on its next tool event, a Grok child by an
interrupted tool call. That reaches a child that is **working**. A child that is
idle has no tool events, so in the desktop app follow the `send` with one
session message to the child's `host_session` (from `list`) — `conductor: message
queued, run bash core/scripts/conduct-link.sh inbox` — which starts its next
turn. An idle terminal session picks the message up on its next turn; tell the
operator that, rather than implying it landed.

Write an instruction the way Step 4 writes a brief: the goal, the done criteria,
and what to report back. The child has its own context but not this
conversation.

### Receive reports

Reports arrive as `[conduct]` context on this session's tool events, each
labelled `[from {name} · {state}]`. On a host with no hooks, or when the waiter
fires, read them directly:

```bash
bash core/scripts/conduct-link.sh read
```

Handle a report the way Step 6 handles a lane result: verify a claimed result
independently before relaying it, send failures back to the same child, and
route every question for the operator through `/decision-queue` — then send the
answer back to the child that asked. When the transcript matters more than the
summary, read it with `mcp__ccd_session_mgmt__list_events`.

### Status

```bash
bash core/scripts/conduct-link.sh list
```

Render one row per child — name, engine, state, note, undelivered count — beside
the pool rows, in the same board widget when two or more things are in motion.

### Limits that are easy to get wrong

- **A child keeps its own company.** `list` shows each child's `company`. Never
  carry one child's findings, files or credentials into an instruction for a
  child bound to a different company. Relay to the operator instead.
- **Forwarded approval must be quoted.** A child treats an instruction as the
  operator speaking, but will not take an irreversible action on it unless the
  message quotes the operator's approval for that specific action. Ask the
  operator first, then quote the answer.
- **The mailbox is the record.** Session messages in the desktop app are
  wake-ups. Instructions and reports go through `conduct-link.sh`, so both sides
  and any later session can read what was said under
  `workspace/conduct-links/{link}/`.
- **Unattended sessions cannot be messaged** by the desktop tools. A scheduled or
  remote-dispatched session can still join and is reached through the hook only.
