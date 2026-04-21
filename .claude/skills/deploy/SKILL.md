---
name: deploy
description: Internal deploy engine — auto-deploys web artifacts to hq-deploy. Invoked by policy, not by user command.
allowed-tools: Read, Grep, Bash(tar:*), Bash(curl:*), Bash(npm:*), Bash(npx:*), Bash(bun:*), Bash(pnpm:*), Bash(yarn:*), Bash(docker:*), Bash(git:*), Bash(ls:*), Bash(cat:*), Bash(aws:*), Bash(jq:*), Bash(op:*), Bash(source:*), Edit, Write
---

# Deploy Engine

Internal skill for deploying web artifacts to hq-deploy infrastructure. This is NOT a user-facing command — it is triggered automatically by the `auto-deploy-on-create` policy when HQ produces a deployable artifact.

**Guiding principle:** The user never asked you to deploy. You noticed something deployable and are giving them a link as a bonus. Keep it quick, quiet, and casual.

**Seven-step flow:**

1. **Preferences** — honor `~/.hq/config.json`, project opt-outs, and exclusions
2. **Build** — framework detection + install + build
3. **Localhost preview** — always serves, signed in or not
4. **Identity check** — read Cognito session; if absent, spawn `hq auth login` via npx (browser popup); if that fails, upsell
5. **Guardrails** — size / file-count / complexity caps
6. **Upload** — presigned URL (static) or ECR push (SSR), with `Authorization: Bearer $JWT`
7. **Present the link** — one casual line, weave it into your response

---

## Step 1 — Preferences and Exclusions

Before doing any work, respect the user's stated preference and rule out projects that shouldn't deploy. Auto-deploy is opt-out.

### 1a. Read user preference

```bash
PREF_FILE="$HOME/.hq/config.json"
if [ -f "$PREF_FILE" ]; then
  DEPLOY_PREF=$(jq -r '.deploy.preference // "hq-deploy"' "$PREF_FILE" 2>/dev/null)
else
  DEPLOY_PREF="hq-deploy"   # default for greenfield HQ
fi
```

**Valid values:** `hq-deploy` (default), `vercel`, `netlify`, `custom`, `none`.

### 1b. Read per-project override

If the active project has a `prd.json` with `metadata.deploy: false`, treat it as `none`:

```bash
if [ -f "prd.json" ]; then
  PRD_DEPLOY=$(jq -r '.metadata.deploy // "unset"' prd.json 2>/dev/null)
  if [ "$PRD_DEPLOY" = "false" ]; then DEPLOY_PREF="none"; fi
fi
```

### 1c. Honor the preference

- `hq-deploy` → continue through the full flow
- `vercel`, `netlify`, `custom` → **silently stop** — the user has their own pipeline
- `none` → **silently stop** — skip the entire deploy flow including localhost preview

Do not mention that you considered deploying. Deploy is a bonus; silently abstaining is correct.

### 1d. Check Exclusions

Before proceeding, verify this artifact should be deployed:
- **Not a Vercel project**: check `manifest.yaml` `vercel_projects[]` — if the current project is listed, skip deploy (Vercel handles it)
- **Not a backend service**: no Dockerfile at root, no serverless.yml, no sst.config.*
- **Build is clean**: if tests or typecheck just ran and failed, skip

If any exclusion matches: silently skip. Do not tell the user you considered deploying.

### 1e. Resolve Context

| Thing | How |
|-------|-----|
| Company | cwd → `companies/manifest.yaml` lookup → default `indigo` |
| API endpoint | manifest `services.hq-deploy.endpoint` → `$HQ_DEPLOY_API` → `https://api.indigo-hq.com` |
| App name | `package.json` `name` → current directory name, slug-cased |

### 1f. Writing a preference on request

When the user says "I use Vercel", "I deploy with Netlify", "don't deploy my stuff", or similar, write the preference and acknowledge once:

```bash
mkdir -p "$HOME/.hq"
if [ -f "$PREF_FILE" ]; then
  jq '.deploy.preference = "vercel"' "$PREF_FILE" > "$PREF_FILE.tmp" && mv "$PREF_FILE.tmp" "$PREF_FILE"
else
  echo '{"deploy":{"preference":"vercel"}}' > "$PREF_FILE"
fi
```

Then say once (never twice):
> Got it — I won't offer auto-deploy. You can change this in `~/.hq/config.json`.

---

## Step 2 — Build

### 2a. Framework detection

