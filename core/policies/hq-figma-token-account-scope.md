---
id: hq-figma-token-account-scope
title: Figma API 404 on an existing file means the token is on the wrong account
scope: global
trigger: when a Figma REST API call (api.figma.com/v1/files/{key}) returns 404 for a file that is known to exist
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: session-learning
---

## Rule

Figma personal access tokens are account-scoped — they only grant read access to files that the token's owning account owns or has been explicitly shared with. A 404 response for a valid-looking file key does NOT mean the file id is wrong. Before assuming the URL or file key is malformed, verify which Figma account the token belongs to and whether that account has access to the file. If not, switch to the correct account's token (usually the owner's personal 1Password vault, not a work/shared vault).

## Rationale

Discovered during a cross-account Figma fetch: an account-scoped token returned 404 on a file key despite working on a different file. The fix was not re-checking the file id (which was correct) but retrieving the personal-account token from the correct 1Password vault.

Secondary lesson: never store Figma tokens in shared / git-tracked files like `.claude/settings.local.json` — store them in `companies/{co}/settings/.env.local` (gitignored, per-company scoped).
