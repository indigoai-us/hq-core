---
id: hq-load-company-hard-policies-on-mid-session-bind
title: Load a company's hard policies when it is bound mid-session, before any infra/deploy/credential work
when: company
on: [SessionStart, PreToolUse, UserPromptSubmit]
enforcement: hard
public: true
vendor_public_ok: true
version: 2
created: 2026-05-31
updated: 2026-09-19
source: user-correction
tags: [hq-core, company-isolation, credentials, policies, session]
---

## Rule

ALWAYS, when a company is bound mid-session (e.g. `hq-session.sh set company_slug`, or working straight into a company task), load that company's hard-enforcement policies (`companies/{co}/policies/`) BEFORE any infrastructure, deploy, or credential work. SessionStart only injects company policies for the company known at session start, so a mid-session bind leaves them unloaded until you read them explicitly.

Never fall back to another company's profile or credentials. A `NoCredentials` error is not permission to guess.

Unattended HQ agents (fleet agents, Outpost jobs, scheduled/cron/background sessions, or when `HQ_UNATTENDED` or `HQ_SESSION_UNATTENDED` is set) take production AWS credentials only via `hq secrets exec`. They have no local AWS-profile fallback. Reach for the vault; do not use a machine profile.

Interactive assistants (a person is driving Claude Code, Codex, or Cursor in this session) may run company AWS/prod work with a named local AWS profile when every check below is true:

1. A verified company member in this conversation explicitly named the profile.
2. The name matches the company's manifest `aws_profile` or a profile documented in that company's settings or policies. Do not invent a name.
3. The call verifies the profile's account belongs to that company (for example `AWS_PROFILE=<name> aws sts get-caller-identity`) without reading `~/.aws/credentials`, `~/.aws/config` contents, env files, or printing secret values.
4. The command uses the profile reference (`AWS_PROFILE=...`), never pasted keys.

Prefer the vault when it authenticates as the identity this task needs. If vault-injected keys authenticate as the wrong identity, stop using them. In an interactive session, honor the owner-authorized named profile above instead of retrying the wrong vault identity. If the owner has not named an allowed profile, say the vault identity is wrong and stop.

## Rationale

The SessionStart hook can only inject policies for the company it knew at launch. Binding a different company later (or starting from the HQ root and anchoring into a company) silently skips that injection, so the company's credential-isolation and infra guardrails are absent exactly when infra/deploy/credential work begins — the highest-stakes moment. Explicitly reading `companies/{co}/policies/` on bind closes that window. Pairs with `credential-access-protocol` (cross-company credential isolation) and `natural-language-mode` (anchor before company work).

Unattended HQ agents have no operator at the keyboard and must not pick up a leftover machine profile. An interactive session with an explicit owner-named company profile is the person using their own authorized CLI, which this rule must not block.
