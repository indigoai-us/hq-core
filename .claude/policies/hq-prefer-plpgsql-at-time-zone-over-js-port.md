---
id: hq-prefer-plpgsql-at-time-zone-over-js-port
title: Prefer PL/pgSQL AT TIME ZONE over porting JS timezone code
scope: global
trigger: writing a Postgres trigger or function that needs timezone math, with reference JS code available
enforcement: soft
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
---

## Rule

When porting timezone-handling logic from JavaScript into PL/pgSQL (triggers, functions, materialized view refreshers), prefer Postgres' native `AT TIME ZONE` over a literal port of the JS implementation. Postgres handles DST transitions natively via the bundled Olson tzdata; the JS equivalent often carries a manual DST hack that is unnecessary in SQL.

Concrete pattern: a JS helper that computes "midnight in tz X for a given UTC instant" may include a `Math.abs(localDate.getUTCDate() - utcDate) > 1` correction to fix off-by-one across DST boundaries. The SQL equivalent is just:

```sql
(some_timestamptz AT TIME ZONE 'America/New_York')::date
```

…with no DST hack required. Postgres' `tzdata` table resolves the rule for the exact instant.

## Rationale

JavaScript's `Date` lacks first-class IANA timezone support, so production code accumulates correction layers (UTC arithmetic + offset adjustments + DST bandaids). A direct line-by-line port replicates those bandaids in SQL where they are not just unnecessary but actively misleading — they suggest the SQL is also fragile across DST boundaries when it is not. Discovered while porting a JS time-zone helper into a Postgres trigger; the SQL version ended up shorter and more correct than the JS source it was meant to mirror.
