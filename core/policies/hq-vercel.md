---
id: hq-vercel
title: Vercel platform rules (consolidated)
when: deploy
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
public: true
vendor_public_ok: true
tags: [vendor:vercel, consolidated]
source: consolidation-merge
---

## Rule

This file consolidates 31 prior Vercel-related global policies into one topical reference. Rules are grouped by surface area (CLI, deploys, domains, projects, edge cases). Each H3 below preserves the original rule body; the bracketed annotation cites the source filename(s).

## CLI

### Use printf, not echo, for env vars
[merged from vercel-env-no-echo.md, vercel-env-no-newlines.md, vercel-env-no-trailing-newline.md]

When piping values to `vercel env add`, ALWAYS use `printf` — NEVER `echo`. `echo` appends a trailing `\n`; Vercel stores the newline as part of the value; SDKs that send the value as an HTTP header (e.g. Anthropic SDK `x-api-key`, `CRON_SECRET`) fail with "not a legal HTTP header value", "leading or trailing whitespace", or generic 400 Bad Request errors that look like middleware bugs.

```bash
# CORRECT
printf '%s' "$VALUE" | vercel env add KEY production --scope team

# WRONG — \n stored verbatim, silent header-validation failures
echo "$VALUE"        | vercel env add KEY production --scope team
```

Diagnose with `vercel env pull` and inspect for `\n` in values. Same rule applies to other CLI tools that store piped values verbatim (`fly secrets set`, `railway variables set`).

### Use the global vercel binary, not `npx vercel`
[from hq-vercel-cli-binary-not-npx.md]

ALWAYS invoke the Vercel CLI via the installed binary, not `npx`:

```bash
vercel inspect <url> --scope <team>
vercel deploy --prod
/opt/homebrew/bin/vercel ls
```

NEVER use `npx vercel ...`. In a repo whose `package.json` defines its own npm scripts, `npx vercel` first tries `npm run vercel` and errors with `Missing script: "vercel"` before falling back to the package. The global binary at `/opt/homebrew/bin/vercel` is always the correct entry point.

### Always cd into the target repo before any vercel CLI op
[merged from vercel-cli-scope-overridden-by-local-link.md, vercel-git-disconnect-cwd.md]

The Vercel CLI silently uses `.vercel/project.json` from the current working directory. Two failure modes converge on the same mitigation:

- **`--scope` flag is silently overridden by the local link.** `vercel --scope {team-slug} blob store add ...` from HQ root created the store in the wrong team because HQ root has a stale `.vercel/project.json`. Stop relying on `--scope` from a foreign cwd.
- **`vercel git disconnect` / `vercel link` operate on cwd.** Running from HQ root will disconnect/link the WRONG project.

ALWAYS: `cd {repo-path} && vercel {cmd}`. Applies to: `vercel deploy`, `vercel env ls/add/rm`, `vercel blob store add/get/remove/list`, `vercel project inspect`, `vercel alias set`, `vercel git disconnect`, `vercel link`. After any `vercel blob store add` or `env add`, confirm the resource landed in the expected team:

```bash
vercel blob store list 2>&1 | grep {name}
vercel project inspect
```

### Pass --scope to read-side commands when targeting another team
[from vercel-scope-for-read-commands.md]

ALWAYS pass `--scope {team}` to `vercel inspect`, `vercel ls`, `vercel alias`, and other read-side Vercel CLI commands when operating on a project linked to a team that is not your current CLI scope. `vercel deploy` reads `.vercel/project.json` and automatically targets the correct team regardless of current scope — but read-side commands default to current scope and fail with `Can't find the deployment "..." under the context "..."` when the deployment lives in a different team.

To find a project's owning team: `cat .vercel/project.json` (check `orgId` / `projectName`), or `vercel teams ls` to see all teams you're a member of. The asymmetry between deploy (project.json wins) and read commands (current scope wins) is load-bearing.

