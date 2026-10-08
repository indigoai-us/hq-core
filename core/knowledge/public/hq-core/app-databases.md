---
type: reference
domain: [operations, engineering]
status: canonical
tags: [hq-deploy, hq-cli, databases, aurora-dsql, billing, workforce-plan]
relates_to:
  - vault-databases.md
  - quick-reference.md
---

# App databases (`database: true`)

An app deployed with HQ Deploy can have its own Postgres-compatible database (Aurora DSQL). Each database app gets its own cluster, so apps never share data or usage.

## Who can use it

- Companies on the HQ Workforce (Team) plan or a staff-set paid plan (Enterprise).
- A company on Starter gets "Remote databases are not available yet on this company's plan" with the price and an upgrade link. Upgrading the plan makes the feature available right away.
- Indigo's own apps are exempt from billing.
- A company can hold 20 database apps. Deleted apps count until their database is removed (see "Delete and retention"). Ask HQ support if you need more.

## Price

| Item | Amount |
|---|---|
| Each database app | $10 a month, prorated, added to the company's Team subscription |
| Included each month | 250,000 compute units (DPU) and 1 GB of storage |
| Extra compute | $32 per 1M DPU |
| Extra storage | $1.32 per GB-month |
| Ceiling | 4x the included amounts (1,000,000 DPU or 4 GB). The database then becomes read-only until the next month or until usage drops. |

The owner gets one DM a month when an app passes 80% of an included amount, and one when it becomes read-only. Billing stops when the app is deleted. The 30-day retention after a delete is not billed.

## Consent

A database is never added without a yes. Before the first database deploy of an app, the deploy flow states the terms above and asks the user to confirm. The confirmation is recorded on the app (who and when), so later deploys are not asked again. A deploy that would create a database for a billed company without the confirmation fails with `409 DATABASE_BILLING_ACK_REQUIRED` and changes nothing on the live app.

- With `/deploy`: the skill asks the question and sends the confirmation.
- Through the API: `PATCH /api/apps/{appId}` with `{"database": true, "databaseBillingAcknowledged": true}`, then deploy with the form field `database_billing_acknowledged=true` (or the header `X-Database-Billing-Acknowledged: true`).

Headless runs and fleet agents never add a database on their own.

## Turning it on

Only `app` deploys (a project with an `api/` directory) can have a database. Set `database: true` on the app (the `/deploy` skill does this after the yes). On deploy, HQ Deploy creates or reuses the app's cluster and gives the app's functions three environment variables (`HQ_DB_*`) that `@hq/db` reads. There is no connection string to copy or store.

The first database deploy of an app usually finishes in under 30 seconds. If the cluster is still being created, the deploy returns `DATABASE_PROVISIONING` and the same deploy can be repeated; it picks up the same database.

## `@hq/db` in app code

```ts
import { getDb, collection, withTransaction } from "@hq/db";

export default async function handler(): Promise<Response> {
  const { rows } = await getDb().query("select count(*)::int as n from entries");
  return Response.json({ entries: rows[0].n });
}
```

- `getDb()` returns a pooled Postgres client. It signs in with short-lived IAM tokens and refreshes them.
- `withTransaction(pool, fn)` repeats the transaction on Aurora DSQL's optimistic-concurrency conflicts.
- `bulkInsert` and `chunkRows` split large inserts to stay under DSQL's per-transaction limits.

## SQL migrations

Put numbered `.sql` files in `db/migrations/` (for example `001_create_entries.sql`). Each deploy applies the files that have not run yet, in name order, and records them in `_hq_migrations`. A failed migration stops the deploy and the previous version stays live.

Aurora DSQL rules that matter for migrations:

- Write indexes as `CREATE INDEX ASYNC`. A plain `CREATE INDEX` is rejected before anything runs.
- Foreign key constraints and triggers are not supported. Use `uuid` or text keys (`gen_random_uuid()` works).
- One DDL statement per transaction. The runner handles this; keep each statement self-contained.

## Document mode (no migrations)

For simple storage without a schema, use collections. The `documents` table is created on first use.

```ts
import { collection } from "@hq/db";

const notes = collection("notes");
await notes.put("n1", { title: "Hello", done: false });
const note = await notes.get("n1");
const open = await notes.find({ done: false });
await notes.index("done");
await notes.delete("n1");
```

`find` matches top-level fields by equality. Use SQL migrations when you need joins, ranges or constraints.

## `hq db` commands for app databases

| Command | What it does |
|---|---|
| `hq db usage --company {co} --app {app}` | This month's compute and storage, the included amounts, overage, ceiling and estimated charge |
| `hq db usage --company {co}` | Usage for the company |
| `hq db sql --company {co} --app {app} -- 'select …'` | Run SQL against the app's database (read-only unless `--write`) |
| `hq db dump --company {co} --app {app} [--out file.sql]` | Export the app's schema and data to a SQL file |
| `hq db destroy --company {co} --app {app}` | Delete the app's database now. Owners and admins only. Asks for the app id again (`--confirm {app}` when not interactive) and offers a dump first (`--dump-first` or `--no-dump`). |

`--app` takes the app name or id. Connection strings and tokens are never printed.

## Delete and retention

- Deleting an app detaches its database at once: the app's access is revoked and billing stops.
- The database is kept for 30 days, then removed for good.
- `hq db destroy` removes it immediately with no retention. Run `hq db dump` first if you want a copy.
- A deleted app keeps counting toward the 20-app limit until its database is removed.

## Moving off

When an app outgrows the ceiling, move it to a larger service. `hq db dump` gives a portable SQL file.

## Related

- Company-level vault databases and local SQLite: `core/knowledge/public/hq-core/vault-databases.md`
- Hard policy: never print database connection strings (`core/policies/hq-vault-db-no-print-connection-strings.md`)
