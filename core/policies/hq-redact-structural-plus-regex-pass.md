---
id: hq-redact-structural-plus-regex-pass
title: Pair structural JSON-field redaction with a regex pass on string values
scope: global
trigger: When redacting credentials/secrets from JSON artifacts (e.g. `.mcp.json`, settings files, config exports)
when: secret || credential
on: [PreToolUse]
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

ALWAYS: Structural JSON-field redaction (walking named keys like `apiKey`, `token`, `secret`) MUST be followed by a regex pass on the resulting string values.

```
Structural pass:   scrub {apiKey, token, secret, password, ...} → "[REDACTED]"
Regex pass:        scrub string values matching /sk-[a-zA-Z0-9]{20,}/, /ghp_.../, /xox[bps]-.../, etc.
```

Credential values living under shouty env keys (`API_KEY`, `TOKEN`, `DATABASE_URL` inside `mcpServers.*.env` blocks) leak through key-based redaction because the key names don't match the known-field list.

## Rationale

Discovered while building `.claude/skills/import-claude/redact.sh`. Named-key redaction is fast and precise but has blind spots wherever config schemas use arbitrary key names for credential envelopes — notably MCP server env blocks, GitHub Actions step envs, and Docker Compose `environment:` sections. A regex pass catches credentials by shape (known secret prefixes, high-entropy tokens) rather than by field name, closing the blind spot without needing an exhaustive key list.
