---
type: guide
domain: [engineering, product, growth]
status: canonical
tags: [shopify, headless, next-js, storefront-api, dtc-launch, ecommerce]
relates_to: []
---

# Shopify DTC Brand Launch Playbook

A comprehensive reference for launching direct-to-consumer brands on headless Shopify (Next.js + Storefront API). Based on the TONAL launch (Feb 2026) -- all patterns are battle-tested, not hypothetical.

---

## 1. Auth Flow

### Shopify 2026 Authentication Model

As of January 2026, Shopify no longer issues permanent Admin API tokens from the store admin. All new apps use the Developer Dashboard with `client_credentials` grant.

#### Token Table

| Credential | Format | Source | Lifespan | Usage |
|-----------|--------|--------|----------|-------|
| `client_id` | App ID string | Shopify Dev Dashboard > App > Overview | Permanent | Identifies your app |
| `client_secret` / `shpss_` | `shpss_*` token | Shopify Dev Dashboard > App > Client credentials | Permanent | Used as grant credential + Storefront API token |
| `shpat_` (Admin API token) | `shpat_*` token | `POST /admin/oauth/access_token` | 24 hours | Admin API calls (products, orders, images) |

#### Token Regeneration Pattern

The Admin API token expires every 24 hours. Regenerate on demand before any Admin API session:

```bash
curl -s -X POST "https://{store}.myshopify.com/admin/oauth/access_token" \
  -H "Content-Type: application/json" \
  -d '{"client_id":"{client_id}","client_secret":"{client_secret}","grant_type":"client_credentials"}' \
  | jq -r '.access_token'
```

In scripts (TypeScript pattern from TONAL `setup-products.ts`):

```typescript
const envPath = resolve(__dirname, "../settings/shopify/.env");
const env = loadEnv(envPath);
const STORE = env.SHOPIFY_STORE_DOMAIN;
const ADMIN_TOKEN = env.SHOPIFY_ADMIN_ACCESS_TOKEN;
// Token must be refreshed if expired. Script exits with clear error if placeholder.
```

#### Credential Storage

Store credentials in `companies/{brand}/settings/shopify/.env`:

```env
# Shopify credentials for {BRAND}
SHOPIFY_STORE_DOMAIN={slug}.myshopify.com
SHOPIFY_CLIENT_ID=<paste-your-client-id>
SHOPIFY_CLIENT_SECRET=<paste-your-shpss-token>
SHOPIFY_ADMIN_ACCESS_TOKEN=<regenerate-via-client_credentials-grant>
SHOPIFY_STOREFRONT_TOKEN=<same-as-client-secret-shpss>
```

#### Required API Scopes

For the custom app in Shopify Dev Dashboard, enable:
- `write_products`, `read_products` -- catalog management
- `write_inventory`, `read_inventory` -- stock tracking
- `read_product_images`, `write_product_images` -- image upload
- `read_orders` -- order visibility (checkout is Shopify-hosted)

#### Gotcha: Storefront API Token Identity

The `shpss_` token from the Dev Dashboard serves double duty: it is both the `client_secret` for Admin API token generation AND the Storefront API access token. The Storefront API does not use `shpat_` tokens. Store it once, use it for both purposes.

---

## 2. Checkout Strategy

### Recommendation: Cart Permalink (not Draft Order API)

Use Shopify's cart permalink pattern to redirect customers to Shopify-hosted checkout. This is simpler and more reliable than the Draft Order API.

#### Cart Permalink Pattern

```
https://{store}.myshopify.com/cart/{variant_id}:{quantity},{variant_id}:{quantity}
```

Example:
```
https://tonal-8.myshopify.com/cart/49012345678:1,49012345679:2
```

#### Why Cart Permalink Over Draft Order API

| Factor | Cart Permalink | Draft Order API |
|--------|---------------|-----------------|
| API scopes needed | None (URL-based) | `write_draft_orders` |
| Token dependency | None | Admin API (24h expiry) |
| Implementation | URL construction | API call + redirect to invoice URL |
| Discount support | URL params | Full API control |
| Failure mode | Graceful (Shopify shows cart) | Hard failure if token expired |
| Checkout UX | Standard Shopify checkout | Invoice-style checkout page |

#### Cart State Architecture

For headless storefronts without a valid Storefront API cart token:

