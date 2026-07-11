---
id: hq-sync-codex-validation-and-conflict-resolution
title: Validate HQ Sync from Codex with the menubar-equivalent root and compare conflict files
when: sync
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-05-17
updated: 2026-05-17
source: session-learning
---

## Rule

ALWAYS, for HQ Sync menubar validation from Codex, run:

```bash
hq sync now --hq-root ~/Documents/HQ --all --on-conflict abort
```

Do not use plain `hq sync` for validation. It only prints help, and the CLI default root may be `~/hq` instead of the menubar-configured HQ path.

ALWAYS compare the original file and its `.conflict-*` counterpart before choosing a conflict resolution. The conflict index can contain duplicate or byte-identical stale entries, while the real content difference may be limited to one repeated path.

## Rationale

Captured from HQ Sync validation work. Menubar behavior needs to be exercised against the same HQ root the menubar uses, and conflict queues can contain stale or duplicate-looking entries that make bulk resolution unsafe without file comparison.
