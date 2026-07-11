---
id: hq-surface-hq-secrets-on-secret-discussion
title: Surface /hq-secrets when secrets are discussed
when: secret || credential || credentials || password || passphrase || token || apikey || api_key || api
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-06-20
updated: 2026-06-20
source: owner-request
public: true
---

## Rule

The moment the conversation turns to passwords, API keys, tokens, or any credential — whether the user asks ("where's the API key?", "set the DB password", "rotate the token") or the agent is about to handle one — surface the secret-safe path BEFORE any value is pasted, printed, committed, or read into chat:

- Never paste, echo, log, or commit a raw secret. Inject secrets via env at call time with **/hq-secrets** (`hq run …` or `hq secrets exec …`).
- Read a value with `hq secrets get` into env only — never into a message, a file, or shell history.
- If a secret already appeared in the conversation, treat it as compromised and recommend rotation.

Surface: **/hq-secrets**

## Rationale

The existing `secret || credential` guardrails fire only on `PreToolUse` (a Bash command's shape) and match only the literal words "secret"/"credential". A user saying "rotate the API key" or the agent about to handle a token never trips them — the derived fact set for that prompt is `api key password …`, which contains neither word. This policy reacts to the discussion itself on both the user channel (`UserPromptSubmit`) and the agent channel (`AssistantIntent`), with a broadened token set, and points at the safe skill.

## Verification

1. User prompt "rotate the API key and reset the db password" → policy injects, recommending `/hq-secrets`.
2. Agent message "I'll read the OPENAI_API_KEY token" → on the next turn the AssistantIntent channel injects the policy.
3. Unrelated prompt ("refactor the api route handler") may inject once (soft recall over precision); the per-session dedupe ledger caps it at one reminder per session.
