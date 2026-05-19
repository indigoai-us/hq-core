---
name: deploy
description: Deploy engine for hq-deploy — invoked directly via /deploy, or auto-triggered by the auto-deploy-on-create / hq-deploy-reinforcement policies when HQ produces a deployable artifact.
allowed-tools: Read, Grep, Bash(tar:*), Bash(curl:*), Bash(npm:*), Bash(npx:*), Bash(bun:*), Bash(pnpm:*), Bash(yarn:*), Bash(docker:*), Bash(git:*), Bash(ls:*), Bash(cat:*), Bash(aws:*), Bash(jq:*), Bash(op:*), Bash(source:*), Bash(pbcopy:*), Bash(chmod:*), Bash(node:*), Bash(lsof:*), Bash(mkdir:*), Bash(echo:*), Bash(wait:*), Bash(disown:*), Bash(test:*), Bash(touch:*), Bash(rm:*), Bash(paste:*), Bash(.claude/skills/deploy/scripts/identity-resolve.sh:*), Bash(.claude/skills/deploy/scripts/sensitivity-check.sh:*), Bash(.claude/skills/deploy/scripts/guardrails-check.sh:*), Bash(.claude/skills/deploy/scripts/password-helper.sh:*), Edit, Write
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
| `company` | Internal/company-only share; user says "restricted to org", "internal-only", "company-only"; or config prefers org-restricted deploys. | Visitors sign in with HQ Cognito on `hq.{your-domain}.com/__access`; hq-console checks active membership in the app's company before minting a policy-versioned `hq-access` cookie. |
| `selected` | Specific HQ people/groups when the caller has resolvable hq-pro IDs. | Same Cognito flow as `company`, but only selected user/group IDs in the policy are accepted. Use only when IDs are known from hq-pro, not from free-form names. |
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
| **Phase A** | Build (inline) ‖ Identity (script) ‖ Sensitivity (script) | 3-way parallel via `&` + `wait` |
| **Phase B** | Localhost preview (inline-bg) ‖ Guardrails (script) | 2-way parallel via `&` + `wait` |
| **Phase C** | Password gen → upload → wire password → announce → present link | sequential, hard-gated |

**Hard ordering constraints (preserved from `core/policies/hq-deploy-reinforcement.md`):**

- Identity (Phase A) MUST complete before Upload (Phase C)
- Guardrails (Phase B) MUST gate Upload (Phase C)
- Upload (Phase C) returns `appId` which MUST exist before password persist + announce
- Localhost preview (Phase B) is NEVER gated by identity — always runs

**Inline helper scripts** (each is self-contained, returns one JSON line on stdout):

| Script | Purpose | Returns |
|--------|---------|---------|
| `.claude/skills/deploy/scripts/identity-resolve.sh` | Resolves Cognito JWT (cache → refresh → login) | `{"status":"ok"\|"login_required",...}` |
| `.claude/skills/deploy/scripts/sensitivity-check.sh <path> [user_msg]` | Classifies artifact sensitivity (filename-list grep, no content surfaces) | `{"sensitive":bool,"trigger":string\|null}` |
| `.claude/skills/deploy/scripts/guardrails-check.sh <output_dir>` | Caps + builds tarball | `{"pass":bool,"reason":string\|null,"tarball_path":string,...}` |
| `.claude/skills/deploy/scripts/password-helper.sh` | `gen` / `announce` / `persist` / `lookup` | password text, or persisted entry |

All scripts are deterministic, run in 0.3–0.5s, and never echo JWTs / artifact contents / matched PII.

---

## Step 1 — Preferences and Exclusions

Auto-deploy is opt-out. Honor user preference and rule out projects that shouldn't deploy.

### 1a. Read user preference

`$PREF_FILE` is `~/.hq/deploy-prefs.json` — a file owned exclusively by `/deploy`. The legacy `~/.hq/config.json` is read-only here (backwards compat) and never written by this skill: that path is owned by HQ Sync's strict `HqConfig` serde struct, and overlapping writers caused the menubar to bail on every sync (see `feedback_3ab4f113-2e7c-4e4e-a171-771b47a2b5fd`).

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
| Org (`$ORG_SLUG`) | Resolution chain below — never default to a hardcoded org |
| API endpoint | manifest `services.hq-deploy.endpoint` → `$HQ_DEPLOY_API` → `https://api.indigo-hq.com` |
| App name | `package.json` `name` → current directory name, slug-cased |

