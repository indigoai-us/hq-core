---
id: hq-sed-delimiter-not-pipe-on-table-rows
title: Use @ or # as sed delimiter when editing markdown table rows
scope: global
trigger: Running sed -i (or sed | tee) substitutions on lines that may contain markdown table pipes (`|`)
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

ALWAYS: When sed-editing markdown table rows (any line containing `|`), use `@` or `#` as the sed substitution delimiter instead of the default `|`. Default `|` collides silently with table pipes — sed reports `bad flag in substitute command` and the substitution is skipped. Subsequent verification grep across a batch of files can still pass on OTHER files in the batch, masking which file failed.

Example — wrong:
```bash
sed -i '' 's|old text|new text|' README.md
```

Example — right:
```bash
sed -i '' 's@old text@new text@' README.md
sed -i '' 's#old text#new text#' README.md
```

If the change spans many files, do not rely on a single batch verification grep — verify each file individually, or use `git diff --stat` to confirm every target file was modified.

## Rationale

Discovered during a multi-file scrub pass where one file in the batch silently failed because the search/replace landed on a markdown table row. The default `|` delimiter was interpreted as part of the table pipe, sed errored out on that file, but the rest of the batch succeeded. The verification grep across all files passed because it matched the expected new text in the OTHER files — masking the single file that was never edited. Switching to `@`/`#` eliminates the collision entirely; markdown content basically never contains `@` or `#` in positions that conflict with sed parsing.
