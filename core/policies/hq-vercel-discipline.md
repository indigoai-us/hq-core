---
id: hq-vercel-discipline
title: Vercel deploy discipline — single-source operational rules
scope: global
trigger: any Vercel CLI invocation, deploy, project creation, env-var write, domain assignment, or redirect/wildcard configuration
enforcement: soft
public: true
version: 1
created: 2026-04-27
updated: 2026-04-27
source: consolidation
applies_to: [vercel]
merged_from:
  - hq-vercel-framework-detection
  - hq-vercel-custom-domain-safety
  - vercel-team-drift-cross-check
  - hq-vercel-project-id-collision
  - hq-vercel-cli-scope-overridden-by-local-link
  - vercel-git-disconnect-cwd
  - vercel-monorepo-root-directory
  - hq-vercel-pnpm-version-pin
  - vercel-env-no-echo
  - hq-vercel-env-no-newlines
  - hq-vercel-env-no-trailing-newline
  - hq-vercel-redirect-splat-misses-apex
  - hq-vercel-wildcard-single-subdomain-level
  - vercel-cross-team-domains
merged_at: 2026-04-27
---

## Rule

Eleven hard rules for Vercel operations. Each preserves the failure mode and remedy of its source slug (see `merged_from`). Soft-enforcement Vercel policies remain as separate files (already excluded from cold-start digest by enforcement filter).

### 1. Verify framework detection after project creation

CLI-created projects (`vercel link --project`) do NOT inherit the framework preset from the dashboard. Build succeeds, every route serves 404. Diagnostic clue: build logs missing "Traced Next.js server files" line despite successful page compilation.

Two fixes:

1. **Preferred — `vercel.json` in repo root**: `{"framework": "nextjs"}` (or appropriate framework). Survives recreation, no API calls.
2. **Alternative — API patch**: `PATCH /v9/projects/{id}` with `{"framework":"nextjs","installCommand":"pnpm install"}` then redeploy.

ALWAYS verify framework is set before announcing the deploy is live.

### 2. Never deploy to production custom domains without explicit confirmation

NEVER deploy to a production custom domain (e.g. `token.{your-domain}`, `{your-domain}.com`) without explicit user confirmation. "Deploy to a temporary Vercel site" means a fresh Vercel project with only a `*.vercel.app` URL — no custom-domain aliases. Existing Vercel projects with custom domains are LIVE production sites.

### 3. Cross-check Vercel team between manifest.yaml and prd.json before any team-scoped op

`companies/manifest.yaml` field `vercel_team` and `companies/{co}/projects/{project}/prd.json` field `metadata.vercelTeam` MUST match byte-for-byte. If they don't, STOP and reconcile before running any Vercel-scoped operation.

Cross-check protocol (mandatory when either field is about to be used):

```bash
manifest_team=$(yq '.companies.{co}.vercel_team' companies/manifest.yaml)
prd_team=$(jq -r '.metadata.vercelTeam' companies/{co}/projects/{project}/prd.json)
[ "$manifest_team" = "$prd_team" ] || { echo "DRIFT — abort"; exit 1; }
```

Resolve ground truth against Vercel itself: `vercel whoami`, `vercel teams ls`, `vercel project ls`. Don't assume either side is right — the PRD is hand-authored and drifts; the manifest can lag a team rename. Both have been wrong in real incidents.

### 4. Verify unique projectId before deploy/link

Before any `vercel deploy` or `vercel link`, check `settings/deploy-registry.yaml` for the target project ID. If two repos share the same `project_id`, deploying either silently overwrites the other's production deployment — last push wins.

- ALWAYS verify `.vercel/project.json` has a unique `projectId` before deploying.
- ALWAYS check `deploy-registry.yaml` for `COLLISION` notes on the target project.
- NEVER run `vercel link` and reuse an existing project name without confirming no collision.
- After creating a new Vercel project, update `deploy-registry.yaml` with the new project ID immediately.

### 5. Always cd into the target repo before any vercel CLI op

The Vercel CLI silently uses `.vercel/project.json` from the current working directory. Two failure modes converge on the same mitigation:

- **`--scope` flag is silently overridden by the local link.** `vercel --scope {team-slug} blob store add ...` from HQ root created the store in the wrong team because HQ root has a stale `.vercel/project.json`. Stop relying on `--scope` from a foreign cwd.
- **`vercel git disconnect` / `vercel link` operate on cwd.** Running from HQ root will disconnect/link the WRONG project.

ALWAYS: `cd {repo-path} && vercel {cmd}`. After any `vercel blob store add` or `env add`, confirm the resource landed in the expected team:

```bash
vercel blob store list 2>&1 | grep {name}
vercel project inspect
```

Applies to: `vercel deploy`, `vercel env ls/add/rm`, `vercel blob store add/get/remove/list`, `vercel project inspect`, `vercel alias set`, `vercel git disconnect`, `vercel link`.

