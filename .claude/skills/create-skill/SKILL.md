---
name: create-skill
description: Create or capture a shared company skill in HQ with a durable identity and FILE_ACL governance. Use when asked to create or add a team/company skill, or to turn a repeatable workflow into an HQ skill. Do not use for personal or local-only Codex skills.
allowed-tools: Bash(hq:*), Read, Write, Edit
---

# Create a company skill

Create company skills through HQ's registration boundary. Do not create an
unstamped `companies/{company}/skills/{slug}/SKILL.md` directly.

## Workflow

1. Resolve one company from the user's request, current company context, or
   `companies/manifest.yaml`. Ask only when the company is genuinely ambiguous.
2. Choose a lowercase kebab-case skill slug.
3. Reserve the immutable identity and create a stamped template without
   uploading it yet:

   ```bash
   hq skill --company {company} create {slug} --no-sync
   ```

4. Edit `companies/{company}/skills/{slug}/SKILL.md`. Preserve `skill_uid`
   exactly. Write a specific `name`, a concise trigger-oriented `description`,
   optional `tags`, and the complete operating instructions.
5. Register the final metadata and sync the stamped file:

   ```bash
   hq skill --company {company} create {slug}
   ```

6. Report the canonical path and immutable skill ID. The skill is discovered by
   HQ reindexing; never hand-write a generated `.claude/skills/` wrapper.

## Existing files

If an unstamped canonical `SKILL.md` already exists, run step 3 first. The
command registers the existing bytes and adds `skill_uid` atomically; it does
not replace the instructions. Then continue with steps 4–6.

If the skill is already stamped, edit it in place and run step 5. Registration
is idempotent and preserves its existing FILE_ACL policy.

## Governance

- New skills start Open: every active company member can edit through the
  company-wide FILE_ACL grant.
- Locked and Private are FILE_ACL policies controlled in HQ Console. Never
  emulate them in frontmatter or registry fields.
- Do not copy a `skill_uid` into another directory. A new skill gets a new ID;
  renaming its display name never changes its directory or ID.
