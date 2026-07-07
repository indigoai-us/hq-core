---
name: hq-integrations
description: "Use company-connected apps (Linear, Notion, …) from any HQ session via `hq integrations` — list connected apps, discover their tools, call them, and handle the approval gate on change-making calls. Use when the user asks an agent to look something up or act in an external app their company has connected on the console Integrations page."
allowed-tools: Bash(hq:*)
---

# HQ Integrations

Company admins connect external apps on the console **Integrations** page (search → sign in or paste a key). Once connected, every company identity — cloud agents and local sessions alike — can use those apps through HQ's governed integration gateway: one company login, per-connection write policy, full audit trail. This skill is the local-session path; requires hq-cli ≥ 5.62.

## Commands

```bash
hq integrations list [--company <slug>]            # what's connected + write policy + connection ids
hq integrations tools --provider <slug>            # the app's live tool catalog (read-only round-trip)
hq integrations call <tool> --provider <slug> --args '<json>'   # invoke a tool
hq integrations approve|reject <queueId> --provider <slug>      # owner decision on a queued call
```

- `--company` defaults to the caller's single active membership; pass the slug when they belong to several. Never hardcode company ids.
- `--json` on any subcommand for machine-readable output.
- `--provider` is the bare slug from `list` (e.g. `linear`); `--connection acct_…` also works.

## The approval gate (important)

Reading is always allowed, but **invoking an app tool routes through the connection's write policy** (default: `confirm`) because the gateway can't know which upstream tools mutate. A gated call returns *queued for approval*, not a result:

```
Queued for approval — this call can change the app, so a company owner decides first.
Approve with:
  hq integrations approve cq_… --provider linear
```

- Tell the user plainly: the request is **waiting for an owner's approval**, and give them the approve command. Do NOT retry the call — retries create duplicate queue entries.
- If the user IS an owner and asked for the action themselves, run the approve command; it executes exactly once and prints the result.
- Queue entries expire after ~7 days; owners can change the policy per connection on the console Integrations page (Ask a person first / Allow automatically / Never allow).

## Recipe: "list my Linear issues"

```bash
hq integrations list                                  # find the provider slug
hq integrations tools --provider linear               # find the tool name (list_issues)
hq integrations call list_issues --provider linear --args '{"assignee":"me","limit":10}'
# → queued → (owner) hq integrations approve <queueId> --provider linear → issues JSON
```

## Errors worth translating

- *No connected apps yet* → the company hasn't connected anything; point an admin at the console Integrations page.
- *Multiple apps are connected* → re-run with `--provider <slug>` (the error lists them).
- *401 / session errors* → `hq auth refresh`, then retry (`hq login` if refresh fails).
- *needs sign-in* flag on `list` → the connection lost its credentials; an admin reconnects it on the console.
