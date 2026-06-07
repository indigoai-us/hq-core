---
id: hq-github
title: GitHub platform rules (consolidated)
scope: global
trigger: when working with github.com (PRs, issues, actions, gh CLI)
when: git
on: [PreToolUse]
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
applies_to: [github]
public: true
vendor_public_ok: true
tags: [vendor:github, consolidated]
source: consolidation-merge
---

## Rule

Consolidated rules for working with github.com — the gh CLI, REST/GraphQL APIs, PR/review workflows, Actions, repo state flags, bot credentials, and library distribution via github-install. Mixed enforcement: the cwd-disambiguation rule is hard; the rest are soft but routinely violated and worth re-reading before any GitHub-touching session.

## gh CLI

### Always pass --repo to gh commands from HQ or the wrong repo
[from hq-gh-pr-merge-explicit-repo.md — enforcement: hard]

NEVER trust any `gh` resource-scoped command without an explicit `-R {owner}/{repo}` (or `--repo`) flag when the current working directory is HQ, a git worktree, or any repo other than the one the resource lives in. IDs (PR numbers, run IDs, issue numbers, release tags) are ambiguous across repos — `gh` resolves them against the current repo's `origin` and will happily act on the wrong resource or return a misleading 404.

ALWAYS specify the target repo:

```bash
gh pr merge <N> --repo {your-org}/{some-repo} --squash
gh pr view  <N> --repo indigoai-us/hq
gh run view <run-id>      -R {your-org}/{another-repo}
gh api      repos/{your-org}/{another-repo}/actions/runs/<id>
```

Applies to (non-exhaustive):
- `gh pr view`, `gh pr checks`, `gh pr merge`, `gh pr close`, `gh pr comment`, `gh pr review`, `gh pr ready`, `gh pr create`
- `gh run view`, `gh run list`, `gh run watch`, `gh run cancel`, `gh run rerun`, `gh run download`
- `gh api repos/{owner}/{repo}/...` — always use the full fully-qualified path; do NOT rely on cwd-inferred repo
- `gh workflow view`, `gh workflow run`, `gh workflow list`
- `gh issue view`, `gh issue list`, `gh issue close`
- `gh release view`, `gh release list`

#### Post-read identity verification

Even with `--repo`, ALSO verify the returned PR identity before acting on it. `gh pr view <N> --repo <owner>/<repo> --json number,headRefName,state,title,url` — confirm `headRefName` matches the branch you expected, and `url` matches the intended repo. A same-numbered stale/merged PR in the right repo can look identical to the live PR you wanted; branch name is the cheapest disambiguator. Acceptance pattern:

```bash
gh pr view "$PR" --repo "$REPO" \
  --json number,headRefName,state,title,url \
  | jq -e '.headRefName == "'"$EXPECTED_BRANCH"'"' \
  || { echo "PR identity mismatch — aborting"; exit 1; }
```

**Rationale.** HQ is itself a git repo. Running any `gh` command from HQ's working tree — or from a worktree whose `origin` differs from the intended target — resolves resource IDs against the wrong repo. Observed failure modes:

1. `gh pr merge 42` in HQ → acts on PR #42 in the HQ repo instead of the downstream company repo (or reports "already merged" on a completely unrelated PR).
2. `gh run view 1234567` in HQ → 404, because that run ID only exists in the repo the workflow actually ran in.
3. `gh api repos/.../actions/runs/<id>` without a fully-qualified path → silently queries the HQ repo and returns stale data for a same-numbered resource.

`-R <owner>/<name>` (or a fully-qualified `gh api` path) removes the ambiguity and makes the intent auditable in shell history. Critical for scripted / multi-step verification flows where a 404 might be mistaken for "the deploy failed" rather than "we queried the wrong repo." Mitigation: per-clone `gh repo set-default <owner>/<repo>` once, AND always pass `--repo` explicitly — defense in depth, since `set-default` doesn't help when cwd is HQ.

