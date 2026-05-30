---
id: hq-slack
title: Slack platform rules (consolidated)
scope: global
trigger: when working with Slack (CLI, webhooks, bots, oauth)
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
applies_to: [slack]
public: true
vendor_public_ok: true
tags: [vendor:slack, consolidated]
source: consolidation-merge
---

## Rule

Consolidated Slack rules covering permissions for posting, workspace routing, posting fallback behavior, and bot token / scope verification. All four sub-rules are independently enforced; this file replaces the prior individual policies.

## Posting permissions

### Never post to Slack channels without explicit user permission
[from `no-slack-channel-posts-without-permission.md`]

NEVER post messages to Slack channels without explicit user permission. Always ask first before sending to any channel. DMs to specific people the user requested are fine — channel broadcasts are not.

**Rationale:** User correction — posted to a team channel in a company Slack workspace without asking. Channel posts are visible to many people and should always be explicitly approved.

## Workspace routing

### `#hq` Slack channel lives on a specific company workspace
[from `hq-slack-channel-workspace.md`]

The `#hq` Slack channel lives on a single designated company workspace (defined per HQ instance). When posting HQ updates, always specify the matching `workspace:` value. Full details (channel ID, post types, discovery quirks) belong in a company-scoped policy at `companies/{co}/policies/hq-slack-channel.md`.

This global pointer ensures any session posting about HQ finds the workspace routing rule, while the canonical details live in the company-scoped policy where they belong.

## Posting fallback behavior

### Never use Claude in Chrome as a fallback when Slack posting fails
[from `hq-no-chrome-mcp-slack-fallback.md`]

Slack posting goes through `/hq-slack` (`bash personal/skills/hq-slack/hq-slack.sh post`). If the post fails or is unavailable, **NEVER fall back to Claude in Chrome** (`mcp__Claude_in_Chrome__*`) to post Slack messages.

If the post fails:
1. Note the failure in the task output/report.
2. Include the message text that would have been posted (so it can be posted manually).
3. Continue with remaining task steps — do not abort.

Browser automation is not a valid fallback for a Slack post failure.

**Rationale:** User correction on 2026-04-01 — during a scheduled infra-health task, Slack posting was unavailable; Claude attempted to use Claude in Chrome to navigate Slack and post the message, burning multiple turns navigating to the wrong workspace. Correct behavior is to note the failure inline and move on.

## Bot token & scope verification

### Slack bot token verification requires scope probes, not just `auth.test`
[from `hq-slack-verify-scopes-beyond-auth-test.md`]

NEVER trust Slack API "successful" responses at face value when a bot token has limited scopes. `auth.test` succeeding only proves the token is valid and tied to a workspace — it does NOT prove the bot has read/write access to any specific channel, or is even installed in that workspace's conversation graph.

#### The schema-echo failure mode

When a bot is post-only-scoped (e.g. has `chat:write` but not `channels:read` / `groups:read`), or when the bot is not installed in the target workspace, `conversations.list` and `chat.postMessage` can return a response that is **the literal TypeScript-interface-like schema declaration** with HTTP 200:

```
{ ok: bool, error: string, needed: string, provided: string, response_metadata: { messages: [string] } }
```

Note: the "keys" are bare identifiers (not quoted strings), and the "values" are type names (`bool`, `string`), not actual values. This is not valid JSON. A naive `response.json()` will throw with an error like `SyntaxError: Expected property name or '}' in JSON at position 2` or `property name without double quotes`.

#### Diagnostic

If a Slack API call's JSON parse fails with "property name without double quotes" or "unexpected identifier", **inspect the raw response bytes before assuming the SDK or network is broken**. The schema-echo is the signature of a scope/installation problem, not a parser or transport bug.

#### Fix

1. Grant the bot the scopes required for the operation — at minimum `channels:read` (public) and `groups:read` (private) in addition to `chat:write`.
2. Invite the bot into the target channel: `/invite @bot-name` from a workspace user with access.
3. Re-test with a raw `chat.postMessage` curl. A properly installed, properly scoped bot returns quoted JSON regardless of message delivery success.

#### Verification gate

After any Slack bot token rotation or scope change, run all three probes — don't stop at `auth.test`:

1. Token validity: `curl ... auth.test`
2. Read scope proof: `curl ... conversations.list?limit=1`
3. Write scope proof: `curl ... chat.postMessage` with a throwaway channel

All three must return quoted JSON with `"ok": true`. If any returns the bare-identifier schema echo, the bot is under-scoped or uninstalled for that operation.

**Rationale:** Initial debugging treated it as a JSON parser bug in the client library; actual root cause was that the bot token had `chat:write` only and was not invited into the target channel. The Slack API surfaces this ambiguity as a non-JSON 200 response instead of a clean error code, which is the worst possible error shape: the HTTP layer says "success" but the payload is unparseable. `auth.test` is not a proxy for "the bot can do the thing you're about to ask it to do." Always probe the exact operation with the exact scope requirements before declaring a Slack integration healthy.

Observed in the signup-safeguards heartbeat work 2026-04-22: a Slack notification poster succeeded on `auth.test` (confirming token validity) but every `chat.postMessage` returned the schema-echo pseudo-JSON.

