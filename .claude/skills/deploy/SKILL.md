---
name: deploy
description: Deploy or share generated HQ artifacts through hq-deploy.
allowed-tools: Read, Grep, Bash(tar:*), Bash(curl:*), Bash(npm:*), Bash(npx:*), Bash(bun:*), Bash(pnpm:*), Bash(yarn:*), Bash(docker:*), Bash(git:*), Bash(ls:*), Bash(cat:*), Bash(aws:*), Bash(jq:*), Bash(op:*), Bash(source:*), Bash(pbcopy:*), Bash(chmod:*), Bash(node:*), Bash(lsof:*), Bash(mkdir:*), Bash(echo:*), Bash(wait:*), Bash(disown:*), Bash(test:*), Bash(touch:*), Bash(rm:*), Bash(paste:*), Bash(.claude/skills/deploy/scripts/identity-resolve.sh:*), Bash(.claude/skills/deploy/scripts/sensitivity-check.sh:*), Bash(.claude/skills/deploy/scripts/guardrails-check.sh:*), Bash(.claude/skills/deploy/scripts/deploy-api-request.sh:*), Bash(.claude/skills/deploy/scripts/og-inject.sh:*), Bash(.claude/skills/deploy/scripts/password-helper.sh:*), Edit, Write
---

# Deploy Engine

Skill for deploying web artifacts to hq-deploy infrastructure. Invoked directly via `/deploy`, or auto-triggered by `auto-deploy-on-create` (silent post-build) and `hq-deploy-reinforcement` (intent-to-share, deliverable PRDs) policies. The two paths share this same engine.

**Guiding principle:** quick casual handoff — preview, upload, link. Sensitive artifacts get the lowest-friction appropriate gate: password, Cognito company access, or an email allowlist when the user names recipients.

## Access modes (reference)

Every deployed app has exactly one edge access mode. New policy-aware deploys prefer the first-class access-policy endpoint for Cognito gates; the legacy access-mode endpoint remains the right path for password and email/domain allowlists.

| Mode | When to pick it | What it does |
|---|---|---|
| `public` | Default. Casual handoff, anyone with the link. | No gate. App serves immediately. |
| `password` | Sensitive content, casual share over Slack/email, recipients unknown ahead of time. | App owner sets a password (Argon2id-hashed). Visitors land on `hq.{your-domain}.com/__access`, enter the password, get a 24h `hq-access` JWT cookie scoped to `.{your-domain}.com`. |
| `company` | Internal/company-only share; user says "restricted to org", "internal-only", "company-only"; or config prefers org-restricted deploys. | Visitors sign in with HQ Cognito on `hq.{your-domain}.com/__access`; the HQ access service checks active membership in the app's company before minting a policy-versioned `hq-access` cookie. |
| `selected` | Specific HQ people/groups when the caller has resolvable HQ directory IDs. | Same Cognito flow as `company`, but only selected user/group IDs in the policy are accepted. Use only when IDs are known from the HQ directory, not from free-form names. |
| `private` | Legacy sensitive sharing for **known recipients by email/domain** when Cognito company membership is not the desired gate. | Visitors must be signed in to hq-auth (`auth.{your-domain}.com`) AND their email must be on the app's allowlist. Lands on `hq.{your-domain}.com/__private`, which checks the session + allowlist and mints the same `hq-access` JWT. |

Pick `company` when the user asks for org/company/internal restriction. Pick `private` over `password` when the user gives concrete email/domain recipients (`"share with [EMAIL] and the @example.com team"`) and did not ask for company-wide Cognito access. Pick `password` when sensitivity is detected but recipients are unspecified and config does not prefer org restriction.

**Canonical mutation endpoint** for switching between modes:
- `POST /api/apps/:id/access-mode {mode, password?}` — atomic; clears the fields that don't belong to the chosen mode; **wipes EmailGrant rows when leaving `private`** so orphans can't silently re-activate on a future flip back.
- `PUT /api/apps/:id/access-policy {mode, companyUid, users?, groups?, password?}` — first-class policy endpoint for `company`, `selected`, and policy-versioned `password`. Use this for Cognito org gates.

**Legacy path gotcha:** `PATCH /api/apps/:id {passwordProtected, password}` is rejected with `409 ACCESS_MODE_CONFLICT` when the app is currently in `private` mode. Always use `/access-mode` to change modes; reserve PATCH for in-mode password rotation.

**Email allowlist CRUD** (only relevant in `private` mode):
- `GET    /api/apps/:id/allowed-emails`
- `POST   /api/apps/:id/allowed-emails  {email}` — accepts an exact address (`[EMAIL]`) or a `@domain.tld` pattern; idempotent; lowercased server-side.
- `DELETE /api/apps/:id/allowed-emails/{patternKey}` — `patternKey` URL-encoded.

---

## Architecture: Three Phases, Inline Parallel Scripts

The engine is **three phases**, structured by data-dependency. Independent work runs in parallel via bash background jobs; I/O-heavy decisions live in inline scripts (no Task sub-agents — they cost 3–5s of spawn overhead each and the JWT/verdicts have to flow back to main anyway).

