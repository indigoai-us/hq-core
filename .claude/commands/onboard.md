# /onboard — HQ Company Onboarding

Interactive walkthrough for creating or joining an HQ company.

## Mode Selection

Ask the user:

> **Welcome to HQ Onboarding!**
> Choose a path:
>   `[c]` Create a new company
>   `[j]` Join an existing company (with invite token)
>   `[r]` Resume a previous onboarding attempt

## Create Company Mode

Prompt for:
1. **Your name** (person name for the entity registry)
2. **Your email** (used for person entity slug + future auth)
3. **Company name** (display name, e.g. "Acme Corp")
4. **Company slug** (URL-safe identifier, e.g. "acme-corp" — validated: lowercase, 3-40 chars, alphanumeric + hyphens)

After collecting inputs, validate slug availability by calling `entity.findBySlug("company", slug)` — if found, tell the user it's taken and ask for another.

Then run `createCompanyFlow` from `@indigoai-us/hq-onboarding` with a progress callback that prints each step:

```
Creating company "Acme Corp" (acme-corp)...

  ◉ Step 1/6: create-person
  ✓ Step 1/6: create-person — personUid: psn_01HV...
  ◉ Step 2/6: create-company
  ✓ Step 2/6: create-company — companyUid: cmp_01HV...
  ◉ Step 3/6: provision-bucket
  ✓ Step 3/6: provision-bucket — bucket: hq-acme-corp-vault
  ◉ Step 4/6: bootstrap-membership
  ✓ Step 4/6: bootstrap-membership — role: owner
  ◉ Step 5/6: verify-sts
  ✓ Step 5/6: verify-sts — Credentials valid until 2026-...
  ◉ Step 6/6: write-config
  ✓ Step 6/6: write-config — /path/to/.hq/config.json

┌─────────────────────────────────────────────┐
│  HQ Onboarding Complete                     │
├─────────────────────────────────────────────┤
│  Company:  acme-corp                        │
│  UID:      cmp_01HV...                      │
│  Person:   psn_01HV...                      │
│  Role:     owner                            │
│  Bucket:   hq-acme-corp-vault               │
├─────────────────────────────────────────────┤
│  Next steps:                                │
│    • Run /invite <email> to add team        │
│    • Run hq sync to push files              │
└─────────────────────────────────────────────┘
```

## Join Company Mode

Prompt for:
1. **Your name** (person name)
2. **Your email** (used for person entity)
3. **Invite token** (accepts `hq://accept/<token>` magic links OR raw base64 tokens)

Then run `joinCompanyFlow` from `@indigoai-us/hq-onboarding`:

```
Joining company via invite...

  ✓ Step 1/6: parse-token
  ✓ Step 2/6: create-person — personUid: psn_02HV...
  ✓ Step 3/6: accept-invite — role: member
  ✓ Step 4/6: verify-sts
  ✓ Step 5/6: first-sync — 12 files synced
  ✓ Step 6/6: write-config

┌─────────────────────────────────────────────┐
│  HQ Onboarding Complete                     │
├─────────────────────────────────────────────┤
│  Company:  acme-corp                        │
│  Role:     member                           │
├─────────────────────────────────────────────┤
│  Next steps:                                │
│    • Run hq sync to pull latest files       │
└─────────────────────────────────────────────┘
```

## Resume Mode (`/onboard --resume`)

Read `.hq/onboarding-state.json` checkpoint. If exists, display:
- Mode (create or join)
- Steps completed so far
- Failed step (if any) with error

Then resume from the last incomplete step using `resumeOnboarding()`.

## Dry Run (`/onboard --dry-run`)

Show what WOULD happen without creating any resources:
```
DRY RUN — simulating create-company flow:
  1. Create person entity
  2. Create company entity
  3. Provision S3 bucket + KMS key
  4. Bootstrap owner membership
  5. Verify STS credential vending
  6. Write .hq/config.json

No resources will be created. Run /onboard to execute.
```

## Error Handling

On any failure:
1. Print the failed step and error message
2. Show the checkpoint path (`.hq/onboarding-state.json`)
3. Offer retry: "Run `/onboard --resume` to continue from where you left off"

## Teardown (Integration Test Only)

For integration tests, teardown in try/finally:
1. Delete company entity
2. Delete person entity
3. Empty the provisioned bucket (list + delete all objects)
4. Delete the bucket
5. Schedule KMS key deletion (7-day minimum retention)

This ensures no leaked resources from test runs.

## Dependencies

- `@indigoai-us/hq-onboarding` — orchestrator library
- `@indigoai-us/hq-cloud` — VaultClient, sync, entity context
- Vault service must be reachable (`VAULT_API_URL` env var or from `.hq/config.json`)
- Valid Cognito auth token (from `hq auth` or env)
