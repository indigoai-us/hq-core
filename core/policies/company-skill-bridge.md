---
id: company-skill-bridge
title: Company skills are registered before authoring and synced by immutable identity
when: company skill || SKILL.md
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
version: 1
created: 2026-08-26
updated: 2026-08-26
source: user-request
public: true
---

## Rule

Shared company skills live at
`companies/{company}/skills/{slug}/SKILL.md`, but their first write must go
through `hq skill create` so HQ can reserve and stamp the immutable `skill_uid`
before normal sync sees the file.

For a new company skill:

1. Run `hq skill --company {company} create {slug} --no-sync`.
2. Edit the stamped canonical file without changing `skill_uid`.
3. Run `hq skill --company {company} create {slug}` to hydrate metadata,
   preserve FILE_ACL policy, reindex, and sync.

Never author a generated `.claude/skills/` wrapper. Never copy an existing
`skill_uid` into a new directory. Existing stamped company skills may be edited
normally; their canonical directory and permissions remain stable even when
their display name changes.

## Enforcement

`route-company-skill-creation.sh` blocks direct Write/Edit attempts that would
create or continue editing an unstamped canonical company skill. The sync engine
also fails closed and registers any unstamped canonical company skill before
upload, covering shell editors, humans, and runtimes where hooks did not fire.

Open, Locked, and Private are projections of authoritative FILE_ACL state. New
skills start Open; subsequent registration must never replace an existing exact
ACL.
