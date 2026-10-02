---
name: deploy
description: Deploy or share generated HQ artifacts through hq-deploy.
allowed-tools: Read, Grep, Bash(tar:*), Bash(curl:*), Bash(npm:*), Bash(npx:*), Bash(bun:*), Bash(pnpm:*), Bash(yarn:*), Bash(docker:*), Bash(git:*), Bash(ls:*), Bash(cat:*), Bash(aws:*), Bash(jq:*), Bash(op:*), Bash(source:*), Bash(pbcopy:*), Bash(chmod:*), Bash(node:*), Bash(lsof:*), Bash(mkdir:*), Bash(echo:*), Bash(wait:*), Bash(disown:*), Bash(test:*), Bash(touch:*), Bash(rm:*), Bash(paste:*), Bash(.claude/skills/deploy/scripts/identity-resolve.sh:*), Bash(.claude/skills/deploy/scripts/sensitivity-check.sh:*), Bash(.claude/skills/deploy/scripts/guardrails-check.sh:*), Bash(.claude/skills/deploy/scripts/deploy-api-request.sh:*), Bash(.claude/skills/deploy/scripts/og-inject.sh:*), Bash(.claude/skills/deploy/scripts/password-helper.sh:*), Bash(.claude/skills/deploy/scripts/route-host.sh:*), Edit, Write
---

# Deploy Engine

Skill for deploying web artifacts to hq-deploy infrastructure. Invoked directly via `/deploy`, or auto-triggered by `auto-deploy-on-create` (silent post-build) and `hq-deploy-reinforcement` (intent-to-share, deliverable PRDs) policies. The two paths share this same engine.

**Guiding principle:** quick casual handoff — preview, upload, link. Sensitive artifacts get the lowest-friction appropriate gate: password, Cognito company access, or an email allowlist when the user names recipients.

**Reuse before creating.** When a static artifact belongs on a site that is already live, add it as a route on that app instead of creating a new one. When it is unclear whether it belongs there, ask the user. See "Reuse an existing deploy (route mode)" in C.2.

## Access modes (reference)

Every deployed app has exactly one edge access mode. New policy-aware deploys prefer the first-class access-policy endpoint for Cognito gates; the legacy access-mode endpoint remains the right path for password and email/domain allowlists.

| Mode | When to pick it | What it does |
|---|---|---|
| `public` | Default. Casual handoff, anyone with the link. | No gate. App serves immediately. |
| `password` | Sensitive content, casual share over Slack/email, recipients unknown ahead of time. | App owner sets a password (Argon2id-hashed). Visitors land on `hq.{your-domain}.com/__access`, enter the password, get a 24h `hq-access` JWT cookie scoped to `.{your-domain}.com`. |
| `company` | Internal/company-only share; user says "restricted to org", "internal-only", "company-only"; or config prefers org-restricted deploys. | Visitors sign in with HQ Cognito on `hq.{your-domain}.com/__access`; the HQ access service checks active membership in the app's company before minting a policy-versioned `hq-access` cookie. |
| `selected` | Specific HQ people/groups when the caller has resolvable HQ directory IDs. | Same Cognito flow as `company`, but only selected user/group IDs in the policy are accepted. Use only when IDs are known from the HQ directory, not from free-form names. |
| `private` | Legacy sensitive sharing for **known recipients by email/domain** when Cognito company membership is not the desired gate. | Visitors must be signed in to hq-auth (`auth.{your-domain}.com`) AND their email must be on the app's allowlist. Lands on `hq.{your-domain}.com/__private`, which checks the session + allowlist and mints the same `hq-access` JWT. |

### Embedding a deployed app in another site

Public apps can be embedded in an iframe on another site, such as Notion. Apps with password, company, selected, or private access cannot be embedded. The browser does not send the `hq-access` cookie inside a third-party frame because it uses `SameSite=Lax`, so the frame shows the access page or fails. To share a gated app, send the link instead.

Pick `company` when the user asks for org/company/internal restriction. Pick `private` over `password` when the user gives concrete email/domain recipients (`"share with [EMAIL] and the @example.com team"`) and did not ask for company-wide Cognito access. Pick `password` when sensitivity is detected but recipients are unspecified and config does not prefer org restriction.

**Canonical mutation endpoint** for switching between modes:
- `POST /api/apps/:id/access-mode {mode, password?}` — atomic; clears the fields that don't belong to the chosen mode; **wipes EmailGrant rows when leaving `private`** so orphans can't silently re-activate on a future flip back.
- `PUT /api/apps/:id/access-policy {mode, companyUid, users?, groups?, password?}` — first-class policy endpoint for `company`, `selected`, and policy-versioned `password`. Use this for Cognito org gates.

**Legacy path gotcha:** `PATCH /api/apps/:id {passwordProtected, password}` is rejected with `409 ACCESS_MODE_CONFLICT` when the app is currently in `private` mode. Always use `/access-mode` to change modes; reserve PATCH for in-mode password rotation.

**Email allowlist CRUD** (only relevant in `private` mode):
- `GET    /api/apps/:id/allowed-emails`
- `POST   /api/apps/:id/allowed-emails  {email}` — accepts an exact address (`[EMAIL]`) or a `@domain.tld` pattern; idempotent; lowercased server-side.
- `DELETE /api/apps/:id/allowed-emails/{patternKey}` — `patternKey` URL-encoded.

**Comments (opt-in) — `--comments on|off`:** orthogonal to access mode. Turn it on when the user wants identity-verified commenting on the deploy: viewers drop a point pin, drag a box/region, or highlight a passage of text and comment on it, each tagged to who they are; the owner reads/resolves/deletes from a side pane, and a "Sign in to comment" Cognito prompt turns viewers into HQ users. It sets the per-app `commentsEnabled` flag, which the deploy pipeline reads to inject the comment widget at deploy time. Access controls still hold: on a gated deploy the thread is only readable/writable by viewers who pass the gate (the recorded owner can also read the in-page list with their own verified HQ sign-in), and access revocation applies to the comment surface too.
- Detect intent from the invocation: `--comments`/`--comments on` (or "with comments", "turn comments on") → on; `--comments off` (or "turn comments off") → off; otherwise leave unset.
- Wire it in Phase C once `appId` is known and **before** `POST /api/deploys/:id/complete` (see C.2.6): `PATCH /api/apps/:id {commentsEnabled: true|false}`. The widget is injected during `…/complete`, which reads the flag at that moment.
- **Off by default.** Without the flag `commentsEnabled` stays unset and the injector is a strict no-op — the served HTML is byte-identical to a pre-feature deploy (no widget markup, no script, no network calls). The flag takes effect on the *next* deploy's `…/complete`.
- **Static deploys only.** Injection runs in the static `…/complete` path. `app` (`api/*`) deploys and Next.js/Hono live deploys do not get the widget. The widget resolves the app from the page's `{sub}.indigo-hq.com` origin, so comments work on the platform URL, not on a custom domain.
- **Turning comments off** (`commentsEnabled: false`) keeps every stored comment. The viewer-facing routes answer `403 COMMENTS_DISABLED`; a widget still present in already-served HTML removes itself on load, and a viewer's post is refused with "Comments are turned off for this page". The owner routes below keep working. Turning comments back on shows the same thread again.

**Reading and answering comments as the owner (no browser needed).** When the user asks to see, answer, or resolve comments on a deploy, use the owner routes. They take the same `Authorization: Bearer $JWT` + `X-Org-Slug` headers as every other Phase C call (send them through `deploy-api-request.sh`), work on gated deploys, and work whether `commentsEnabled` is on or off. Only the app owner or an org admin can call them (others get `403 FORBIDDEN`).
- `GET   /api/apps/:id/manage/comments` — every comment on the app. Returns `{commentsEnabled, comments: [{id, body, author{email,name}, anchor, status, deployId, createdAt}]}`.
- `POST  /api/apps/:id/manage/comments {body, anchor, deployId?}` — add a comment as the caller. The author is always the verified caller; the body cannot set it.
- `PATCH /api/apps/:id/manage/comments/:commentId {status: "resolved"|"open"}` — resolve or reopen. Any other `status` → `400 COMMENT_STATUS_INVALID`; unknown id → `404 COMMENT_NOT_FOUND`.
- There is no owner-route delete. GET takes no filters; filter `status == "open"` client-side. Rate limits are per IP: 60 reads/min, 10 writes/min (`429 RATE_LIMITED` with `Retry-After`).

**POST body rules.** `body` must be a non-empty string (else `400 COMMENT_BODY_REQUIRED`). `anchor` is required and must be an object with a valid `mode` (else `400 COMMENT_ANCHOR_INVALID`). Anchor shapes:

| `mode` | Fields | Use |
|---|---|---|
| `unanchored` | none | General reply or note not tied to a spot. Default for agent replies. |
| `anchored` | `cssPath`, `xRatio`, `yRatio` (0..1), optional `viewportWidth`, `scrollY` | Point pin. |
| `region` | as `anchored`, plus `wRatio`, `hRatio` | Dragged box. |
| `text` | `quote` (required, non-empty, ≤3000 UTF-16 units), `prefix`/`suffix` (optional, ≤64 each), optional `cssPath` of the starting block | Highlighted passage. Over-length or blank `quote` → `COMMENT_ANCHOR_INVALID`. |

To place a reply next to the comment it answers, copy that comment's `anchor` object verbatim.

**Replies are flat.** A comment has no parent/thread id; the API ignores any `parentId`. Quote or name what you are answering in `body` (for example `Re: "tighten the headline" — done in the latest deploy.`).

**Author naming.** The server sets the author; the body cannot. Name resolution for owner-route posts: the name this user already has on the app's comments (from a browser sign-in), else their email, else `App owner` / `Org admin`. Viewer comments carry the verified Cognito name and email; there are no anonymous comments.

**Stale text highlights.** On load the widget re-finds each `text` quote using its stored `prefix`/`suffix`. If the words were edited out, or the only matches have no agreeing context, the comment is not moved to another passage; it is listed in the side pane with a "Text changed" tag ("Hidden on page" when found but not visible). Point and box comments whose element is gone show a "context changed" state. Treat these as likely addressed, but confirm before resolving.

**Review loop (on redeploy, or "what did reviewers say").**
1. `GET /api/apps/:id/manage/comments`; keep `status == "open"`.
2. Group by anchor: `text` by `quote`, pins/boxes by `cssPath`, `unanchored` separately. Note `deployId` so you know which version each comment was left on.
3. Summarize for the user and make the fixes in the source.
4. Redeploy through this skill.
5. For each addressed comment, optionally `POST` a short `unanchored` (or same-anchor) reply that quotes it, then `PATCH … {status: "resolved"}`. Leave anything not addressed open and say which ones.

Do **not** use `/api/apps/:id/comments` for this. That route serves the in-page widget only: it needs the deploy's browser `Origin` plus the `hq-access` cookie from signing in on the page, and returns `403 COMMENT_ORIGIN_REQUIRED` / `COMMENT_ACCESS_REQUIRED` to a CLI or agent. A 403 from it does not mean the owner can't read comments. The `hq-deploy` CLI has no comments command, so these HTTP routes are the only non-browser path. If the local `repos/private/hq-deploy` checkout lacks `src/api/routes/comments-manage.ts`, it is stale; read `origin/main` before concluding a capability doesn't exist.

