---
id: hq-surface-share-on-completion
title: Offer /hq-share or /deploy when work completes
when: completed || complete || shipped || merged || deployed || landed || published
on: [UserPromptSubmit, AssistantIntent, PostToolUse]
enforcement: soft
tier: 2
version: 1
created: 2026-06-20
updated: 2026-06-20
source: owner-request
public: true
---

## Rule

When a unit of work finishes — the agent says it is done / shipped / merged / deployed, or a `gh pr merge` / deploy command returns success — proactively offer to share the result rather than leaving it siloed. Ask once:

- Artifact with a URL form (report, deck, dashboard) → **/deploy**, then share the link.
- A vault path or session result a teammate needs → **/hq-share** (single-use link or direct grant).
- A result a specific teammate must see → **/dm** the link.

Never share an artifact externally without offering an HQ link first.

Surface: **/hq-share**, **/deploy**

## Rationale

No policy currently fires on completion, and `PostToolUse` (the channel that sees a merge/deploy result) is almost unused (3 of 152 policies). This closes the "I finished — now what?" gap: the `AssistantIntent` channel catches the agent announcing done/shipped/merged, and `PostToolUse` catches the success output of a `gh pr merge` or deploy command. Kept `soft` so it nudges rather than blocks; the per-session dedupe ledger caps it at one reminder.

## Verification

1. Agent message "PR merged and deployed live" → AssistantIntent injects, offering `/hq-share` / `/deploy`.
2. `gh pr merge` returns "Merged" in its output → PostToolUse injects on the result.
3. Unrelated message containing "complete" injects at most once per session (dedupe ledger).
