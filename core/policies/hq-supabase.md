---
id: hq-supabase
title: Supabase — never delete a project without confirmation
scope: global
trigger: when working with Supabase (auth, storage, postgres, realtime)
when: supabase
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
version: 2
created: 2026-04-29
updated: 2026-07-28
applies_to: [supabase]
public: true
vendor_public_ok: true
tags: [vendor:supabase, gate]
source: split-from-hq-supabase
---

## Rule

NEVER delete a Supabase project without explicit user confirmation first. Deletion is irreversible and takes the database with it — a project that looks "unused" may be a live production DB (one was incorrectly deleted as unused on 2026-02-10). Always ask before deleting any Supabase project, and apply the same caution to deleting any managed Vercel/Supabase resource.

**Full Supabase reference** (CLI project-ref verification, `@supabase/ssr` middleware env guards, migration ghost-apply repair, storage bucket bootstrap) is on-demand in `hq-supabase-reference` — not auto-injected. `qmd get -c hq-infra hq-supabase-reference`.