**Provenance.** HQ's git remote is `indigoai-us/hq`. Multiple recurrences observed across a ten-day window (PR-merge against the wrong repo, run-view 404s in HQ, gh api hitting HQ instead of the intended downstream repo from a worktree whose origin chained back to HQ). The recurring cadence justifies treating bare `gh pr <N>` as a hard error in shell history reviews; consider a shell wrapper that refuses any `gh pr/run/issue/release` invocation lacking `--repo`/`-R`.

## PR review & merge workflow

### Resolve GitHub PR review threads via GraphQL
[from hq-github-review-thread-resolution.md]

- GitHub REST API has no endpoint for resolving PR review threads. Use the **GraphQL `resolveReviewThread` mutation** instead.
- To get thread IDs: query `repository.pullRequest.reviewThreads` via GraphQL — each thread has a node `id` and `isResolved` boolean.
- To resolve: `mutation { resolveReviewThread(input: {threadId: "{id}"}) { thread { isResolved } } }`
- Batch resolution: loop over thread IDs with sequential GraphQL mutations via `gh api graphql`.

**Rationale.** Discovered while landing PR #3040. The GitHub ruleset required all review threads to be resolved before merge. The REST API (`/pulls/{number}/comments`) only lists comments — it cannot resolve threads. The GraphQL API is the only way to programmatically resolve review threads.

## Commit statuses & polling

### Slice /commits/{sha}/statuses to [0] (newest), or use the combined /status endpoint
[from hq-github-commit-statuses-slice-newest.md]

ALWAYS slice the response from `GET /repos/{owner}/{repo}/commits/{sha}/statuses` to `.[0]` (newest first) when polling for a deploy/CI outcome, OR call `GET /repos/{owner}/{repo}/commits/{sha}/status` (the *combined* endpoint) instead. NEVER iterate the full array as if each row represents a distinct active context — that endpoint returns the entire state-transition history per context, so a single Vercel deploy will surface as one `pending` row plus a later `success` row. Treating both as live makes the poll loop see "still pending" forever and never terminate.

**Rationale.** GitHub exposes two superficially similar endpoints with very different semantics:

- `/commits/{sha}/statuses` — append-only history log. Every transition for every context (`pending` → `success`, etc.) is preserved as its own row, ordered newest-first. Length grows with each state change.
- `/commits/{sha}/status` — combined view. Returns one row per context, reflecting the *latest* state, plus an aggregate `state` field for the commit.

Polling code that loops over `.statuses[*]` and reasons "any pending → keep waiting" will treat the historical pending row from the start of a deploy as still active even after the success row lands. The deploy effectively never completes from the poller's perspective. Fix: either `data.statuses[0]` per context (newest-first ordering is documented), or — preferable for poll loops — switch to the combined endpoint which already collapses history to the current state.

## Repo state & flags

### Verify GitHub archive flag via API, not description text
[from hq-github-archive-flag-verify.md]

NEVER assume a GitHub repo is archived based on the word `[ARCHIVED]` (or any marker) in its description text. The true archive state must be verified via the API before planning any mutation:

```bash
gh api repos/{owner}/{name} --jq '.archived'
```

- `false` → pushes and API writes are allowed.
- `true`  → all writes rejected; run `gh repo unarchive {owner}/{name}` before any mutation, and consider re-archiving after (`gh repo archive ...`).

Description text is free-form metadata and does not change GitHub's access rules. `gh repo list` renders description prefixes verbatim, which can produce a `[ARCHIVED]` column that lies about the actual flag.

**Rationale.** Session on 2026-04-17 planned a full-repo history wipe on `{your-name}/hq-starter-kit`, which `gh repo list` showed as `[ARCHIVED]`. The plan reserved an extra step for `gh repo unarchive` under the assumption pushes would be rejected. A direct `gh api` check showed `archived: false` — the label was description text, not the flag. The unarchive step was a waste, and more importantly the opposite failure mode (assuming a truly archived repo is writable) would silently 403 every push. Always trust the API field, never the display.

## Bot credentials & GitHub Apps

### Prefer a scoped GitHub App over a fine-grained PAT for bot repo-creation scopes
[from hq-github-app-over-pat-for-bot-repo-creation.md]