1. **localStorage cart** -- store line items (variant ID, quantity, color, size, title, price, image) in React context backed by localStorage
2. **Checkout redirect** -- on "Checkout" click, construct cart permalink from localStorage items and redirect to Shopify-hosted checkout
3. **No Shopify Cart API dependency** -- avoids needing a separate Storefront API token for cart operations

```typescript
// Build checkout URL from local cart state
const checkoutUrl = `https://${STORE}/cart/${
  items.map(item => `${item.variantId}:${item.quantity}`).join(',')
}`;
window.location.href = checkoutUrl;
```

#### Draft Order API (When Needed)

Use Draft Orders only when you need:
- Custom line item pricing not in Shopify
- Complex discount logic beyond URL params
- B2B/wholesale pricing per customer
- Tax-exempt orders

If using Draft Orders, always regenerate the Admin API token before the checkout flow -- expired tokens cause silent checkout failures.

---

## 3. Catalog Pipeline

### Product Data Architecture

Maintain a single source-of-truth JSON catalog file at `companies/{brand}/data/product-catalog.json`.

#### Catalog Structure

```json
{
  "metadata": {
    "brand": "BRAND_NAME",
    "store": "{slug}.myshopify.com",
    "fulfillment": "TapStitch|Printful|Custom",
    "currency": "USD",
    "pricingStrategy": "Description of pricing position"
  },
  "collections": [
    {
      "handle": "collection-slug",
      "title": "Collection Name",
      "description": "Collection description",
      "sortOrder": "BEST_SELLING|MANUAL"
    }
  ],
  "products": [
    {
      "productType": "Tee",
      "title": "Product Name",
      "handle": "product-slug",
      "description": "Product description in brand voice",
      "baseCost": 15.00,
      "retailPrice": 48.00,
      "compareAtPrice": null,
      "collections": ["collection-handle"],
      "tags": ["tag1", "tag2"],
      "sizes": ["S", "M", "L", "XL", "2XL", "3XL"],
      "colors": [{"name": "White", "hex": "#FFFFFF"}],
      "weight": "200g",
      "material": "100% Cotton, 6.5oz",
      "fit": "Relaxed",
      "care": "Machine wash cold, tumble dry low"
    }
  ]
}
```

### Product Push Script Pattern

Use a TypeScript script (`setup-products.ts`) to push the catalog to Shopify via Admin REST API:

1. **Read** `product-catalog.json` as the catalog source
2. **Create collections** first (products reference them via handles)
3. **Create products** with full variant matrix (color x size)
4. **Link products to collections** via the Collects API
5. **Rate limiting**: 500ms between collections, 1000ms between products, retry on 429

Key implementation details from TONAL:
- SKU format: `{handle}-{color-slug}-{size}` (e.g., `heavyweight-tee-white-xl`)
- Inventory policy: `continue` for print-on-demand fulfillment (never track stock)
- Metafields: store material, fit, care, base cost in `{brand}` namespace
- Body HTML: structured with `<h3>Details</h3>` and `<h3>Care</h3>` sections
- Variant options: always `[{name: "Color"}, {name: "Size"}]`
- Use `--dry-run` flag for testing without API calls

#### TONAL Scale Reference

TONAL launched with: 6 products, 186 variants, 3 custom collections, 9 collection links. Setup time: ~5 minutes (including rate limiting pauses).

---

## 4. Imagery Pipeline

### AI Image Generation

Use Google Gemini (Imagen 3 via `gnb` CLI or API) for product imagery when studio photography is not available:

1. **Generate PNG source images** at high resolution
2. **Flat-lay or on-model** style against white/light backgrounds
3. **Two images minimum per product**: front view + detail/texture shot
4. **Hero/lifestyle images**: 16:9 aspect ratio for homepage sections

#### TONAL Image Counts

| Category | Images | Notes |
|----------|--------|-------|
| Product fronts | 16 | One per product/colorway |
| Product details | 6 | One per product type |
| Hero/lifestyle | 3 | 16:9 for homepage |
| **Total PNGs** | **25** | Source files |
| **Total WebPs** | **75** | 3 sizes each |

### WebP Optimization Script

Convert PNGs to responsive WebP using ImageMagick:

```bash
#!/bin/bash
# optimize-images.sh - PNG to WebP at 400w, 800w, 1200w

DST="companies/{brand}/data/product-images"
WEBP_DIR="$DST/webp"
mkdir -p "$WEBP_DIR"

convert_image() {
  local src="$1"
  local basename=$(basename "$src" .png)
  for width in 400 800 1200; do
    local outfile="$WEBP_DIR/${basename}-${width}w.webp"
    magick "$src" -resize "${width}x>" -quality 85 -define webp:method=6 "$outfile"
  done
}

for category in tees hoodies sweaters quarter-zips bombers jerseys hero; do
  for png in "$DST/$category"/*.png; do
    [ -f "$png" ] || continue
    convert_image "$png"
  done
done
```

