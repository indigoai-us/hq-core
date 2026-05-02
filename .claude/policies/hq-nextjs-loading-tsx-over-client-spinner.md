---
id: hq-nextjs-loading-tsx-over-client-spinner
title: Prefer loading.tsx over custom client-side spinners for App Router perceived-latency
scope: global
trigger: Next.js App Router page with cached server payload and noticeable cold-nav wait
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

For Next.js App Router perceived-latency fixes, prefer colocated `loading.tsx` (automatic `<Suspense>` boundary wrapped around the segment) over wiring custom client-side spinners in the page shell.

Rule of thumb:
- Cold nav → server-rendered skeleton (from `loading.tsx`) shows instantly while the server component streams.
- Warm nav (cached payload) → page serves in <1s, skeleton flashes briefly or not at all.

**Do not:**
- Wrap server components in client `<Spinner>` components — forces a client boundary, defeats streaming, and doubles work.
- Use `router.events` or `usePathname` listeners to toggle a manual loading state — `loading.tsx` is free and does this natively.

Pairs cheaply with cached payloads: the skeleton is the cost-free perceived-latency fix.

## Rationale

Adding `loading.tsx` next to `page.tsx` with a lightweight skeleton eliminated the blank screen with zero client-bundle cost. The custom spinner version attempted earlier required a client shell + `useEffect` + cleanup and still flashed through transitions oddly.

Reference: Next.js App Router docs, `loading.tsx` file convention wraps the segment in `<Suspense>` automatically, which composes with `use()` and streaming RSC.
