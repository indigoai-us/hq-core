---
name: hq-integrations
description: "Use the company's connected external apps (Linear, Notion, Jira, GitHub, Slack, Sentry, Gmail, Google Drive, Asana, ClickUp, Figma, HubSpot, Salesforce, and anything else wired through `hq integrations`) BEFORE reaching for a separate MCP, a web search, or asking the user. Trigger on any request to look up, read, create, update, or search in an external app, including natural phrasings like 'check my Linear tickets', 'open issues assigned to me', 'find the Notion doc about X', 'any new Sentry errors', 'my Jira issues', 'search Slack for', 'create a GitHub issue', 'add a task in Asana'. Check the SessionStart note 'HQ Integrations you can use in company <slug>' or run `hq integrations list --usable` first; only fall back to another path when no usable app covers it. Also covers connecting, sharing, policy, approval, and disconnect flows."
allowed-tools: Bash(hq:*)
---

# HQ Integrations

An HQ company can connect external apps — Linear, Notion, Sentry, and anything else exposing a remote MCP server. Once connected, every company identity (cloud agents and local sessions alike) reaches them through HQ's governed integration gateway: one company login, per-connection write policy, per-tool exceptions, and a full audit trail.

The whole lifecycle is available from the CLI. The console Integrations page does the same things with a UI.

## Commands

```bash
# find and add                                    (owner/admin)
hq integrations catalog [query]                   # apps you can connect (alias: search)
hq integrations inspect <app>                     # surfaces, credentials, warnings
hq integrations discover <docsUrl>                # find a server from its docs page
hq integrations connect <app>                     # connect it (alias: add)
hq integrations import [--company <slug>] [--dry-run] [--only <name>] [--json]  # import Claude Desktop connectors
hq integrations reconnect [app]                   # re-authenticate a broken app

# use                                             (any member with access)
hq integrations list                              # what's connected + policy + connection ids
hq integrations list --usable                     # apps YOU can use now + the exact flag to call each
hq integrations show [app]                        # one connection in full
hq integrations tools --provider <slug>           # the app's live tool catalog
hq integrations call <tool> --provider <slug> --args '<json>'
hq integrations pending                           # calls waiting on an owner (read-only)
hq integrations approve|reject <queueId> --provider <slug>   # OWNER ONLY

# govern and remove
hq integrations policy [app] [--set auto-allow|confirm|deny]   # owner
hq integrations grants|grant|ungrant [app] --tool <t> --to|--from <who>   # owner
hq integrations access|share|unshare [app] --with|--from <who>  # creator or admin
hq integrations audit [--provider <slug>] [--limit <n>]
hq integrations disconnect [app] [--yes]          # owner/admin (alias: remove)
```

- `--company` defaults to the caller's single active membership; pass the slug when they belong to several. Never hardcode company ids.
- `--json` on any subcommand for machine-readable output.
- Most verbs take the app positionally (`hq integrations policy linear`) or as `--provider <slug>` / `--connection acct_…`.
- If a verb reports an unknown command, the CLI is too old: `npm install -g @indigoai-us/hq-cli@latest` — the same package manager HQ's own setup uses, so the upgrade replaces the existing global binary instead of installing a second one somewhere else on `PATH`.

## Which apps can I use?

Sessions get a short SessionStart note, "HQ Integrations you can use in company <slug>", listing the apps that are connected AND shared with the caller in the active company. It comes from a per-company cache refreshed in the background (`core/scripts/usable-integrations.sh`), so it may be up to an hour old, and it is absent when the company is unknown, the caller is signed out, or the cache is cold. A session started at the HQ root gets the device's default company, labeled as such; ignore that note once the session is bound to another company.

- `bash core/scripts/usable-integrations.sh show --company <slug>` prints the cached list (refreshing it when stale) with the exact flag per app.
- `hq integrations list --usable --company <slug>` asks the server live. An app connected but missing from this list is not shared with the caller: say so and suggest asking an admin to share it.
- When two connections share a provider the list prints `--connection <id>`; use it, because `--provider` would pick the first match whoever may use it.
- Never use one company's apps for another company's work.

## Connecting an app

`connect` accepts a domain (`linear.app`), a catalog `--entry-id`, a documentation page (`--docs-url`), or a raw endpoint (`--mcp-url`). **Do not tell the user which auth mode to use — the command detects it.**

