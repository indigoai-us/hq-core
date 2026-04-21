---
id: auto-deploy-on-create
title: Auto-deploy deployable artifacts on creation
scope: global
trigger: after-build, after-execute-task, after-run-project, after-prd
enforcement: soft
public: true
version: 2
created: 2026-04-05
updated: 2026-04-20
---

## Rule

When HQ creates or builds a web-servable artifact, automatically deploy it to hq-deploy and present the live URL. No user prompt needed — deploy is a default behavior, not a decision.

### Flow summary

The deploy skill runs a seven-step flow: **Preferences → Build → Localhost preview → Identity check → Guardrails → Upload → Present link**. Steps 1–3 always run for everyone (signed in or not). Steps 5–7 are gated by identity.

### When to deploy

1. **After a successful build** that produces web output (static HTML, SPA, or SSR bundle)
2. **After `/prd`** scaffolds a docs site (Astro + Starlight)
3. **After `/execute-task`** completes a story in a project that has a web-servable output
4. **After `/run-project`** finishes all stories in a deployable project
5. **After a worker** generates an HTML report or dashboard to `workspace/reports/` or `companies/{co}/data/`

### How to detect deployable output

An artifact is deployable if ANY of these are true:
- Has a framework config: `next.config.*`, `astro.config.*`, `vite.config.*`, `remix.config.*`
- Has static output in `dist/`, `build/`, `out/`, or `public/` containing `.html` files
- Is an HTML file or directory of HTML files generated as a report/dashboard

### Deploy behavior

1. **Just do it** — don't ask, don't confirm, don't announce you're about to deploy
2. Use the deploy skill (`skills/deploy/SKILL.md`) for framework detection, build, upload, and status
3. App name = project name or directory name, slug-cased (e.g., `hq-vault-docs`, `levelfit-dashboard`)
4. After deploy succeeds, present the link casually as part of your response:
   - "Here's a link you can share: https://{app}.indigo-hq.com"
   - Or inline: "The docs are live at https://{app}.indigo-hq.com"
5. If deploy fails, mention it in one line and continue — deploy is a bonus, not a blocker

### When NOT to deploy

- **Backend services** (Lambda, ECS, API, Docker containers) — these have their own workflows
- **Vercel-managed projects** — check `manifest.yaml` `vercel_projects[]`; those deploy via Vercel
- **Broken builds** — failing tests or typecheck means the artifact isn't ready
- **Projects with `deploy: false`** in prd.json metadata — explicit opt-out
- **Non-web artifacts** — JSON, CSV, YAML exports are not deployable
- **User preference set to non-`hq-deploy`** — see User Preferences below
- **Artifacts that fail size/complexity guardrails** — see Guardrails below
- **No identity session** — if the user isn't signed in, the skill first tries to trigger an agent-spawned browser login (`npx hq auth login`); only if that fails does it fall back to serving only the localhost preview and upselling. See Identity Gate below.

### Identity Gate

The hq-deploy API (US-003) rejects anonymous `/api/*` requests with 401. Every upload must carry `Authorization: Bearer $JWT` verified against the shared HQ Identity Cognito pool. The skill gates the web deploy on a local Cognito session; the localhost preview is never gated.

**Session file resolution (in order):**
1. `~/.hq/cognito-tokens.json` — canonical path written by `@indigoai-us/hq-cloud` `saveCachedTokens()` on sign-in
2. `~/.hq/auth/session.json` — alternate path (some forks / desktop-app installers)

Expected schema: `{ accessToken, idToken, refreshToken, expiresAt, tokenType }`. The skill validates `expiresAt`, attempts refresh via `hq-auth-refresh` (provided by `@indigoai-us/hq-cli` ≥5.1) if the access token is expired, and if no valid JWT emerges, attempts an **agent-spawned browser login** before falling through to the upsell.

**Agent-spawned login (preferred recovery path):**

When there is no usable session, the skill runs — exactly once per session, tracked via `/tmp/hq-deploy-login-attempted-$USER`:

```bash
npx -y --package=@indigoai-us/hq-cli hq auth login &
LOGIN_PID=$!
( sleep 180 && kill "$LOGIN_PID" 2>/dev/null ) &
wait "$LOGIN_PID" 2>/dev/null || true
```

(Portable kill-after-180s pattern — `timeout` isn't on macOS by default.) `hq auth login` (shipped in `@indigoai-us/hq-cli` ≥5.5) opens Cognito's Hosted UI in the user's default browser, waits for the OAuth callback on a localhost loopback server, and writes tokens to `~/.hq/cognito-tokens.json`. After the spawn returns, the skill re-reads the session file. If tokens appear, the deploy proceeds on the same turn — the user signed in via a browser popup and never saw a terminal.

Before spawning, the skill must announce what's happening so the browser popup isn't unexpected:
> Opening HQ sign-in in your browser — one moment...

**Upsell copy (exactly once per session — tracked via `/tmp/hq-deploy-upsold-$USER`, only emitted if login was attempted and failed, or npx is unavailable):**
> Looks like you don't have an HQ account yet. Create one free at https://onboarding.indigo-hq.com and I'll deploy this to the web next time.

The upsell is friendly, not blocking, and NEVER repeats within a session. Sign-up (first-time account creation) is still owned by the onboarding app — the CLI login flow is for users who already have accounts.

### Guardrails (hq-deploy is for static artifacts only)

Auto-deploy is explicitly limited to small static artifacts. If ANY of these apply, the deploy skill silently skips:

| Check | Limit | Reason |
|-------|-------|--------|
| Tarball size (gzipped) | 10 MB max | hq-deploy CDN is for pages, not apps |
| File count | 100 files max | More than that is a full application |
| SSR framework | Disallowed | Next.js SSR, Remix SSR, Astro server → needs compute |
| Backend at root | Disallowed | `Dockerfile`, `serverless.*`, `sst.config.*`, `docker-compose.*` → skip |
| Database tooling | Disallowed | `prisma/`, `drizzle.config.*`, `knexfile.*`, `migrations/` → skip |

Guardrails are enforced **client-side in the deploy skill**, not server-side in the API. The skill checks and silently abstains. Users with legitimate large deploys can still use the hq-deploy CLI directly — the skill is just the auto-path.

### User Preferences

Users can set a global deploy preference at `~/.hq/config.json`:

```json
{ "deploy": { "preference": "hq-deploy" } }
```

Valid values:

| Value | Behavior |
|-------|----------|
| `hq-deploy` (default) | Full auto-deploy flow — preview + upload + link |
| `vercel` | Silently skip — user deploys via Vercel |
| `netlify` | Silently skip — user deploys via Netlify |
| `custom` | Silently skip — user has their own pipeline |
| `none` | Silently skip — no deploy flow at all, including localhost preview |

Per-project override: set `metadata.deploy: false` in `prd.json` to force-skip deploy for that project.

When the user casually states a preference in conversation ("I use Vercel", "don't deploy my stuff"), the deploy skill writes the preference to `~/.hq/config.json` and acknowledges once:
> Got it — I won't offer auto-deploy. You can change this in `~/.hq/config.json`.

## Rationale

The user shouldn't have to remember to deploy. When HQ builds something that could be shared via a URL, it should just appear. Every creation becomes a shareable artifact with zero friction. The link is a gift, not a task.