### 6. Configure rootDirectory via REST API for monorepo subdirectory apps

When a Next.js (or other framework) app lives in a repo subdirectory (e.g. `site/`), `vercel deploy --yes` from the repo root creates a NEW project that fails framework detection (builds in <1s, serves static files instead of the framework runtime).

ALWAYS set rootDirectory via REST API before the first successful deploy:

```
PATCH /v9/projects/{projectId}?teamId={teamId}
{"rootDirectory":"site","framework":"nextjs","installCommand":"pnpm install","buildCommand":"pnpm build"}
```

After creating the correct project, ALWAYS disconnect old/duplicate projects from the same GitHub repo via `DELETE /v9/projects/{oldProjectId}/link` to prevent duplicate builds on push. The Vercel CLI has no `vercel project settings` subcommand — REST API is the only way to set `rootDirectory` programmatically.

### 7. Pin pnpm version with packageManager for Vercel deploys

ALWAYS add `"packageManager": "pnpm@X.Y.Z"` to `package.json` for any pnpm project deployed to Vercel. Without this field, Vercel auto-selects pnpm version "based on project creation date" — which may pick pnpm 10.x even when the lockfile is v9.0 format. This causes `--frozen-lockfile` to fail with specifier mismatch errors.

After adding new dependencies to `package.json`, ALWAYS run `pnpm install` locally to regenerate the lockfile before pushing — Vercel CI uses `--frozen-lockfile` by default.

### 8. Use printf (not echo) when piping to vercel env add

When piping values to `vercel env add`, ALWAYS use `printf` — NEVER `echo`. `echo` appends a trailing `\n`; Vercel stores the newline as part of the value; SDKs that send the value as an HTTP header (e.g. Anthropic SDK `x-api-key`, `CRON_SECRET`) fail with "not a legal HTTP header value" or "leading or trailing whitespace" build errors.

```bash
# CORRECT
printf '%s' "$VALUE" | vercel env add KEY production --scope team

# WRONG — \n stored verbatim, silent header-validation failures
echo "$VALUE"        | vercel env add KEY production --scope team
```

Diagnose with `vercel env pull` and inspect for `\n` in values. Same rule applies to other CLI tools that store piped values verbatim (`fly secrets set`, `railway variables set`).

### 9. Splat redirects (/:path*) do NOT match the empty apex /

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

### 10. Vercel wildcard custom domains match exactly one subdomain level

`*.example.com` matches EXACTLY ONE subdomain label. `preview.{slug}.example.com` (two labels under `example.com`) does NOT match. Vercel does not support 2-level wildcards (`*.*.example.com`) on custom domains.

When designing preview/tenant URL schemes, ALWAYS flatten to a single label:

| Does NOT work with `*.example.com` | DOES work with `*.example.com` |
|---|---|
| `preview.{slug}.example.com` | `preview-{slug}.example.com` |
| `staging.api.example.com` | `staging-api.example.com` |
| `{tenant}.admin.example.com` | `{tenant}-admin.example.com` |

If a nested hierarchy is genuinely required for DNS clarity, attach each parent zone (`*.{tenant}.example.com`) as its own custom domain — one per tenant. Does not scale; flatten instead.

### 11. Cross-team domains: use Path B (redirect-only project on original team)

Vercel does NOT allow adding a domain registered on Team A to a project on Team B (returns 403). When the redirect destination already exists on Team B and the original domain is being repurposed as a redirect-only host, prefer **Path B** (recreate a redirect-only project on Team A) over **Path A** (cross-team Vercel project transfer):

- **Path B (preferred)**: Spin up a fresh `<domain>-redirect` project on Team A with a minimal `vercel.json` permanent-redirect rule. Original project stays put; new project becomes the redirect host. Zero net-new infrastructure on Team B.
- **Path A (avoid)**: Cross-team transfer is slow, often blocked by SSO/billing differences, and ALWAYS requires creating a redirect-only project on Team A afterward anyway — the transfer doesn't move the domain.

## Rationale

These eleven rules each block a distinct, observed Vercel failure mode that wasted a session or shipped a broken cutover. Consolidating into one file:

- Cuts cold-start digest size by collapsing 14 separate frontmatter blocks + section headers + provenance footers into a single structured doc.
- Eliminates three near-duplicate "use printf not echo" policies that were redundantly authored as the same lesson recurred across teams (rule 8 `merged_from` lists all three slugs).
- Pairs adjacent failure modes that share a mitigation: rules 5 (cd before CLI) groups `--scope` override and `git disconnect` cwd because the fix is identical.
- Preserves provenance: every original slug stays grepable via `merged_from`.

## Related

- `companies/{co}/policies/vercel-project-drift.md` — company-scoped CLI-deploy policy that depends on rule 5
- `.claude/policies/hq-dns-wildcard-shadows-deleted-subdomain.md` — adjacent DNS-layer wildcard gotcha
- `.claude/CLAUDE.md` — "Vercel Deployments" section (top-level summary)
