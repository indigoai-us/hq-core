---
description: Hand off to fresh session, work continues from checkpoint
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
argument-hint: [message]
visibility: public
---

# /handoff - Fresh Session Continuity

Run the `/handoff` skill to prepare for a new session — batches learnings, concurrently commits knowledge repos in the background, commits HQ, updates INDEX files, runs gated doc-release, and fires qmd update as a background fire-and-forget. Runtime-agnostic canonical logic lives in the skill.

**User's message (optional):** $ARGUMENTS

## Steps

1. Load the handoff skill from `.claude/skills/handoff/SKILL.md`
2. Execute the optimized pipeline:
   - **Step 0** (concurrent): batch learnings via `/learn` + launch background git loop for knowledge repos
   - **Step 0b**: update knowledge from session work
   - **Step 0c**: sync barrier — wait for background git loop to complete
   - **Step 1**: ensure thread exists
   - **Step 2**: find latest thread
   - **Step 3**: commit dirty knowledge repos (skips re-run; already done in Step 0 background)
   - **Step 3b**: commit HQ changes
   - **Step 4**: update INDEX files and recent threads
   - **Step 4b**: document-release (gated — skipped if no `companies/*/` or `repos/*/` files touched)
   - **Step 5** (background, fire-and-forget): `qmd cleanup && qmd update && qmd embed`
   - **Step 6**: detect active pipelines
   - **Step 7**: write handoff note
   - **Step 8**: report
3. Never enter plan mode during handoff — execute steps directly

## After Handoff

- Start a fresh session and run `/startwork` (or `/nexttask`) to continue
- Fallback: read `workspace/threads/handoff.json` directly