| Priority | Framework | Config Files | Default Type |
|----------|-----------|-------------|--------------|
| 1 | Next.js | `next.config.{js,mjs,ts}` | SSR |
| 2 | Remix | `remix.config.{js,ts}`, `app/root.tsx` | SSR |
| 3 | Astro | `astro.config.{js,mjs,ts}` | Static (SSR if `output: 'server'`) |
| 4 | Vite | `vite.config.{js,ts,mjs}` | Static |
| 5 | Static HTML | `index.html` in output dir | Static |
| 6 | Fallback | — | Static |

### 2b. Install + Build

If the project was just built by the calling workflow (e.g., `/execute-task` already ran `npm run build`), skip — use existing output.

```bash
if   [ -f "bun.lockb" ] || [ -f "bun.lock" ]; then PM="bun"
elif [ -f "pnpm-lock.yaml" ]; then PM="pnpm"
elif [ -f "yarn.lock" ]; then PM="yarn"
else PM="npm"; fi

$PM install && $PM run build
```

If build fails: skip deploy silently. The calling workflow already handles build failures.

### 2c. Output Directory

| Framework | Static Output | SSR Output |
|-----------|--------------|------------|
| Next.js | `out/` (if `output: 'export'`) | `.next/` |
| Remix | `build/client/` | `build/` |
| Astro | `dist/` | `dist/` |
| Vite | `dist/` | — |
| Static | `dist/`, `build/`, `out/`, `public/`, `.` | — |

---

## Step 3 — Localhost Preview (always runs)

After build, spin up a local HTTP server serving the static output directory. This runs **before the identity check and before guardrails** — everyone gets a preview URL, signed-in or not.

### 3a. Pick a port

Default 4321. If occupied, scan upward (4321 → 4322 → 4323 ...) to the next available port.

```bash
PORT=4321
while lsof -iTCP:"$PORT" -sTCP:LISTEN -Pn >/dev/null 2>&1; do
  PORT=$((PORT + 1))
  [ "$PORT" -gt 4400 ] && break   # sane upper bound
done
```

### 3b. Start the server (backgrounded, tracked)

Use Node's built-in `http` module — no extra install needed. Serve the framework-detected output directory (`$OUTPUT_DIR` from Step 2c).

```bash
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
disown   # detach from shell so it survives tool call boundaries
```

### 3c. Announce the preview URL

Always print this — it's the guaranteed-working user feedback:

> Preview: http://localhost:{port}

Keep it in a visible line of your response. This is the user's instant feedback regardless of what happens next.

### 3d. Persistence + cleanup

- Server **stays open** until the session ends or the user explicitly stops it. Do NOT kill it after deploy.
- PID is tracked in `/tmp/hq-deploy-preview-$$.pid` so cleanup on session exit can find it (`kill $(cat /tmp/hq-deploy-preview-*.pid) 2>/dev/null`).
- If the user runs deploy again in the same session with a new build: re-use the port by killing the old PID, then restart on the same port. Do not accumulate orphan servers.

---

## Step 4 — Identity Check

The hq-deploy API is locked down (US-003): anonymous `/api/*` requests return 401. Before attempting any upload, read the local Cognito session. If it's valid, use the JWT. If it's expired, refresh it. If it's missing entirely, trigger an agent-spawned browser login via `npx hq auth login` (Step 4d) — the user never opens a terminal, just signs in to the browser popup and the deploy continues. Only if that fails do we serve the localhost preview and upsell the free HQ account.

**Localhost preview (Step 3) is NOT gated by identity — it always runs.** The identity gate only applies to the web deploy (Steps 5–7).

### 4a. Locate the session file

The `hq-cli` (and hq-cloud onboarding helper) write Cognito tokens on sign-in. The canonical path is `~/.hq/cognito-tokens.json` — that's what `saveCachedTokens()` in `@indigoai-us/hq-cloud` produces and what `hq auth refresh` / `hq-auth-refresh` reads. Some forks or pre-release installs may use `~/.hq/auth/session.json`; check both, prefer the canonical path.

```bash
SESSION_FILE=""
for candidate in "$HOME/.hq/cognito-tokens.json" "$HOME/.hq/auth/session.json"; do
  if [ -f "$candidate" ]; then SESSION_FILE="$candidate"; break; fi
done
```

Expected schema (either path):
```json
{
  "accessToken": "eyJraWQi...",
  "idToken":     "eyJraWQi...",
  "refreshToken": "eyJjdHki...",
  "expiresAt":   "2026-04-17T01:29:05.472Z",
  "tokenType":   "Bearer"
}
```