- **No auth** → installs directly.
- **API key** → `--token-stdin` (reads stdin), or let the CLI prompt. **Never put the key in the command line.** `--token <key>` exists, but an agent must not use it and must not suggest it: the literal key would land in shell history, in `ps` output, and in this session's recorded tool call, which is a long-lived credential leaked into three places at once. If the user pastes a key into chat, feed it through stdin — do not echo it back.
- **Sign-in (OAuth)** → the CLI opens a browser, catches the callback on a local port, and finishes the install itself. `--no-browser` prints the URL instead.

Detection is server-side, so a catalog row that claims "api key" but is really sign-in protected still connects on the first try.

Two OAuth outcomes to relay accurately:

- If the CLI prints **"Connected …"**, the app is live and usable now.
- If it instead prints a sign-in URL and says the console will finish it, the backend does not accept the CLI's local callback. The app is **not connected yet** — the user must open that URL, and `hq integrations list` confirms afterwards. Never report this as success.

## Importing Claude Desktop connectors

`hq integrations import` reads the Claude Desktop connector configuration for the selected company. Remote connectors become company integrations; OAuth connectors may need a follow-up `hq integrations reconnect <app>` to finish sign-in. Local (stdio) connectors are written to `companies/{co}/settings/connectors/<name>.json`, with secrets stripped, so teammates can install them locally.

## The approval gate (important)

Reading is always allowed, but **invoking an app tool routes through the connection's write policy** (default: `confirm`) because the gateway can't know which upstream tools mutate. A gated call returns *queued for approval*, not a result:

```
Queued for approval — this call can change the app, so a company owner decides first.
Approve with:
  hq integrations approve cq_… --provider linear
```

- Tell the user plainly: the request is **waiting for an owner's approval**, and give them the approve command. Do NOT retry the call — retries create duplicate queue entries.
- If the user IS an owner and asked for the action themselves, run the approve command; it executes exactly once and prints the result.
- Queue entries expire after ~7 days.
- `hq integrations pending` lists queued calls, but it is derived from the recent-activity feed, which records the queuing and not the later decision — an already-decided entry can still appear. Say so rather than presenting it as authoritative.

## Governance: two different things

Do not confuse these — they answer different questions.

- **Access** (`access` / `share` / `unshare`) — *who may use this app at all.* Managed by the connection's creator or a company admin.
- **Grants** (`grants` / `grant` / `ungrant`) — *which of those people may run one specific change-making tool without an approval round trip.* Owner-only, and layered under the write policy.

Both name a person as an email address, a uid (`prs_…`, `agt_…`, `grp_…`), or `everyone`. An ambiguous name is refused rather than guessed.

## Recipes

```bash
# "connect Linear"
hq integrations catalog linear                        # confirm the domain
hq integrations connect linear.app                    # detects sign-in, opens a browser
hq integrations tools --provider linear               # confirm it works

# "list my Linear issues"
hq integrations call list_issues --provider linear --args '{"assignee":"me","limit":10}'
# → queued → (owner) hq integrations approve <queueId> --provider linear → issues JSON

# "let the team use Notion, but keep changes gated"
hq integrations share notion --with everyone --permission write
hq integrations policy notion --set confirm
```

## Errors worth translating

- *No connected apps yet* → nothing is connected; offer `hq integrations catalog` then `hq integrations connect <app>` (needs owner/admin).
- *Multiple apps are connected* → re-run with `--provider <slug>` (the error lists them).
- *Only a company owner…* → the caller lacks the role for that governance change; name who to ask.
- *401 / session errors* → `hq auth refresh`, then retry (`hq login` if refresh fails).
- *needs sign-in* flag on `list` → the connection lost its credentials; `hq integrations reconnect <app>`.
- *Integration factory is not enabled for this company* → the connect flow is off for that tenant; the existing connections still work.
- *402 / "Starter plan limit reached" / `plan_limit_reached`* → the company's plan caps connected apps. Starter includes 1; HQ Workforce and Enterprise have no cap. Only a brand-new connection is refused (the check runs before the sign-in is exchanged, so no stray token is created). `reconnect`, `list`, `call`, `disconnect`, and sharing an existing app are not affected. Relay the upgrade link HQ returns; do not quote a price HQ did not show. Whether HQ refuses or only reminds depends on HQ's current enforcement setting, so do not predict it. Plan details: `core/knowledge/public/hq-core/plans-and-pricing.md`.

## Care

`disconnect` deletes the app's stored credentials, revokes the connection, and clears its approval exceptions — anything relying on it stops working, and reconnecting means signing in again. Confirm with the user before running it. It prompts by default and refuses non-interactively unless `--yes` is passed; do not reach for `--yes` to skip a confirmation the user has not actually given.
