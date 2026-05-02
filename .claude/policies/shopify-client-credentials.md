---
id: shopify-client-credentials
title: Shopify Admin API uses Client Credentials Grant (no permanent tokens)
scope: global
trigger: shopify admin api, create pages, shopify custom app
enforcement: soft
applies_to: [shopify]
public: true
---

## Rule

Shopify no longer issues permanent `shpat_*` Admin API access tokens. Custom apps use **Client Credentials Grant** (OAuth 2.0):

1. Get Client ID + Client Secret from the app's Settings in Shopify Admin
2. Exchange for a short-lived token (24h expiry):
   ```
   POST https://{store}.myshopify.com/admin/oauth/access_token
   -d grant_type=client_credentials
   -d client_id={client_id}
   -d client_secret={client_secret}
   ```
3. Response: `{ "access_token": "shpat_...", "scope": "...", "expires_in": 86399 }`
4. Use the `shpat_*` token in `X-Shopify-Access-Token` header for Admin API calls

The `shpss_*` value is the **Client Secret** — it's used to *request* tokens, not as a token itself.

Theme Access tokens (`shptka_*`) remain unchanged and are still used for `shopify theme push/pull`.

## Rationale

Shopify deprecated permanent admin tokens. The new model limits blast radius of leaked credentials (24h window vs forever). Discovered 2026-03-17 when attempting to create Shopify pages.
