---
id: hq-prefer-usable-integrations
title: Use a usable HQ Integration before a separate MCP, web search, or asking the user
when: integrations || connector || connectors || jira || gmail || hubspot || salesforce || figma || asana || clickup || airtable || calendly || notion
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-10-06
source: hq-core-staging:usable-integrations-session-start
public: true
---

## Rule

HQ Integrations come first. When a task needs data from, or an action in, an
external app, check whether the active company has a usable HQ Integration for
that app before you use a separately configured MCP server or connector, a web
search, a browser session, or ask the user to look something up or paste data.
If it does, use it through the HQ gateway.

A usable integration is connected in the active company and shared with the
caller under the gateway's access rule. Find them in this order:

1. The SessionStart note "HQ Integrations you can use in company <slug>",
   when present and `<slug>` is the company this session is working for. It
   is cached and may be up to an hour old. A note marked as this device's
   default company is a guess made at the HQ root: ignore it once the
   session is bound to a different company. The note names at most 30 apps;
   an app it does not name may still be usable, so check step 2 before
   choosing another route.
2. `bash core/scripts/usable-integrations.sh show --company <slug>`, which
   reads the same cache and refreshes it live when it is stale. It prints the
   exact flag for each app.
3. `hq integrations list --usable --company <slug>` for a live answer.

Call the app with the exact flag `show` or `list --usable` prints for it
(`--provider <slug>`, or `--connection <id>` when two connections share a
provider):

```bash
hq integrations tools --company <slug> <flag>
hq integrations call <tool> --company <slug> <flag> --args '<json>'
```

A queued write returns a queue id; finish it with `hq integrations approve
<queueId>` only after the user confirms.

Tenant boundary: the list is scoped to one company. Never use one company's
integration for another company's work, and never list or query another
company's integrations to find a substitute.

Fall back to a separate MCP, web search, or asking the user only when no
usable integration covers the app, the gateway refuses the call, or the user
asks for a different route. If an app is connected but not shared with the
caller, say so and suggest asking a company admin to share it.

## Rationale

HQ Integrations run through one governed gateway: per-company credentials,
access grants, write approvals, and an audit trail. A separate MCP or a pasted
answer bypasses all of that and often uses a different account. The
SessionStart note and the `--usable` list come from the same access decision
the gateway applies, so an app on the list is one the call will accept.