**Plan limits, domains, visit stats, receipts (reference).**
- **Deploy counts never block.** hq-deploy observes plan and personal caps but does not refuse a deploy for them (no `402`/`503` on the deploy path). For personal scope, hq-deploy logs a soft 500-deploy cap (hq-pro's plan table lists 50 lifetime deploys for an unpaid personal scope); neither blocks. Starter companies have a 500-deploy limit in hq-pro; when a Starter company is at ≥80% or over, responses from `POST /api/apps/:id/deploy` carry a `planLimits` object (`planName`, `upgradeUrl`, `deployments{used,limit,over,pctUsed}`). The presigned `/api/deploys` path used in C.2 does not attach it. If you see it, tell the user once with the upgrade link. Numbers come from hq-pro; see `core/knowledge/public/hq-core/plans-and-pricing.md`.
- **Custom domains.** `GET|POST /api/apps/:id/domains {domain, environment?}`, `PATCH|DELETE /api/apps/:id/domains/:domain`, `POST /api/apps/:id/domains/:domain/refresh`; the `hq-deploy` CLI wraps these as `hq-deploy domains list|add|edit|refresh|remove` (run in a directory linked with `hq-deploy link`). Only the `production` environment can have a custom domain (`409 ENVIRONMENT_NOT_SERVED` otherwise). Adding one requires the company's staff-assigned plan field in HQ (`metadata.plan`) to be `pro` or `enterprise`; a self-serve HQ Workforce subscription alone may not satisfy this check. Otherwise `403 DOMAIN_NOT_ENTITLED`. A company-wide base domain (`/api/orgs/:orgSlug/base-domain`) is Enterprise-only. Comments do not work on a custom domain (see above).
- **Visit stats.** `GET /api/apps` items carry `lastVisitAt` (ISO or `null`) and `views30d` (`null` = analytics unavailable, not zero). `GET /api/apps/:id/analytics` returns a trailing 30-day daily `series` and `totals`. Counts come from a nightly CloudFront log rollup, so today's views appear the next day; `lastVisitAt` is written at the edge at most every 5 minutes per app and ignores bots. The console's Deployments page shows the same numbers.
- **Completion receipts.** When a deploy goes live, hq-deploy sends a `deployment_completed` receipt and a `deploy-succeeded` outcome event to hq-pro on the deployer's behalf (best effort; a failure never fails the deploy). No action is needed from this skill.

---

## Architecture: Three Phases, Inline Parallel Scripts

The engine is **three phases**, structured by data-dependency. Independent work runs in parallel via bash background jobs; I/O-heavy decisions live in inline scripts (no Task sub-agents — they cost 3–5s of spawn overhead each and the JWT/verdicts have to flow back to main anyway).

| Phase | What runs | Parallelism |
|-------|-----------|-------------|
| **Step 1** | Preferences + exclusions (gate) | inline, sequential |
| **Phase A** | Framework detect + **design pass** (A.1.5, generated static only) → Build (inline) ‖ Identity (script) ‖ Sensitivity (script) | detect + design sync, then 3-way parallel via `&` + `wait` |
| **Phase B** | Localhost preview (inline-bg) ‖ Guardrails (script) | 2-way parallel via `&` + `wait` |
| **Phase C** | Password gen → reuse check (route mode) → upload → wire password → announce → present link | sequential, hard-gated |

**Hard ordering constraints (preserved from `core/policies/hq-deploy-reinforcement.md`):**

- Identity (Phase A) MUST complete before Upload (Phase C)
- Guardrails (Phase B) MUST gate Upload (Phase C)
- Upload (Phase C) returns `appId` which MUST exist before password persist + announce
- The route-mode reuse check (C.2) MUST decide the target app before any app is created, and a merged route-mode tree MUST pass guardrails again before upload
- Localhost preview (Phase B) is NEVER gated by identity — always runs
- **Design pass (A.1.5) MUST complete before Build/Guardrails package the artifact** — it restyles the generated static source in place, so it runs synchronously right after framework detection and before the Phase A fan-out

**Inline helper scripts** (each is self-contained, returns one JSON line on stdout):

| Script | Purpose | Returns |
|--------|---------|---------|
| `.claude/skills/deploy/scripts/identity-resolve.sh` | Resolves Cognito JWT (cache → refresh → login); `--force-refresh` bypasses a rejected cache token; jq preferred, node via `hook-lib.sh` | `{"status":"ok"\|"login_required"\|"missing_dependency",...}` |
| `.claude/skills/deploy/scripts/sensitivity-check.sh <path> [user_msg]` | Classifies artifact sensitivity (filename-list grep, no content surfaces) | `{"sensitive":bool,"trigger":string\|null}` |
| `.claude/skills/deploy/scripts/guardrails-check.sh <output_dir>` | Caps + builds tarball | `{"pass":bool,"reason":string\|null,"tarball_path":string,...}` |
| `.claude/skills/deploy/scripts/deploy-api-request.sh` | Makes a checked Phase C API/S3 request | validated body on stdout; safe failure diagnostic on stderr |
| `.claude/skills/deploy/scripts/og-inject.sh <output_dir> [base_url] [app_name]` | Injects OG/Twitter preview tags; generates a 1200x630 card image when none exists | `{"injected":int,"image":string,"changed":bool}` |
| `.claude/skills/deploy/scripts/password-helper.sh` | `gen` / `announce` / `persist` / `lookup` | password text, or persisted entry |
| `.claude/skills/deploy/scripts/route-host.sh` | `hosts` / `merge` / `record`: local snapshots of live static sites, so a new artifact can be added as a route on an existing app | one JSON line |

All scripts are deterministic, run in 0.3–0.5s, and never echo JWTs / artifact contents / matched PII.

---

## Step 1 — Preferences and Exclusions

Auto-deploy is opt-out. Honor user preference and rule out projects that shouldn't deploy.

### 1a. Read user preference

`$PREF_FILE` is `~/.hq/deploy-prefs.json` — a file owned exclusively by `/deploy`. The legacy `~/.hq/config.json` is read-only here (backwards compat) and never written by this skill: that path is owned by the HQ Desktop App's strict `HqConfig` serde struct, and overlapping writers caused the HQ Desktop App to bail on every sync (see `feedback_3ab4f113-2e7c-4e4e-a171-771b47a2b5fd`).

```bash
PREF_FILE="$HOME/.hq/deploy-prefs.json"
LEGACY_PREF_FILE="$HOME/.hq/config.json"

# One-time migration: lift deploy-owned fields out of the legacy file so
# hq-sync can resume parsing ~/.hq/config.json as HqConfig. Read-only on the
# legacy path — never write back to it.
if [ ! -f "$PREF_FILE" ] && [ -f "$LEGACY_PREF_FILE" ]; then
  LEGACY_DEFAULT=$(jq -r '.defaultOrg // empty' "$LEGACY_PREF_FILE" 2>/dev/null)
  LEGACY_PREF=$(jq -r '.deploy.preference // empty' "$LEGACY_PREF_FILE" 2>/dev/null)
  if [ -n "$LEGACY_DEFAULT" ] || [ -n "$LEGACY_PREF" ]; then
    mkdir -p "$HOME/.hq"
    jq -n --arg slug "$LEGACY_DEFAULT" --arg pref "$LEGACY_PREF" \
      '{} | (if $slug != "" then .defaultOrg = $slug else . end)
          | (if $pref  != "" then .deploy.preference = $pref else . end)' \
      > "$PREF_FILE"
  fi
fi

if [ -f "$PREF_FILE" ]; then
  DEPLOY_PREF=$(jq -r '.deploy.preference // "hq-deploy"' "$PREF_FILE" 2>/dev/null)
  DEPLOY_ACCESS_SENSITIVE_DEFAULT=$(jq -r '.deploy.access.sensitiveDefault // "password"' "$PREF_FILE" 2>/dev/null)
  DEPLOY_ACCESS_INTERNAL_DEFAULT=$(jq -r '.deploy.access.internalDefault // "company"' "$PREF_FILE" 2>/dev/null)
  DEPLOY_ORG_RESTRICTED_BY_DEFAULT=$(jq -r '.deploy.access.orgRestrictedByDefault // false' "$PREF_FILE" 2>/dev/null)
else
  DEPLOY_PREF="hq-deploy"
  DEPLOY_ACCESS_SENSITIVE_DEFAULT="password"
  DEPLOY_ACCESS_INTERNAL_DEFAULT="company"
  DEPLOY_ORG_RESTRICTED_BY_DEFAULT="false"
fi
```

**Valid values:** `hq-deploy` (default), `vercel`, `netlify`, `custom`, `none`.

**Access preference values:**
- `.deploy.access.sensitiveDefault`: `password` (default) or `company`
- `.deploy.access.internalDefault`: `company` (default)
- `.deploy.access.orgRestrictedByDefault`: `true` makes sensitive deploys company-restricted unless the user asks for public/password/email-recipient sharing

### 1b. Per-project override

```bash
if [ -f "prd.json" ]; then
  PRD_DEPLOY=$(jq -r '.metadata.deploy // "unset"' prd.json 2>/dev/null)
  if [ "$PRD_DEPLOY" = "false" ]; then DEPLOY_PREF="none"; fi
fi
```

### 1c. Honor the preference

- `hq-deploy` → continue
- `vercel`, `netlify`, `custom` → silently stop (user has their own pipeline)
- `none` → silently stop, skip even localhost preview

### 1d. Exclusions

- **Vercel-managed**: `manifest.yaml` `vercel_projects[]` lists this project → skip
- **Backend service**: Dockerfile / serverless.yml / sst.config.* at root → skip (Phase B guardrails will also catch these)
- **Build is dirty**: a recent test/typecheck failed → skip

### 1e. Resolve Context

| Thing | How |
|-------|-----|
| Deploy context | Company context via `$ORG_SLUG`, or explicit personal context when the signed-in user has no companies |
| API endpoint | `$HQ_DEPLOY_API` → manifest `services.hq-deploy.endpoint` → `https://api.indigo-hq.com` (always-on public default) — via `resolve-deploy-api.sh` |
| App name | `package.json` `name` → current directory name, slug-cased |

Resolve the deploy API base **concretely, up front** — this must produce a non-empty
`$API` or Phase C stalls on an empty upload host. The resolver applies the chain above
and always falls back to the public default, so a fresh install (no manifest, no
`$HQ_DEPLOY_API`) still deploys:

```bash
API="$(.claude/skills/deploy/scripts/resolve-deploy-api.sh)"
# $API is now guaranteed non-empty (public default https://api.indigo-hq.com when
# nothing else is configured). Every Phase C hq-deploy call uses "$API/api/...".
```

#### Org resolution chain

The org the deploy targets MUST be resolved — never fall back to a hardcoded slug. Walk these priorities in order until one produces `$ORG_SLUG`. Priorities 1–4 don't need a JWT and run here; Priority 5 needs `$JWT` and runs in **A.5** after the Phase A barrier. When the signed-in user has no company at all, A.5 sets `PERSONAL_SCOPE=true` and the deploy ships to their personal scope (Priority 5b). Priority 6 is the state-aware CTA path, reached only when the org is genuinely ambiguous (multi-org) or vault is unreachable.

| Priority | Source | Notes |
|---|---|---|
| 1 | `--org=<slug>` arg or `HQ_ORG` env | Explicit one-off override |
| 2 | Agent-supplied via session context | Agent sets `HQ_ORG` before invoking when conversation clearly implies a company |
| 3 | cwd → `companies/{slug}/…` segment | Running inside HQ tree |
| 4 | `~/.hq/deploy-prefs.json` `defaultOrg` field | Persisted choice (legacy `~/.hq/config.json` read as fallback for backwards-compat) |
| 5 | Single active vault membership | Auto-resolved + auto-written to `defaultOrg` (runs in A.5) |
| 5b | No active membership → personal scope | Signed in but no company: deploy to the auto-provisioned `personal-<sub>` scope (`PERSONAL_SCOPE=true`, runs in A.5). Upload proceeds with `X-HQ-Deploy-Scope: personal` |
| 6 | State-aware CTA (multi-org / unreachable — see C.5) | Only when the org is genuinely ambiguous or vault is down; preview already shown; skip upload |

Pre-JWT block (Priorities 1–4):

```bash
ORG_SLUG="${HQ_ORG:-}"

# Priority 3: cwd → companies/{slug}/...
if [ -z "$ORG_SLUG" ]; then
  PWD_REAL="$(pwd -P)"
  HQ_ROOT=""
  D="$PWD_REAL"
  while [ "$D" != "/" ] && [ -n "$D" ]; do
    if [ -f "$D/companies/manifest.yaml" ]; then HQ_ROOT="$D"; break; fi
    D="$(dirname "$D")"
  done
  if [ -n "$HQ_ROOT" ]; then
    REL="${PWD_REAL#$HQ_ROOT/companies/}"
    if [ "$REL" != "$PWD_REAL" ]; then
      CAND="${REL%%/*}"
      # Reject non-company paths like _template or stray files
      if [ -d "$HQ_ROOT/companies/$CAND" ] && [[ "$CAND" != _* ]]; then
        ORG_SLUG="$CAND"
      fi
    fi
  fi
fi

# Priority 4: ~/.hq/deploy-prefs.json defaultOrg (legacy ~/.hq/config.json read-only fallback)
if [ -z "$ORG_SLUG" ] && [ -f "$HOME/.hq/deploy-prefs.json" ]; then
  ORG_SLUG=$(jq -r '.defaultOrg // empty' "$HOME/.hq/deploy-prefs.json" 2>/dev/null)
fi
if [ -z "$ORG_SLUG" ] && [ -f "$HOME/.hq/config.json" ]; then
  ORG_SLUG=$(jq -r '.defaultOrg // empty' "$HOME/.hq/config.json" 2>/dev/null)
fi
```

Priorities 5 and 6 run in **A.5** once `$JWT` is in scope.

### 1f. Writing a preference on request

When the user says "I use Vercel", "don't deploy my stuff":

```bash
mkdir -p "$HOME/.hq"
if [ -f "$PREF_FILE" ]; then
  jq '.deploy.preference = "vercel"' "$PREF_FILE" > "$PREF_FILE.tmp" && mv "$PREF_FILE.tmp" "$PREF_FILE"
else
  echo '{"deploy":{"preference":"vercel"}}' > "$PREF_FILE"
fi
```

Then say once:
> Got it — I won't offer auto-deploy. You can change this in `~/.hq/deploy-prefs.json`.

---

## Phase A — Fan-out (3-way parallel)

After Step 1 resolves preferences, kick three workstreams off **in the same shell command**: Build inline, Identity script, Sensitivity script. Phase A completes when all three have returned.

### A.1 — Framework detection (sync, fast)

```bash
# Skip rebuild if dist/index.html newer than newest source file
if [ -f "dist/index.html" ] || [ -f "out/index.html" ] || [ -f "build/client/index.html" ]; then
  SKIP_BUILD=1
fi

# Detect framework + output dir + deploy type
if   [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ]; then
  FRAMEWORK="nextjs"; OUTPUT_DIR="out"; DEPLOY_TYPE="static"
elif [ -f "remix.config.js" ] || [ -f "remix.config.ts" ]; then
  FRAMEWORK="remix"; OUTPUT_DIR="build/client"; DEPLOY_TYPE="ssr"
elif [ -f "astro.config.js" ] || [ -f "astro.config.mjs" ] || [ -f "astro.config.ts" ]; then
  FRAMEWORK="astro"; OUTPUT_DIR="dist"; DEPLOY_TYPE="static"
elif [ -f "vite.config.js" ] || [ -f "vite.config.ts" ] || [ -f "vite.config.mjs" ]; then
  FRAMEWORK="vite"; OUTPUT_DIR="dist"; DEPLOY_TYPE="static"
else
  FRAMEWORK="static"; DEPLOY_TYPE="static"
  for d in dist build out public .; do [ -f "$d/index.html" ] && OUTPUT_DIR="$d" && break; done
fi

# Backend API routes → upgrade to the `app` deploy type (per-app-function path).
# Orthogonal to the framework above: a root `api/` dir with >=1 handler file
# (api/**/*.{ts,js}) means the app ships backend routes, so it deploys as a
# static frontend PLUS an `api/*` per-app Lambda with keyless secret bindings —
# NOT Docker/ECR/ECS. Framework NAME is preserved (a Vite app with api/ stays
# framework=vite, type=app). No api/ dir (or empty) stays `static`. See the
# "App deploy type" section below and hq-deploy `src/deploy/function/`.
if [ "$DEPLOY_TYPE" != "ssr" ] && [ -n "$(find api -type f \( -name '*.ts' -o -name '*.js' \) 2>/dev/null | head -n1)" ]; then
  DEPLOY_TYPE="app"
fi

# Next.js here means a static export (`output: 'export'` → out/). A Next.js 15
# app that needs a server (SSR, route handlers, middleware), or a Hono 4 app,
# is not a tarball deploy: hq-deploy runs those live through its own CLI
# (`hq-deploy link --org <slug>` once, then `hq-deploy deploy`; Next via the
# pinned OpenNext builder, Hono via the Fetch/Lambda adapter, production
# environment only). If the Next build produces no out/index.html, or the
# project depends on `hono`, hand off to that CLI instead of this tarball flow.

# Package manager
if   [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then PM="bun"
elif [ -f "pnpm-lock.yaml" ]; then PM="pnpm"
elif [ -f "yarn.lock" ]; then PM="yarn"
else PM="npm"; fi
```

### A.1.5 — Design pass (generated single-page artifacts only)

**Default ON — this is the deploy-quality default.** A plain, HQ-generated report/deck/summary should never ship looking like an unstyled document. Before the artifact is packaged, lift a self-authored single-page HTML to on-brand quality using the **hq-design** house system. This runs *synchronously* here (right after framework detection, before the Phase A fan-out) so the restyled file is what Phase B guardrails tars and Phase C uploads.

**Gate — decide whether to run it:**

```bash
DESIGN_PASS=1
[ "$FRAMEWORK" != "static" ] && DESIGN_PASS=0          # framework builds (Next/Vite/Astro/Remix) own their design — never touch them
[ -f "$OUTPUT_DIR/DESIGN.md" ] && DESIGN_PASS=0         # artifact already declares its own design system
[ "$(jq -r '.deploy.designPass // "true"' "$HOME/.hq/deploy-prefs.json" 2>/dev/null)" = "false" ] && DESIGN_PASS=0   # user disabled globally
case "$LATEST_USER_MSG" in                             # explicit opt-out in the latest message
  *as-is*|*"as is"*|*"no design"*|*"skip design"*|*"no restyle"*|*"don't restyle"*|*"dont restyle"*|*"leave the styling"*|*"keep the design"*|*"keep the styling"*) DESIGN_PASS=0 ;;
esac
```

Scope is deliberately narrow: **only `FRAMEWORK=static` single-page artifacts** (reports, decks, summaries, briefs that HQ generated). Framework builds and already-designed artifacts pass through untouched.

**When `DESIGN_PASS=1`, apply the pass — this is design work you do inline, not a script:**

1. Read the house system: [`core/knowledge/public/hq-core/design-md-spec.md`](../../../core/knowledge/public/hq-core/design-md-spec.md). If the design packs are installed (`core/knowledge/public/design-styles/`, `core/knowledge/public/design-quality/`), fold them in for a higher bar.
2. Restyle `$OUTPUT_DIR/index.html` to that bar — deliberate type scale, spacing rhythm, color/token discipline, restraint, visual hierarchy; accessible (semantic HTML, aria) and responsive; wrap any animation in `@media (prefers-reduced-motion: reduce)`.
3. **Preserve exactly:** every piece of content and every link, and self-containment (inline CSS, inline SVG, web fonts via CDN only — no new local asset dependencies, no external calls). Never invent facts, drop items, or add `.html` sub-pages (the static host SPA-fallbacks them — keep one self-contained `index.html`).
4. If the page is **already at the hq-design bar**, make it a no-op and move on — don't restyle good work.

Then continue to A.2 with the restyled artifact in place.

### A.2 — Spawn three workstreams in parallel

Launch Build (if needed), Identity, and Sensitivity simultaneously — each writes to its own tmp file, then `wait` syncs the barrier.

```bash
T_IDENTITY=$(mktemp -t hq-deploy-identity.XXXXXX)
T_SENSITIVITY=$(mktemp -t hq-deploy-sensitivity.XXXXXX)
T_BUILD=$(mktemp -t hq-deploy-build.XXXXXX)

# A.2.1 — Identity in background (script self-resolves cache/refresh/login)
.claude/skills/deploy/scripts/identity-resolve.sh > "$T_IDENTITY" 2>/dev/null &
IDENTITY_PID=$!

# A.2.2 — Sensitivity in background ($LATEST_USER_MSG = excerpt of latest user message, ≤200 chars)
.claude/skills/deploy/scripts/sensitivity-check.sh "$PWD" "$LATEST_USER_MSG" > "$T_SENSITIVITY" 2>/dev/null &
SENSITIVITY_PID=$!

# A.2.3 — Build in background (skipped if SKIP_BUILD)
if [ -z "$SKIP_BUILD" ]; then
  ( $PM install >/dev/null 2>&1 && $PM run build >/dev/null 2>&1 \
      && echo '{"status":"ok"}' || echo '{"status":"fail"}' ) > "$T_BUILD" &
  BUILD_PID=$!
else
  echo '{"status":"ok","skipped":true}' > "$T_BUILD"
  BUILD_PID=""
fi

# Barrier — wait for all three
wait $IDENTITY_PID $SENSITIVITY_PID $BUILD_PID 2>/dev/null
```

### A.3 — Parse the three verdicts

```bash
IDENTITY_JSON=$(cat "$T_IDENTITY")
SENSITIVITY_JSON=$(cat "$T_SENSITIVITY")
BUILD_JSON=$(cat "$T_BUILD")
rm -f "$T_IDENTITY" "$T_SENSITIVITY" "$T_BUILD"

# Parse all Phase A verdicts through the shared jq-first, node-fallback engine.
# Do not use bare jq here: identity-resolve may have succeeded through node.
. core/scripts/hook-lib.sh
# hook-lib intentionally uses command -v for hot-path hooks, but /deploy must
# not trust a broken Windows app-execution alias or stale node shim.
if [ -n "$HQ_LIB_NODE" ] \
  && ! "$HQ_LIB_NODE" -e 'process.exit(0)' >/dev/null 2>&1; then
  HQ_LIB_NODE=""
fi
if [ -z "$HQ_LIB_JQ" ] && [ -z "$HQ_LIB_NODE" ]; then
  printf '%s\n' "Deploy requires jq or Node.js to parse its phase verdicts. Install jq: Windows: winget install jqlang.jq | choco install jq | scoop install jq; Linux: sudo apt install jq | sudo dnf install jq; macOS: brew install jq" >&2
  IDENTITY_STATUS="missing_dependency"
  JWT=""
  HQ_PRO_JWT=""
  LOGIN_REASON="missing_jq_and_node"
  SENSITIVE="false"
  SENSITIVITY_TRIGGER=""
  BUILD_STATUS="fail"
else
  IDENTITY_STATUS=$(printf '%s' "$IDENTITY_JSON" | hq_json_get status)
  JWT=$(printf '%s' "$IDENTITY_JSON" | hq_json_get jwt)
  IDENTITY_KIND=$(printf '%s' "$IDENTITY_JSON" | hq_json_get identity)
  # id_token is the HQ Pro / grantee-validation token used by C.3. Take it from
  # the resolver output, never from a raw read of ~/.hq/cognito-tokens.json —
  # only the resolver applies the expiry skew and the refresh path.
  HQ_PRO_JWT=$(printf '%s' "$IDENTITY_JSON" | hq_json_get id_token)
  LOGIN_REASON=$(printf '%s' "$IDENTITY_JSON" | hq_json_get reason)

  SENSITIVE=$(printf '%s' "$SENSITIVITY_JSON" | hq_json_get sensitive)
  SENSITIVITY_TRIGGER=$(printf '%s' "$SENSITIVITY_JSON" | hq_json_get trigger)

  BUILD_STATUS=$(printf '%s' "$BUILD_JSON" | hq_json_get status)
fi
```

### A.4 — Phase A barrier rules

- `BUILD_STATUS == "fail"` → abort the deploy entirely (silent skip). Localhost preview also skipped.
- `IDENTITY_STATUS == "login_required"` → mark Phase C upload as no-op; Phase B preview still runs.
- `IDENTITY_STATUS == "missing_dependency"` → **not** a sign-in problem. The A.3 parser has already printed per-OS jq guidance and set `BUILD_STATUS=fail`; abort the deploy without a login upsell or browser sign-in. When node exists, A.3 uses it and this hard-stop is not taken. Note: later Phase C steps still require `jq` even when identity itself used the node fallback.
- `SENSITIVE == "true"` → choose an access mode for Phase C:
  - If the latest user message asks for org/company/internal restriction (`"restricted to org"`, `"company-only"`, `"internal-only"`, `"HQ members only"`), set `ACCESS_MODE=${DEPLOY_ACCESS_INTERNAL_DEFAULT:-company}`.
  - Else if the latest user message names specific recipients (`"share with alice@…"`, `"@example.com only"`, `"private to the design team"`), set `ACCESS_MODE=private` and parse the recipient list into `ALLOW_PATTERNS` (newline-separated, each either `[EMAIL]` or `@domain.tld`).
  - Else if `DEPLOY_ORG_RESTRICTED_BY_DEFAULT=true` or `DEPLOY_ACCESS_SENSITIVE_DEFAULT=company`, set `ACCESS_MODE=company`.
  - Otherwise set `ACCESS_MODE=password` — the historical default for sensitive auto-deploy.

The Identity script derives a filename-safe deploy user key from `${USER:-${USERNAME:-unknown}}` (replacing characters outside `[[:alnum:]_.-]` with `_`) and owns the one-shot login attempt internally (`${TMPDIR:-/tmp}/hq-deploy-login-attempted-<deploy-user-key>`); the main agent does NOT re-trigger login mid-deploy. Token JSON is read with jq first, then node via `core/scripts/hook-lib.sh` (`hq_json_get`) — never a second ad-hoc JSON engine.

### A.5 — Resolve org via vault (Priority 5) and flag CTA state (Priority 6)

If `$ORG_SLUG` is still empty after Step 1e (Priorities 1–4) AND identity returned `ok` (`$JWT` is in scope), ask vault directly. The same person/membership endpoints the API middleware uses are publicly callable with the user's JWT.

This block is no-op when:
- `$ORG_SLUG` already resolved in Step 1e (the common path — no extra round-trip)
- `IDENTITY_STATUS != "ok"` (no JWT — Phase C is already a no-op; State A handled at C.5)

```bash
VAULT_API="${VAULT_API_URL:-https://4nfy67z28h.execute-api.us-east-1.amazonaws.com}"
ORG_RESOLUTION_STATE=""
ACTIVE_SLUGS=""
DEPLOY_CONTEXT_ARGS=()
# Set when the signed-in person belongs to NO company. The deploy still ships,
# under an auto-provisioned per-user PERSONAL scope. The upload below sends
# X-HQ-Deploy-Scope: personal so hq-deploy bypasses company resolution and
# find-or-creates the caller's `personal-<sub>` Org.
PERSONAL_SCOPE=""

if [ -z "$ORG_SLUG" ] && [ "$IDENTITY_STATUS" = "ok" ] && [ -n "$JWT" ]; then
  # Resolve active memberships via GET /membership/me — it works for BOTH human
  # (prs_) AND AGENT (agt_) callers because the vault service derives the agent
  # entity from the JWT (custom:entityType=agent) server-side and unions its
  # memberships. The OLD person-only chain (/entity/by-type/person ->
  # /membership/person/{personUid}) returned NOTHING for an agent — agents have
  # no person entity — so an agent deploy silently downgraded to personal scope,
  # blocking company-scoped deploys for machine identities
  # (feedback_1e8d78ed / DEV-1843: Nanit dashboard). For a machine identity,
  # JWT is the resolver's ID token, so both hq-deploy and vault see the agt_
  # claims. resolve-deploy-org.sh turns
  # the /membership/me body into ORG_SLUG / ORG_RESOLUTION_STATE / PERSONAL_SCOPE
  # / ACTIVE_SLUGS / ACTIVE_COMPANY_UID (single active -> slug; none -> personal;
  # many -> multi-org CTA; missing jq -> missing_dependency, NEVER personal).
  MEMBERSHIPS_JSON=$(curl -s -H "Authorization: Bearer $JWT" "$VAULT_API/membership/me")
  eval "$(printf '%s' "$MEMBERSHIPS_JSON" \
    | DEPLOY_IDENTITY="${IDENTITY_KIND:-person}" .claude/skills/deploy/scripts/resolve-deploy-org.sh)"

  # Single active membership whose companySlug wasn't enriched → resolve it via
  # the entity lookup (fallback only).
  if [ -z "$ORG_SLUG" ] && [ -z "$ORG_RESOLUTION_STATE" ] && [ -n "$ACTIVE_COMPANY_UID" ]; then
    ORG_SLUG=$(curl -s -H "Authorization: Bearer $JWT" \
      "$VAULT_API/entity/$ACTIVE_COMPANY_UID" \
      | jq -r '.entity.slug // empty' 2>/dev/null)
  fi

  # Persist a resolved single-org as defaultOrg so future deploys skip the vault
  # round-trip. ~/.hq/deploy-prefs.json only — never ~/.hq/config.json, which
  # HQ Sync parses as a strict HqConfig.
  if [ -n "$ORG_SLUG" ]; then
    mkdir -p "$HOME/.hq"
    PREFS="$HOME/.hq/deploy-prefs.json"
    if [ -f "$PREFS" ]; then
      jq --arg slug "$ORG_SLUG" '.defaultOrg = $slug' \
        "$PREFS" > "$PREFS.tmp" && mv "$PREFS.tmp" "$PREFS"
    else
      printf '{"defaultOrg":"%s"}\n' "$ORG_SLUG" > "$PREFS"
    fi
  fi
fi

if [ -n "$ORG_SLUG" ]; then
  DEPLOY_CONTEXT_ARGS=(--header "X-Org-Slug: $ORG_SLUG")
elif [ "$PERSONAL_SCOPE" = "true" ]; then
  DEPLOY_CONTEXT_ARGS=(--header "X-HQ-Deploy-Scope: personal")
fi
```

After A.5, Phase C upload proceeds when **either** `$ORG_SLUG` is set (company deploy) **or** `PERSONAL_SCOPE=true` (a signed-in person with no company → personal deploy). Every hq-deploy API call passes `"${DEPLOY_CONTEXT_ARGS[@]}"` to `deploy-api-request.sh`, which adds `X-Org-Slug` for company deploys and `X-HQ-Deploy-Scope: personal` for personal deploys. A machine identity can never use the personal fallback: zero memberships set `machine_no_orgs` and skip upload. Never silently fall back to a hardcoded org. The remaining unresolved states (`multi-org`, `missing_dependency`, `machine_no_orgs`, vault-unreachable) skip the upload and hit the state-aware CTA at C.5, which reads `$ORG_RESOLUTION_STATE`.

A personal deploy has no company to gate against, so `company` / `selected` access modes are impossible. Normalize the access mode chosen in A.4 before Phase C:

```bash
# Personal scope can't use a Cognito company/selected gate. Sensitive content
# falls back to a password; non-sensitive stays public (default, no policy).
# NOTE: this default (public, or password when sensitive) is the security-
# relevant choice flagged for confirmation at the hq-core-staging promotion gate.
if [ "$PERSONAL_SCOPE" = "true" ]; then
  case "$ACCESS_MODE" in
    company|selected)
      ACCESS_MODE="password"
      echo "[deploy] personal scope: no company to gate on — using a password instead of company access." >&2
      ;;
  esac
fi
```

---

## Phase B — Preview + Guardrails (2-way parallel)

Once Build returns `OUTPUT_DIR`, kick off localhost preview (inline backgrounded server) and Guardrails (inline script) in parallel. Phase B completes when both return.

### B.1 — Localhost preview (always runs, never gated)

Pick a port, start a Node http server backgrounded with `disown`, write PID + URL to `/tmp/hq-deploy-preview-$$.{pid,url}`.

```bash
PORT=4321
while lsof -iTCP:"$PORT" -sTCP:LISTEN -Pn >/dev/null 2>&1; do
  PORT=$((PORT + 1))
  [ "$PORT" -gt 4400 ] && break
done

PIDFILE="/tmp/hq-deploy-preview-$$.pid"
URLFILE="/tmp/hq-deploy-preview-$$.url"

node -e "
  const http = require('http');
  const fs = require('fs');
  const path = require('path');
  const root = process.argv[1];
  const port = Number(process.argv[2]);
  const mime = { '.html':'text/html','.js':'application/javascript','.css':'text/css',
                 '.json':'application/json','.svg':'image/svg+xml','.png':'image/png',
                 '.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif',
                 '.ico':'image/x-icon','.woff':'font/woff','.woff2':'font/woff2' };
  http.createServer((req, res) => {
    let p = path.join(root, decodeURIComponent(req.url.split('?')[0]));
    try { if (fs.statSync(p).isDirectory()) p = path.join(p, 'index.html'); } catch {}
    fs.readFile(p, (err, data) => {
      if (err) { res.writeHead(404); return res.end('Not found'); }
      res.writeHead(200, { 'Content-Type': mime[path.extname(p)] || 'application/octet-stream' });
      res.end(data);
    });
  }).listen(port, () => console.log('ready'));
" "$OUTPUT_DIR" "$PORT" > /dev/null 2>&1 &

echo $! > "$PIDFILE"
echo "http://localhost:$PORT" > "$URLFILE"
disown
```

**Persistence:** server stays open until session end. On re-deploy in the same session, kill the old PID and re-use the port. Never accumulate orphans.

### B.2 — Guardrails (inline, backgrounded)

Walks `$OUTPUT_DIR`, includes root `api/` handlers for `DEPLOY_TYPE=app`, applies caps to the combined artifact, and returns path + size + sha256.

```bash
T_GUARDRAILS=$(mktemp -t hq-deploy-guardrails.XXXXXX)
GUARDRAILS_API_DIR=""
if [ "$DEPLOY_TYPE" = "app" ] && [ "$OUTPUT_DIR" != "." ]; then
  GUARDRAILS_API_DIR="$PWD/api"
fi
.claude/skills/deploy/scripts/guardrails-check.sh "$OUTPUT_DIR" "$GUARDRAILS_API_DIR" > "$T_GUARDRAILS" 2>/dev/null &
GUARDRAILS_PID=$!

# Preview server is already disowned and serving — nothing to wait on for it.
wait $GUARDRAILS_PID 2>/dev/null

GUARDRAILS_JSON=$(cat "$T_GUARDRAILS")
rm -f "$T_GUARDRAILS"

GUARDRAILS_PASS=$(echo "$GUARDRAILS_JSON" | jq -r '.pass')
GUARDRAILS_REASON=$(echo "$GUARDRAILS_JSON" | jq -r '.reason // empty')
TARBALL_PATH=$(echo "$GUARDRAILS_JSON" | jq -r '.tarball_path // empty')
TARBALL_SIZE=$(echo "$GUARDRAILS_JSON" | jq -r '.size_bytes // 0')
TARBALL_SHA256=$(echo "$GUARDRAILS_JSON" | jq -r '.sha256 // empty')
FILE_COUNT=$(echo "$GUARDRAILS_JSON" | jq -r '.file_count // 0')
```

**Caps (encoded in script):** project-root disqualifiers (Dockerfile, serverless.yml, sst.config.*, prisma/, migrations/, knex/drizzle configs); >100 files → fail; tarball >10MB gzipped → fail.

If `GUARDRAILS_PASS=false`, skip Phase C entirely. Localhost preview already served the user.

### B.3 — Announce preview URL

Always print this — it's the guaranteed-working feedback:
> Preview: http://localhost:{port}

---

## Phase C — Upload + Password + Link (sequential, hard-gated)

Every API call carries `Authorization: Bearer $JWT`. For a person, `$JWT` is the Cognito access token. For a fleet machine identity, it is the Cognito ID token so hq-deploy and `/membership/me` receive the agent claims (`custom:entityType=agent`, `custom:entityUid=agt_*`).

**Pre-conditions:**
- Phase A: `BUILD_STATUS="ok"`, `IDENTITY_STATUS="ok"` (otherwise skip upload, jump to C.5 with preview-only outcome)
- A.5: `$ORG_SLUG` is non-empty **or** `PERSONAL_SCOPE=true` (otherwise — `multi-org` or vault-unreachable — skip upload, jump to C.5 with the appropriate state-aware CTA — see C.5)
- Phase B: `GUARDRAILS_PASS=true` (otherwise abort silently)

### C.1 — Generate password (sensitive + password mode only)

Only generated when `ACCESS_MODE=password`. Private mode uses the user's hq-auth identity, no password needed.

```bash
if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "password" ]; then
  PW=$(.claude/skills/deploy/scripts/password-helper.sh gen)
  # Format: adjective-noun-NN, e.g. foxtrot-river-92
fi
```

### C.2 — Upload

#### Ensure app exists

```bash
# All Phase C HTTP calls go through this helper. It records the response body
# separately from the HTTP status, validates the expected response shape, and
# exits before the next stage on any failure. It never prints auth headers or
# presigned query strings. `--no-auth` is only for the direct S3 PUT.
DEPLOY_SCOPE="company"
[ "$PERSONAL_SCOPE" = "true" ] && DEPLOY_SCOPE="personal"
deploy_request() {
  local stage="$1"
  shift
  HQ_DEPLOY_JWT="$JWT" .claude/skills/deploy/scripts/deploy-api-request.sh \
    --stage "$stage" --org "${ORG_SLUG:--}" --scope "$DEPLOY_SCOPE" \
    "${DEPLOY_CONTEXT_ARGS[@]}" "$@"
}

# GET /api/apps returns {apps: [...]}
APPS_JSON=$(deploy_request app-list --method GET --url "$API/api/apps" \
  --expect '.apps | type == "array"') || exit 1
```

#### Reuse an existing deploy (route mode, static only)

Before creating a new app, check whether this artifact belongs on a site that is already live. When it does, add it as a route on that app (`https://<host>.indigo-hq.com/<route>/`) instead of creating another app. Related pages such as dated reports, a series of briefs, or documentation sections then share one link and one access gate.

hq-deploy has no merge upload. `POST /api/deploys/:id/complete` deletes every live file of the app and then uploads the new tarball, so adding a route means re-uploading the host's full current site with the artifact placed under `/<route>/`. hq-deploy also has no API for downloading a live site. `route-host.sh record` (run after every successful static upload, see "Static upload") therefore keeps a local snapshot of each static site this skill publishes under `~/.hq/deploy-hosts/<org>/<subdomain>/`, indexed in `~/.hq/deploy-routes.json`, and route mode merges against that snapshot. A site with no local snapshot (deployed from another machine, by the `hq-deploy` CLI, or before this step existed) cannot take a route here without losing its current pages.

Invocation intents (detected like `--comments`):
- `--host=<subdomain>`, or "add this to <app>", "put it on the <app> site", "publish it under <app>": the user named the host.
- `--route=<path>`, or "at /<path>", "under <app>/<path>": the user named the route.
- `--new-app`, or "as its own deploy", "give it a separate link": skip route mode.

**1. Gather candidate hosts.** Only when `DEPLOY_TYPE=static` and `--new-app` was not given. A candidate is a recorded host in the current org (or personal scope) whose snapshot still exists and whose app still appears in `$APPS_JSON` as a `static` app.

```bash
# Re-run guardrails on a new tree; on pass, swap it in as the upload artifact.
rerun_guardrails() {
  local g
  g=$(.claude/skills/deploy/scripts/guardrails-check.sh "$1" "")
  if [ "$(jq -r '.pass' <<<"$g")" != "true" ]; then
    rm -f "$(jq -r '.tarball_path // empty' <<<"$g")"
    return 1
  fi
  rm -f "$TARBALL_PATH"
  OUTPUT_DIR="$1"
  TARBALL_PATH=$(jq -r '.tarball_path' <<<"$g")
  TARBALL_SIZE=$(jq -r '.size_bytes' <<<"$g")
  TARBALL_SHA256=$(jq -r '.sha256' <<<"$g")
  FILE_COUNT=$(jq -r '.file_count' <<<"$g")
}

ROUTE_MODE=false
ROUTE_BLOCKER=""
CANDIDATES='[]'
if [ "$DEPLOY_TYPE" = "static" ] && [ "$NEW_APP" != "true" ]; then
  HOSTS_JSON=$(.claude/skills/deploy/scripts/route-host.sh hosts --org "${ORG_SLUG:--}")
  CANDIDATES=$(jq -c --argjson apps "$APPS_JSON" '
    [ (.hosts // [])[] | select(.siteExists == true) | . as $h
      | ($apps.apps[] | select(.id == $h.appId and .type == "static")) as $a
      | $h + { name: $a.name, url: $a.url,
               liveAccess: (if $a.privateMode then "private"
                            elif ($a.accessMode // "") != "" then $a.accessMode
                            elif $a.passwordProtected then "password"
                            else "public" end) } ]' <<<"$HOSTS_JSON" 2>/dev/null || echo '[]')
fi
```

**2. Decide whether reuse applies.** Walk this table top to bottom and stop at the first matching row.

| Situation | Decision |
|---|---|
| `CANDIDATES` is empty | Not applicable. Continue to "Ensure app exists" without saying anything. |
| `APP_NAME` matches a candidate's `name` | This is a redeploy of the host itself. Go to "Redeploying a host" below. |
| The user named a host and it is a candidate | Applicable. Do not ask. |
| The user named a host that is not a candidate (no local snapshot, not a static app, or in another org) | Ask (step 4) with these options: deploy as a new app, point me at the folder that holds the full current site, or cancel. Never upload a partial site over it. If the user supplies the folder, run `route-host.sh record --site <folder>` for that host first, then continue. |
| A calling skill or policy passed both `--host` and `--route` (series deploys such as a dated report) | Applicable. Do not ask. |
| A candidate looks related but the user did not say so: same project or series, a shared slug prefix with `APP_NAME` (`q3-report` and `reports`), the artifact is a new edition of pages already on the host (date- or version-named routes), or the user's words point at an existing site ("add another one", "next week's version") | Not sure. Ask (step 4). |
| Candidates exist but none looks related | Not applicable. Continue to "Ensure app exists". |

When more than one candidate qualifies, never pick one yourself. List them in the question.

**3. Blockers.** Check these once a host is chosen. Each one makes reuse unsafe for that host. Tell the user in one plain line and deploy as a new app, except where the row says to ask.

- **Access mismatch.** The route inherits the host's gate; route mode never changes it. If `SENSITIVE=true` and the host's `liveAccess` is `public`, the page would go out ungated: deploy it as its own gated app. If the user named specific recipients (`ACCESS_MODE=private` or `selected`) and the host's gate is different, ask. A non-sensitive page on a gated host is fine. Say in the link line that it shares the host's access.
- **Stale snapshot.** The host's newest deploy that did not fail is not the `deployId` the registry recorded, so someone redeployed it from somewhere else and merging would roll that back. Ask: new app, or the folder that holds the current site. (A console rollback does not create a deploy record and is not detected here.)
- **Merge refused.** `route_exists`: ask whether to replace that page (`ROUTE_REPLACE=1`), use another route, or make a new app. `root_absolute_paths`: the artifact loads files from `/…`, which break under a sub-path. Rebuild it with a relative base (Vite `base: './'`, Astro `base`) or deploy as a new app. `invalid_route`: pick a lowercase slug route. `no_index` and `route_blocked`: deploy as a new app.
- **Host full.** Guardrails fail on the merged tree (more than 100 files or 10 MB gzipped). Deploy as a new app.

```bash
# Stale-snapshot check for the chosen host ($HOST = one element of $CANDIDATES).
HOST_APP_ID=$(jq -r '.appId' <<<"$HOST")
HOST_DEPLOYS=$(deploy_request host-deploys --method GET \
  --url "$API/api/apps/$HOST_APP_ID/deploys" --expect '.deploys | type == "array"') || HOST_DEPLOYS=""
# Newest deploy that did not fail. A newer in-flight deploy also counts as
# stale: someone else is replacing the site right now.
LIVE_DEPLOY_ID=""
[ -n "$HOST_DEPLOYS" ] && LIVE_DEPLOY_ID=$(jq -r \
  '[.deploys[] | select(.status != "failed")] | sort_by(.createdAt) | last | .id // empty' <<<"$HOST_DEPLOYS")
if [ -z "$LIVE_DEPLOY_ID" ] || [ "$LIVE_DEPLOY_ID" != "$(jq -r '.deployId' <<<"$HOST")" ]; then
  ROUTE_BLOCKER="stale_snapshot"
fi
```

**4. Asking.** Use AskUserQuestion with one question, for example "This looks like it belongs with <host>. Where should it go?" Options:
1. "Add to <host> at /<route>/ (Recommended)" when exactly one related host exists. The description gives the URL the page will get and says it shares <host>'s access.
2. "New separate deploy". The description gives the new app's own link.
3. Up to two more candidate hosts when several qualify.

Default route: `--route` when given; else the artifact's date as `YYYY-MM-DD` when the host's existing routes are date-named; else the slug-cased `APP_NAME`. The user can type a different route through the free-text answer.

When no structured picker is available (headless runs, the silent `auto-deploy-on-create` path, fleet agents), do not guess. Deploy as a new app and add one line to the final message: "This could also live on <host> at /<route>/. Say so and I'll move it there."

**5. Merge.** Assign `HOST` the chosen element of `$CANDIDATES` and `ROUTE_PATH` the route. Assign `ROUTE_REPLACE=1` only when the user agreed to replace an existing page. Build the combined site in a temp directory. The host snapshot and the build output are never modified.

```bash
if [ -n "$HOST" ] && [ -z "$ROUTE_BLOCKER" ]; then
  HOST_SITE=$(jq -r '.site' <<<"$HOST")
  ROUTE_OUT=$(mktemp -d -t hq-deploy-route.XXXXXX)
  MERGE_JSON=$(.claude/skills/deploy/scripts/route-host.sh merge \
    "$HOST_SITE" "$OUTPUT_DIR" "$ROUTE_PATH" "$ROUTE_OUT" ${ROUTE_REPLACE:+--replace})
  if [ "$(jq -r '.ok' <<<"$MERGE_JSON")" != "true" ]; then
    ROUTE_BLOCKER=$(jq -r '.reason' <<<"$MERGE_JSON")
    rm -rf "$ROUTE_OUT"
  elif ! rerun_guardrails "$ROUTE_OUT"; then
    ROUTE_BLOCKER="host_full"
    rm -rf "$ROUTE_OUT"
  else
    ROUTE_MODE=true
    APP_ID="$HOST_APP_ID"
    APP_SUBDOMAIN=$(jq -r '.subdomain' <<<"$HOST")
    HOST_ACCESS_MODE=$(jq -r '.liveAccess' <<<"$HOST")
    ROUTE_URL_PATH=$(jq -r '.route' <<<"$MERGE_JSON")   # e.g. /2026-09-29/
    # C.3 and C.4 key off SENSITIVE. The host keeps its own gate, so turn them
    # off here; step 3 already checked the host gate against the artifact.
    ARTIFACT_SENSITIVE="$SENSITIVE"
    SENSITIVE=false
  fi
fi
```

If `ROUTE_BLOCKER` is set, handle it as step 3 says and continue on the normal new-app path. The artifact's own tarball from Phase B is still in place for that path.

With `ROUTE_MODE=true`, skip the app lookup below and continue with social preview tags and the static upload against the host app. Route mode also skips C.2.6 (unless the user asked to change comments on the host), C.3, and C.4: the host keeps its access mode, password, and allowlist, and any password generated in C.1 is discarded without being announced.

**Redeploying a host.** When `APP_NAME` matches a candidate, a plain redeploy replaces the whole site, including routes that were added to it later. List the candidate's recorded routes (other than `/`) that the new build does not contain. If there are none, or the snapshot is stale, continue with the normal redeploy. Otherwise ask one question: "Keep the other pages on <host> (Recommended)" or "Replace the whole site". Without a picker, keep them. To keep them, assign `SAME_HOST` the matching candidate and run:

```bash
SAME_SITE=$(jq -r '.site' <<<"$SAME_HOST")
KEEP_OUT=$(mktemp -d -t hq-deploy-keep.XXXXXX)
cp -R "$OUTPUT_DIR/." "$KEEP_OUT/"
jq -r '.routes[] | select(. != "/")' <<<"$SAME_HOST" | while IFS= read -r r; do
  rel="${r#/}"; rel="${rel%/}"
  { [ -n "$rel" ] && [ ! -e "$KEEP_OUT/$rel" ]; } || continue
  mkdir -p "$KEEP_OUT/$(dirname "$rel")"
  cp -R "$SAME_SITE/$rel" "$KEEP_OUT/$rel"
done
rerun_guardrails "$KEEP_OUT" || { rm -rf "$KEEP_OUT"; echo "[deploy] site too large to keep the other pages" >&2; }
```

If keeping the pages makes the site too large, ask whether to replace the whole site or cancel.

#### Find or create the app

```bash
# Route mode already chose the host app; everything else looks up or creates one.
if [ "$ROUTE_MODE" != "true" ]; then
APP_ID=$(echo "$APPS_JSON" | jq -r --arg name "$APP_NAME" '.apps[] | select(.name == $name) | .id' | head -1)
APP_SUBDOMAIN=$(echo "$APPS_JSON" | jq -r --arg name "$APP_NAME" '[.apps[] | select(.name == $name)][0].subdomain // empty')

if [ -z "$APP_ID" ]; then
  # POST /api/apps requires {name, type}
  APP_RESPONSE=$(deploy_request app-creation --method POST --url "$API/api/apps" \
    --header 'Content-Type: application/json' \
    --data "{\"name\": \"$APP_NAME\", \"type\": \"$DEPLOY_TYPE\"}" \
    --expect '(.id | type == "string" and length > 0)') || exit 1
  APP_ID=$(echo "$APP_RESPONSE" | jq -r '.id')
  APP_SUBDOMAIN=$(echo "$APP_RESPONSE" | jq -r '.subdomain')
fi
fi
# Subdomain anchors both the upload (appSlug) and the preview-tag base URL; fall
# back to the app-name slug if the API response didn't surface one.
if [ -z "$APP_SUBDOMAIN" ] || [ "$APP_SUBDOMAIN" = "null" ]; then APP_SUBDOMAIN="$APP_NAME"; fi
```

#### Inject social preview tags (static deploys only)

Before tarring for upload, add Open Graph / Twitter Card tags so a shared link unfurls with a real card (title + description + 1200x630 image) instead of a bare URL. This is what makes Slack/iMessage/Twitter render a rich preview. Runs only for `DEPLOY_TYPE=static`, and never overwrites a page's author-supplied `og:title`. The base URL is derived from the resolved subdomain so `og:url`/`og:image` are absolute. If injection changes the output, the tarball is rebuilt so the deploy manifest's `size` + `sha256` match the bytes actually uploaded.

```bash
if [ "$DEPLOY_TYPE" = "static" ]; then
  BASE_URL="https://${APP_SUBDOMAIN}.${HQ_DEPLOY_DOMAIN:-indigo-hq.com}"
  OG_JSON=$(.claude/skills/deploy/scripts/og-inject.sh "$OUTPUT_DIR" "$BASE_URL" "$APP_NAME")
  if [ "$(echo "$OG_JSON" | jq -r '.changed')" = "true" ]; then
    NEW_TAR=$(mktemp -t hq-deploy-tar.XXXXXX)
    if ! tar -czf "$NEW_TAR" -C "$OUTPUT_DIR" . 2>/dev/null; then
      rm -f "$NEW_TAR"
      echo "tar_create_failed" >&2
      exit 1
    fi
    rm -f "$TARBALL_PATH"
    TARBALL_PATH="$NEW_TAR"
    TARBALL_SIZE=$(stat -c%s "$TARBALL_PATH" 2>/dev/null || stat -f%z "$TARBALL_PATH" 2>/dev/null || echo 0)
    if command -v sha256sum >/dev/null 2>&1; then
      TARBALL_SHA256=$(sha256sum "$TARBALL_PATH" | awk '{print $1}')
    else
      TARBALL_SHA256=$(shasum -a 256 "$TARBALL_PATH" | awk '{print $1}')
    fi
  fi
fi
```

#### Static upload (presigned URL)

The Guardrails script already produced `$TARBALL_PATH`, `$TARBALL_SIZE`, `$TARBALL_SHA256` — reuse them, do not re-tar:

The `org` field below is informational only — the hq-deploy API resolves the
target org from the caller's auth context and context headers. Company deploys
carry `X-Org-Slug: $ORG_SLUG`; personal deploys carry
`X-HQ-Deploy-Scope: personal` and leave `$ORG_SLUG` empty. Never send both
headers on the same request.

```bash
if [ "$DEPLOY_TYPE" = "static" ]; then
  DEPLOY_RESPONSE=$(deploy_request deploy-creation --method POST --url "$API/api/deploys" \
  --header 'Content-Type: application/json' \
  --data "{\"appSlug\": \"$APP_SUBDOMAIN\", \"org\": \"$ORG_SLUG\", \"manifest\": {\"files\": [], \"size\": $TARBALL_SIZE, \"sha256\": \"$TARBALL_SHA256\"}}" \
  --expect '(.deployId | type == "string" and length > 0) and (.presignedUrl | type == "string" and length > 0)') || exit 1

DEPLOY_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.deployId')
PRESIGNED_URL=$(echo "$DEPLOY_RESPONSE" | jq -r '.presignedUrl')

# Direct S3 PUT — presigned URL carries its own signature, no Authorization header
deploy_request s3-upload --no-auth --method PUT --url "$PRESIGNED_URL" \
  --header 'Content-Type: application/gzip' --upload-file "$TARBALL_PATH" || exit 1

COMPLETE_RESPONSE=$(deploy_request deploy-completion --method POST \
  --url "$API/api/deploys/$DEPLOY_ID/complete" \
  --header 'Content-Type: application/json' --data "{\"appSlug\": \"$APP_SUBDOMAIN\"}" \
  --expect '(.url | type == "string" and length > 0)') || exit 1

LIVE_URL=$(echo "$COMPLETE_RESPONSE" | jq -r '.url')

# Snapshot exactly what just went live so a later deploy can add a route to
# this app without deleting its pages (see "Reuse an existing deploy"). A
# failed snapshot never fails the deploy.
.claude/skills/deploy/scripts/route-host.sh record --org "${ORG_SLUG:--}" \
  --subdomain "$APP_SUBDOMAIN" --app-id "$APP_ID" \
  --access-mode "${HOST_ACCESS_MODE:-${ACCESS_MODE:-public}}" \
  --deploy-id "$DEPLOY_ID" --tarball "$TARBALL_PATH" >/dev/null 2>&1 || true

# Route mode on a public host: confirm the new page and every page that was
# already there still load. Gated hosts redirect to sign-in, so skip them.
ROUTE_VERIFY_FAILED=""
if [ "$ROUTE_MODE" = "true" ] && [ "$HOST_ACCESS_MODE" = "public" ]; then
  for r in $(jq -r '.routes[:25][]' <<<"$MERGE_JSON"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --fail --retry 5 --retry-delay 3 \
      --retry-all-errors "${LIVE_URL%/}$r" 2>/dev/null)
    [ "$code" = "200" ] || ROUTE_VERIFY_FAILED="$ROUTE_VERIFY_FAILED $r"
  done
fi
rm -f "$TARBALL_PATH"
[ -n "$ROUTE_OUT" ] && rm -rf "$ROUTE_OUT"
[ -n "$KEEP_OUT" ] && rm -rf "$KEEP_OUT"
fi
```

#### App upload (backend `api/*` → per-app Lambda)

When `DEPLOY_TYPE=app` (a root `api/` dir was detected in A.1), the app ships a
static frontend **and** backend `api/*` handlers. Guardrails includes the root
`api/` directory in the capped archive when the build output is a separate
directory. Use the app deploy route, which accepts `type=app`; `/api/deploys`
supports only `static`, `fetch`, and `next` artifact types and defaults an
omitted type to `static`.

```bash
if [ "$DEPLOY_TYPE" = "app" ]; then
  APP_DEPLOY_RESPONSE=$(deploy_request app-deploy --method POST \
    --url "$API/api/apps/$APP_ID/deploy" \
    --form-string 'type=app' \
    --form-file "file=$TARBALL_PATH" \
    --expect '(.deployId | type == "string" and length > 0) and (.statusUrl | type == "string" and length > 0)') || exit 1
  LIVE_URL="https://${APP_SUBDOMAIN}.${HQ_DEPLOY_DOMAIN:-indigo-hq.com}"
  rm -f "$TARBALL_PATH"
fi
```

The control plane esbuild-bundles `api/**/*.{ts,js}` into a per-app Lambda,
mounts it behind a shared front-door HTTP API, and maps the app subdomain to it.
This multipart request performs the app deploy; do not follow it with the static
presigned upload or a separate completion request. There is no Docker/ECR/ECS step.

**Runtime secrets → SecretBindings (not env vars in the bundle).** A backend
handler that needs a secret (DB URL, Slack webhook, API key) must NOT have the
value baked into the tarball. Instead bind the app to named HQ-Pro vault secrets;
the per-app function reads its own bound secrets **keylessly at runtime** via
SigV4 against its app identity. Author the bindings before deploy:

```bash
# List current bindings
BINDINGS_JSON=$(deploy_request secret-bindings-list --method GET \
  --url "$API/api/apps/$APP_ID/secret-bindings" \
  --expect '.secrets | type == "array"') || exit 1
echo "$BINDINGS_JSON" | jq '.secrets'

# Bind vault secrets the caller currently has read on (references only — no values).
# Requires an hq-pro token; each ref is validated against the vault + deployer grant.
deploy_request secret-bindings-write --method PUT \
  --url "$API/api/apps/$APP_ID/secret-bindings" \
  "${HQ_PRO_REQUEST_HEADERS[@]}" --header 'Content-Type: application/json' \
  --data '{"companyUid":"'"$COMPANY_UID"'","secrets":[{"name":"SLACK_WEBHOOK_URL"},{"name":"DATABASE_URL"}]}'
```

The binding stores references only. At deploy time, the per-app Lambda receives
`HQ_SECRET_BINDINGS` (alias → vault secret name), `HQ_COMPANY_UID`, and the vault
API settings; secret values are not copied into its Lambda environment or bundle.
At cold start, the runtime uses the function's own IAM execution-role credentials
to SigV4-sign a request to the vault `app-load` route, then passes resolved values
to each `api/*` handler as `ctx.secrets`. Keys are the binding alias (`envVar`
when configured, otherwise the vault secret name):

```ts
export default async function handler(_req, ctx) {
  const databaseUrl = ctx.secrets.DATABASE_URL;
  // Use the secret in server-side work; never return it in a response.
}
```

Do not read a bound secret from `process.env`; `ctx.env` is a non-secret snapshot
and excludes HQ runtime internals. The runtime fails closed if a bound secret
cannot be resolved. Never expose `ctx.secrets` or its values to the browser.

**Public + secret-backed deploy gate (ADVISORY-first — STOP before deploying).**
The trigger is deliberately simple — no source analysis, no route inspection:

```
(access mode is PUBLIC)  AND  (runtime SecretBinding count > 0)
```

Fetch access mode + binding count and decide PUBLIC the same way the edge
validator does (public = `accessMode=="public"`, or legacy rows where neither
`privateMode` nor `passwordProtected` is true; any password/company/selected/
private gate is NOT public):

```bash
APP_JSON=$(deploy_request app-read --method GET --url "$API/api/apps/$APP_ID" \
  --expect 'type == "object"') || exit 1
ACCESS_MODE=$(echo "$APP_JSON" | jq -r '.accessMode // empty')
BINDINGS_JSON=$(deploy_request secret-bindings-list --method GET \
  --url "$API/api/apps/$APP_ID/secret-bindings" \
  --expect '.secrets | type == "array"') || exit 1
BINDING_COUNT=$(echo "$BINDINGS_JSON" | jq -r '.secrets | length')
```

- **PUBLIC and `BINDING_COUNT > 0` → STOP.** Secret-backed endpoints would be
  world-callable. Surface the risk in full prose and require the user to EITHER
  add an access gate (password/company/private) and re-run, OR explicitly
  acknowledge the risk for this deploy — then pass `acknowledgePublicSecretRisk`
  through the deploy call so the acceptance is recorded/audited. Do not proceed
  silently.
- **`BINDING_COUNT == 0`**, or **any gate present** → proceed with no prompt.

> Canonical, testable trigger lives in hq-deploy at
> `src/deploy/function/security-gate.ts` (`evaluateDeployGate`/`assertDeployGate`);
> this step is the operator-facing surface. The full app-runtime contract lives
> alongside it in the hq-deploy repo's app/api-routes runtime spec.

#### SSR upload (ECR image)

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$ECR_URI"
docker build -t "$APP_NAME:$VERSION" .
docker tag "$APP_NAME:$VERSION" "$ECR_URI/$APP_NAME:$VERSION"
docker push "$ECR_URI/$APP_NAME:$VERSION"

deploy_request ssr-deploy --method POST --url "$API/api/apps/$APP_ID/deploy" \
  --header 'Content-Type: application/json' \
  --data "{\"image_tag\": \"$VERSION\", \"deploy_type\": \"ssr\"}" || exit 1
```

#### 401 handling

`deploy-api-request.sh` is the only Phase C request path. On a 401 from an
authenticated request it calls `identity-resolve.sh --force-refresh` and retries
that request exactly once with the new access token. A successful retry continues
the current deploy. If refresh or the retry fails, it stops before any later
stage and explicitly reports that live content was not updated. Other non-2xx
responses also stop the phase. Diagnostics include the stage, method, sanitized
URL, status, API code/message, request ID, and non-secret org/scope while
stripping old and refreshed Authorization values and the full query string
(including presigned S3 credentials). A 403 is marked `authorization=forbidden`
with the target org/scope so authorization failures are not mistaken for
malformed responses.

### C.2.6 — Enable comments (opt-in)

Skipped when `ROUTE_MODE=true`, unless the user asked to change comments on the host site: the flag is app-wide.

Only when the invocation opted in (`$COMMENTS` is `on` or `off` per the `--comments` intent in "Access modes"; unset → skip this step entirely). Comments are a per-app opt-in, off by default. The static completion route reads the flag inside `POST /api/deploys/:id/complete`, so this PATCH must run **before** that call: right after "Ensure app exists" in C.2 (the app, new or existing, has `$APP_ID` by then). The app route has no comment-widget injection.

```bash
if [ "$COMMENTS" = "on" ] || [ "$COMMENTS" = "off" ]; then
  ENABLED=$([ "$COMMENTS" = "on" ] && echo true || echo false)
  deploy_request comments-toggle --method PATCH --url "$API/api/apps/$APP_ID" \
    --header 'Content-Type: application/json' \
    --data "{\"commentsEnabled\": $ENABLED}" >/dev/null || exit 1
fi
```

`commentsEnabled` is orthogonal to `ACCESS_MODE` — the comment surface enforces the SAME gate as the deploy (a gated deploy's thread is only readable/writable by viewers who pass the gate; access revocation reaches comments too), so no extra access wiring is needed here. Mention it once in C.5 when it was toggled ("comments are on for this deploy").

This step is documented after C.2 for reference, but execute it between "Ensure app exists" and the static upload so the current static deploy ships with (or without) the widget. It has no effect on `app` or SSR deploys, which never get the widget. To read or resolve the comments afterwards, use the owner routes and the review loop under "Reading and answering comments as the owner" in the Access modes section.

### C.3 — Wire access mode (sensitive only)

Skipped when `ROUTE_MODE=true`. The new route inherits the host's existing gate; route mode never changes a host's access mode, password, or allowlist. C.4 is skipped for the same reason.

After upload, with `appId` in hand. Branch on `ACCESS_MODE`. Use `PUT /access-policy` for first-class Cognito policy modes (`company`, `selected`, policy-versioned password); use `POST /access-mode` for legacy password/private transitions and allowlist cleanup.

For grantee validation, send the id token when available. `identity-resolve.sh` returns the hq-deploy access token as `$JWT` and the companion id token as `id_token`; take it from that output only, keep it inside the shell, and never echo it.

```bash
# BOTH tokens come from identity-resolve.sh — A.3 parsed `id_token` into
# $HQ_PRO_JWT. Never re-read ~/.hq/cognito-tokens.json with a raw `jq` (as this
# did until 2026-07-19): only the resolver applies the expiry skew and the
# refresh path, so a raw read bypasses both and hands C.3 an id token that can
# already be dead while the access token is still fresh — which 401s the
# access-policy call below and silently downgrades a members-only gate.
# No re-resolve fallback here on purpose. A second invocation of the resolver
# would be a second resolution path — the exact shape of the bug above — and
# every other Phase C variable ($JWT, $APP_ID, $API) already carries over from
# its defining block. If HQ_PRO_JWT is somehow empty, the header is simply
# omitted and the companyUid lookup falls back to $JWT, which the API accepts.
HQ_PRO_REQUEST_HEADERS=()
[ -n "$HQ_PRO_JWT" ] && HQ_PRO_REQUEST_HEADERS=(--header "X-HQ-Pro-Authorization: Bearer $HQ_PRO_JWT")

# A 401 anywhere in the company-gate path is a transient auth failure, never a
# policy decision — so it must fail closed instead of falling back to a weaker
# gate. Report the artifact's current anonymous reachability first so the
# exposure is visible rather than implied.
# LIVE_URL is set in the upload block above. If these blocks are run as
# separate shell invocations it will be unset here — and an unset URL must not
# silently turn the exposure warning into "artifact is live at  and its status
# is unknown", which reads as reassuring noise at the exact moment the operator
# needs a real answer. Fall back to reconstructing it from the subdomain, and
# if even that is unavailable, say plainly that the state is unverified.
report_gate_exposure_and_fail() {
  local why="$1" live_code url
  url="${LIVE_URL:-}"
  # Same construction as BASE_URL in the upload block — keep them in step.
  if [ -z "$url" ] && [ -n "${APP_SUBDOMAIN:-}" ]; then
    url="https://${APP_SUBDOMAIN}.${HQ_DEPLOY_DOMAIN:-indigo-hq.com}"
  fi
  if [ -n "$url" ]; then
    live_code=$(curl -sS -o /dev/null -w '%{http_code}' "$url/" || true)
    echo "[deploy] artifact is live at $url and its anonymous status is ${live_code:-unknown} (302 = gated, 200 = OPEN). Re-gate or remove it after logging in." >&2
  else
    echo "[deploy] WARNING: the artifact was uploaded and is live, but its URL could not be resolved here, so its anonymous reachability is UNVERIFIED. Check it in the HQ console and re-gate or remove it." >&2
  fi
  echo "[deploy] auth_expired: $why Run /hq-login, then re-run /deploy to apply the company gate. Refusing to downgrade a members-only artifact to a shared password." >&2
  exit 1
}

if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "password" ]; then
  deploy_request access-mode-password --method POST \
    --url "$API/api/apps/$APP_ID/access-mode" \
    --header 'Content-Type: application/json' \
    --data "{\"mode\": \"password\", \"password\": \"$PW\"}" >/dev/null || exit 1
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "company" ]; then
  # Resolve the companyUid with the status code in hand. An expired HQ Pro token
  # answers 401 here, which yields an empty uid — indistinguishable from "no such
  # company" unless the status is checked, and an empty uid is what triggers the
  # password fallback below.
  UID_RESPONSE=$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer ${HQ_PRO_JWT:-$JWT}" \
    "$VAULT_API/entity/by-slug/company/$ORG_SLUG" 2>/dev/null || printf '\n000')
  UID_STATUS="${UID_RESPONSE##*$'\n'}"
  COMPANY_UID=$(printf '%s' "${UID_RESPONSE%$'\n'*}" | jq -r '.entity.uid // empty' 2>/dev/null)
  if [ "$UID_STATUS" = "401" ]; then
    report_gate_exposure_and_fail "companyUid lookup for $ORG_SLUG returned 401 AUTH_FAILED."
  fi
  if [ -z "$COMPANY_UID" ]; then
    echo "[deploy] company access requested but companyUid could not be resolved for $ORG_SLUG (status=$UID_STATUS); falling back to password mode." >&2
    PW=${PW:-$(.claude/skills/deploy/scripts/password-helper.sh gen)}
    ACCESS_MODE=password
    deploy_request access-mode-password-fallback --method POST \
      --url "$API/api/apps/$APP_ID/access-mode" \
      --header 'Content-Type: application/json' \
      --data "{\"mode\": \"password\", \"password\": \"$PW\"}" >/dev/null || exit 1
  else
    # deploy_request already fails closed: it prints a `status=NNN api_code=...`
    # diagnostic and exits non-zero on any non-2xx, so a 401 here can no longer
    # fall through to the password gate. What it does NOT do is say what the
    # artifact's exposure is right now — and by this point it is already
    # uploaded and live. Any failure to apply the gate leaves it in an unknown
    # state, so report reachability and the recovery step on every failure, not
    # just on 401.
    deploy_request access-policy-company --method PUT \
      --url "$API/api/apps/$APP_ID/access-policy" \
      "${HQ_PRO_REQUEST_HEADERS[@]}" --header 'Content-Type: application/json' \
      --data "{\"mode\":\"company\",\"companyUid\":\"$COMPANY_UID\",\"users\":[],\"groups\":[]}" >/dev/null \
      || report_gate_exposure_and_fail "PUT /access-policy failed for $ORG_SLUG (see the status= diagnostic above)."
  fi
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "selected" ]; then
  # SELECTED_USERS_JSON / SELECTED_GROUPS_JSON must be arrays of {id} objects
  # resolved from the HQ directory. Do not invent IDs from display names.
  COMPANY_UID=${COMPANY_UID:-$(curl -sS -H "Authorization: Bearer ${HQ_PRO_JWT:-$JWT}" \
    "$VAULT_API/entity/by-slug/company/$ORG_SLUG" \
    | jq -r '.entity.uid // empty' 2>/dev/null)}
  deploy_request access-policy-selected --method PUT \
    --url "$API/api/apps/$APP_ID/access-policy" \
    "${HQ_PRO_REQUEST_HEADERS[@]}" --header 'Content-Type: application/json' \
    --data "{\"mode\":\"selected\",\"companyUid\":\"$COMPANY_UID\",\"users\":${SELECTED_USERS_JSON:-[]},\"groups\":${SELECTED_GROUPS_JSON:-[]}}" >/dev/null || exit 1
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "private" ]; then
  # Flip the app to private mode, then grant each pattern.
  deploy_request access-mode-private --method POST \
    --url "$API/api/apps/$APP_ID/access-mode" \
    --header 'Content-Type: application/json' --data '{"mode": "private"}' >/dev/null || exit 1

  # ALLOW_PATTERNS is one pattern per line (set in A.4 from the user message).
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    deploy_request allowed-email-grant --method POST \
      --url "$API/api/apps/$APP_ID/allowed-emails" \
      --header 'Content-Type: application/json' \
      --data "{\"email\": \"$PATTERN\"}" >/dev/null || exit 1
  done <<< "$ALLOW_PATTERNS"
fi
```

**Legacy PATCH gotcha:** never call `PATCH /api/apps/:id {passwordProtected: true, password: ...}` on an app that may already be in `private` mode — it returns `409 ACCESS_MODE_CONFLICT` because the server refuses to bypass the mutex. The `/access-mode` endpoint above handles the transition cleanly.

#### Auth-gate verify (sensitive only)

Treat gate setup as unproven until all three checks pass: the mutation returns a
2xx status, an authenticated `GET /api/apps/{appId}` reread reports the expected
protection state, and an anonymous request to the live URL returns `302`. Poll
the reread + anonymous redirect a small bounded number of times for propagation.
Do not announce a selected access mode, password, or live link as gated before
that proof succeeds. If a company gate cannot be proven, attempt the password
fallback with the same checks — subject to the 401 exception below; if that also
cannot be proven, fail the deploy closed rather than reporting a potentially
public artifact.

**The password fallback is for policy rejections only — never for 401.** A 401 on
the access-policy call or on the companyUid lookup means the credential expired, not
that the policy engine refused this caller. Treating the two alike silently
publishes a members-only artifact behind a shared password — a weaker gate than
the one requested, reached because a token aged out. On 401: stop, report the
artifact's current anonymous reachability, tell the user to run `/hq-login`, and
re-run — do not weaken the gate. Genuine rejections (`400`, or
`403 ACCESS_POLICY_COMPANY_MISMATCH` on a cross-company deploy the caller's token
cannot gate) are what the fallback exists for.

```bash
if [ "$SENSITIVE" = "true" ]; then
  APP_JSON=$(deploy_request auth-gate-reread --method GET \
    --url "$API/api/apps/$APP_ID" --expect 'type == "object"') || exit 1
  PROTECTED=$(echo "$APP_JSON" | jq -r '.passwordProtected // false')
  PRIVATE=$(echo "$APP_JSON" | jq -r '.privateMode // false')
  POLICY_MODE=$(echo "$APP_JSON" | jq -r '.accessPolicy.mode // .accessMode // empty')
  if [ "$ACCESS_MODE" = "company" ] || [ "$ACCESS_MODE" = "selected" ]; then
    [ "$POLICY_MODE" != "$ACCESS_MODE" ] && echo "[deploy] auth-gate verify: expected accessPolicy.mode=$ACCESS_MODE got ${POLICY_MODE:-empty} for $APP_ID — re-run /deploy if this artifact must stay gated." >&2
  else
    EXPECTED_FLAG="$([ "$ACCESS_MODE" = "password" ] && echo "$PROTECTED" || echo "$PRIVATE")"
    if [ "$EXPECTED_FLAG" != "true" ]; then
      echo "[deploy] auth-gate verify: mode=$ACCESS_MODE protected=$PROTECTED private=$PRIVATE for $APP_ID — re-run /deploy if this artifact must stay gated." >&2
    fi
  fi
fi
```

Failure handling: do not auto-delete the deploy, but exit non-zero and do not
present it as gated when neither the selected mode nor password fallback is proven.

### C.4 — Announce access (sensitive only)

#### Password mode

```bash
if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "password" ]; then
  .claude/skills/deploy/scripts/password-helper.sh announce \
    "$APP_SUBDOMAIN" "$PW" "$SENSITIVITY_TRIGGER"
  # announce: prints once to stderr, copies to clipboard via pbcopy,
  # persists to ~/.hq/deploy-passwords.json (mode 0600), keyed by slug.
fi
```

#### Private mode

No password to announce. Surface who got access so the user can sanity-check before sharing the link:

```bash
if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "private" ]; then
  PATTERN_LIST=$(echo "$ALLOW_PATTERNS" | paste -sd ', ' -)
  echo "[deploy] private mode: $PATTERN_LIST can sign in via auth.{your-domain}.com to view." >&2
fi
```

#### Company mode

No password to announce. Surface the org restriction once:

```bash
if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "company" ]; then
  echo "[deploy] company mode: active $ORG_SLUG members can sign in with HQ to view." >&2
fi
```

### C.5 — Present the link

The only user-visible output. Keep it casual.

**On success (non-sensitive):** weave naturally:
- "Here's a link you can share: https://{app}.indigo-hq.com"
- "The docs are live at https://{app}.indigo-hq.com"

**On success (route mode, `ROUTE_MODE=true`):** give the route URL, `${LIVE_URL%/}$ROUTE_URL_PATH`, and name the host once. Describe access from `$HOST_ACCESS_MODE` without re-announcing any password:
- Public host: "Added it to <host>: https://<host>.indigo-hq.com/<route>/"
- Gated host: "Added it to <host>: https://<host>.indigo-hq.com/<route>/. It uses the same sign-in (or password) as the rest of <host>."
- If `ROUTE_VERIFY_FAILED` is non-empty, list those pages in plain words and say they did not load after the upload.

When route mode was skipped because of a blocker the user should know about (step 3), add one plain line saying why the page got its own link.

**On success (personal scope, `PERSONAL_SCOPE=true`):** the deploy went to the
user's own personal space (no company). Say so once, casually, so they know it
isn't org-restricted — and only mention a password if the content was sensitive
(personal sensitive deploys use password mode, see A.5 normalization):
- Non-sensitive: "Deployed to your personal space — here's the link: https://$APP_SUBDOMAIN.indigo-hq.com (it's public; once you join a company you can deploy there too)."
- Sensitive: same `password mode` line as below, plus a one-time note that it landed in your personal space.

**On success (sensitive, password mode):** mention password ONCE:
> Live at `https://$APP_SUBDOMAIN.indigo-hq.com` — password copied to your clipboard (also saved to `~/.hq/deploy-passwords.json`).

If the user asks "what was the password?" later, do NOT re-emit. Tell them:
> Run `jq -r '."$APP_SUBDOMAIN".password' ~/.hq/deploy-passwords.json` to retrieve it.

**On success (sensitive, private mode):** name the allowlist once, no password mention:
> Live at `https://$APP_SUBDOMAIN.{your-domain}.com` — gated to {[EMAIL], @example.com}. They'll sign in via auth.{your-domain}.com on first visit.

**On success (sensitive, company mode):** name the org gate once, no password mention:
> Live at `https://$APP_SUBDOMAIN.{your-domain}.com` — restricted to active `$ORG_SLUG` members. They'll sign in with HQ on first visit.

For changes after the fact, point at the CLI rather than re-orchestrating from this skill:
> Run `hq-deploy access share $APP_SUBDOMAIN <email|@domain>` to add a teammate, or `… unshare …` to revoke.

The `~/.hq/deploy-passwords.json` path is in `.claude/settings.json` Read deny list — the session can't pull it back into context.

**On no-identity path** (Phase A returned `login_required`) — **State A**: preview URL was already emitted in Phase B; emit upsell once if `/tmp/hq-deploy-upsold-<deploy-user-key>` doesn't exist:

```bash
DEPLOY_USER_KEY=${USER:-${USERNAME:-unknown}}
DEPLOY_USER_KEY=${DEPLOY_USER_KEY//[^[:alnum:]_.-]/_}
UPSOLD_FILE="/tmp/hq-deploy-upsold-$DEPLOY_USER_KEY"
if [ ! -f "$UPSOLD_FILE" ]; then
  echo "Looks like you don't have an HQ account yet. Create one free at https://onboarding.indigo-hq.com and I'll deploy this to the web next time."
  touch "$UPSOLD_FILE"
fi
```

**On signed-in-but-org-unresolved path** (`IDENTITY_STATUS=ok`, `PERSONAL_SCOPE` not set, and `$ORG_SLUG` still empty after A.5): emit the appropriate state-aware CTA. This covers `multi-org`, `missing_dependency`, and the vault-unreachable defensive case — the `no-orgs` state deploys to personal scope above. Preview URL was already shown in Phase B, so the CTA pairs with that, not in place of it:

```bash
PREVIEW_URL=$(cat "$URLFILE" 2>/dev/null || echo "http://localhost:$PORT")
case "$ORG_RESOLUTION_STATE" in
  multi-org)
    # State C — multiple memberships, no default
    echo "You're a member of multiple companies (${ACTIVE_SLUGS:-multiple}). Tell me which one to deploy to (\"deploy this to <slug>\") or set a default (\"make <slug> my default org\"). Preview: $PREVIEW_URL"
    ;;
  missing_dependency)
    # Memberships could not be inspected. Never infer personal scope.
    echo "I couldn't inspect your HQ memberships because jq is missing. Install jq (Windows: winget/choco/scoop; Linux: apt/dnf; macOS: brew), then rerun /deploy. Preview: $PREVIEW_URL"
    ;;
  machine_no_orgs)
    echo "This agent is not a member of any company, so it cannot create a personal deploy. Ask a company admin to add the agent to the target company, then rerun /deploy. Preview: $PREVIEW_URL"
    ;;
  *)
    # Defensive — JWT was valid but vault was unreachable. Don't silently
    # default to indigo; surface a recoverable next step.
    echo "Couldn't resolve a deploy target right now. Set HQ_ORG=<slug> for this run, or \"make <slug> my default org\" to persist. Preview: $PREVIEW_URL"
    ;;
esac
```

Skip the rest of Phase C (no upload, no password, no link) — local preview is already up.

**On upload failure** (after Phase A passed but Phase C failed):
- "Deploy to hq-deploy didn't go through, but everything else is done."

Then move on. Deploy is never the main event.

---

## Inline-script reference

| Script | Input | Returns |
|--------|-------|---------|
| `identity-resolve.sh` | `[--force-refresh]` (reads `~/.hq/cognito-tokens.json`) | `{"status":"ok","jwt":"...","id_token":"...","identity":"person\|machine","expires_at":<epoch-ms>,"source":"cache\|refresh\|login\|machine_mint"}` or `{"status":"login_required","reason":"..."}` or `{"status":"missing_dependency","dep":"jq\|node","install":"..."}`. A machine identity is detected from `HQ_MACHINE_CREDS_FILE` or `~/.hq-agent/machine-creds.json`, calls `hq-auth-refresh` without a browser, and returns its ID token in both `jwt` and `id_token` so agent claims reach hq-deploy and vault. A person keeps the access-token `jwt` path. `--force-refresh` bypasses a person's cache after an API 401. `id_token` is the only sanctioned source of the HQ Pro token — a raw `jq` read of the token file skips the expiry skew and the refresh path |
| `sensitivity-check.sh <path> [user_msg]` | artifact path + latest user message excerpt | `{"sensitive":bool,"trigger":"companies-data-path\|private-repo\|pii-detected\|financial-filename\|user-stated-private"\|null}` |
| `guardrails-check.sh <output_dir>` | build output directory | `{"pass":bool,"reason":string\|null,"tarball_path":string,"size_bytes":int,"sha256":string,"file_count":int}` |
| `og-inject.sh <output_dir> [base_url] [app_name]` | static build dir (+ live base URL) | `{"injected":int,"image":"generated\|existing\|none","changed":bool}` |
| `password-helper.sh gen` | — | `<adjective-noun-NN>` on stdout |
| `password-helper.sh announce <slug> <pw> [trigger]` | slug + password | stderr message + pbcopy + writes `~/.hq/deploy-passwords.json` |
| `route-host.sh hosts [--org <slug>\|-]` | reads `~/.hq/deploy-routes.json` | `{"hosts":[{key,org,subdomain,appId,accessMode,deployId,site,siteExists,routes,updatedAt}]}` |
| `route-host.sh merge <host_site> <artifact_dir> <route> <out_dir> [--replace]` | host snapshot + build output | `{"ok":true,"out_dir","route","replaced","file_count","routes"}` or `{"ok":false,"reason":"invalid_route\|route_exists\|route_blocked\|no_index\|root_absolute_paths\|host_missing\|artifact_missing\|out_not_empty\|copy_failed"}` |
| `route-host.sh record --org <slug\|-> --subdomain <s> --app-id <id> --access-mode <m> --deploy-id <id> --tarball <path>` | the uploaded tarball | `{"ok":true,"key","site","routes"}`; snapshot at `~/.hq/deploy-hosts/<org>/<subdomain>/` |

All scripts:
- Are deterministic and run in 0.3–0.5s
- Return exactly ONE line of JSON to stdout (except password-helper subcommands)
- Never echo JWTs, artifact contents, or matched PII
- Are forbidden by harness deny rules from being read directly — invocation is via Bash only

---

## Notes

- Auth tokens are never displayed in output — script returns JWT in JSON, main agent uses it in `Authorization: Bearer` headers only.
- The CLI at `repos/public/hq-deploy/cli/` remains for CI/CD pipelines (uses its own auth flow).
- For Vercel-managed projects, skip entirely.
- Respects company isolation — credentials resolved from active company context.
- Shared HQ Identity pool means one sign-in works across HQ's deploy, vault, and onboarding surfaces.

## Fleet agents (machine identity)

Fleet agents deploy through their own machine identity. When the agent runtime exposes a readable `HQ_MACHINE_CREDS_FILE` (or the standard `~/.hq-agent/machine-creds.json`), `/deploy` runs `hq-auth-refresh` to mint or refresh its cached session without opening a browser. The resolver supplies the Cognito ID token to both hq-deploy and vault membership resolution because that is where the agent identity claims live. The agent must be an active member of the target company; it cannot deploy to a personal scope. This ships in the next hq-core release. The fleet self-update runs about every six hours and re-runs `hq rescue --hq-root` to refresh the agent's HQ root.

## See also

- `/hq-share` — grant a teammate access to a vault path
- `/dm` — send the live link to someone