| Phase | What runs | Parallelism |
|-------|-----------|-------------|
| **Step 1** | Preferences + exclusions (gate) | inline, sequential |
| **Phase A** | Framework detect + **design pass** (A.1.5, generated static only) → Build (inline) ‖ Identity (script) ‖ Sensitivity (script) | detect + design sync, then 3-way parallel via `&` + `wait` |
| **Phase B** | Localhost preview (inline-bg) ‖ Guardrails (script) | 2-way parallel via `&` + `wait` |
| **Phase C** | Password gen → upload → wire password → announce → present link | sequential, hard-gated |

**Hard ordering constraints (preserved from `core/policies/hq-deploy-reinforcement.md`):**

- Identity (Phase A) MUST complete before Upload (Phase C)
- Guardrails (Phase B) MUST gate Upload (Phase C)
- Upload (Phase C) returns `appId` which MUST exist before password persist + announce
- Localhost preview (Phase B) is NEVER gated by identity — always runs
- **Design pass (A.1.5) MUST complete before Build/Guardrails package the artifact** — it restyles the generated static source in place, so it runs synchronously right after framework detection and before the Phase A fan-out

**Inline helper scripts** (each is self-contained, returns one JSON line on stdout):

| Script | Purpose | Returns |
|--------|---------|---------|
| `.claude/skills/deploy/scripts/identity-resolve.sh` | Resolves Cognito JWT (cache → refresh → login); jq preferred, node via `hook-lib.sh` | `{"status":"ok"\|"login_required"\|"missing_dependency",...}` |
| `.claude/skills/deploy/scripts/sensitivity-check.sh <path> [user_msg]` | Classifies artifact sensitivity (filename-list grep, no content surfaces) | `{"sensitive":bool,"trigger":string\|null}` |
| `.claude/skills/deploy/scripts/guardrails-check.sh <output_dir>` | Caps + builds tarball | `{"pass":bool,"reason":string\|null,"tarball_path":string,...}` |
| `.claude/skills/deploy/scripts/deploy-api-request.sh` | Makes a checked Phase C API/S3 request | validated body on stdout; safe failure diagnostic on stderr |
| `.claude/skills/deploy/scripts/og-inject.sh <output_dir> [base_url] [app_name]` | Injects OG/Twitter preview tags; generates a 1200x630 card image when none exists | `{"injected":int,"image":string,"changed":bool}` |
| `.claude/skills/deploy/scripts/password-helper.sh` | `gen` / `announce` / `persist` / `lookup` | password text, or persisted entry |

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
  LOGIN_REASON="missing_jq_and_node"
  SENSITIVE="false"
  SENSITIVITY_TRIGGER=""
  BUILD_STATUS="fail"
else
  IDENTITY_STATUS=$(printf '%s' "$IDENTITY_JSON" | hq_json_get status)
  JWT=$(printf '%s' "$IDENTITY_JSON" | hq_json_get jwt)
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
  # (feedback_1e8d78ed / DEV-1843: Nanit dashboard). resolve-deploy-org.sh turns
  # the /membership/me body into ORG_SLUG / ORG_RESOLUTION_STATE / PERSONAL_SCOPE
  # / ACTIVE_SLUGS / ACTIVE_COMPANY_UID (single active -> slug; none -> personal;
  # many -> multi-org CTA; missing jq -> missing_dependency, NEVER personal).
  MEMBERSHIPS_JSON=$(curl -s -H "Authorization: Bearer $JWT" "$VAULT_API/membership/me")
  eval "$(printf '%s' "$MEMBERSHIPS_JSON" \
    | .claude/skills/deploy/scripts/resolve-deploy-org.sh)"

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

After A.5, Phase C upload proceeds when **either** `$ORG_SLUG` is set (company deploy) **or** `PERSONAL_SCOPE=true` (signed-in user with no company → personal deploy). Every hq-deploy API call passes `"${DEPLOY_CONTEXT_ARGS[@]}"` to `deploy-api-request.sh`, which adds `X-Org-Slug` for company deploys and `X-HQ-Deploy-Scope: personal` for personal deploys. Never silently fall back to a hardcoded org. The remaining unresolved states (`multi-org`, `missing_dependency`, vault-unreachable) skip the upload and hit the state-aware CTA at C.5, which reads `$ORG_RESOLUTION_STATE`.

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

Walks `$OUTPUT_DIR`, applies caps, builds tarball, returns path + size + sha256.

```bash
T_GUARDRAILS=$(mktemp -t hq-deploy-guardrails.XXXXXX)
.claude/skills/deploy/scripts/guardrails-check.sh "$OUTPUT_DIR" > "$T_GUARDRAILS" 2>/dev/null &
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

Every API call carries `Authorization: Bearer $JWT`.

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
    NEW_TAR=$(mktemp -t hq-deploy-tar.XXXXXX).tar.gz
    tar -czf "$NEW_TAR" -C "$OUTPUT_DIR" . 2>/dev/null
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
rm -f "$TARBALL_PATH"
```

#### App upload (backend `api/*` → per-app Lambda)

