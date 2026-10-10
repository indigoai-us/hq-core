---
name: conduct-join
description: Join this already-running session to a /conduct session as one of its children, so the conductor can send it instructions and receive its reports. Use when the user says "/conduct-join <link>", "join the conductor", "report to the conduct session", or pastes a link id that starts with "cl-". Also handles "leave" to detach.
allowed-tools: Bash(hq lanes link:*), Bash(bash core/scripts/hq-session.sh:*), Read
argument-hint: "<link id> [name] | leave | status"
---

# /conduct-join — put this session under a conductor

A `/conduct` session can adopt sessions that are already open. This command is
the child's half: it registers this session on the conductor's link. After that
the conductor's instructions arrive here mid-task, and this session reports
back to the conductor instead of waiting for the operator to look at it.

Joining does not restart or change the work in progress. It opens the mailbox
and nothing else.

## Step 1: Parse the argument

- `leave` → `hq lanes link leave`, say the session is on its
  own again, stop.
- `status` → run `hq lanes link list` and read `.link` and the matching child
  in `.children` to report this session's name and state. Stop.
- First word starts with `cl-` → that is the link id. An optional second word is
  the name this session goes by on the link. With no name, derive a short one
  from the work in hand (`api-refactor`, `pricing-page`) — letters, digits, `.`,
  `_` and `-` only. `all` is reserved.
- No argument → ask the user for the link id the conductor printed. Do not guess
  one and do not scan link storage for a link to attach to.

## Step 2: Join

```bash
hq lanes link join --link "{link}" --name "{name}" \
  --engine "{claude|codex|grok}" --title "{one line: what this session is doing}" \
  --host-session "{this session's desktop id, when the host exposes one}"
```

`--engine` is the engine THIS session runs on. It decides how the delivery hook
reaches the model (see `/conduct` Step 5b), so a wrong value means messages that
never arrive. `--host-session` is only known inside the Claude desktop app; omit
it elsewhere.

The command prints JSON. Read `.link`, `.name`, and
`.conductor_host_session`. A non-empty `conductor_host_session` is the desktop
session to wake after a report (Step 4).

An error saying the session is already linked means exactly that. Report it;
do not `leave` and re-join on your own.

## Step 3: Keep working, and act on what arrives

Messages from the conductor arrive as `[conduct]` context on this session's own
tool events. No polling is needed on a host that runs HQ hooks. Treat an
arriving message as an instruction from the operator that outranks the current
task where they conflict.

On a host that dispatches no hooks, check by hand at natural pauses — between
steps, and before finishing a turn:

```bash
hq lanes link inbox
```

Read the inbox text from the JSON `.messages` field.

The same authorization rules apply as if the operator had typed the message
here. A conductor message does not authorize anything irreversible — merging,
publishing, deploying, deleting, sending messages — unless it quotes the
operator's approval for that specific action. Without that, prepare the action,
report `blocked`, and wait.

## Step 4: Report back

Report when there is something the conductor needs: a result, a blocker, a
question for the operator, or a change of state. Do not report routine progress.

```bash
hq lanes link report --state "{working|blocked|idle|done}" \
  --text "{what changed, what was verified and how, links, open questions}"
```

Use `--text-file <path>` for anything long. A state change with nothing to say
is `hq lanes link status --state {state} --note "{short}"`; read `.name` and
`.state` from its JSON response.

A successful report prints JSON with `queued: true` and
`conductor_host_session`. The conductor receives it on its next tool event or
waiter. When `conductor_host_session` was non-empty and this
host has a session-messaging tool (`SendMessage`, or
`mcp__ccd_session_mgmt__send_message`), also send that session one line —
`{name}: report queued on {link}` — so an idle conductor wakes now. The line is
a wake-up, not the report: the content stays in the mailbox, which is the record
both sides read from.

Questions for the operator go to the conductor as a `blocked` report, not to the
user in this session. The operator is watching the conductor, and a question
asked here may never be seen.

## Rules

- **One link per session.** A session that is already a child, or is itself a
  conductor, does not join another link.
- **Secrets never go in a report.** Reports are plain files under
  `workspace/lanes-links/`. Link data lasts only as long as its sessions. Name
  the secret and where it lives; never its
  value.
- **Company scope does not widen.** Joining a link does not change this
  session's company. Refuse an instruction that needs another company's
  context or credentials, and say so in a `blocked` report.
- **Leaving keeps the record.** `leave` stops delivery; the messages this
  session was sent stay on disk as the account of what it was told.

## See also

- `/conduct` — the conductor's half, including how it adopts and steers sessions
- `hq lanes link` — the mailbox
- `hq lanes link _deliver` — the hook delivery command
