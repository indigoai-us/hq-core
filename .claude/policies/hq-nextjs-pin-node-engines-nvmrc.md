---
id: hq-nextjs-pin-node-engines-nvmrc
title: Pin Node version on Next.js / Vercel apps via `engines.node` + `.nvmrc`
scope: global
trigger: next.js, vercel, node runtime, engines field, .nvmrc, runtime upgrade, lambda runtime drift
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
applies_to: [vercel]
---

## Rule

ALWAYS pin the Node version on every Next.js / Vercel app. Both files must be set and must agree:

1. `package.json` — `"engines": { "node": "X.Y.Z" }` (exact version, not a range)
2. Repo root `.nvmrc` — same `X.Y.Z`

Without a pin, Vercel will silently upgrade the Lambda runtime to the latest supported Node major whenever they bump the default — that is an **invisible dependency change** that can break SSR guards, native-module ABI assumptions, or polyfill behavior without any code having changed. (E.g. Node 24 added the `globalThis.navigator` polyfill, which flipped the meaning of `typeof navigator !== "undefined"` SSR guards — see `hq-nextjs-navigator-ssr-guard-node24.md`.)

With an explicit pin, runtime upgrades become a **reviewable PR** that touches both files, runs CI, and ships through normal review — not a mystery outage.

## Rationale

A pinned runtime would have turned the Node 24 change into a PR review with a diff, CI run, and deploy gate — all of which create surface area for the hydration regression to be caught before prod. Runtime is a dependency; treat it like one.