#### Org resolution chain

The org the deploy targets MUST be resolved — never fall back to a hardcoded slug. Walk these priorities in order until one produces `$ORG_SLUG`. Priorities 1–4 don't need a JWT and run here; Priority 5 needs `$JWT` and runs in **A.5** after the Phase A barrier. Priority 6 is the state-aware CTA path when nothing resolves.

| Priority | Source | Notes |
|---|---|---|
| 1 | `--org=<slug>` arg or `HQ_ORG` env | Explicit one-off override |
| 2 | Agent-supplied via session context | Agent sets `HQ_ORG` before invoking when conversation clearly implies a company |
| 3 | cwd → `companies/{slug}/…` segment | Running inside HQ tree |
| 4 | `~/.hq/deploy-prefs.json` `defaultOrg` field | Persisted choice (legacy `~/.hq/config.json` read as fallback for backwards-compat) |
| 5 | Single active vault membership | Auto-resolved + auto-written to `defaultOrg` (runs in A.5) |
| 6 | State-aware CTA (A/B/C — see C.5) | Preview already shown; skip upload |

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

# Package manager
if   [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then PM="bun"
elif [ -f "pnpm-lock.yaml" ]; then PM="pnpm"
elif [ -f "yarn.lock" ]; then PM="yarn"
else PM="npm"; fi
```

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

IDENTITY_STATUS=$(echo "$IDENTITY_JSON" | jq -r '.status')
JWT=$(echo "$IDENTITY_JSON" | jq -r '.jwt // empty')
LOGIN_REASON=$(echo "$IDENTITY_JSON" | jq -r '.reason // empty')

SENSITIVE=$(echo "$SENSITIVITY_JSON" | jq -r '.sensitive')
SENSITIVITY_TRIGGER=$(echo "$SENSITIVITY_JSON" | jq -r '.trigger // empty')

BUILD_STATUS=$(echo "$BUILD_JSON" | jq -r '.status')
```

### A.4 — Phase A barrier rules

- `BUILD_STATUS == "fail"` → abort the deploy entirely (silent skip). Localhost preview also skipped.
- `IDENTITY_STATUS == "login_required"` → mark Phase C upload as no-op; Phase B preview still runs.
- `SENSITIVE == "true"` → choose an access mode for Phase C:
  - If the latest user message asks for org/company/internal restriction (`"restricted to org"`, `"company-only"`, `"internal-only"`, `"HQ members only"`), set `ACCESS_MODE=${DEPLOY_ACCESS_INTERNAL_DEFAULT:-company}`.
  - Else if the latest user message names specific recipients (`"share with alice@…"`, `"@example.com only"`, `"private to the design team"`), set `ACCESS_MODE=private` and parse the recipient list into `ALLOW_PATTERNS` (newline-separated, each either `[EMAIL]` or `@domain.tld`).
  - Else if `DEPLOY_ORG_RESTRICTED_BY_DEFAULT=true` or `DEPLOY_ACCESS_SENSITIVE_DEFAULT=company`, set `ACCESS_MODE=company`.
  - Otherwise set `ACCESS_MODE=password` — the historical default for sensitive auto-deploy.

The Identity script owns the one-shot login attempt internally (`/tmp/hq-deploy-login-attempted-$USER`); the main agent does NOT re-trigger login mid-deploy.

### A.5 — Resolve org via vault (Priority 5) and flag CTA state (Priority 6)

If `$ORG_SLUG` is still empty after Step 1e (Priorities 1–4) AND identity returned `ok` (`$JWT` is in scope), ask vault directly. The same person/membership endpoints the API middleware uses are publicly callable with the user's JWT.

This block is no-op when:
- `$ORG_SLUG` already resolved in Step 1e (the common path — no extra round-trip)
- `IDENTITY_STATUS != "ok"` (no JWT — Phase C is already a no-op; State A handled at C.5)

```bash
VAULT_API="${VAULT_API_URL:-https://4nfy67z28h.execute-api.us-east-1.amazonaws.com}"
ORG_RESOLUTION_STATE=""
ACTIVE_SLUGS=""

if [ -z "$ORG_SLUG" ] && [ "$IDENTITY_STATUS" = "ok" ] && [ -n "$JWT" ]; then
  PERSON_UID=$(curl -s -H "Authorization: Bearer $JWT" \
    "$VAULT_API/entity/by-type/person" \
    | jq -r '.entities[0].uid // empty' 2>/dev/null)

  if [ -n "$PERSON_UID" ]; then
    MEMBERSHIPS_JSON=$(curl -s -H "Authorization: Bearer $JWT" \
      "$VAULT_API/membership/person/$PERSON_UID")
    ACTIVE=$(echo "$MEMBERSHIPS_JSON" \
      | jq -r '[.memberships[]? | select(.status=="active")]' 2>/dev/null)
    COUNT=$(echo "$ACTIVE" | jq 'length' 2>/dev/null)

    case "$COUNT" in
      1)
        COMPANY_UID=$(echo "$ACTIVE" | jq -r '.[0].companyUid')
        ORG_SLUG=$(curl -s -H "Authorization: Bearer $JWT" \
          "$VAULT_API/entity/$COMPANY_UID" \
          | jq -r '.entity.slug // empty' 2>/dev/null)
        # Persist as defaultOrg so future deploys skip the vault round-trip.
        # Written to ~/.hq/deploy-prefs.json — never to ~/.hq/config.json, which
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
        ;;
      0)
        ORG_RESOLUTION_STATE="no-orgs"
        ;;
      *)
        ORG_RESOLUTION_STATE="multi-org"
        # Best-effort: collect company slugs for the CTA, capped at 5 in
        # the user-facing message so it stays readable.
        for uid in $(echo "$ACTIVE" | jq -r '.[].companyUid'); do
          SLUG=$(curl -s -H "Authorization: Bearer $JWT" \
            "$VAULT_API/entity/$uid" | jq -r '.entity.slug // empty' 2>/dev/null)
          [ -n "$SLUG" ] && ACTIVE_SLUGS="${ACTIVE_SLUGS:+$ACTIVE_SLUGS, }$SLUG"
        done
        ;;
    esac
  fi
fi
```

After A.5, Phase C upload is gated additionally by `ORG_SLUG` being set — never silently fall back to a hardcoded org. The CTA at C.5 reads `$ORG_RESOLUTION_STATE` to pick the right copy.

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
- A.5: `$ORG_SLUG` is non-empty (otherwise skip upload, jump to C.5 with the appropriate state-aware CTA — see C.5)
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
# GET /api/apps returns {apps: [...]}
APP_ID=$(curl -s -H "Authorization: Bearer $JWT" \
  "$API/api/apps" | jq -r --arg name "$APP_NAME" '.apps[] | select(.name == $name) | .id' | head -1)

if [ -z "$APP_ID" ]; then
  # POST /api/apps requires {name, type}
  APP_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$APP_NAME\", \"type\": \"$DEPLOY_TYPE\"}" \
    "$API/api/apps")
  APP_ID=$(echo "$APP_RESPONSE" | jq -r '.id')
  APP_SUBDOMAIN=$(echo "$APP_RESPONSE" | jq -r '.subdomain')
