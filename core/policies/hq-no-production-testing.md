---
id: hq-no-production-testing
title: Never Test Against Production — Use Staging or Sandbox
when: test || webhook
on: [PreToolUse, UserPromptSubmit]
enforcement: hard
tier: 1
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **NEVER use production API endpoints, credentials, or accounts for testing, debugging, or development.** Always ask which environment to target. If no staging environment exists, confirm with the user before proceeding against production.
2. **Before any API mutation (POST, PUT, DELETE, PATCH) to an external service, verify the endpoint is not production.** Check the base URL, API key scope, and account name. Common production indicators: no "staging"/"sandbox"/"test"/"dev" in the URL, production API keys (often lack "test_" or "sk_test_" prefixes).
3. **Social media APIs are always production — there is no sandbox for most social platforms.** Never post, publish, or create content on social APIs without explicit user confirmation that the post should go live. Social posts often cannot be deleted via API after creation.
4. **For webhook testing, use a local tunnel (ngrok, cloudflare tunnel) or a test endpoint** rather than registering production webhook URLs. Test payloads should go to disposable endpoints.
5. **When debugging API field issues, use read-only operations (GET) against production and write operations (POST/PUT) against staging or test accounts only.**

## Rationale

A Post-Bridge test post was published to an actual social account and could not be deleted via API — the content was permanently live. API field debugging against a production endpoint created immutable records. In both cases, the agent treated production as a test environment because no staging guard existed. External API mutations are often irreversible, and social platforms in particular offer no undo.
