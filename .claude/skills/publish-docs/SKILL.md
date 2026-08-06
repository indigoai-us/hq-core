---
name: publish-docs
description: Sync the active company's PUBLISHED documentation site (the standalone docs-site repo, e.g. docs.{company}.com) to match what shipped. Company-agnostic dispatcher — resolves the company's docs-site sync skill and runs it foreground. Distinct from document-release, which syncs in-repo docs (README, CLAUDE.md, architecture, INDEX). Use after shipping a material change, or as the final foreground step of /ship. Triggers on "publish the docs site", "update the docs site", "sync published docs".
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(yq:*), Bash(grep:*), Bash(ls:*), Bash(test:*), Skill, AskUserQuestion
---

# Publish Docs

Sync the active company's **published documentation site** — the standalone,
user-facing docs site that lives in its own repo and deploys to its own URL
(e.g. `docs.{company}.com` built from `repos/public/{company}-docs`) — so it
reflects what actually shipped.

This command is a **company-agnostic dispatcher**. It does not itself know how
any one company builds or publishes its docs site. It resolves the active
company, finds that company's docs-site sync skill, and runs it **foreground**.
Companies without a published docs site are a clean no-op.

## Scope boundary (read this first)

There are two distinct documentation layers, and this command owns exactly one:

| Layer | Owner | What it touches |
|---|---|---|
| **In-repo docs** | `document-release` | `README.md`, `CLAUDE.md`, architecture docs, `INDEX.md`, `CHANGELOG` — docs that live *alongside the code* |
| **Published docs site** | **this skill** | the standalone docs-site repo that builds and deploys to a public URL |

`document-release` never reaches into a separate docs-site repo. This command is
that missing half. `/ship` runs both, in order, as its final foreground step.

## When NOT to run

- The change did not ship anything material to a product users see (internal
  refactor, HQ-core plumbing, tooling). Publishing docs for a no-op change is
  churn.
- No company is resolvable. This command requires a company anchor; it never
  guesses across tenants.

## Step 0: Resolve Company

1. Bind the active company the same way every HQ command does: explicit mention
   → cwd → the repo's owning company in `companies/manifest.yaml` → handoff.
   Never guess or cross tenants.
2. Announce: `Publishing docs site for: {company name}`

If no company resolves, stop and say so — do not proceed unanchored.

## Step 1: Discover the Company's Docs-Site Sync Skill

A company opts in to docs-site publishing in one of two ways. Check in this
order and use the first that matches:

1. **Explicit manifest declaration.** Read the company's entry in
   `companies/manifest.yaml`. If it declares:
   ```yaml
   {co}:
     docs_site:
       sync_skill: {co}:sync-docs   # skill to invoke
       repo: repos/public/{co}-docs # optional, informational
       url: https://docs.example.com # optional, informational
   ```
   use `docs_site.sync_skill` as the skill to run.

2. **Convention.** If no manifest declaration, check whether the company ships a
   docs-site sync skill by convention at
   `companies/{co}/skills/sync-docs/SKILL.md`. If present, the skill to run is
   `{co}:sync-docs`.

3. **Neither → clean no-op.** If the company declares no `docs_site.sync_skill`
   and has no `companies/{co}/skills/sync-docs/`, report and exit successfully:
   ```
   publish-docs: no published docs site configured for {company name} — skipping.
   (To enable: add a `sync-docs` skill under companies/{co}/skills/, or a
    docs_site.sync_skill entry in companies/manifest.yaml.)
   ```
   Exit 0. This is the expected path for companies without a public docs site,
   and it is why `/ship` can call this unconditionally without going red.

Do NOT fabricate or hardcode any specific company's skill name. The only
company-specific knowledge lives in that company's own skill/manifest.

## Step 2: Dispatch (foreground)

Invoke the resolved docs-site sync skill **in the foreground** via the `Skill`
tool (e.g. `Skill(skill: "{co}:sync-docs")`). Never background this — the whole
point is that published docs are live and verified before the caller reports
done.

The company skill owns everything site-specific: deciding whether the shipped
change is material to the public docs, editing the affected pages, building the
docs-site repo (anchored with an explicit absolute `cd /abs/repo && ...` per
`hq-anchor-repo-build-cwd`), publishing, and verifying the pages live. This
command does not second-guess that skill's build/publish steps.

Pass through any context the caller provided (the shipped diff, PR refs, project
slug) so the company skill can judge materiality without re-deriving it.

## Step 3: Report

Relay the company skill's outcome in one plain line, keeping any live URL it
returns:

```
Docs site: {published — <url> | no material change, nothing to publish | skipped — none configured}
```

If the company skill failed, surface the failure plainly — do NOT swallow it.
When called from `/ship`, a docs-site failure is reported but does not retroact
the ship's merged/deployed/smoked status (docs are not in ship's done-criteria);
the caller decides whether to heal or hand off the docs failure.

## Rules

- **Company isolation** — resolve exactly one company; only touch that company's
  docs site, repo, and credentials. Cross-company docs publishing is a
  category-1 bug.
- **Foreground only** — never dispatch the docs-site sync as a background job.
- **Dispatcher, not implementer** — all site-specific build/publish/verify logic
  lives in the company's own skill. Keep this command generic.
- **Clean no-op for unconfigured companies** — absence of a docs site is a
  success, not an error, so callers (like `/ship`) stay green.
- **Anchor builds** — if you ever run a build directly, anchor it with an
  explicit absolute `cd /abs/repo && ...` (policy `hq-anchor-repo-build-cwd`);
  a green build is not proof you built the right repo.
- **Never guess credentials or targets** — read them from the resolved company's
  policies/manifest only.
