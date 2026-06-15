---
name: work-broadcast
description: Draft Slack broadcasts for completed or proposed HQ work.
allowed-tools: Read, Bash, Write, Edit
---

# Work Broadcast

Compose a Slack broadcast for completed or proposed work. Channel posts are doorways, not documents — keep them short and link out to detail.

**Arguments:** `[company] [context — PR URL, feature name, or description of what shipped]`

## Step 1 — Resolve company

Infer company from context (cwd, repo, manifest lookup, or explicit argument). Required for channel routing and credential lookup.

## Step 2 — Assess tier

Measure the change size to determine the broadcast tier:

| Tier | Size | Message format |
|------|------|----------------|
| **Small** | <50 lines changed, single-file | 1 line: lead emoji, bold change name, PR link |
| **Medium** | 50–300 lines, single feature/API | Up to 3 lines: one-sentence summary, 1–2 bullets max, PR link |
| **Large** | >300 lines, multi-file feature, infra rollout, project milestone | Deploy a marketing page with the deploy skill, then post 1 line: summary + page URL + PR link(s) |

When unsure which tier applies, ask the user once with a one-line summary of why you're unsure.

### Large tier — marketing page

For Large broadcasts, build and deploy a summary page before composing the Slack message:

1. Create a single-page site (HTML or Astro) summarizing the change — what shipped, why it matters, key details, screenshots if relevant
2. Deploy via the deploy skill (`.claude/skills/deploy/SKILL.md`)
3. Use the deployed URL as the primary link in the Slack message

The Slack message itself stays at 1 line — all detail lives on the page.

## Step 3 — Load channel routing

Read `companies/{co}/settings/slack/channels.yaml` to determine the target channel.

The YAML maps channel purposes to Slack channel IDs or names. Pick the channel that best matches the work type (engineering, product, general, etc.). If no channels file exists or no channel matches, ask the user which channel to post to.

## Step 4 — Compose message

All tiers follow these composition rules:

- **Lead with** `:chart_with_upwards_trend:` as the visual signature
- **Bold the change name** using Slack format (`*name*`)
- **Never include** file paths or function names
- **Never include** open questions, sub-sections, or multi-bullet lists in the Slack message itself — those belong on the marketing page or in the PR description
- **No emoji decoration** beyond the standard `:chart_with_upwards_trend:` lead

### Templates

**Small:**
```
:chart_with_upwards_trend: *Change Name* — one-sentence summary. <PR-URL>
```

**Medium:**
```
:chart_with_upwards_trend: *Change Name* — one-sentence summary.
• Key detail or impact point
• Second detail (optional)
<PR-URL>
```

**Large:**
```
:chart_with_upwards_trend: *Change Name* — one-sentence summary. <PAGE-URL> | <PR-URL(s)>
```

## Step 5 — Resolve the broadcaster's personal token

A work broadcast posts **as the person running the skill**, so the Slack user token must belong to *that* person — never a shared or company-wide token. A single shared user token makes every teammate's broadcast appear under one person's name, which is wrong and confusing.

Read `companies/{co}/settings/slack/credentials.json` for two fields:

- `personal_secret` — name of the per-person secret holding the Slack **user** token (`xoxp-…`). Defaults to `SLACK_USER_TOKEN` when the field is absent.
- `slack_workspace` — the Slack workspace the token must belong to (used only to guide onboarding).

Resolve the token from the running person's **personal** vault, never the company vault:

```bash
hq secrets --personal list   # confirms the name exists; never reveals the value
```

The `--personal` scope is keyed to the caller's own identity, so each teammate automatically resolves *their own* token with the same secret name. **Never** read this user token with `--company` — a company-scoped user token is exactly the shared-identity bug this design exists to prevent. (A company-scoped *bot* token is fine for other purposes, but work broadcasts post as the human, not the bot.)

- Personal secret **present** → continue to Step 6.
- Personal secret **missing** → run the onboarding in Step 5a first, then continue.

Never capture, echo, log, or command-substitute the token value. The agent never needs to see it — `hq secrets … exec` injects it directly into the child process at send time (Step 7).

## Step 5a — Onboarding: help the person mint and store their token

Runs only when the running person has no personal Slack user token yet. It works for **any** person and **any** workspace — nothing here is company-specific. The agent guides; the agent never sees the token value.

1. **Explain** that posting as themselves requires their own Slack **user** token (`xoxp-…`), which only they can mint, and that they will paste it into a secure prompt the agent cannot read.

2. **Acquire the token.** If `credentials.json` provides a `slack_app_oauth_url`, send the person there to authorize and copy their **User OAuth Token**. Otherwise walk them through the generic self-serve path:
   - Open https://api.slack.com/apps → **Create New App** → **From scratch**.
   - Name it (e.g. "HQ Broadcasts") and select the `{slack_workspace}` workspace.
   - **OAuth & Permissions** → **User Token Scopes** → add `chat:write`.
   - **Install to Workspace** → authorize.
   - Copy the **User OAuth Token** — it starts with `xoxp-`.

