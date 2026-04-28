---
id: hq-pre-push-gate-probes-prod-not-localhost
title: Pre-push E2E gates probe production, not localhost
scope: global
trigger: when designing or editing git pre-push hooks, pre-merge checks, or any "blocking" gate that guards against regressions before code lands
enforcement: hard
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

Pre-push E2E gates MUST probe the current production deployment, not a local dev server (localhost, :3000, etc.). Local-env drift — missing secrets, port collisions, stale dev servers, unbuilt assets — causes false-positive failures that train developers into the `--no-verify` / bypass habit. Once bypass is normalized, the gate is worse than no gate at all.

The gate's charter is **"don't push onto broken prod"**, not "prove your laptop can render the page." Checking prod directly gives tighter signal:

- If prod is already broken, the gate blocks the push (correct) and surfaces the need to triage.
- If prod is healthy, the gate passes and the push proceeds.
- Neither outcome depends on the developer's local environment being correctly bootstrapped.

Pair the pre-push gate with a scheduled heartbeat (hourly or 3x/day minimum) that re-runs the same probes against prod, so post-push regressions are caught within one heartbeat interval. Pre-push + heartbeat together cap MTTD; pre-push alone leaves a blind spot between pushes.

Implementation notes:
- Use curl/fetch against the real production URL (`https://{domain}/...`) with a short `--max-time` ceiling, or a Playwright run pinned to `baseURL: https://{prod-domain}`.
- If the probe must authenticate, use a scoped production-readable token — never a dev/local token.
- If the probe legitimately needs a local build (e.g. verifying a new route that doesn't exist in prod yet), separate it into a "pre-flight" stage that the developer runs manually, and keep the automatic pre-push gate on prod-probes only.

## Rationale

Developers started routinely using `git push --no-verify` to get work out the door, which trained the reflex of bypassing *all* gates. The pre-push hook was doing the opposite of its job — it was eroding gate discipline instead of enforcing it.

The charter reframe ("don't push onto broken prod" vs. "prove local renders") is the fix. Prod is the single source of truth, requires no local bootstrapping, and produces true-positive signals. A 5-second curl against `https://{prod}/api/health` is strictly better back-pressure than a 45-second local Playwright run that flakes on missing secrets.

Scheduled heartbeats close the temporal gap between pushes: a canary that runs every 60 minutes bounds MTTD at ≤1 hour regardless of how long the release window is.

