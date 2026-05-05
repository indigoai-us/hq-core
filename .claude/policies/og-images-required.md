---
id: hq-og-images-required
title: OG Images Required on All Deployed Sites
scope: global
trigger: deploying any site to Vercel or any public hosting
enforcement: soft
version: 1
created: 2026-02-26
updated: 2026-02-26
source: user-directive
learned_from: "{your-project} deployment — user requested OG images always be included"
public: true
---

## Rule

Every site deployed to Vercel (or any public hosting) MUST have Open Graph images configured before the first production deploy. This includes:

1. **OG image** — at minimum one 1200x630 image for the site root
2. **Metadata** — `og:image`, `og:title`, `og:description`, `twitter:card`, `twitter:image` meta tags
3. **metadataBase** — set to the production URL so OG image URLs resolve correctly

**Preferred approaches (in order):**
- Next.js `opengraph-image.tsx` file convention (generates at build/runtime)
- Static image in `public/` referenced via metadata export
- `@vercel/og` route handler for dynamic generation

**Per-page OG images** are preferred for sites with distinct sections (e.g. product pages, blog posts). At minimum, the root layout must set a default OG image that all pages inherit.

## Rationale

Sites without OG images display blank thumbnails when shared on social media, Slack, and messaging apps. This is a basic quality bar for any deployed site.