When `DEPLOY_TYPE=app` (a root `api/` dir was detected in A.1), the app ships a
static frontend **and** backend `api/*` handlers. The client-side flow is the
**same presigned-tarball upload as static** — tar the whole build (frontend +
`api/` dir) and push it through `POST /api/deploys` → S3 PUT → `…/complete`
exactly as in "Static upload" above. The control plane does the backend work:
it esbuild-bundles `api/**/*.{ts,js}` into a per-app Lambda, mounts it behind a
shared front-door HTTP API, and maps the app's subdomain to it. There is **no**
Docker/ECR/ECS step — `app` is distinct from the dormant SSR path.

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

`deploy-api-request.sh` is the only Phase C request path. On a non-2xx response it
stops the phase before a later request runs and reports the stage, method,
sanitized URL, status, API code/message, request ID, and non-secret org/scope.
It strips Authorization values and the full query string (including presigned S3
credentials). A 401 is explicitly marked `auth=stale-login action=preview-only`:
fall back to the no-upload branch, present preview, and do not re-trigger login
mid-deploy. A 403 is marked `authorization=forbidden` with the target org/scope
so authorization failures are not mistaken for malformed responses.

### C.3 — Wire access mode (sensitive only)

After upload, with `appId` in hand. Branch on `ACCESS_MODE`. Use `PUT /access-policy` for first-class Cognito policy modes (`company`, `selected`, policy-versioned password); use `POST /access-mode` for legacy password/private transitions and allowlist cleanup.

For grantee validation, send the id token when available. `identity-resolve.sh` returns the hq-deploy access token as `$JWT`; read the companion id token from the local token file only inside the shell and never echo it.

```bash
TOKEN_FILE="$HOME/.hq/cognito-tokens.json"
HQ_PRO_JWT=""
if [ -f "$TOKEN_FILE" ]; then
  HQ_PRO_JWT=$(jq -r '.idToken // .accessToken // empty' "$TOKEN_FILE" 2>/dev/null)
fi
HQ_PRO_REQUEST_HEADERS=()
[ -n "$HQ_PRO_JWT" ] && HQ_PRO_REQUEST_HEADERS=(--header "X-HQ-Pro-Authorization: Bearer $HQ_PRO_JWT")

if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "password" ]; then
  deploy_request access-mode-password --method POST \
    --url "$API/api/apps/$APP_ID/access-mode" \
    --header 'Content-Type: application/json' \
    --data "{\"mode\": \"password\", \"password\": \"$PW\"}" >/dev/null || exit 1
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "company" ]; then
  COMPANY_UID=$(curl -sS -H "Authorization: Bearer ${HQ_PRO_JWT:-$JWT}" \
    "$VAULT_API/entity/by-slug/company/$ORG_SLUG" \
    | jq -r '.entity.uid // empty' 2>/dev/null)
  if [ -z "$COMPANY_UID" ]; then
    echo "[deploy] company access requested but companyUid could not be resolved for $ORG_SLUG; falling back to password mode." >&2
    PW=${PW:-$(.claude/skills/deploy/scripts/password-helper.sh gen)}
    ACCESS_MODE=password
    deploy_request access-mode-password-fallback --method POST \
      --url "$API/api/apps/$APP_ID/access-mode" \
      --header 'Content-Type: application/json' \
      --data "{\"mode\": \"password\", \"password\": \"$PW\"}" >/dev/null || exit 1
  else
    deploy_request access-policy-company --method PUT \
      --url "$API/api/apps/$APP_ID/access-policy" \
      "${HQ_PRO_REQUEST_HEADERS[@]}" --header 'Content-Type: application/json' \
      --data "{\"mode\":\"company\",\"companyUid\":\"$COMPANY_UID\",\"users\":[],\"groups\":[]}" >/dev/null || exit 1
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
fallback with the same checks; if that also cannot be proven, fail the deploy
closed rather than reporting a potentially public artifact.

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
| `identity-resolve.sh` | (none — reads `~/.hq/cognito-tokens.json`) | `{"status":"ok","jwt":"...","expires_at":<epoch-ms>,"source":"cache\|refresh\|login"}` or `{"status":"login_required","reason":"..."}` or `{"status":"missing_dependency","dep":"jq\|node","install":"..."}` (agent must show install help, not login upsell) |
| `sensitivity-check.sh <path> [user_msg]` | artifact path + latest user message excerpt | `{"sensitive":bool,"trigger":"companies-data-path\|private-repo\|pii-detected\|financial-filename\|user-stated-private"\|null}` |
| `guardrails-check.sh <output_dir>` | build output directory | `{"pass":bool,"reason":string\|null,"tarball_path":string,"size_bytes":int,"sha256":string,"file_count":int}` |
| `og-inject.sh <output_dir> [base_url] [app_name]` | static build dir (+ live base URL) | `{"injected":int,"image":"generated\|existing\|none","changed":bool}` |
| `password-helper.sh gen` | — | `<adjective-noun-NN>` on stdout |
| `password-helper.sh announce <slug> <pw> [trigger]` | slug + password | stderr message + pbcopy + writes `~/.hq/deploy-passwords.json` |

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

## See also

- `/hq-share` — grant a teammate access to a vault path
- `/dm` — send the live link to someone
