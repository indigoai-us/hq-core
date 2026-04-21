---
id: og-image-twitter-cache
title: Deploy OG images before sharing URLs on social
scope: command
trigger: blog publishing, /post, social posting
enforcement: soft
---

## Rule

When adding or changing OG images for a site, always deploy and verify the OG image endpoint returns valid PNG **before** sharing the URL on X/LinkedIn. X caches link card previews on first crawl — if the URL is shared before the OG image is live, the cached "no image" card persists and cannot be refreshed without deleting and reposting.

**Workflow:** Deploy site → verify OG endpoint with `curl -sI` → then post to social.

