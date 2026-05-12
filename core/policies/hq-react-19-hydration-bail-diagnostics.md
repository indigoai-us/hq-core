---
id: hq-react-19-hydration-bail-diagnostics
title: Diagnose React 19 "form submits but does nothing" → silent hydration bail
scope: global
trigger: react 19, hydration bail, onSubmit lost, form GET fallback, __reactFiber, ssr/client divergence, form submits but does nothing
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

When a React 19 app shows the symptom **"form submits but does nothing"** (button click triggers page navigation or does nothing visible, no API POST in network tab, no JS error in console), suspect a **silent hydration bail** on the form's subtree. Run the two confirming checks before chasing any other hypothesis.

### Check 1 — fiber key probe (in the browser console)

```js
Object.keys(formEl).filter(k => k.startsWith('__reactFiber'))
```

- Non-empty array → subtree is hydrated; root cause is elsewhere
- **Empty array → hydration silently bailed** on that subtree. React 19 did not wire any of the event handlers (`onSubmit`, `onClick`, etc.)

### Check 2 — native-submit signature (in the network tab)

If hydration bailed, the browser falls back to native HTML form submission. The giveaway:

- The request method is **GET**, not the POST the app expects (unless the `<form>` has explicit `method="post"`)
- The URL contains the form field names and values as **query-string params** — unmistakable; no app code would ever construct that URL

### Fix

Find the **render-time SSR / client divergence** that caused React to abandon hydration. Common culprits, in order of frequency:

1. `navigator` / `document` / `window` reads at render time (see `hq-nextjs-navigator-ssr-guard-node24.md` — Node 24 polyfills `navigator`)
2. `document.cookie` read at render time
3. `localStorage` / `sessionStorage` read at render time
4. `Date.now()` or `new Date()` at render time (non-deterministic)
5. `Math.random()` or any nondeterministic value at render time
6. Locale/timezone-dependent formatting at render time

Fix: defer the browser-only read to `useEffect` (with a server-safe state default), OR gate it behind `typeof window !== "undefined"` when it only needs to run on the client.

## Rationale

React 19 downgraded hydration mismatches from hard errors to recoverable — it silently re-renders the offending subtree on the client but does **not** attach event handlers to the server-rendered DOM for that subtree. Default console output gives no obvious error. Without this playbook the symptom looks identical to "form action is wrong" / "button not wired up" / "middleware hijacked POST" — all of which send investigators into the wrong files. The two-check probe (fiber keys + GET-with-query-string) uniquely identifies the hydration-bail failure mode in under a minute and points directly at render-time client/server divergence.