**Key settings:**
- `-resize "${width}x>"` -- downscale only (never upscale), maintain aspect ratio
- `-quality 85` -- good balance of size vs quality for product photos
- `-define webp:method=6` -- slowest/best compression
- Three breakpoints: 400w (mobile), 800w (tablet), 1200w (desktop)

### Image Upload to Shopify

After optimization, upload images to Shopify CDN via Admin API:
- Use `POST /admin/api/{version}/products/{id}/images.json`
- Set `variant_ids` for color-specific product shots
- Shopify CDN handles further optimization and edge caching

#### Directory Structure

```
companies/{brand}/data/product-images/
  tees/
    heavyweight-tee-white-front.png
    heavyweight-tee-white-detail.png
  hoodies/
    ...
  hero/
    hero-collection-flatlay.png
    hero-lifestyle-model.png
  webp/
    heavyweight-tee-white-front-400w.webp
    heavyweight-tee-white-front-800w.webp
    heavyweight-tee-white-front-1200w.webp
    ...
```

---

## 5. Storefront Architecture

### Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Framework | Next.js 14+ (App Router) | Server components for SEO, client for interactivity |
| Styling | Tailwind CSS | Customized with brand tokens |
| Data | Shopify Storefront API (GraphQL) | Products, collections, shop info |
| Admin ops | Shopify Admin REST API | Product creation, image upload, order management |
| Hosting | Vercel | Git-push deploys, edge functions |
| Images | Shopify CDN + Next.js Image | Automatic optimization |

### Scaffold Approach

Start from an established template rather than from scratch:
- **Vercel Commerce template** (v0 base) is the recommended starting point
- Provides: product grid, PDP, cart, Shopify integration, Tailwind, TypeScript
- Customize: strip template branding, apply brand guidelines, add custom pages

### Key Architecture Decisions

1. **Server Components for SEO**: Product pages, collection pages, and the homepage use React Server Components. This enables full server-side rendering with proper meta tags and JSON-LD structured data.

2. **Client Components for Interactivity**: Cart slide-out, color/size selectors, and add-to-cart actions use client components with React context for cart state.

3. **localStorage Cart**: When Storefront API cart tokens are unavailable or unreliable, use localStorage-backed React context. Cart permalink handles checkout redirect.

4. **No Shopify theme dependency**: The entire storefront is custom Next.js. Shopify's theme engine is not used. The Shopify store exists only as a headless backend for products, orders, and checkout.

### Storefront File Structure

```
src/
  app/
    page.tsx              # Homepage (hero, featured products, brand story)
    products/
      page.tsx            # PLP - collection grid
      [handle]/page.tsx   # PDP - product detail
    about/page.tsx        # Brand story
    cart/page.tsx         # Cart page (or slide-out component)
    layout.tsx            # Root layout with nav, footer, cart provider
  components/
    product-card.tsx      # Grid card with swatches
    product-gallery.tsx   # PDP image gallery
    color-swatch.tsx      # Interactive color selector
    size-selector.tsx     # Size buttons with guide modal
    cart-provider.tsx     # React context for cart state
    cart-slide-out.tsx    # Slide-out cart modal
  lib/
    shopify.ts            # Storefront API client
    shopify-admin.ts      # Admin API client (if needed)
```

---

## 6. Fulfillment Integration

### Print-on-Demand (TapStitch / Printful)

For print-on-demand fulfillment:

1. **Install the fulfillment app** in Shopify admin (TapStitch, Printful, etc.)
2. **Set inventory policy to `continue`** -- never track stock (items are printed on demand)
3. **Map products** in the fulfillment app's dashboard to their print templates
4. **Orders auto-route** -- when a customer completes Shopify checkout, the order automatically routes to the fulfillment provider

#### Shopify Integration Points

| Setting | Value | Why |
|---------|-------|-----|
| `inventory_management` | `"shopify"` | Required by Shopify |
| `inventory_policy` | `"continue"` | Allow overselling (print-on-demand has no stock) |
| `requires_shipping` | `true` | Physical goods |
| `fulfillment_service` | Set via app | Auto-assigned when fulfillment app processes order |

#### Testing Fulfillment

