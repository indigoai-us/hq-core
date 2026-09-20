---
id: credential-access-protocol
title: Credential Access Protocol
when: secret || credential || credentials || password || passphrase || token || apikey || api_key
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
version: 2
created: 2026-03-05
updated: 2026-09-19
source: policy-slimming
vendor_public_ok: true
tags: [deployment, data-handling, infrastructure]
public: true
---

## Rule

Before accessing any company credentials (`companies/{co}/settings/`):

1. Identify the active company from cwd, repo ownership, domain, or explicit user context.
2. Read `companies/manifest.yaml` and confirm the company owns the credential type you need.
3. Read only that company's `settings/`; never try another company's credentials as fallback.
4. Use profiles or config references, not inline secrets. For AWS, prefer `AWS_PROFILE={co}` (or the company's documented profile name) over pasted `AWS_ACCESS_KEY_ID=...` values. Unattended HQ agents still inject via `hq secrets exec` and have no local AWS-profile fallback; interactive owner-authorized named profiles follow `hq-load-company-hard-policies-on-mid-session-bind`.
5. Read company policies first; `companies/{co}/policies/` may have service-specific instructions.

Violations include trying another company's credentials first, pasting secrets inline, or guessing service ownership without the manifest.

## Rationale

Cross-company credential access leaks secrets into the wrong context and risks deploying to the wrong infrastructure. Inline secrets also persist in shell history, logs, and tool output.
