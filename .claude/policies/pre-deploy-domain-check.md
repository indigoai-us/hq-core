---
id: hq-pre-deploy-domain-check
title: Check Domain Ownership Before Vercel Deploys
scope: global
trigger: before any Vercel deploy or domain assignment
enforcement: hard
public: true
version: 3
created: 2026-02-22
updated: 2026-04-20
source: {your-project}.get{company}.ai overwrite incident
---

## Rule

Before ANY Vercel deploy:

1. **Look up the repo** in `settings/deploy-registry.yaml` — confirm `project_id`, `org_id`, and `domains` match what you're about to deploy
2. **Verify `--scope`** matches the registry's `org_id` for this entry. If no `--scope` flag, verify `.vercel/project.json` in cwd matches registry
3. **If domains[] is non-empty** in the registry entry, `curl -s` the live URL first to confirm what's currently there
4. **NEVER** remove a domain from one Vercel project to assign it to another — add new routes within the existing project instead
5. **NEVER** deploy a repo whose registry entry shows a different `owner` without explicit user confirmation

Protected domains (never reassign): `hq.get{company}.ai`, `{your-project}.get{company}.ai`, `get{company}.ai`, `{company}.com`, `{your-domain}.com`, `{your-domain}.com`, `{your-domain}.com`, `{your-domain}.band`, `{company}.com`, `{your-name}.com`, `{your-domain}.com`, `www.{company}.ai`