- Place a test order through the live checkout flow
- Verify the order appears in both Shopify admin and the fulfillment provider dashboard
- Confirm shipping notification emails fire when the provider ships
- Note: test orders require the store to be publicly accessible (disable Shopify password protection)

---

## 7. Vercel Deployment

### Project Setup

```bash
# Create Vercel project (CLI)
vercel --scope {vercel-org} --yes

# Or link existing repo
vercel link --scope {vercel-org}
```

### Environment Variables

Set in Vercel project settings (Production environment):

```
SHOPIFY_STORE_DOMAIN={slug}.myshopify.com
SHOPIFY_STOREFRONT_ACCESS_TOKEN={shpss_token}
SHOPIFY_ADMIN_ACCESS_TOKEN={shpat_token}  # If admin API needed at runtime
NEXT_PUBLIC_STORE_DOMAIN={slug}.myshopify.com
SITE_NAME={Brand Name}
SITE_URL=https://{domain}
```

### Framework Detection Gotcha

**Critical:** If the Vercel project has `framework: null`, production builds will deploy successfully but serve 404 on ALL routes. The build output appears normal, but Vercel does not know how to route requests to the Next.js app.

**Fix:**
```bash
# Check current framework setting
curl -s -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v9/projects/{project-id}?teamId={team-id}" \
  | jq '.framework'

# If null, set it:
curl -s -X PATCH -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.vercel.com/v9/projects/{project-id}?teamId={team-id}" \
  -d '{"framework":"nextjs","installCommand":"pnpm install"}'

# Then redeploy
git push  # or vercel --prod
```

**Prevention:** Always verify `framework` is set after creating a Vercel project. The `vercel link` command sometimes fails to detect the framework automatically.

### Domain Connection

1. **Purchase domain** via preferred registrar (Name.com, Namecheap, Cloudflare, or Vercel itself)
2. **Add domain to Vercel project**: Settings > Domains > Add
3. **Configure DNS**: Point domain to Vercel
   - A record: `76.76.21.21`
   - Or CNAME: `cname.vercel-dns.com`
