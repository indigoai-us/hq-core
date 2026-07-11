---
id: indigo-hq-fetch-access
title: Fetching access-gated *.indigo-hq.com pages
when: indigo-hq && com
on: [UserPromptSubmit, AssistantIntent, PreToolUse, PostToolUse]
enforcement: soft
public: true
version: 1
created: 2026-07-07
updated: 2026-07-07
---

## Rule

`*.indigo-hq.com` sites are access-gated: a plain curl/WebFetch 302s to the login page. If you have HQ access, fetch via the id_token -> hq-access flow below — and it only works if your identity is authorized for that app.

### Why a bare fetch fails

Every `*.indigo-hq.com` deployment sits behind a Lambda@Edge access validator that requires a valid, app-scoped `hq-access` cookie (an HS256 JWT whose audience is the subdomain). Anonymous requests are redirected (302) to the console access page at `https://hq.getindigo.ai/__access?app=<sub>&return=<url>`. `WebFetch` cannot get past this — it refuses authenticated URLs and has no way to send a header or cookie — so use `curl` with the token flow below.

### How to fetch (you must already have access)

The caller's HQ Cognito id_token lives at `~/.hq/cognito-tokens.json` under `.idToken`. It is a capability credential — never print, log, echo, or commit it; keep it only in a shell variable.

1. Redeem an app-scoped `hq-access` token from the console, presenting your id_token as a Bearer header:

   ```bash
   SUB=current-time                                  # subdomain of <sub>.indigo-hq.com
   TOK=$(jq -r .idToken ~/.hq/cognito-tokens.json)
   REDIR=$(curl -sS -X POST https://hq.getindigo.ai/api/access/redeem \
     -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
     -d "{\"app\":\"$SUB\",\"return\":\"https://$SUB.indigo-hq.com/\"}" \
     | jq -r .redirectUrl)
   ```

2. Follow the handoff URL so the edge plants the `hq-access` cookie, then fetch the page with it:

   ```bash
   curl -sS -L -c /tmp/hq-access.jar "$REDIR" >/dev/null   # sets the hq-access cookie
   curl -sS -b /tmp/hq-access.jar "https://$SUB.indigo-hq.com/"
   rm -f /tmp/hq-access.jar                                # clean up the cookie jar
   ```

### Access is enforced, never bypassed

`/api/access/redeem` hands back a token ONLY after hq-pro confirms your identity is a member of — or an explicitly selected user/group for — the app's company access policy. A caller without access gets `signin-required` (401) or `access-denied` (403) and no token. This flow is the programmatic equivalent of signing in; it does not weaken the gate.

### Caveats

- **Client-rendered apps**: some deployments (e.g. `current-time`) render their content with JavaScript, so `curl` returns only an empty HTML shell. To read the rendered output, drive the page in a headless browser (Agent browser) carrying the same `hq-access` cookie.
- **Password-protected apps**: deployments gated by a shared password (not company membership) use `/api/access/verify` with the password instead of the id_token — the Bearer flow above does not apply to them.
- **Token expiry**: the id_token is short-lived. If `redeem` returns `signin-required` against a token you believe is valid, refresh it with `/hq-login` and retry.

## Rationale

A `WebFetch` against an `*.indigo-hq.com` URL silently dead-ends at the access page, which reads as "the site is down" when it is actually just gated. Surfacing the token-based fetch — and the fact that it still respects access control — turns a confusing redirect into a single-command fetch for anyone who is entitled to the page, without ever tempting a bypass.