3. **Store it without exposing it** — two ways, both keep the value out of the agent's process (never echoed, never a command argument, never pasted into chat or a file). Prefer **(a)** for remote teammates or anyone not sitting at a terminal with `hq`:

   **(a) Browser self-capture link.** The agent mints a one-time secrets-input link; the person opens it and pastes their token into the web form, so the value never touches a terminal:

   ```bash
   hq secrets --personal generate-link SLACK_USER_TOKEN --expires 30m
   ```

   `generate-link` works under `--personal` — the link is a one-time write-capability to the person's *own* secret, so only they need it. **Render the URL to the person as EXACTLY ONE Markdown inline link** (label carries no token, href carries the full token), per the hard policy `hq-secure-link-render-as-markdown`:

   ```
   [Capture your Slack user token — expires <ts>](<full-url-with-token>)
   ```

   Mint it only in this (parent) turn — never echo it as bare text or inside a code fence, never delegate minting to a sub-agent, and refer to it only in redacted form on any later turn. The exposed token is single-use: if it ever leaks as bare text, mint a fresh one.

   **(b) Interactive terminal setter.** The person runs this themselves in their own terminal:

   ```bash
   hq secrets --personal set SLACK_USER_TOKEN
   ```

   Use the `personal_secret` name from `credentials.json` if it differs from `SLACK_USER_TOKEN`. Never ask the person to paste the token into the chat, a file, or a command argument — only into the browser form or this interactive prompt.

4. **Confirm** it stored: `hq secrets --personal list` shows the name (not the value). Optionally validate the token works without printing it:

   ```bash
   hq secrets --personal exec --only SLACK_USER_TOKEN -- \
     bash -c 'curl -s -H "Authorization: Bearer $SLACK_USER_TOKEN" https://slack.com/api/auth.test | jq "{ok, user, team}"'
   ```

5. **Resume** the broadcast at Step 6.

Security: token writes and any capability minting happen in this (parent) turn — never delegate them to a sub-agent. Never reveal the value with `get --reveal` in this flow.

## Step 6 — Confirm draft (MANDATORY)

Before presenting the draft, run the channel-aware humanize pass on the
summary line per `core/knowledge/public/hq-core/humanize-before-send.md`
(channel `work-broadcast`, intensity `light`). Clean only the prose a human
reads: strip AI vocabulary, em/en dashes, and promotional framing from the
one-sentence summary. Never touch the `:chart_with_upwards_trend:` signature,
the PR/page links, the channel, or the Slack `*bold*` markup.

Present the composed message to the user exactly as it will appear in Slack, including the target channel:

```
Channel: #channel-name
Message:
:chart_with_upwards_trend: *Change Name* — summary...
```

Wait for explicit approval before sending. If the user edits the draft, use their version. Never auto-send.

## Step 7 — Send

Post the message with the running person's **personal** token. Two rules make this safe and avoid the Bash-harness quoting trap (see policy `work-broadcast-jq-inline-recipe-fails-bash-harness`):

1. **Build the JSON body with `jq -n` in the PARENT shell**, using a single-quoted filter, and validate it with `printf '%s' "$PAYLOAD" | jq -e .` before sending — use `printf`, not `echo`, since some `echo` builtins re-interpret the `\n` escapes in the pretty-printed JSON and make `jq` reject a body that `curl` would post fine. Do **not** nest the `jq -n "{…}"` substitution inside the single-quoted `bash -c` — the harness mangles the brace filter and `curl` errors with `option : blank argument`.
2. **Pass the validated payload to the child as an env var.** The child `bash -c` runs only `curl`, so `$SLACK_USER_TOKEN` (injected by `hq secrets … exec`) still expands inside the child — keeping the token out of the parent shell and out of the agent's view.

```bash
PAYLOAD=$(jq -n --arg c "$CHANNEL" --arg t "$MESSAGE" '{channel:$c, text:$t, unfurl_links:true}')
printf '%s' "$PAYLOAD" | jq -e . >/dev/null && echo "payload-valid"
PAYLOAD="$PAYLOAD" hq secrets --personal exec --only SLACK_USER_TOKEN -- bash -c '
  curl -s -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_USER_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$PAYLOAD"
' | jq -r 'if .ok then "OK ts=\(.ts)" else "ERROR: \(.error)" end'
```

If `credentials.json` sets a different `personal_secret` name, substitute it for `SLACK_USER_TOKEN` in both `--only` and the `Bearer $…` reference so they stay matched.

Confirm the output is `OK ts=…`.

- On `not_authed`, `token_revoked`, `invalid_auth`, or a missing secret → the running person's token is absent or expired. Send them through Step 5a to (re)mint it. **Never** fall back to another person's token or a company-shared token — that reintroduces the shared-identity bug.
- On `channel_not_found` / `not_in_channel` → fix the channel (Step 3), not the credentials.

Report any other error to the user; do not silently retry with different credentials or channels.

## Step 8 — Report

```
✓ Posted to #channel-name
  Tier: Small | Medium | Large
  Message: [first line of message]
```
