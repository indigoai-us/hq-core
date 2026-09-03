---
name: conduct
description: Put the session into orchestrator mode — every task is dispatched to a background worker agent on a user-chosen model (grok-worker on grok-4.5, ocx-self, ocx-gpt-5-6-sol-pro, or native Claude opus/sonnet/haiku), so the parent session stays free to accept and route new messages. Use when the user says "/conduct", "use background agents for everything", "keep the session free", "orchestrate via workers", or names a model for delegated work.
allowed-tools: Agent, Bash, Read, AskUserQuestion, SendMessage
argument-hint: "[agent] [task description] | status | off"
---

# Conduct — Orchestrate the Session Through Background Agents

The parent session is the conductor. It never does the work itself; it writes
briefs, dispatches background agents, relays results, and stays responsive.

## Agent roster (the model the user chooses)

| Choice | `subagent_type` | Underlying model | Best for |
|---|---|---|---|
| `grok` (default when a mode is already set and none is named) | `grok-worker` | grok-4.5 via the local grok Build CLI | implementation, landing, CI babysitting, fixes |
| `opus` | `ocx-self` | the session's own default Claude model via opencodex (self-clone) | judgment-heavy work, review, design |
| `gpt` | `ocx-gpt-5-6-sol-pro` | gpt-5.6-sol-pro via opencodex | second-opinion review, exploration |
| `claude-opus` / `claude-sonnet` / `claude-haiku` | `general-purpose` with `model:` opus/sonnet/haiku | native Claude subagent | research, reads, quick lookups |

The `grok-worker` and `ocx-*` rows require those agent definitions to be
installed in the user's Claude Code agents directory (`~/.claude/agents/`).
When an agent definition is absent, fall back to `general-purpose` with
`model:` (opus/sonnet/haiku) and tell the user which roster entry was
unavailable.

The `ocx-*` agents ignore the `model` argument (pinned by the proxy).

## Step 1: Parse the argument

- `off` → clear the mode with `bash core/scripts/hq-session.sh set conduct_agent ""` and say the session is back to doing work directly.
- `status` → read `conduct_agent` from the session meta and list running and finished agents from this session's notifications. No agent spawn.
- First word matches a roster choice → persist it as the session default with
  `bash core/scripts/hq-session.sh set conduct_agent "{choice}"`. Remaining words are the first task.
- First word is not a roster choice and no `conduct_agent` is set → ask ONE `AskUserQuestion` (options: grok / opus / gpt / claude-sonnet, grok recommended; only offer grok/opus/gpt when their agent definitions are installed), then persist it.
- No task text → confirm the mode and wait.

## Step 2: Dispatch (per task — this turn and every later turn while the mode is set)

For each task the user sends while `conduct_agent` is set:

1. Do at most two cheap read-only calls yourself to fill the brief (branch state, PR number, file path). Never edit, build, test, or run long commands in the parent.
2. Write a self-contained brief. The agent has no access to this conversation. Include:
   - the goal and observable done criteria;
   - absolute repo path, branch, PR or release identifiers;
   - the company slug and the relevant hard policies (repo-anchored version-control commands, never push the HQ root, no secrets in output, tests never loosened);
   - what to do if blocked (report back; do not ask the user);
   - the report shape: what changed, what was verified, links, open risks.
3. `Agent` with `run_in_background: true`, `subagent_type` from the roster, a 3–5 word `description`. For `general-purpose` also pass `model`.
4. Reply to the user in one line: what was dispatched and on which model. Then end the turn. Do not poll.
5. On the completion notification: relay the outcome plainly (done / blocked / needs a decision) with any links. If the agent needs a decision, ask the user with `AskUserQuestion`; when answered, continue the SAME agent with `SendMessage` so it keeps its context.

Independent tasks go out in parallel in one response. Dependent tasks chain: dispatch the next one from the completion notification of the previous.

## Rules

- The parent never blocks on an agent. `run_in_background: true` always.
- Irreversible actions (merge, publish a release, force-push, delete, send messages) stay with the user: the agent prepares and reports; the parent asks once, then tells the agent to proceed.
- Agents doing story work commit their own work with repo-anchored commands; the parent verifies from the report.
- Keep company context isolated: one company per brief.
- The mode persists for the session in `workspace/sessions/<id>/meta.yaml` under `conduct_agent`. Later turns read it; `/conduct off` clears it.