fi
```

#### Static upload (presigned URL)

The Guardrails script already produced `$TARBALL_PATH`, `$TARBALL_SIZE`, `$TARBALL_SHA256` — reuse them, do not re-tar:

```bash
DEPLOY_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"appSlug\": \"$APP_SUBDOMAIN\", \"org\": \"$ORG_SLUG\", \"manifest\": {\"files\": [], \"size\": $TARBALL_SIZE, \"sha256\": \"$TARBALL_SHA256\"}}" \
  "$API/api/deploys")

DEPLOY_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.deployId')
PRESIGNED_URL=$(echo "$DEPLOY_RESPONSE" | jq -r '.presignedUrl')

# Direct S3 PUT — presigned URL carries its own signature, no Authorization header
curl -s -X PUT \
  -H "Content-Type: application/gzip" \
  --data-binary @"$TARBALL_PATH" \
  "$PRESIGNED_URL"

COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"appSlug\": \"$APP_SUBDOMAIN\"}" \
  "$API/api/deploys/$DEPLOY_ID/complete")

LIVE_URL=$(echo "$COMPLETE_RESPONSE" | jq -r '.url')
rm -f "$TARBALL_PATH"
```

#### SSR upload (ECR image)

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$ECR_URI"
docker build -t "$APP_NAME:$VERSION" .
docker tag "$APP_NAME:$VERSION" "$ECR_URI/$APP_NAME:$VERSION"
docker push "$ECR_URI/$APP_NAME:$VERSION"

curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"image_tag\": \"$VERSION\", \"deploy_type\": \"ssr\"}" \
  "$API/api/apps/$APP_ID/deploy"
```

