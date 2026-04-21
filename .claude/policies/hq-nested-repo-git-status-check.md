---
id: hq-nested-repo-git-status-check
title: Check git status inside nested repos like repos/public/hq/
scope: global
trigger: When editing files inside `repos/public/hq/template/` or any other nested git repo under HQ
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: user-correction
---

## Rule

`repos/public/hq/` is a separate git repository, not a submodule. HQ has no `.gitmodules` file — nested repos are opaque to HQ root git. After editing anything under `repos/public/hq/template/`:

```bash
# WRONG — HQ root git does not see template edits
git -C /Users/{your-name}/Documents/HQ status

# RIGHT — check the nested repo
git -C /Users/{your-name}/Documents/HQ/repos/public/hq status
git -C /Users/{your-name}/Documents/HQ/repos/public/hq diff template/
```

Same pattern applies to pattern-1 embedded knowledge repos (`companies/*/knowledge/.git`) and pattern-2 symlinked repos whose target lives in `repos/private/knowledge-*/`.

