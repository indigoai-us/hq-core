---
id: prd-content-sources
title: PRD content extraction stories should reference all HQ source locations
scope: command
trigger: /prd, content-extraction stories
enforcement: soft
---

## Rule

When creating PRD stories that involve content extraction or analysis of a person's written/spoken work, enumerate ALL available source locations in HQ — not just the obvious one. Content lives in multiple places:

- `companies/{co}/data/` — raw data (transcripts, exports)
- `repos/private/personal-website/src/content/blog/*.mdx` — published blog posts (24+ files)
- `workspace/social-drafts/x/*-article.md` — article drafts (20+ files)
- `workspace/social-drafts/linkedin/` — LinkedIn posts (67+ files)
- `companies/{co}/knowledge/` — strategic docs, voice guides
- `companies/personal/knowledge/brand/` — personal voice guide, story arc

List specific glob paths in the story's `acceptanceCriteria` so the execute-task sub-agent can find them without searching.

