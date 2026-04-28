---
id: hq-slack-verify-scopes-beyond-auth-test
title: Slack bot token verification requires scope probes, not just auth.test
scope: global
trigger: when configuring a new Slack bot token, adding a Slack MCP server, or diagnosing Slack API failures where auth.test succeeds but posts silently fail
enforcement: hard
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
applies_to: [slack]
---

## Rule

NEVER trust Slack API "successful" responses at face value when a bot token has limited scopes. `auth.test` succeeding only proves the token is valid and tied to a workspace — it does NOT prove the bot has read/write access to any specific channel, or is even installed in that workspace's conversation graph.

### The schema-echo failure mode

When a bot is post-only-scoped (e.g. has `chat:write` but not `channels:read` / `groups:read`), or when the bot is not installed in the target workspace, `conversations.list` and `chat.postMessage` can return a response that is **the literal TypeScript-interface-like schema declaration** with HTTP 200:

```
{ ok: bool, error: string, needed: string, provided: string, response_metadata: { messages: [string] } }
```

Note: the "keys" are bare identifiers (not quoted strings), and the "values" are type names (`bool`, `string`), not actual values. This is not valid JSON. A naive `response.json()` will throw with an error like `SyntaxError: Expected property name or '}' in JSON at position 2` or `property name without double quotes`.

### Diagnostic

If a Slack API call's JSON parse fails with "property name without double quotes" or "unexpected identifier", **inspect the raw response bytes before assuming the SDK or network is broken**. The schema-echo is the signature of a scope/installation problem, not a parser or transport bug.

```bash
curl -sS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"channel":"C123","text":"probe"}' \
  -o /tmp/slack-raw.txt
cat /tmp/slack-raw.txt   # if it starts with "{ ok: bool", you have the schema echo
```

### Fix

1. Grant the bot the scopes required for the operation — at minimum `channels:read` (public) and `groups:read` (private) in addition to `chat:write`.
2. Invite the bot into the target channel: `/invite @bot-name` from a workspace user with access.
3. Re-test with a raw `chat.postMessage` curl. A properly installed, properly scoped bot returns quoted JSON (`{"ok":true,"channel":"C123",...}`) regardless of message delivery success.

### Verification gate

After any Slack bot token rotation or scope change, run all three probes — don't stop at `auth.test`:

```bash
# 1. Token validity
curl -sS -H "Authorization: Bearer $TOK" https://slack.com/api/auth.test | jq .

# 2. Read scope proof
curl -sS -H "Authorization: Bearer $TOK" "https://slack.com/api/conversations.list?limit=1" | jq .

# 3. Write scope proof (use a throwaway channel)
curl -sS -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"channel":"C_TEST","text":"scope-probe"}' https://slack.com/api/chat.postMessage | jq .
```

All three must return quoted JSON with `"ok": true`. If any of them returns the bare-identifier schema echo, the bot is under-scoped or uninstalled for that operation.

## Rationale

Initial debugging treated it as a JSON parser bug in the client library; actual root cause was that the bot token had `chat:write` only and was not invited into the target channel. The Slack API surfaces this ambiguity as a non-JSON 200 response instead of a clean error code, which is the worst possible error shape: the HTTP layer says "success" but the payload is unparseable.

`auth.test` is not a proxy for "the bot can do the thing you're about to ask it to do." Always probe the exact operation with the exact scope requirements before declaring a Slack integration healthy.

