---
id: hq-supabase
title: Supabase rules (consolidated)
when: supabase
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
public: true
vendor_public_ok: true
tags: [vendor:supabase, consolidated]
source: consolidation-merge
---

## Rule

Consolidated Supabase guardrails covering project lifecycle, CLI/env alignment, Next.js middleware safety, migration verification, and storage bucket bootstrap. Treat the deletion rule as hard enforcement; the rest are operational best-practices learned from production failures.

## Project lifecycle

### Never Delete Supabase Projects Without Confirmation
[from `no-supabase-deletion.md`]

NEVER delete Supabase projects without confirming with user first. {project-name} was {Product}'s DB and was incorrectly deleted as "unused" on 2026-02-10. Always ask before deleting any Supabase/Vercel project.

**Rationale:** Prevents irreversible data loss from mistakenly identifying active projects as unused.

## CLI & environment alignment

### Verify Supabase CLI project ref matches `.env.local` URL before using keys
[from `supabase-cli-project-ref-verify.md`]

ALWAYS verify the Supabase CLI-linked project ref matches the `.env.local` URL before using keys from `supabase projects api-keys`. Decode the JWT to check:

```
node -e "console.log(JSON.parse(Buffer.from(key.split('.')[1],'base64')).ref)"
```

Vercel-managed Supabase integrations often create a different project than the locally-linked one.

**Rationale:** Using the CLI key gave "Invalid API key" errors. The production project was Vercel-managed and required `vercel env pull --environment production` to get the correct key.

**Provenance:** Observed in a project where `supabase/.temp/project-ref` pointed to one ref but `.env.local` URL pointed to a different ref.

## Next.js middleware & client safety

### Supabase middleware must guard missing env vars
[from `supabase-env-guard.md`]

When creating `@supabase/ssr` middleware in Next.js projects, always add an early-return guard for missing `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`. Without this, the dev server crashes on every request when credentials aren't yet configured.

For server/client factory functions (`createClient()`), use placeholder fallbacks (`|| "http://localhost:54321"`) instead of returning `null` — null returns cause cascading TypeScript errors across all consuming server components.

**Rationale:** Discovered during puffin-platform scaffold. `createServerClient()` throws synchronously if URL/key are empty. Middleware runs on every request, making the entire app unusable. Placeholder values let the client instantiate; auth calls simply return null user, which existing redirect logic already handles.

## Migrations

### Supabase migrations can be tracked as applied without SQL executing
[from `supabase-migration-ghost-apply.md`]

When debugging "table not found" errors on a Supabase-backed app, ALWAYS verify the table actually exists via REST API (`curl .../rest/v1/{table}?select=id&limit=1`) even if `supabase migration list` shows the migration as applied. Migrations with non-standard naming (e.g. `001_...` instead of timestamp prefix) can be recorded in the tracking table without the SQL executing.

**Fix:** `supabase migration repair --status reverted {version}` then `supabase db push --include-all`.

**Rationale:** Encountered on agent-ops-hq (Mar 2026): migration 015 showed as applied in both local and remote columns of `supabase migration list`, but the `trainees` table didn't exist. Root cause: non-standard migration file naming. The repair + re-push workflow resolved it.

## Storage

### Create Supabase Storage bucket before uploading objects
[from `supabase-storage-bucket-creation.md`]

Before uploading to Supabase Storage via `PUT /storage/v1/object/{bucket}/{path}`, verify the bucket exists. If it returns 404 "Bucket not found", create it first via `POST /storage/v1/bucket` with `{"id":"{name}","name":"{name}","public":false}`. Use the service role key for both operations.

**Rationale:** A book upload failed with 404 because the `books` bucket had never been created in Supabase. The upload endpoint does not auto-create buckets.

