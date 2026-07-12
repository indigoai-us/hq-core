---
id: hq-company-scoped-writes-verify-company
title: Company-scoped writes must resolve and verify the target company before writing
when: company
on: [SessionStart]
enforcement: hard
public: true
version: 1
created: 2026-05-29
updated: 2026-05-29
source: user-correction
---

## Rule

Before writing any company-scoped file under `companies/{co}/` (a policy, knowledge entry, worker, or project artifact), you MUST resolve and confirm the target company explicitly:

1. **Resolve the company** from the strongest available signal — current working directory (the **leaf** `companies/<slug>/` segment, not the first one in a nested path), project `prd.json` metadata, repo ownership via `companies/manifest.yaml`, worker path, or explicit user instruction.
2. **Verify the resolved slug exists** in `companies/manifest.yaml`.
3. **Never silently fall back to `core/`** (global scope) for a learning or rule that is company-specific. If the company cannot be resolved unambiguously, **stop and ask** — do not default the write into `core/policies/` or any other global location.
4. **Surface the resolved slug and the full target path before committing the write**, so a misroute is visible and correctable.

This applies to `/learn` and any skill or agent that authors company-scoped content.

## Rationale

For cloud-backed HQ-Pro companies, `hq-sync` uploads `companies/{co}/` **wholesale** to that tenant's vault (keyed by the company's `cloud_uid` / `bucket_name` in `companies/manifest.yaml`). There is no schema-level or sync-side guard that checks a file's declared `scope: company` against the directory it actually sits in. So a company policy written into the wrong `companies/{co}/` directory — or one that silently fell back to global `core/` — propagates the mistake straight into a tenant vault on the next sync. That is a category-1 cross-company contamination, and the only practical place to prevent it is at authoring time.

This generalizes the company-isolation principle in `credential-access-protocol` (which today covers credentials only) to policy, knowledge, and worker writes.

## See also

- `core/policies/credential-access-protocol.md` (credential-scope isolation; this rule extends the same principle to content writes)
- `core/policies/hq-customizations-live-in-personal-or-company.md` (where customizations belong by scope)
- `.claude/skills/learn/SKILL.md` (Step 3 resolution + Step 9 confirmation implement this rule)
