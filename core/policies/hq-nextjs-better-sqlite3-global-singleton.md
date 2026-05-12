---
id: hq-nextjs-better-sqlite3-global-singleton
title: Next.js + better-sqlite3 — adapter MUST be a module-level singleton cached on globalThis
scope: global
trigger: any Next.js app using better-sqlite3 (or any native-binding SQLite adapter) — especially dev mode where HMR re-executes modules
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
# applies_to: [nextjs]
---

## Rule

When a Next.js app uses `better-sqlite3` (or any SQLite adapter with native bindings), the database adapter MUST be a module-level singleton cached on `globalThis` so it survives dev-mode HMR reloads:

```ts
// lib/db.ts
import Database from 'better-sqlite3';

const globalForDb = globalThis as unknown as { __db?: Database.Database };

export const db =
  globalForDb.__db ?? new Database(process.env.DB_PATH ?? 'local.db');

if (process.env.NODE_ENV !== 'production') {
  globalForDb.__db = db;
}
```

Every PRD for a Next.js app with SQLite storage MUST include this as an acceptance-criterion on the data-layer story (equivalent to the Prisma `globalForPrisma` pattern).

## Rationale

Next.js dev mode (Turbopack and webpack) re-evaluates modules on HMR. Without `globalThis` caching:

- Each HMR tick constructs a new `Database` instance pointing at the same file
- Native handles from prior instances don't immediately GC — they hold file descriptors and WAL/journal locks
- Result: intermittent `SQLITE_BUSY`, `database is locked`, or stale-handle errors that appear under load but never in the test suite (tests spin up a fresh process each time and never exercise the HMR reload path)
- The symptoms are timing-dependent, flaky, and nearly impossible to reproduce deterministically in CI

This is the same class of problem as the well-known Prisma-on-Next.js `globalForPrisma` pattern. better-sqlite3 is worse in practice because the native bindings hold OS-level locks that outlive the JS garbage collector.

In production (serverless Vercel / Node runtime), each cold start gets a fresh process so the singleton isn't strictly required — but the guard is cheap and the code reads identically across environments.

## Anti-patterns

- `export const db = new Database(path)` at module scope with no global cache → HMR leak
- Opening a new `Database` per request inside a route handler → file descriptor exhaustion under load
- Relying on unit/integration tests to catch HMR-induced locking → tests never exercise the reload path
- Using `process.on('beforeExit', () => db.close())` as a mitigation → doesn't fire on HMR module replacement
