---
id: hq-share-session-urls-are-capabilities
enforcement: hard
public: true
scope: global
trigger: any context handling output of `hq files share` (without `--with`), `hq secrets generate-link`, or any other share-session URL minted by the HQ vault-service
when: share || secret || credential || credentials || password || passphrase || token || apikey || api_key
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
tags: [security, hq-cli, vault, capabilities, secrets]
created: 2026-05-12
provenance: feature-launch
---

## Rule

NEVER paste, log, commit, or otherwise persist a share-session URL into any durable surface — including auto-checkpoint thread files (`workspace/threads/`), journal entries, learnings, session logs, git commit messages, PR descriptions, worker handoff payloads, Slack/email/chat surfaces other than the intended human recipient, or any HQ workspace file.

When demonstrating a share-session flow in documentation, examples, or status messages, redact the token segment as `https://hq.{co}.com/share-session/<TOKEN_REDACTED>`. Print the *real* URL only in the assistant turn that produced it (so the human can use it immediately) and never echo it again in subsequent turns or persisted artifacts.

If a recipient says "the link doesn't work," mint a fresh URL via `hq files share` rather than re-sending the prior token.

## Rationale

A share-session URL is an **encrypted single-use capability**, not a coordinate. Whoever holds the URL within its TTL can redeem it to write ACLs in the issuer's name, scoped to whatever paths and max permission the issuer pinned at mint time.

The defenses are layered:

1. **15-minute default TTL** (bounded `60s..7d`) limits the window
2. **Single-use nonce** (DynamoDB `attribute_not_exists` claim) prevents replay
3. **Scope cap** — the encrypted payload pins `maxPermissionByPath` so the page cannot grant beyond what the issuer had at mint
4. **Issuer pinning** — every grant the page writes is attributed to the issuer's identity

But all four collapse if the URL leaks before TTL expiry into a surface the wrong human can reach. A token in a git commit message is a token in a public log. A token in an auto-checkpoint thread is a token any future agent session can read and redeem.

The TTL is defense in depth, not a license to log them.

## How to apply

- **In assistant turns that mint a URL**: print the full URL once, with the expiry timestamp, so the human can act on it. Do not include it in summaries, follow-up messages, or any persisted artifact in the same session.
- **When summarizing a session that involved sharing**: describe the action ("minted a share-session URL for `path/x/`, expires 03:34Z") without including the token.
- **When checkpointing or handing off**: never include share-session URLs in `workspace/threads/`, journal files, or any state file.
- **In documentation/examples**: use the `<TOKEN_REDACTED>` placeholder.
- **For analogous artifacts** — `hq secrets generate-link` URLs, signed S3 presigned URLs with mutate scope, OIDC redemption tokens — apply the same rule. Any short-lived encrypted capability that grants write access on redemption is in scope.

## Detection (future hook target)

This rule is currently enforced by agent discipline. A future PreToolUse hook on `Write`/`Edit` could pattern-match `/share-session/[A-Za-z0-9_-]{40,}` and `/secrets-input/[A-Za-z0-9_-]{40,}` to hard-block writes to `workspace/threads/`, `workspace/checkpoints/`, `companies/*/projects/*/journal/`, and any tracked HQ file.
