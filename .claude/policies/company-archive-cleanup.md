---
id: company-archive-cleanup
title: Clean up qmd + modules when archiving a company
scope: global
public: true
trigger: company archival or deletion
enforcement: hard
---

## Rule

When archiving or deleting a company, always:
1. Remove its qmd collection: `qmd collection remove {name}`
2. Delete the entry from `modules/modules.yaml`
3. Remove from `companies/manifest.yaml`
4. Remove from CLAUDE.md companies list

Stale collections pointing to deleted directories crash `qmd update` with ENOENT, blocking all reindexing.