`accessToken` is what hq-deploy verifies (it runs `tokenUse: "access"` in `aws-jwt-verify`).

### 4b. Validate the session

```bash
if [ -z "$SESSION_FILE" ]; then
  JWT=""
else
  JWT=$(jq -r '.accessToken // empty' "$SESSION_FILE" 2>/dev/null)
  EXPIRES_AT=$(jq -r '.expiresAt // empty' "$SESSION_FILE" 2>/dev/null)

  if [ -n "$EXPIRES_AT" ]; then
    EXP_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%.*}" +%s 2>/dev/null \
                || date -d "$EXPIRES_AT" +%s 2>/dev/null)
    NOW=$(date +%s)
    if [ -n "$EXP_EPOCH" ] && [ "$EXP_EPOCH" -le "$NOW" ]; then
      JWT=""   # expired — attempt refresh below
    fi
  fi
fi
```

### 4c. Attempt refresh on expiry

If the access token is expired but a `refreshToken` is present, shell out to `hq-auth-refresh` (provided by `@indigoai-us/hq-cli` ≥5.4). It calls the shared Cognito pool's `/oauth2/token` endpoint with grant_type=refresh_token and rewrites `~/.hq/cognito-tokens.json`. Never implement the Cognito client inline.

**Agents must not require the CLI to be pre-installed.** Prefer a local bin if present; otherwise fall back to `npx` so any Node-enabled environment can invoke the refresh on demand without the user having run `npm install -g` beforehand.

```bash
if [ -z "$JWT" ] && [ -f "$SESSION_FILE" ]; then
  REFRESH=$(jq -r '.refreshToken // empty' "$SESSION_FILE" 2>/dev/null)
  if [ -n "$REFRESH" ]; then
    REFRESH_CMD=""
    if command -v hq-auth-refresh >/dev/null 2>&1; then
      REFRESH_CMD="hq-auth-refresh"
    elif command -v npx >/dev/null 2>&1; then
      # First-run downloads the package into npm cache (~10s);
      # subsequent runs hit the cache.
      REFRESH_CMD="npx -y --package=@indigoai-us/hq-cli hq-auth-refresh"
    fi
    if [ -n "$REFRESH_CMD" ]; then
      $REFRESH_CMD >/dev/null 2>&1 && JWT=$(jq -r '.accessToken // empty' "$SESSION_FILE" 2>/dev/null)
    fi
  fi
fi
```

If neither a local bin nor `npx` is available, silently fall through to the upsell. Do not prompt the user for credentials — sign-in is owned by `onboarding.indigo-hq.com`.

### 4d. Attempt interactive login (agent-triggered, once per session)

If refresh failed or no session exists at all, **try interactive login before falling back to the upsell**. Spawning `hq auth login` via `npx` opens Cognito's Hosted UI in the user's default browser — they sign in once, the token gets cached to `~/.hq/cognito-tokens.json`, and deploy continues on the same turn.

This is the "user never touched a terminal" path:

```
User:  "Deploy my dashboard to indigo-hq.com"
Agent: [runs deploy skill → hits Step 4d with no session]
       → tells the user "Opening HQ sign-in in your browser…"
       → spawns: npx -y --package=@indigoai-us/hq-cli hq auth login
       → browser pops open (Cognito Hosted UI)
       → user signs in (one-time, cached 30 days)
       → token file written → re-read → deploy continues
```

**Gate rules:**

- Only trigger once per session — record in `/tmp/hq-deploy-login-attempted-$USER`
- Only trigger if `npx` is available (almost always on a dev box; silently skip to upsell if not)
- Announce to the user BEFORE spawning: `"Opening HQ sign-in in your browser — one moment..."`
- Cap the wait at ~180s (background PID + killer) so a user who closes the browser doesn't hang the tool call. `hq auth login` has its own 15-min hard limit, but we don't want the deploy flow to wait that long.
- After the spawn returns, re-read `$HOME/.hq/cognito-tokens.json` and re-populate `$JWT`.