### Specify --environment when pulling prod-only env vars
[from vercel-env-pull-environment.md]

ALWAYS check `vercel env ls` to see which environment vars are scoped to before pulling. `vercel env pull` defaults to "development" — production-only vars (like `SUPABASE_SERVICE_ROLE_KEY`) won't appear. Use `vercel env pull --environment production` to get prod-scoped vars.

### Don't rely on `vercel logs` in non-streaming tool contexts
[from hq-vercel-logs-streaming-empty-in-tool-context.md]

Do NOT use `vercel logs <url>` to validate cache hits, payload shape, or latency from within an agent tool context (Claude Code Bash, Codex shell, run_in_background, etc.). `vercel logs` runs as a persistent streaming command — when invoked in a non-TTY / non-streaming tool context it returns empty (or exits immediately with no output), producing false-negative observations.

Validate cache / latency behavior empirically instead:

```bash
curl -sI "https://{app}.vercel.app/path" -o /dev/null -w "%{http_code} %{time_total}s\n"
curl -sI "https://{app}.vercel.app/path" -o /dev/null -w "%{http_code} %{time_total}s\n"
```

A warm cache hit shows as a sub-1s second invocation after the first. For payload-shape checks, curl the JSON endpoint and jq the response.

## Deploys

### Route Vercel-managed projects to `vercel` CLI, not `/deploy`
[from hq-deploy-skill-vs-vercel-cli-routing.md]

When deploying a project that is Vercel-managed (listed in `companies/{co}/manifest.yaml` under `vercel_projects[]`, or has a `.vercel/project.json` file at its repo root), ALWAYS use the `vercel` CLI directly:

```bash
cd {repo-root}
vercel deploy --prod --yes    # or: vercel deploy (for preview)
```

Do NOT invoke the `/deploy` skill for Vercel-managed projects. The `/deploy` skill targets **hq-deploy** infrastructure only (static tarballs, type:static apps, the `/api/apps` registry). It silently no-ops on Vercel projects because its artifact detector does not recognize `.vercel/project.json` as an hq-deploy candidate.

| Project shape | Deploy mechanism |
|---|---|
| Has `.vercel/project.json` | `vercel` CLI from the repo root |
| Listed in `manifest.yaml → vercel_projects[]` | `vercel` CLI from the repo root |
| Static HTML report / dashboard in `workspace/reports/` or `companies/{co}/data/` | `/deploy` (hq-deploy) |
| Astro docs site scaffolded by `/plan` with hq-deploy target | `/deploy` (hq-deploy) |
| Next.js app with no `.vercel/project.json` but user intends Vercel | `vercel link` first, then `vercel deploy` |

### Never deploy to production custom domains without explicit confirmation
[from vercel-custom-domain-safety.md]

NEVER deploy to a production custom domain (e.g. `token.{your-domain}`, `{your-domain}.com`) without explicit user confirmation. "Deploy to a temporary Vercel site" means a fresh Vercel project with only a `*.vercel.app` URL — no custom-domain aliases. Existing Vercel projects with custom domains are LIVE production sites. Accidental deploys can take down live sites.

### Cross-check vercel team between manifest.yaml and prd.json
[from vercel-team-drift-cross-check.md]

`companies/manifest.yaml` field `vercel_team` and `companies/{co}/projects/{project}/prd.json` field `metadata.vercelTeam` MUST match byte-for-byte. If they don't, STOP and reconcile before running any Vercel-scoped operation.

```bash
manifest_team=$(yq '.companies.{co}.vercel_team' companies/manifest.yaml)
prd_team=$(jq -r '.metadata.vercelTeam' companies/{co}/projects/{project}/prd.json)
[ "$manifest_team" = "$prd_team" ] || { echo "DRIFT — abort"; exit 1; }
```

