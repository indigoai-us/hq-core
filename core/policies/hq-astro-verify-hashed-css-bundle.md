---
id: hq-astro-verify-hashed-css-bundle
title: Verify Astro CSS tokens/keyframes against the hashed /_astro/*.css bundle, not the HTML response
scope: global
trigger: verifying CSS on deployed Astro page, grep for keyframes/tokens in curl output, astro deploy verification
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

When verifying CSS tokens, keyframes, custom properties, or any global stylesheet content on a deployed Astro page, fetch the **hashed `/_astro/*.css` bundle** (linked from the HTML `<head>`), not just the HTML response.

Astro compiles `<style>@import "..."</style>` blocks and any global CSS into a separate hashed asset during build. The inline `<style>` block in the rendered HTML contains ONLY the component-scoped selectors emitted by scoped `<style>` blocks — NOT the imported global stylesheets.

Canonical verification pattern:

```bash
# 1. Find the hashed CSS asset link in the HTML
CSS_PATH=$(curl -s "$URL" | grep -oE '/_astro/[^"]+\.css' | head -1)

# 2. Fetch the compiled bundle
curl -sSL -o /tmp/served.css "$URL$CSS_PATH"

# 3. Grep the bundle (not the HTML)
grep -c "your-token-name\|@keyframes your-anim" /tmp/served.css
```

Greeping `curl -s "$URL"` directly will produce false negatives for any global/imported CSS.

## Rationale

Session debug loop wasted iterations greping the HTML for tokens that had been moved into an `@import`-ed global stylesheet. The tokens existed in the deployed build but lived in `/_astro/abc123.css`, not in the inline scoped `<style>` block. Once the hashed bundle was fetched directly, verification passed immediately. This pattern generalizes to any bundler that emits hashed CSS assets (Vite, Rollup-based frameworks) but Astro is the primary case inside HQ.
