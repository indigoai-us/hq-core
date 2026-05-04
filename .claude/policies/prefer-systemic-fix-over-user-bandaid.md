---
id: prefer-systemic-fix-over-user-bandaid
title: Prefer systemic fix over individual-user bandaid
scope: global
trigger: bug fix, hotfix, error report, "X doesn't work for <user>", version drift, default config, env mismatch, package upgrade
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
source: user-correction
public: true
---

## Rule

When a bug affects multiple users — or could affect them, because the cause is structural (wrong default, version drift, env mismatch, stale published package, mismatched pool/region/scope) — fix the system, not the individual.

The default response to a reported bug is:

1. **Diagnose the root cause** down to a specific file, version, default, or config.
2. **Patch the source** — change the default, bump the package, ship the release, run the migration.
3. **Document the upgrade path** that everyone follows (CHANGELOG, MIGRATION.md, release notes).
4. Only after the systemic fix is in flight, mention an individual unblock — and only if it is genuinely zero-cost on top of the real fix, or the affected user explicitly asks "what do I do right now while we ship?"

Banned framings (when proposed alone, without a paired systemic fix already in flight):

- "Layer A: unblock <user> today" + manual env exports.
- "Tell <user> to set HQ_FOO=… in their shell."
- "Have <user> run `bun install -g foo@latest`" — unless that upgrade itself is the systemic fix being announced.
- "Quick fix vs proper fix" — implies the proper fix can wait. It cannot.
- Adding a `--legacy` / `--allow-old` flag instead of cutting over.
- "We can come back to this" on a structural bug.

Required framings:

- "Root cause is X at <file>:<line>. Fix: change default / bump version / migrate. Releasing as vX.Y.Z. All affected users get fixed by upgrading."
- If a hot-bandaid is genuinely needed (release pipeline broken, customer ETA tight), say so explicitly and write a follow-up TODO into MIGRATION.md or a tracked issue, with a date.

## Rationale

We ship a lot. Work that gets queued behind "I'll come back to that root cause" almost never gets done — the bandaid stays, the trap stays, and the next operator hits the same diagnosis. Spending the extra hour now to patch the system is cheaper than the cumulative cost of repeating the same debug session across N users.

Individual-user unblocks also leak diagnostic surface. If only one user has the env override, only that user's session catches the surprise. The systemic fix surfaces the bug class for everyone — better signal, fewer silent failures.

This policy compounds with `hq-fix-root-cause-not-symptoms`: that one bans masking errors at the UI layer; this one bans masking them at the operator layer.

## Examples

**Correct:**
- "{your-name}'s `/designate-team` failed because hq-cli still defaulted to the dev Cognito pool in the create-hq bootstrapper. Fixing `packages/create-hq/src/auth.ts` so prod is the only default; bumping create-hq, ship release. Everyone upgrades, everyone is unblocked."
- "Service export 500s for one customer because of an integration ID drift. Removing the dead ID from the union type at the source; new release ships in next deploy; reproduces zero-out for all tenants."

**Incorrect:**
- "Layer A: have {your-name} run `export HQ_VAULT_API_URL=…`. Layer B: we'll patch the CLI when we get to it."
- "Add a try/catch around the personal sync 401 so it doesn't abort the run." (Masks the auth-path bug — see `hq-fix-root-cause-not-symptoms`.)
- "Customer can use the dashboard while we fix the API." (If the API is broken for that customer, it's broken for all of them in the same code path; ship the fix.)

## Related

- `hq-fix-root-cause-not-symptoms.md` — sibling policy: never mask errors at the UI layer.
- `hq-bugfix-requires-tests.md` — every fix needs a regression test, including systemic ones.
- HQ Core Directive #4: "Fix the root cause."
- HQ Core Directive #5: "Be persistent, not clever."