Resolve ground truth against Vercel itself: `vercel whoami`, `vercel teams ls`, `vercel project ls`. Don't assume either side is right — the PRD is hand-authored and drifts; the manifest can lag a team rename. Both have been wrong in real incidents. Update the wrong file, commit the correction with a `fix(manifest)` or `fix(prd)` message naming both files.

### Pin pnpm version with packageManager
[from vercel-pnpm-version-pin.md]

ALWAYS add `"packageManager": "pnpm@X.Y.Z"` to `package.json` for any pnpm project deployed to Vercel. Without this field, Vercel auto-selects pnpm version "based on project creation date" — which may pick pnpm 10.x even when the lockfile is v9.0 format. This causes `--frozen-lockfile` to fail with specifier mismatch errors.

After adding new dependencies to `package.json`, ALWAYS run `pnpm install` locally to regenerate the lockfile before pushing — Vercel CI uses `--frozen-lockfile` by default.

### Pin peer-dep pairs when installCommand mutates package.json
[from hq-vercel-install-mutates-pkg-pin-peer-deps.md]

When a Vercel `installCommand` mutates `package.json` before or during install (sed-strip `workspace:` deps, jq edits, `mv package.json.prod package.json`, etc.), the lockfile is no longer authoritative — npm/pnpm/bun will re-resolve semver ranges against the mutated manifest and can pick divergent patch versions across sibling workspaces.

To keep the build deterministic:

1. Pin critical peer-dep pairs to exact versions across every workspace that declares them (`react`/`react-dom`, `@types/react`/`@types/react-dom`, `next` + `@next/*`, `@tanstack/react-query` + devtools).
2. Add root-level `overrides` (npm/pnpm) or `resolutions` (yarn/bun) for the same pairs so the package manager rejects divergent resolutions.
3. Do not rely on caret ranges + lockfile to preserve alignment — the mutation invalidates that contract.
4. If the mutation step can be removed (e.g. modern pnpm/bun with proper workspace-protocol support), prefer removing it over tightening pins.

### Reproduce build failures locally with the exact installCommand
[from hq-vercel-reproduce-install-command-locally.md]

When a Vercel build fails, reproduce it locally by running the exact `installCommand` from `vercel.json` (including every sed / jq / mv / cp step) BEFORE blaming transient CI issues, cache poisoning, or "flaky network."

1. `git clean -fdx` (or work in a scratch clone) so you start from the same clean state Vercel sees.
2. Copy the `installCommand` from `vercel.json` verbatim — including the pre-install mutation steps.
3. Run it in a shell with the same Node/package-manager versions declared in `package.json` (`engines`, `packageManager`).
4. If the `installCommand` succeeds, run the `buildCommand` next — same verbatim copy.
5. If either step reproduces the failure, fix at the source. If not, then consider CI-specific causes.

### Prove prod alias flipped via chunk-hash probe
[from hq-vercel-post-deploy-chunk-hash-probe.md]

After any `vercel deploy --prod` (or GitHub-App-triggered prod build), the deploy URL printed by Vercel and the green GitHub Check are NOT sufficient proof that the production alias actually flipped to the new build. Vercel can build a deployment and return success while the alias continues pointing at an older build (wrong project, wrong team, or the flip was skipped).

Always run the chunk-hash probe before declaring the deploy complete:

```bash
cd {repo}
rm -rf .next && npm run build   # or: pnpm build / bun run build
ls .next/static/chunks/ | grep -oE '[a-f0-9]{16}\.js' | sort -u > /tmp/local-chunks.txt
curl -sSL https://{prod-domain}/ \
  | grep -oE '[a-f0-9]{16}\.js' | sort -u > /tmp/prod-chunks.txt
comm -12 /tmp/local-chunks.txt /tmp/prod-chunks.txt
```

A non-empty intersection = the build you just shipped is live. Empty intersection = alias did NOT flip; investigate project/team drift before retrying. Auth-gated routes return a 307 to `/login` — always use `-L`. For non-Next.js frameworks, substitute the chunk-path pattern (`assets/*.js`, `_app/immutable/chunks/*.js`).