> ⚠️ Do NOT use `timeout 180 ...` — the `timeout` command is not available on macOS by default (it's GNU coreutils). Use the background-and-killer pattern below, which is portable across macOS and Linux.

```bash
LOGIN_ATTEMPTED_FILE="/tmp/hq-deploy-login-attempted-$USER"

if [ -z "$JWT" ] && [ ! -f "$LOGIN_ATTEMPTED_FILE" ] && command -v npx >/dev/null 2>&1; then
  touch "$LOGIN_ATTEMPTED_FILE"

  # Tell the user what's about to happen so the browser popup isn't unexpected.
  echo "Opening HQ sign-in in your browser — one moment..."

  # Spawn hq auth login as a background job; kill it after 180s if it hasn't exited.
  npx -y --package=@indigoai-us/hq-cli hq auth login &
  LOGIN_PID=$!

  ( sleep 180 && kill "$LOGIN_PID" 2>/dev/null ) &
  KILLER_PID=$!

  wait "$LOGIN_PID" 2>/dev/null || true
  kill "$KILLER_PID" 2>/dev/null; wait "$KILLER_PID" 2>/dev/null || true

  # Re-read session after login attempt — browserLogin() writes this file on success.
  if [ -f "$HOME/.hq/cognito-tokens.json" ]; then
    SESSION_FILE="$HOME/.hq/cognito-tokens.json"
    JWT=$(jq -r '.accessToken // empty' "$SESSION_FILE" 2>/dev/null)
  fi
fi
```

**Why `npx -y --package=...`:** the agent does NOT require the user to have previously run `npm install -g @indigoai-us/hq-cli`. `npx` downloads on first use (~10s) and caches, subsequent invocations are instant. The `--package=` flag is needed because the binary name (`hq`) differs from the package name (`@indigoai-us/hq-cli`).

### 4e. Branch on identity

| State | Action |
|-------|--------|
| Valid `$JWT` in scope | Continue to Step 5 (Guardrails). Carry `Authorization: Bearer $JWT` through all `/api/*` calls. |
| No `$JWT` after login attempt, user hasn't been upsold this session | Skip Steps 5–6. Emit the upsell message once. Present preview URL only. |
| No `$JWT`, already upsold this session | Skip Steps 5–6 silently. Present preview URL only. |

Track "already upsold" in a tmp file so it survives tool-call boundaries:

```bash
UPSOLD_FILE="/tmp/hq-deploy-upsold-$USER"
```

### 4f. Upsell copy (once per session, only if login didn't succeed)

When `$JWT` is still absent after 4d and `$UPSOLD_FILE` does not exist, emit exactly once — friendly, not blocking, not a nag. Phrase it as "create an account" (not "sign in") because reaching this branch means login failed — most likely the user doesn't have an account yet:

> Looks like you don't have an HQ account yet. Create one free at https://onboarding.indigo-hq.com and I'll deploy this to the web next time.

Then touch the upsold file so subsequent runs in the same session stay quiet:

```bash
touch "$UPSOLD_FILE"
```

Move on. The user got their preview URL; deploy is a bonus, not a blocker.

---

## Step 5 — Guardrails

Run these checks **before tarball creation** to fail fast on unsuitable artifacts. All rejections are silent — no error message, just skip. Deploy is a bonus.

### 5a. Detect full-app disqualifiers

These should already be caught in Step 1d exclusions, but re-verify at project root:

- **SSR framework:** if framework detection in Step 2a returned an SSR type (Next.js SSR, Remix SSR, Astro `output: 'server'`) → skip
- **Backend service files at project root:** `Dockerfile`, `serverless.yml`, `serverless.ts`, `sst.config.ts`, `sst.config.js`, `docker-compose.yml`, `docker-compose.yaml` → skip
- **Database tooling:** `prisma/` directory, `drizzle.config.ts`, `drizzle.config.js`, `knexfile.ts`, `knexfile.js`, `migrations/` directory → skip

```bash
for f in Dockerfile serverless.yml serverless.ts sst.config.ts sst.config.js \
         docker-compose.yml docker-compose.yaml \
         drizzle.config.ts drizzle.config.js knexfile.ts knexfile.js; do
  [ -f "$f" ] && exit 0    # silent skip
done
for d in prisma migrations; do
  [ -d "$d" ] && exit 0    # silent skip
done
```

### 5b. File count limit (post-build, pre-tarball)

```bash
FILE_COUNT=$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -gt 100 ]; then exit 0; fi   # silent skip
```

**Limit: 100 files max** (excluding directories). If exceeded, the artifact is a full app, not a static page — skip.

### 5c. Size limit (tarball-gzip)

```bash
tar -czf /tmp/hq-deploy-upload.tar.gz -C "$OUTPUT_DIR" .
TARBALL_SIZE=$(stat -f%z /tmp/hq-deploy-upload.tar.gz 2>/dev/null \
               || stat -c%s /tmp/hq-deploy-upload.tar.gz)
if [ "$TARBALL_SIZE" -gt 10485760 ]; then
  rm -f /tmp/hq-deploy-upload.tar.gz
  exit 0    # silent skip — over 10MB gzipped
fi
```

**Limit: 10MB max (gzip compressed).**

### 5d. Existing exclusions preserved

The Step 1d exclusions still apply:
- Vercel-managed projects (`manifest.yaml` `vercel_projects[]`)
- Projects with `metadata.deploy: false` in prd.json

---

## Step 6 — Upload

Every request carries `Authorization: Bearer $JWT` — verified against the shared HQ Identity Cognito pool by hq-deploy's `resolveAuth` resolver.

### 6a. Ensure App Exists

```bash
APP_ID=$(curl -s -H "Authorization: Bearer $JWT" \
  "$API/api/apps" | jq -r '.[] | select(.name == "'"$APP_NAME"'") | .id')

if [ -z "$APP_ID" ]; then
  APP_ID=$(curl -s -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d '{"name": "'"$APP_NAME"'"}' \
    "$API/api/apps" | jq -r '.id')
fi
```

### 6b. Upload — Static (presigned URL)

```bash
TARBALL_SHA256=$(shasum -a 256 /tmp/hq-deploy-upload.tar.gz | cut -d' ' -f1)

DEPLOY_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"appSlug\": \"$APP_SUBDOMAIN\", \"org\": \"indigo\", \"manifest\": {\"files\": [], \"size\": $TARBALL_SIZE, \"sha256\": \"$TARBALL_SHA256\"}}" \
  "$API/api/deploys")

DEPLOY_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.deployId')
PRESIGNED_URL=$(echo "$DEPLOY_RESPONSE" | jq -r '.presignedUrl')

# Upload is directly to S3 — no Authorization header on this PUT (presigned URL carries its own signature)
curl -s -X PUT \
  -H "Content-Type: application/gzip" \
  --data-binary @/tmp/hq-deploy-upload.tar.gz \
  "$PRESIGNED_URL"

COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"appSlug\": \"$APP_SUBDOMAIN\"}" \
  "$API/api/deploys/$DEPLOY_ID/complete")

LIVE_URL=$(echo "$COMPLETE_RESPONSE" | jq -r '.url')
rm -f /tmp/hq-deploy-upload.tar.gz
```

### 6c. Upload — SSR (ECR image)

```bash
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "$ECR_URI"
docker build -t "$APP_NAME:$VERSION" .
docker tag "$APP_NAME:$VERSION" "$ECR_URI/$APP_NAME:$VERSION"
docker push "$ECR_URI/$APP_NAME:$VERSION"

curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"image_tag": "'"$VERSION"'", "deploy_type": "ssr"}' \
  "$API/api/apps/$APP_ID/deploy"
```

### 6d. 401 handling

If any `/api/*` call returns 401, the session is stale (expired between Step 4 check and now). Fall back to the "no JWT" branch of Step 4e — present the preview, upsell if not already shown, and stop. Do not re-trigger `hq auth login` mid-deploy (we already attempted it in 4d) and do not retry uploads indefinitely.

---

## Step 7 — Present the Link

This is the only user-visible output from the entire deploy. Keep it casual and brief.

**On success** — weave the URL naturally into your response:
- "Here's a link you can share: https://{app}.indigo-hq.com"
- "The docs are live at https://{app}.indigo-hq.com"
- "Deployed to https://{app}.indigo-hq.com"

Do NOT print a deploy report, duration, file count, version, or status block. Just the link.

**On upload failure** (after auth worked) — one line, no drama:
- "Deploy to hq-deploy didn't go through, but everything else is done."

**On no-identity path** — you already emitted the preview URL in Step 3c and either triggered login (4d) or upsold (4f). Nothing to add here.

Then move on. Deploy is never the main event.

---

## Notes

- Auth tokens are never displayed in output — pipe to files or use env vars
- The CLI at `repos/public/hq-deploy/cli/` remains for CI/CD pipelines (uses its own auth flow)
- For Vercel-managed projects, skip entirely (Vercel handles those)
- Respects company isolation — credentials resolved from active company context
- Shared HQ Identity pool (US-002) means one onboarding.indigo-hq.com sign-in works across hq-deploy, hq-pro, hq-onboarding
