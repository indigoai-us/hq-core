---
id: hq-env-local-prod-test-cred-mismatch-check
title: Before migrating Clerk/Stripe/Supabase prod state, verify `.env.local` holds matching prod creds
scope: global
trigger: snapshotting, backing up, exporting, or migrating production state from Clerk, Stripe, Supabase, or any provider whose client library keys off env vars; any script that reads a repo `.env.local` and writes to a production resource
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
applies_to: [clerk, stripe, supabase, vercel]
---

## Rule

ALWAYS verify the token prefixes in a repo's `.env.local` before using it as the credential source for a prod snapshot, migration, or cross-provider cutover. Mixed files are common — a single `.env.local` often ends up with `sk_test_*` Clerk + `sk_live_*` Stripe (or any other split) because developers pulled different values at different times.

Verification checklist (before any prod action):

1. **Read key prefixes only** (never full values — see `hq-never-grep-secrets-file-content`):
   ```bash
   awk -F= '/^(CLERK|STRIPE|SUPABASE|NEXT_PUBLIC_CLERK|NEXT_PUBLIC_STRIPE)/ {
     split($2, v, "_"); print $1"="v[1]"_"v[2]"_***"
   }' .env.local
   ```
   Look for prefix mismatches (`sk_test_` vs `sk_live_`, Clerk `pk_test_*` vs `pk_live_*`, Supabase anon vs service-role).

2. **Pull prod explicitly** rather than trusting an ambient `.env.local`:
   ```bash
   vercel env pull --environment=production .env.production.local
   ```
   `.env.production.local` is gitignored by Next.js convention. Use it for the snapshot/migration and delete it when done.

3. **If the repo's `.env.local` is the only source** (no Vercel mirror), stop and surface the mismatch to the user — do not proceed on assumption.

4. **Target-provider confirmation** — if Clerk prefixes indicate test but Stripe prefixes indicate live, the snapshot is ambiguous. Ask which provider's prod state is actually in scope before mutating either.

## Rationale

Running a snapshot script against that file would have read Clerk's test tenant and Stripe's live account in the same pass — a silently wrong baseline. Production values usually live only in Vercel; pulling them explicitly (`vercel env pull --environment=production`) makes the snapshot's provenance unambiguous.

Composes with `hq-vercel-env-pull-environment` (which addresses missed prod-scoped vars) by catching the complementary failure mode: the vars are present, but some are from the wrong environment.
