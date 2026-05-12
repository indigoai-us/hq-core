---
id: hq-prd-verify-passes-vs-artifact-registry
title: Verify PRD story passes against the artifact registry, not just the PR
scope: global
trigger: Marking a PRD story `passes: true` when the acceptance criteria references a published artifact (npm version, Docker image tag, Vercel deployment URL, GitHub release, APK/IPA build)
enforcement: hard
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

NEVER: Mark a PRD story `passes: true` when the acceptance criteria says "published to npm at vX.Y.Z" (or "deployed to {url}", "released as {tag}", etc.) based solely on a merged PR, a green CI run, or a sub-agent's self-report. Merged code is not shipped code — the artifact registry is the source of truth.

ALWAYS: Before flipping `passes: true` on any story whose AC references an external artifact, probe the registry directly AND confirm the artifact carries the expected diff:

```bash
# npm — version must match AND tarball must contain the change
npm view <pkg> version                               # matches target?
npm pack <pkg>@<version> --dry-run 2>&1 | grep <file> # contains expected file?
# or: install into a throwaway dir and grep the installed tree for a post-change string

# Vercel — deployed URL must serve the expected build
curl -sI https://<domain>/<path> | grep -i x-vercel-id  # live?
curl -s https://<domain>/<route> | grep '<post-change-string>'

# Docker — tag must resolve and image must contain the change
docker manifest inspect <registry>/<image>:<tag> >/dev/null
docker pull <registry>/<image>:<tag> && docker run --rm <image>:<tag> --version

# GitHub release — tag must exist and asset must be present
gh release view <tag> -R <owner>/<repo> --json assets
```

Both checks are required: version match + diff presence. A version bump without the diff (e.g. because the publisher built from a stale branch) is the exact failure mode this rule exists to catch.

## Rationale

Observed 2026-04-22/23 on `hq-core-split`: US-002, US-003, and US-004 were all marked `passes: true` based on the merged PR and green CI, while `create-hq@10.10.0` on the npm registry still shipped the pre-split behavior. The publisher had built from a stale local branch; the artifact carried none of the split's changes. Downstream users installing the package got the old behavior while the PRD claimed the stories were complete.

This policy is the artifact-registry sibling to `hq-prd-verify-passes-vs-git-log.md` (which enforces the git-log axis of the same underlying principle). The lesson is the same at both layers: `passes` must reflect the state of the deliverable users actually receive, not the state of the commits that were supposed to produce it. A PR merge proves the intent; only the registry proves the outcome.

## Related

- `.claude/policies/hq-prd-verify-passes-vs-git-log.md` — same principle, git-log axis
- `.claude/policies/hq-npm-version-transitive-check.md` — additional npm-specific install-probe rule
- `.claude/policies/hq-cli-version-read-from-package-json.md` — makes `--version` a reliable probe target
