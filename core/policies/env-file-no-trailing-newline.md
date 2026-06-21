---
id: hq-env-file-no-trailing-newline
title: .env files must not contain literal \n or trailing whitespace inside quoted KEY="..." values
scope: global
trigger: Write or Edit to any .env* file
when: secret || credential || credentials || password || passphrase || token || apikey || api_key
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
version: 1
created: 2026-04-22
updated: 2026-04-22
source: back-pressure-failure
public: true
---

## Rule

A `.env*` file MUST NOT contain a line of the form `KEY="…\n"` or `KEY="… "` (trailing space / tab / literal `\n` inside the quoted value).

Bad:

```
API_SECRET="f9fe318abc\n"
AGENT_API_KEY="…secret… "
API_SECRET="…secret…	"    # literal tab before the closing quote
```

Good (unquoted, or quoted with no trailing whitespace):

```
API_SECRET=f9fe318abc
AGENT_API_KEY="some secret"
```

If you genuinely need a trailing newline inside a secret (you do not), wrap it in an explicit `$'…\n'` shell construct at use-time — never bake it into the env file.

## Rationale

Root cause chain:

1. Someone pasted `API_SECRET="…\n"` (quoted, trailing `\n`) into Vercel/Railway/AWS Secrets Manager.
2. The server read the literal 9-char sequence `…\n` into `env.API_SECRET`.
3. Clients sent a clean `Bearer …secret…` header (HTTP strips CR/LF from header values per RFC 7230 — the `\n` could not survive transport even if anyone tried).
4. The auth middleware compares byte-exactly (`token !== env.API_SECRET`) → mismatch → 401 forever. No hint in the error.

This hook stops the bug at source: at Write/Edit time, before the file is ever created on disk or pasted into a secret store.

Related defense in depth (installed the same day):

- `repos/private/acme-platform/apps/api/src/config/env.ts` — Zod schema enforces `/^\S+$/` on `API_SECRET` so a contaminated value fails at boot, not silently at request time.
- `repos/private/acme-platform/apps/api/src/router.test.ts` — regression test pins the byte-exact compare.
- `repos/private/acme-comms/.github/workflows/smoke-crm-auth.yml` — nightly smoke test hitting `/api/agent/health` with the real `AGENT_API_KEY` from AWS SM.

## Examples

- **Block (hard, exit 2):** Write `/path/.env.prod` with content `API_SECRET="abc\n"`.
- **Allow:** Write the same file with `API_SECRET=abc` or `API_SECRET="abc"`.
- **Allow:** `ANTHROPIC_API_KEY=sk-ant-api03-...` (no quotes, no trailing whitespace).

## Related artifacts

- Hook: `.claude/hooks/env-file-no-trailing-newline.sh`
- Runbook: `companies/acme-mgmt/knowledge/runbooks/credential-sync-crm-api.md`
- Incident reference omitted.
