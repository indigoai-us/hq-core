---
id: hq-npm-subpackage-hydration
title: Hydrate npm sub-package node_modules via root postinstall/pretest hooks
scope: global
trigger: repo contains a sub-directory with its own package.json that tests or scripts invoke
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: back-pressure-failure
---

## Rule

When a repo has a sub-package (e.g. `cli/`, `lambda/`, `worker/`) with its own `package.json` and the root test suite or build invokes binaries from that sub-package, the root `package.json` must hydrate the sub-package's `node_modules` automatically. Two hooks, both required:

```json
"scripts": {
  "postinstall": "npm install --prefix <subdir> --no-audit --no-fund",
  "pretest": "node -e \"require('fs').existsSync('<subdir>/node_modules') || require('child_process').execSync('npm install --prefix <subdir> --no-audit --no-fund', {stdio:'inherit'})\""
}
```

The `postinstall` covers fresh clones. The `pretest` guard covers the case where `node_modules` was pruned, never populated, or the repo was checked out without running `npm install` (e.g. a CI cache that skipped the root hook). Keep the guard cheap — test for the directory's existence before shelling out.

Never assume `npm install` at the repo root traverses sub-directories. It does not. Workspaces (`workspaces:` in `package.json`) are the idiomatic solution when the tree is designed for it, but they require buy-in from every sub-package and may conflict with independent versioning. For retrofits onto an existing layout, the postinstall+pretest pair is strictly additive and carries no workspace semantics.

