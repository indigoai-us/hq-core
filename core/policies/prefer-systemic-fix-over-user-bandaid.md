---
id: prefer-systemic-fix-over-user-bandaid
title: Prefer systemic fix over individual-user bandaid
when: bug || hotfix
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
source: user-correction
public: true
tags: [deployment, auth, testing, design, docs, knowledge]
---

## Rule

Bug fix default: (1) diagnose root cause to file/version/default/config, (2) patch the source (default, package, release, migration), (3) document upgrade path (CHANGELOG/MIGRATION/release notes). Individual-user bandaid is only allowed AFTER systemic fix is in flight, or if user explicitly asks "what do I do right now." Banned alone: "Layer A: unblock user today," manual env exports, "tell user to upgrade locally," "quick fix vs proper fix," `--legacy`/`--allow-old` flags, "we can come back to this." Always pair bandaid with tracked follow-up if used.

## Rationale

We ship a lot. Work that gets queued behind "I'll come back to that root cause" almost never gets done — the bandaid stays, the trap stays, and the next operator hits the same diagnosis. Spending the extra hour now to patch the system is cheaper than the cumulative cost of repeating the same debug session across N users.

Individual-user unblocks also leak diagnostic surface. If only one user has the env override, only that user's session catches the surprise. The systemic fix surfaces the bug class for everyone — better signal, fewer silent failures.

This policy compounds with `hq-fix-root-cause-not-symptoms`: that one bans masking errors at the UI layer; this one bans masking them at the operator layer.

## Examples

**Correct:**
- "{your-name}'s `/designate-team` failed because hq-cli still defaulted to the dev Cognito pool in the create-hq bootstrapper. Fixing `packages/create-hq/src/auth.ts` so prod is the only default; bumping create-hq, ship release. Everyone upgrades, everyone is unblocked."
- "Service export 500s for one customer because of an integration ID drift. Removing the dead ID from the union type at the source; new release ships in next deploy; reproduces zero-out for all tenants."

**Incorrect:**
- "Layer A: have Corey run `export HQ_VAULT_API_URL=…`. Layer B: we'll patch the CLI when we get to it."
- "Add a try/catch around the personal sync 401 so it doesn't abort the run." (Masks the auth-path bug — see `hq-fix-root-cause-not-symptoms`.)
- "Customer can use the dashboard while we fix the API." (If the API is broken for that customer, it's broken for all of them in the same code path; ship the fix.)

## Related

- `hq-fix-root-cause-not-symptoms.md` — sibling policy: never mask errors at the UI layer.
- `hq-bugfix-requires-tests.md` — every fix needs a regression test, including systemic ones.
- HQ Core Directive #4: "Fix the root cause."
- HQ Core Directive #5: "Be persistent, not clever."