### Deployment Protection blocks external requests
[from vercel-preview-sso.md]

`vercel deploy --public` makes source public, NOT bypasses deployment protection (SSO). Vercel preview URLs always require login unless project-level protection is disabled. To test a preview without auth: run prod server locally (`npm run build && npm run start`).

Vercel Deployment Protection also blocks ALL external requests (mobile apps, curl, etc.) to `.vercel.app` production domains on team plans. `vercel curl` auto-injects bypass token, but real clients get 307 redirects. For APIs consumed by mobile apps: use a **custom domain** (protection doesn't apply) or **hardcode small, stable datasets** client-side to avoid the fetch entirely.

## Domains

### Splat redirects (/:path*) do not match the empty apex /
[merged from hq-vercel-redirect-splat-misses-apex.md, also covered in hq-vercel-discipline.md]

Never use `/:path*` (or any single-splat pattern) in `vercel.json` redirects expecting it to match the empty apex `/`. The splat is one-or-more segments, not zero-or-more — `GET /` falls through every `/:path*` rule.

ALWAYS add an explicit apex rule BEFORE the splat:

```json
{
  "redirects": [
    { "source": "/", "destination": "https://new.example.com", "permanent": true },
    { "source": "/:path*", "destination": "https://new.example.com/:path*", "permanent": true }
  ]
}
```

Same gotcha applies to Next.js middleware `matcher: ['/:path*']` (won't run on `/`), Cloudflare Page Rules / Bulk Redirects with `*` segment patterns, and AWS CloudFront behaviors with path-pattern wildcards.

### Wildcard custom domains match exactly one subdomain level
[from hq-vercel-wildcard-single-subdomain-level.md]

Vercel wildcard custom domains (`*.example.com`) match EXACTLY ONE subdomain label. `preview.{slug}.example.com` (two labels under `example.com`) does NOT match. Vercel does not support 2-level wildcards (`*.*.example.com`) on custom domains.

| Does NOT work with `*.example.com` | DOES work with `*.example.com` |
|---|---|
| `preview.{slug}.example.com` | `preview-{slug}.example.com` |
| `staging.api.example.com` | `staging-api.example.com` |
| `{tenant}.admin.example.com` | `{tenant}-admin.example.com` |

If a nested hierarchy is genuinely required, attach each parent zone (`*.{tenant}.example.com`) as its own custom domain — one per tenant. Does not scale; flatten instead. Mirrors DNS wildcard semantics (RFC 4592 §2.1.1).

### Cross-team domains: prefer redirect-only project on original team (Path B)
[from vercel-cross-team-domains.md]

Vercel does NOT allow adding a domain registered on Team A to a project on Team B (returns 403). When the redirect destination already exists on Team B and the original domain is being repurposed as a redirect-only host, prefer **Path B** over **Path A**:

- **Path B (preferred)**: Spin up a fresh `<domain>-redirect` project on Team A with a minimal `vercel.json` permanent-redirect rule. Original project stays put; new project becomes the redirect host. Zero net-new infrastructure on Team B.
- **Path A (avoid)**: Cross-team Vercel project transfer is slow, often blocked by SSO/billing differences, and ALWAYS requires creating a redirect-only project on Team A afterward anyway — the transfer doesn't move the domain.

### Vercel domain team-move procedure
[from vercel-domain-team-move.md]

When purchasing a domain via Vercel/Name.com, it can land in the wrong team/org. Check ownership with `GET /v6/domains/{domain}?teamId={teamId}` across all teams. Move between teams with `PATCH /v6/domains/{domain}?teamId={source}` body `{"op": "move-out", "destination": "{target_team_id}"}`. Cannot delete Vercel-purchased domains — must move them.

### Domain transfer between projects reissues vc-domain-verify TXT
[from vercel-domain-transfer-reissues-verification.md]

When transferring a Vercel domain between projects on the same team (DELETE from project A → POST to project B), expect Vercel to issue a NEW `vc-domain-verify` TXT token and return `verified:false` on the POST. The `_vercel.{apex}` TXT RRset is multi-valued (one token per subdomain across all projects on the team), so UPSERT the new token into the existing RRset preserving all prior values, wait for DNS propagation, then POST `/v9/projects/{project}/domains/{domain}/verify`.

If a subdomain redirect shim (e.g. `old-alias.example.com` → `target.example.com`) exists in the source project, DELETE the shim BEFORE deleting the target domain — otherwise the DELETE returns `409 domain_is_redirect`.

Ship the `next.config.mjs` host-matched redirect commit to the destination project BEFORE transferring the domain. This closes the zero-duplicate-content window.

NEVER assume `vercel domains add {domain} --force` can transfer a domain across projects via the CLI — it returns 403. Use the REST API (`/v9/projects/{id}/domains/{domain}`) with the CLI's auth token directly.

### Route 53 custom domain setup
[from vercel-route53-domain-setup.md]

When adding a custom domain to a Vercel project where DNS is managed by AWS Route 53:

1. The `vercel domains add` CLI command will return **403 Not authorized** for domains not registered in Vercel's domain list — even if the project is in the correct team scope.
2. Use the **Vercel REST API** instead: `POST /v10/projects/{projectId}/domains?teamId={teamId}` with `{"name":"subdomain.apex.com"}`.
3. The API returns a `verification` array with a TXT record requirement at `_vercel.{apex}`.
4. The `_vercel.{apex}` TXT record may already exist with values for other subdomains — UPSERT with all existing values plus the new one (Route 53 `UPSERT` action).
5. Also create a CNAME: `subdomain.apex.com → cname.vercel-dns.com`.
6. After DNS propagates, trigger verification: `POST /v10/projects/{projectId}/domains/{domain}/verify?teamId={teamId}` — Vercel does NOT auto-verify.
7. Vercel auth token location on macOS: `~/Library/Application Support/com.vercel.cli/auth.json`.

The CLI path is a dead end for Route 53 domains — REST API is required.

## Projects

### Verify framework detection after project creation
[from vercel-framework-detection.md]

If a Vercel project has `framework: null`, production builds deploy but serve 404 on all routes (even though build succeeds). CLI-created projects (`vercel link --project`) do NOT inherit the framework preset from the dashboard. Diagnostic clue: build logs missing "Traced Next.js server files" line despite successful page compilation.

Two fixes:

1. **Preferred — `vercel.json` in repo root**: `{"framework": "nextjs"}` (or appropriate framework). Survives recreation, no API calls.
2. **Alternative — API patch**: `PATCH /v9/projects/{id}` with `{"framework":"nextjs","installCommand":"pnpm install"}` then redeploy.

ALWAYS verify framework is set before announcing the deploy is live.

### Configure rootDirectory via REST API for monorepo subdirectory apps
[from vercel-monorepo-root-directory.md]

When a Next.js (or other framework) app lives in a repo subdirectory (e.g. `site/`), `vercel deploy --yes` from the repo root creates a NEW project that fails framework detection (builds in <1s, serves static files instead of the framework runtime).

ALWAYS set rootDirectory via REST API before the first successful deploy:

```
PATCH /v9/projects/{projectId}?teamId={teamId}
{"rootDirectory":"site","framework":"nextjs","installCommand":"pnpm install","buildCommand":"pnpm build"}
```

After creating the correct project, ALWAYS disconnect old/duplicate projects from the same GitHub repo via `DELETE /v9/projects/{oldProjectId}/link` to prevent duplicate builds on push. The Vercel CLI has no `vercel project settings` subcommand — REST API is the only way to set `rootDirectory` programmatically.

### Verify unique projectId before deploy/link
[from vercel-project-id-collision.md]

Before any `vercel deploy` or `vercel link`, check `settings/deploy-registry.yaml` for the target project ID. If two repos share the same `project_id`, deploying either silently overwrites the other's production deployment — last push wins.

- ALWAYS verify `.vercel/project.json` has a unique `projectId` before deploying.
- ALWAYS check `deploy-registry.yaml` for `COLLISION` notes on the target project.
- NEVER run `vercel link` and reuse an existing project name without confirming no collision.
- After creating a new Vercel project, update `deploy-registry.yaml` with the new project ID immediately.

### Verify project exists before domain operations
[from verify-vercel-project-exists.md]

Before running `vercel domains add` or assuming a Vercel project is live, verify it actually exists on the team with `vercel project ls --scope {team}`. The deploy registry `live: false` may mean the project was never created on Vercel — not just that it's paused. If the project doesn't exist, run `vercel link --yes` + `vercel --prod` first. Running `vercel domains add` on a nonexistent project would fail silently or create orphan domain assignments.

## Edge cases

### No headless browser in Vercel Lambda
[from no-headless-browser-in-vercel-lambda.md]

NEVER run Playwright, Puppeteer, or Chromium in a Vercel Lambda. Use ingest-only endpoints that accept pre-captured payloads from client-side callers (extensions, local scripts). The 250 MB unzipped Lambda cap makes shipping a headless browser architecturally impossible. Attempts to slim the binary or chunk dependencies do not close the gap; the architecture has to move the browser-execution side off Lambda entirely.

### Use @neondatabase/serverless instead of @vercel/postgres
[from hq-use-neon-not-vercel-postgres.md]

ALWAYS use `@neondatabase/serverless` instead of `@vercel/postgres` for Vercel-hosted Postgres. `@vercel/postgres` is deprecated — Vercel migrated all Postgres databases to Neon. The Neon SDK uses HTTP-based queries optimized for serverless, auto-reads `POSTGRES_URL`. Create databases via `neonctl` CLI. Installing `@vercel/postgres` triggers a deprecation warning and points to the Neon transition guide.

### Add @anthropic-ai/sdk to serverExternalPackages
[from anthropic-sdk-vercel-bundling.md]

When deploying a Next.js app that uses `@anthropic-ai/sdk` to Vercel, add it to `serverExternalPackages` in `next.config.ts`:

```ts
const nextConfig: NextConfig = {
  serverExternalPackages: ['@anthropic-ai/sdk'],
};
```

Next.js Turbopack bundles server-side dependencies by default. The Anthropic SDK's HTTP client can break when bundled — its internal fetch/node-http usage doesn't survive the transformation. `serverExternalPackages` tells Next.js to load the package directly from `node_modules` at runtime.

### Removing Clerk from Vercel may require a new project
[from clerk-vercel-edge-removal.md]

Removing `@clerk/nextjs` from code + env vars is NOT enough to remove Clerk auth from a Vercel project. Clerk injects middleware at the Vercel edge infrastructure level (visible via `x-clerk-auth-status` and `x-clerk-auth-reason` response headers). Even disabling `ssoProtection`, `vercelAuthentication`, and `passwordProtection` via the Vercel API may not remove it.

**Fastest fix:** Create a new Vercel project without the Clerk integration, copy env vars via the Vercel API, and deploy there. When migrating away from Clerk on Vercel, budget for creating a new Vercel project rather than trying to strip Clerk from the existing one.

### hq-vercel-discipline supersedes ad-hoc combinations
[from hq-vercel-discipline.md]

The prior `hq-vercel-discipline.md` consolidated 14 of these rules into a single doc on 2026-04-27. This file (`hq-vercel.md`) further consolidates that doc plus the remaining standalone Vercel policies. If you encounter `hq-vercel-discipline.md` in the wild, treat its rules as already merged here — same content, organized topically rather than as a numbered list.

