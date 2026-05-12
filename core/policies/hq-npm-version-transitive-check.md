---
id: hq-npm-version-transitive-check
title: Verify transitive install resolves before recommending a new npm version
scope: global
trigger: bumping or recommending a newly-published npm package version (own or third-party)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

NEVER: Assume a newly-published npm version is installable just because `npm publish` succeeded or `npm view <pkg> version` shows it. Transitive dependencies may reference unpublished sibling packages.

ALWAYS: Before recommending a version (in docs, install commands, skill snippets, onboarding flows), verify a clean install succeeds end-to-end:

```bash
# In a throwaway dir
npm install <pkg>@<version> --no-save --prefer-online
# or equivalently
npx --yes <pkg>@<version> --help
```

If the install 404s on a transitive dep, the version is unshipped from the consumer's perspective regardless of what the registry says about the top-level package. Pin to the last known-good version.

## Rationale

A package published successfully but its `package.json` listed a transitive dependency that had never been published. `npm install -g` 404'd for every user. The prior version already shipped the needed flow and was the correct target to recommend.

The lesson is that `npm publish` validates the tarball, not the dep graph. A green publish can still yield an uninstallable package. Always do a fresh install probe before telling anyone (including your own docs or skills) to use the new version.
