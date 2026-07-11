---
id: hq-auth-middleware-whitelist-password-flow
title: Audit auth middleware whitelist when adding password-protected flow entry points
when: auth || middleware
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
vendor_public_ok: true
version: 1
created: 2026-04-28
updated: 2026-04-28
source: session-learning
---

## Rule

ALWAYS: For password-protected app flows where the entry-point endpoints (e.g. `/__access` form, `/api/access/verify` POST) must serve unauthenticated visitors of the customer's customers, audit the auth middleware whitelist whenever you add such endpoints. NextAuth/Clerk middleware blocks unauth visitors by default, deadlocking the flow with a redirect they can't fulfill.

## Rationale

NextAuth v5 and Clerk middleware apply to all routes by default and redirect unauthenticated requests to the sign-in page. For B2B features like password-protected microsites, preview links, or embeds, the end-visitor is never a logged-in user — they're a customer's customer. If the access entry point (form GET + verify POST) is not explicitly whitelisted in `matcher` or `publicRoutes`, the visitor is redirected to the app's own sign-in page, which they have no credentials for and can never satisfy.

Always check middleware config immediately after adding any endpoint that must be publicly accessible. The symptom (redirect loop or 401) is easy to misread as a CSRF or cookie issue.
