---
id: hq-console-smoke-redirect-is-success
title: Treat 302/307 as route-existence success on auth-gated smoke tests (hq-console)
scope: global
trigger: running unauthenticated smoke tests against hq-console routes (post-deploy verification, CI smoke matrix, probe scripts)
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
applies_to: [vercel]
---

## Rule

Post-deploy smoke tests against hq-console MUST classify response codes as follows:

| Status | Meaning | Smoke verdict |
|--------|---------|---------------|
| `200` | Route exists, public | PASS |
| `302` / `307` | Route exists, middleware redirected (sign-in flow) | **PASS** (route exists + middleware fired) |
| `401` / `403` | Route exists, explicit unauthorized | PASS (route responded) |
| `404` | Route missing | **FAIL** (regression) |
| `500` / `502` / `503` | Route crashed | **FAIL** (regression) |

A 302/307 on an unauthenticated probe is the DESIRED outcome for any auth-gated route — it proves the route is deployed AND that middleware is running and correctly redirecting to sign-in. Coding the smoke matrix to treat 302/307 as failure produces false-positive "deployment is broken" alerts on every successful deploy.

### Authenticated probes belong in a separate matrix

Routes that need to verify post-auth behavior (not just existence) require a real session token and MUST be excluded from the unauthenticated smoke matrix. Mixing auth-required probes with existence probes produces a matrix that is impossible to satisfy — anonymous probes will always 302, authenticated probes need a token, and a single matrix can't carry both.

Structure the smoke suite as two separate passes:

1. **Unauthenticated existence matrix** — probe all routes, accept `200/302/307/401/403`, fail on `404/500+`.
2. **Authenticated behavior matrix** — seeded with a valid session token (stored in CI secret, refreshed via test user), probes a curated subset of routes that need to verify post-auth content.

### Concrete code shape

```bash
# GOOD — existence smoke
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/dashboard")
case "$code" in
  200|302|307|401|403) echo "PASS $URL/dashboard ($code)" ;;
  *) echo "FAIL $URL/dashboard ($code)"; exit 1 ;;
esac
```

```bash
# BAD — treats 302 as failure, will false-alarm on every deploy
[[ "$code" == "200" ]] || exit 1
```

## Rationale

hq-console uses Next.js App Router with middleware-based auth. Unauthenticated requests to any gated route (`/dashboard`, `/apps`, `/settings`, etc.) return 302/307 with a `Location: /sign-in?callbackUrl=…` header — that IS the middleware working correctly. A route that 200s anonymously would indicate a broken auth gate, not a success.

Observed during session: a smoke-test script treated only 200 as success, flagging every post-deploy run as "dashboard broken" when in fact the deploy was healthy and middleware was redirecting correctly. Separating existence checks (accept 302/307) from behavior checks (require auth token) makes the smoke matrix trustworthy again.

Scope note: authored as global scope with an hq-console-specific trigger because repos/private/hq-console has no .claude/policies/ dir and the sensitive-path gate blocks creating one. The rule generalizes naturally to any auth-gated Next.js app, but the concrete code and observed incident are hq-console-specific.
