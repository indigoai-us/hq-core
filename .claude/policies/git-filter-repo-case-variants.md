---
id: git-filter-repo-case-variants
title: git-filter-repo requires explicit case variants
scope: command
trigger: /promote-hq-core, git history scrub
enforcement: hard
public: true
---

## Rule

When using `git filter-repo --replace-text`, add explicit replacement rules for EVERY case variant of each term (lowercase, Capitalized, UPPERCASE). The tool does exact literal matching — `{team-member}` does NOT match `{team-member}` or `SHAHZAIB`.

## Rationale

During v9.0.0 history scrub, first pass left 65 hits because names like `{team-member}`, `{team-member}`, `{team-member}`, and `{PRODUCT}` weren't matched by lowercase-only rules. Required a second pass with 29 additional case variants (74 total rules).

## How to apply

Build replacement files with all three cases for every denylist term: `literal:term==>`, `literal:Term==>`, `literal:TERM==>`.