4. **SSL**: Auto-provisioned by Vercel (Let's Encrypt)

### Domain Team Move Issue

When purchasing a domain via Vercel/Name.com, it can land in the wrong Vercel team/org.

**Diagnosis:**
```bash
# Check which team owns the domain
curl -s -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v6/domains/{domain}?teamId={team-id}"
```

**Fix -- move between teams:**
```bash
curl -s -X PATCH -H "Authorization: Bearer $VERCEL_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.vercel.com/v6/domains/{domain}?teamId={source-team-id}" \
  -d '{"op":"move-out","destination":"{target-team-id}"}'
```

Vercel-purchased domains cannot be deleted -- they must be moved to the correct team.

### Deploy Checklist

- [ ] GitHub repo connected for auto-deploy on push to `main`
- [ ] All environment variables set in Vercel production
- [ ] Framework set to `nextjs` (not null)
- [ ] Custom domain added and DNS configured
- [ ] SSL certificate provisioned (auto)
- [ ] Build succeeds on Vercel with no errors
- [ ] All routes return 200 (not 404)

---

## 8. SEO Checklist

### Technical SEO

- [ ] `sitemap.xml` auto-generated (Next.js `app/sitemap.ts`)
- [ ] `robots.txt` configured (`app/robots.ts`)
- [ ] All pages have unique `<title>` tags (pattern: `{Page} | {Brand}`)
- [ ] All pages have `<meta name="description">` tags
- [ ] OpenGraph meta tags on every page (`og:title`, `og:description`, `og:image`)
- [ ] Twitter/X card meta tags (`twitter:card`, `twitter:title`, `twitter:image`)
- [ ] Canonical URLs set on all pages
- [ ] JSON-LD structured data on product pages (`Product` schema with `brand`, `offers`, `image`)

### Performance SEO

- [ ] Lighthouse Performance score > 90
- [ ] Images use Next.js `<Image>` component with proper `width`/`height`/`alt`
- [ ] Web fonts loaded with `font-display: swap` (no layout shift)
- [ ] No render-blocking resources

### Content SEO

- [ ] Product descriptions are unique (not copy-pasted from fulfillment provider)
- [ ] Collection pages have descriptions
- [ ] About page exists with brand story
- [ ] Alt text on all product images (format: `{Product Name} in {Color}`)

### Shopify-Specific

- [ ] Shopify admin SEO fields filled (title, description) -- even though headless, Shopify indexes these
- [ ] Product handles are clean slugs (e.g., `heavyweight-tee` not `heavyweight-tee-1`)

---

## 9. QA Checklist

### Functional QA

- [ ] **Browse flow**: Homepage > collection > PLP > PDP works with no errors
- [ ] **Product display**: All products load with correct images, prices, descriptions
- [ ] **Color selector**: Swatches change product image and update variant selection
- [ ] **Size selector**: All sizes selectable, size guide modal opens/closes correctly
- [ ] **Add to cart**: Item appears in cart with correct details (name, color, size, quantity, price)
- [ ] **Cart operations**: Update quantity, remove item, cart total updates in real-time
- [ ] **Checkout redirect**: Cart permalink redirects to Shopify-hosted checkout with correct items
- [ ] **Navigation**: All nav links work, mobile menu opens/closes, logo links to homepage
- [ ] **About page**: Content renders, responsive layout works

### Responsive QA

Test on three breakpoints:
- [ ] **375px** (mobile): Single column, hamburger menu, touch-friendly targets
- [ ] **768px** (tablet): 2-column grids, nav adjusts
- [ ] **1280px** (desktop): Full layout, 3-4 column grids, hover states work

### Cross-Browser QA

- [ ] **Chrome** (primary): Full test pass
- [ ] **Safari**: Verify CSS grid, WebP support, scroll behavior
- [ ] **Firefox**: Verify layout, fonts, interactive elements

### Performance QA

- [ ] Lighthouse audit: Performance > 90, Accessibility > 90, SEO = 100, Best Practices = 100
- [ ] No console errors in production build
- [ ] Images lazy-load below the fold
- [ ] First Contentful Paint < 2s

### Pre-Launch Checks

- [ ] Shopify store password protection disabled (Settings > Online Store > Preferences)
- [ ] Test order placed through full checkout flow
- [ ] Fulfillment provider receives and processes test order
- [ ] Order confirmation email received
- [ ] Shipping notification fires when fulfilled
- [ ] Custom domain resolves with valid SSL
- [ ] Analytics tracking verified (Vercel Analytics or GA4)

---

## 10. Cost Summary

### Recurring Costs

| Service | Cost | Billing | Notes |
|---------|------|---------|-------|
| Shopify Basic | $39/mo | Monthly | Store backend + checkout |
| Vercel Pro | $20/mo | Monthly | Hosting (or free Hobby tier for low traffic) |
| Domain | ~$12/yr | Annual | Via Name.com, Namecheap, or Vercel |
| **Total (minimum)** | **~$51/mo** | | Shopify + free Vercel tier |
| **Total (recommended)** | **~$71/mo** | | Shopify + Vercel Pro |

### One-Time / Variable Costs

| Item | Cost | Notes |
|------|------|-------|
| Shopify app (TapStitch/Printful) | Free | Revenue share model (cost per item) |
| Product fulfillment | Per order | Varies by product (e.g., $15 base for tee) |
| AI image generation | ~$0 | Gemini API free tier covers launch volume |
| Domain purchase | $10-15 | One-time via registrar |
| Custom photography | $0-2000 | Optional -- AI generation works for launch |

### Margin Planning

Use the catalog JSON to track margins:
```
Retail price - Base cost = Gross margin per unit
```

TONAL reference margins:
- Tees: $48 retail / $15 cost = 69% margin
- Hoodies: $85 retail / $30 cost = 65% margin
- Bombers: $120 retail / $40 cost = 67% margin

Target: 60-70% gross margin for print-on-demand DTC. Factor in Shopify transaction fees (2.9% + $0.30 on Basic plan) and fulfillment shipping costs.

---

## Appendix: TONAL Launch Timeline

For reference, the TONAL launch followed this sequence across 13 user stories:

1. Brand Identity (creative -- opus model)
2. Company Scaffold in HQ
3. Shopify Store Creation (manual)
4. Product Catalog Setup (script)
5. Product Imagery (AI generation + optimization)
6. Scaffold Storefront (from template)
7. Brand Design Customization
8. Product Pages (PLP + PDP)
9. Cart + Checkout Flow
10. About/Brand Story Page
11. Domain + Vercel Deployment
12. Analytics + SEO
13. Launch QA

**Optimized sequence for future launches:** 10 stories (merge brand story into brand design, merge analytics into deployment, eliminate separate scaffold step by using `/launch-brand` command). See `brand-launch-template.json` for the streamlined template.
