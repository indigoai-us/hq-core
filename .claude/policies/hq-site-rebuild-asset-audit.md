---
id: hq-site-rebuild-asset-audit
title: Audit total asset count when scraping sites for rebuilds
scope: global
trigger: site rebuild, asset download, US-002-style asset scraping stories
enforcement: soft
version: 1
created: 2026-03-12
updated: 2026-03-12
source: success-pattern
public: true
---

## Rule

ALWAYS compare total asset count between source site and destination repo when scraping assets for site rebuilds. Do not rely solely on pattern-matching brand/entity names — site-level assets (hero videos, background images, global media, intro reels) are commonly missed because they lack entity-specific naming. After downloading, run a count comparison: source asset URLs vs local files.

## Rationale

During the {company}-brands-site rebuild, the US-002 asset scraper downloaded all 6 brand videos and 6 product images but missed the dedicated `hero-video.mp4` because it wasn't associated with any specific brand name. The hero section rendered as a white void on deployment. A simple count comparison (7 videos on source vs 6 downloaded) would have caught it immediately.
