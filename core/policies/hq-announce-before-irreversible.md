---
id: hq-announce-before-irreversible
title: Announce and Confirm Before Any Irreversible Action
scope: global
trigger: before any action that cannot be undone — deletes, deploys to production, sending emails/messages, publishing content, DNS changes, database migrations, API mutations that create immutable records
when: deploy || push || share || slack || email || migration
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: soft
tier: 1
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **Before executing any irreversible action, state what you are about to do, which account/project/environment it targets, and ask for explicit confirmation.** Format: "[ACTION] → [TARGET] → [CONSEQUENCE]. Proceed?"
2. **Verify context before the announcement.** Check which company, account, project, org, and environment is active. Do not rely on assumptions from earlier in the session — context can drift.
3. **The following actions are always irreversible and require announcement:**
   - Deleting any resource (database, project, file, DNS record)
   - Deploying to a production domain or production environment
   - Sending emails, messages, or social posts (published content cannot always be recalled)
   - Running database migrations (especially destructive: DROP, ALTER, DELETE)
   - API mutations that create records which cannot be deleted (social posts, webhook registrations, billing changes)
   - DNS changes (propagation makes rollback slow)
4. **If the user pre-authorized the action** (e.g., "deploy to prod" as an explicit instruction), still confirm the specific target: "Deploying to [project] on [team/scope] at [domain]. Confirming." One sentence, no blocking question needed — but the target must be stated.
5. **NEVER fall back to a different target if the intended one fails.** If the authorized account/project/environment is unavailable, stop and report — do not silently use an alternative.

## Rationale

A kickoff email to a $10k client was sent from a personal Gmail instead of the business account because the agent fell back silently when auth failed. A Supabase project was deleted because it was misclassified as "unused." Deploys landed on wrong Vercel projects because .vercel/project.json was not verified. Each incident involved an irreversible action where the agent did not pause to confirm the target.
