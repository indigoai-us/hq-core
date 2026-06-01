---
id: work-broadcast-jq-inline-recipe-fails-bash-harness
title: work-broadcast inline jq recipe fails in Bash harness — use python3 body fallback
scope: global
trigger: when building a Slack message body for the work-broadcast skill (or any chat.postMessage call) via inline jq in the Bash tool
enforcement: soft
public: true
version: 3
created: 2026-05-30
updated: 2026-05-31
source: session-learning
---

## Rule

WORKAROUND: The work-broadcast skill's inline jq recipe fails when the `jq -n` filter is left unquoted or is nested inside the single-quoted `bash -c '...'` that runs curl. In both cases the shell mangles the `{...}` filter (brace-expansion word-splitting, or the inner double-quotes collapsing) before jq sees it, so jq receives the filter split into separate fragments (`channel:$c`, `text:$t`, `unfurl_links:true`) → three compile errors, and curl then errors with `option : blank argument`.

**Primary fix (confirmed 2026-05-31 posting to #hq-dev):** build the payload with `jq -n` in the PARENT shell using a SINGLE-quoted filter, validate it, then pass it to the child as an env var — the child `bash -c` does ONLY the curl (the token still expands inside the child):

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

**Identity:** use `--personal` (not `--company`). A work broadcast posts as the person running it, so the user token must come from the running person's own vault — a company-scoped user token would post under whoever populated it. See `work-broadcast/SKILL.md` Step 5.

**Alternate fallback:** build the body via `python3 -c 'import json; open("/tmp/slack-body.json","w").write(json.dumps({...}))'` and `curl --data-binary @/tmp/slack-body.json` — sidesteps shell quoting entirely.

## Rationale

The Bash tool shell mangles the jq object filter before jq runs — either by treating an unquoted `{...}` as a brace-expansion candidate and splitting on commas, or by collapsing the inner double-quotes when the `$(jq -n ... "{...}")` substitution is nested inside a single-quoted `bash -c`. Either way jq is handed malformed program fragments instead of one object filter. Building `PAYLOAD` in the parent shell with a single-quoted filter keeps quoting intact and lets you validate with `jq -e .` before sending; passing it to the child as an env var keeps the `$SLACK_USER_TOKEN` expansion inside the secrets-injected child process. The python3 temp-file approach is an equivalent fallback that avoids shell quoting altogether.

Validate the payload with `printf '%s' "$PAYLOAD" | jq -e .`, not `echo` — when the message spans multiple lines the pretty-printed `PAYLOAD` carries `\n` escapes that some `echo` builtins re-interpret into raw control characters, so `jq -e` rejects a body that `curl --data "$PAYLOAD"` posts successfully (confirmed 2026-05-31: the `echo` check errored with "Invalid string: control characters … must be escaped" while Slack still returned `ok:true`).