ALWAYS prefer a scoped **GitHub App** (installed on a single organization) over a **fine-grained PAT** when a bot or automation needs repo-creation scope, org-admin permissions, or any scope that would be catastrophic if leaked.

Why the App wins:

| Property | GitHub App installation token | Fine-grained PAT |
|---|---|---|
| Lifetime | ~1 hour (auto-rotated by the App) | Up to 1 year (user sets it) |
| Scope | One org + one installation | Every org + every scope on the PAT, until revoked |
| Rotation | Automatic per request | Manual / calendar-driven |
| Leak blast radius | Bounded to installed org + install permissions | Every resource the PAT can reach |
| Revocation UX | Uninstall App from org (single click) | Requires the user to find + delete the PAT |
| Audit trail | App-specific audit events per action | Attributed to the owning user |

Use a fine-grained PAT only when:

1. You genuinely cannot run a GitHub App (e.g. no server to host the App's private key + JWT minting).
2. The PAT has a single, narrow scope that couldn't be harmful (e.g. read-only `metadata`).
3. You've set a PAT expiry ≤ 30 days and scheduled rotation.

NEVER use a classic PAT for bot automation if a fine-grained PAT or App can do the job.

**Implementation sketch (GitHub App):**

```
1. Create GitHub App in org settings → generate private key (.pem)
2. Install App into target org, pin to a specific repo list or "All repositories"
3. Bot code: sign a short-lived JWT with the App's private key →
   POST /app/installations/{installation_id}/access_tokens
   → receive ~1h installation token → use for API calls
4. Store the private key in Secrets Manager / 1Password; NEVER check it in
```

**Rationale.** Captured 2026-04-23 while designing a repo-creation bot. The initial impulse was to issue a fine-grained PAT with `contents: write + administration: write` scoped to the org. That PAT would have lived up to a year on the server and, if exfiltrated, would have granted the attacker the ability to create and archive every repo in the org until rotated. A GitHub App scoped to the same org, with identical permissions, ships ~1-hour installation tokens minted on demand. A leaked token expires within the hour; a leaked App private key can be rotated via App settings without re-auth'ing any caller. Operational cost of the App is one-time (generate key, install); the security improvement is permanent.

**Related:** `.claude/policies/hq-never-echo-tokens-stdout.md` (secrets hygiene); `companies/*/policies/*credential-access*` (per-company credential storage).

## Distribution via github-install

### Ship pre-built dist when distributing a Tailwind UI library via github-install
[from hq-tailwind-lib-github-install-ship-dist.md]

NEVER ship a Tailwind UI library via github-install with only source `.tsx` files. Tailwind's content scanner on the consumer side does not traverse `node_modules/` by default, so utility classes referenced inside the library drop from the generated CSS and inputs/buttons fall back to browser defaults (white inputs, unstyled text).

On the **producer** side, pick one:
- (a) Commit the pre-built `dist/` tree to git so `github:owner/repo` installs include compiled JS + CSS + types.
- (b) Publish to npm with explicit instructions for consumers to extend `tailwind.config.content` with the library's dist glob.
- (c) Ship a precompiled CSS file (`dist/styles.css`) that consumers import once — safest for Tailwind v4 consumers whose `content:` config is replaced by `@source` directives.

On the **consumer** side, extend `tailwind.config.ts`:

```ts
content: [
  './src/**/*.{ts,tsx}',
  './node_modules/<lib-name>/dist/**/*.{js,mjs}',
]
```

…or add `@source "../node_modules/<lib-name>/dist/**/*.{js,mjs}";` in Tailwind v4 CSS.

**Rationale.** Tailwind only emits a utility class if its content scanner finds a string match somewhere in the scanned tree. The default content glob stops at the app source tree; `node_modules/` is excluded for performance. A github-installed library that ships only source files therefore contributes zero matches to the consumer's CSS, even though its components render correctly at the DOM level — the classes just have no corresponding rules. Symptoms present as "styles missing on one component," "form inputs look unstyled," or "dark mode toggle doesn't work" after a fresh install. Pre-built dist files with inlined class strings sidestep the scanner limitation entirely.