#### 401 handling

If any `/api/*` call returns 401, the JWT went stale between Phase A and now. Fall back to the no-upload branch — present preview, upsell if not already shown, stop. Do NOT re-trigger login mid-deploy.

### C.3 — Wire access mode (sensitive only)

After upload, with `appId` in hand. Branch on `ACCESS_MODE`. Use `PUT /access-policy` for first-class Cognito policy modes (`company`, `selected`, policy-versioned password); use `POST /access-mode` for legacy password/private transitions and allowlist cleanup.

For hq-pro validation, send the id token when available. `identity-resolve.sh` returns the hq-deploy access token as `$JWT`; read the companion id token from the local token file only inside the shell and never echo it.

```bash
TOKEN_FILE="$HOME/.hq/cognito-tokens.json"
HQ_PRO_JWT=""
if [ -f "$TOKEN_FILE" ]; then
  HQ_PRO_JWT=$(jq -r '.idToken // .accessToken // empty' "$TOKEN_FILE" 2>/dev/null)
fi
HQ_PRO_HEADER=()
[ -n "$HQ_PRO_JWT" ] && HQ_PRO_HEADER=(-H "X-HQ-Pro-Authorization: Bearer $HQ_PRO_JWT")

if [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "password" ]; then
  curl -sS -X POST "$API/api/apps/$APP_ID/access-mode" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "{\"mode\": \"password\", \"password\": \"$PW\"}" >/dev/null
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "company" ]; then
  COMPANY_UID=$(curl -sS -H "Authorization: Bearer ${HQ_PRO_JWT:-$JWT}" \
    "$VAULT_API/entity/by-slug/company/$ORG_SLUG" \
    | jq -r '.entity.uid // empty' 2>/dev/null)
  if [ -z "$COMPANY_UID" ]; then
    echo "[deploy] company access requested but companyUid could not be resolved for $ORG_SLUG; falling back to password mode." >&2
    PW=${PW:-$(.claude/skills/deploy/scripts/password-helper.sh gen)}
    ACCESS_MODE=password
    curl -sS -X POST "$API/api/apps/$APP_ID/access-mode" \
      -H "Authorization: Bearer $JWT" \
      -H "Content-Type: application/json" \
      -d "{\"mode\": \"password\", \"password\": \"$PW\"}" >/dev/null
  else
    curl -sS -X PUT "$API/api/apps/$APP_ID/access-policy" \
      -H "Authorization: Bearer $JWT" \
      "${HQ_PRO_HEADER[@]}" \
      -H "Content-Type: application/json" \
      -d "{\"mode\":\"company\",\"companyUid\":\"$COMPANY_UID\",\"users\":[],\"groups\":[]}" >/dev/null
  fi
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "selected" ]; then
  # SELECTED_USERS_JSON / SELECTED_GROUPS_JSON must be arrays of {id} objects
  # resolved from hq-pro. Do not invent IDs from display names.
  COMPANY_UID=${COMPANY_UID:-$(curl -sS -H "Authorization: Bearer ${HQ_PRO_JWT:-$JWT}" \
    "$VAULT_API/entity/by-slug/company/$ORG_SLUG" \
    | jq -r '.entity.uid // empty' 2>/dev/null)}
  curl -sS -X PUT "$API/api/apps/$APP_ID/access-policy" \
    -H "Authorization: Bearer $JWT" \
    "${HQ_PRO_HEADER[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"mode\":\"selected\",\"companyUid\":\"$COMPANY_UID\",\"users\":${SELECTED_USERS_JSON:-[]},\"groups\":${SELECTED_GROUPS_JSON:-[]}}" >/dev/null
elif [ "$SENSITIVE" = "true" ] && [ "$ACCESS_MODE" = "private" ]; then
  # Flip the app to private mode, then grant each pattern.
  curl -sS -X POST "$API/api/apps/$APP_ID/access-mode" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d '{"mode": "private"}' >/dev/null

  # ALLOW_PATTERNS is one pattern per line (set in A.4 from the user message).
  while IFS= read -r PATTERN; do
    [ -z "$PATTERN" ] && continue
    curl -sS -X POST "$API/api/apps/$APP_ID/allowed-emails" \
      -H "Authorization: Bearer $JWT" \
      -H "Content-Type: application/json" \
      -d "{\"email\": \"$PATTERN\"}" >/dev/null
  done <<< "$ALLOW_PATTERNS"
fi
```

