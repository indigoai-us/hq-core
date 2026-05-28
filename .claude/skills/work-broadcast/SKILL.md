---
name: work-broadcast
description: |
  Compose and send Slack channel broadcasts announcing completed or proposed work.
  Enforces tier discipline: small changes get 1 line, medium get 3 lines max, large get a deployed marketing page + 1 line.
  Routes to the correct channel and confirms drafts before sending.
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

## Step 5 — Load credentials

Read `companies/{co}/settings/slack/credentials.json` to get the Slack token.

**Resolution order** (try in order, use the first that works):

1. **`hq_secret` field** → fetch via `hq secrets exec --company {co} --only {hq_secret} -- bash -c 'echo "$SLACK_USER_TOKEN"'`. This is the preferred path — no biometric prompt, cached locally.
2. **`op_reference` field** → fetch via `op read "{op_reference}" --account {op_account}`. Fallback — requires 1Password biometric approval each time.

Use the **user token** (starts with `xoxp-`), not a bot token. User tokens post as the user, which is the desired behavior for work broadcasts.

## Step 6 — Confirm draft (MANDATORY)

Present the composed message to the user exactly as it will appear in Slack, including the target channel:

```
Channel: #channel-name
Message:
:chart_with_upwards_trend: *Change Name* — summary...
```

Wait for explicit approval before sending. If the user edits the draft, use their version. Never auto-send.

## Step 7 — Send

Post the message to Slack using the API. Two rules make this safe:

1. **Build the JSON body with `jq -n`** — never hand-quote it. Agent-drafted broadcast text may contain `"`, `\`, backticks, or newlines, which break a hand-built JSON string or smuggle fields.
2. **Let the token expand inside the child process** — wrap `curl` in `bash -c '...'` with *single* quotes. The parent shell would otherwise expand `$SLACK_USER_TOKEN` to empty *before* `hq secrets exec` injects it, so the `Authorization` header ships blank and Slack returns `not_authed` silently.

Preferred path (`hq_secret` configured):

```bash
CHANNEL="$CHANNEL" MESSAGE="$MESSAGE" \
  hq secrets exec --company {co} --only SLACK_USER_TOKEN -- bash -c '
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_USER_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$(jq -n --arg c "$CHANNEL" --arg t "$MESSAGE" \
                  "{channel:\$c, text:\$t, unfurl_links:true}")"
  '
```

Fallback (1Password — only when `hq_secret` is unavailable): same command, with the token sourced via `op run` so it too resolves inside the child process:

```bash
CHANNEL="$CHANNEL" MESSAGE="$MESSAGE" SLACK_USER_TOKEN="{op_reference}" \
  op run --account {op_account} -- bash -c '
    curl -s -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer $SLACK_USER_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$(jq -n --arg c "$CHANNEL" --arg t "$MESSAGE" \
                  "{channel:\$c, text:\$t, unfurl_links:true}")"
  '
```

Verify the response includes `"ok": true`. If it fails, report the error to the user — do not silently retry with different credentials or channels.

## Step 8 — Report

```
✓ Posted to #channel-name
  Tier: Small | Medium | Large
  Message: [first line of message]
```