**Legacy PATCH gotcha:** never call `PATCH /api/apps/:id {passwordProtected: true, password: ...}` on an app that may already be in `private` mode — it returns `409 ACCESS_MODE_CONFLICT` because the server refuses to bypass the mutex. The `/access-mode` endpoint above handles the transition cleanly.

#### Auth-gate verify (sensitive only)

```bash
if [ "$SENSITIVE" = "true" ]; then
  APP_JSON=$(curl -sS -H "Authorization: Bearer $JWT" "$API/api/apps/$APP_ID")
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

Failure handling: log to stderr, continue. Never auto-delete the deploy.

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

**On no-identity path** (Phase A returned `login_required`) — **State A**: preview URL was already emitted in Phase B; emit upsell once if `/tmp/hq-deploy-upsold-$USER` doesn't exist:

```bash
UPSOLD_FILE="/tmp/hq-deploy-upsold-$USER"
if [ ! -f "$UPSOLD_FILE" ]; then
  echo "Looks like you don't have an HQ account yet. Create one free at https://onboarding.indigo-hq.com and I'll deploy this to the web next time."
  touch "$UPSOLD_FILE"
fi
```

**On signed-in-but-org-unresolved path** (`IDENTITY_STATUS=ok` but `$ORG_SLUG` is empty after A.5): emit the appropriate state-aware CTA. Preview URL was already shown in Phase B, so the CTA pairs with that, not in place of it:

```bash
PREVIEW_URL=$(cat "$URLFILE" 2>/dev/null || echo "http://localhost:$PORT")
case "$ORG_RESOLUTION_STATE" in
  no-orgs)
    # State B — signed in, no companies yet
    echo "You're signed in but don't have any companies yet. Create or sync one (\`hq onboard\` or push your local companies/ folder) and I'll deploy this next time. Preview: $PREVIEW_URL"
    ;;
  multi-org)
    # State C — multiple memberships, no default
    echo "You're a member of multiple companies (${ACTIVE_SLUGS:-multiple}). Tell me which one to deploy to (\"deploy this to <slug>\") or set a default (\"make <slug> my default org\"). Preview: $PREVIEW_URL"
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
| `identity-resolve.sh` | (none — reads `~/.hq/cognito-tokens.json`) | `{"status":"ok","jwt":"...","expires_at":<epoch-ms>,"source":"cache\|refresh\|login"}` or `{"status":"login_required","reason":"..."}` |
| `sensitivity-check.sh <path> [user_msg]` | artifact path + latest user message excerpt | `{"sensitive":bool,"trigger":"companies-data-path\|private-repo\|pii-detected\|financial-filename\|user-stated-private"\|null}` |
| `guardrails-check.sh <output_dir>` | build output directory | `{"pass":bool,"reason":string\|null,"tarball_path":string,"size_bytes":int,"sha256":string,"file_count":int}` |
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
- Shared HQ Identity pool means one onboarding.indigo-hq.com sign-in works across hq-deploy, hq-pro, hq-onboarding.
