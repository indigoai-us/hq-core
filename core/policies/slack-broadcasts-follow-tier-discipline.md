---
id: hq-slack-broadcasts-follow-tier-discipline
title: Slack broadcasts must follow work-broadcast skill tier discipline
when: slack
on: [PreToolUse, UserPromptSubmit]
enforcement: hard
public: true
version: 1
created: 2026-05-10
updated: 2026-05-27
source: user-correction
---

## Rule

Before composing any Slack channel broadcast announcing completed or proposed work, READ `.claude/skills/work-broadcast/SKILL.md` and follow its tier rules. Do NOT compose multi-section, multi-bullet, multi-question Slack messages. Channel posts are doorways, not documents.

Tier discipline (from the skill):

- **Small** (<50 lines, single-file change): one line, lead with what changed, PR link. No `:emoji:` decoration beyond the standard `:chart_with_upwards_trend:` lead.
- **Medium** (50–300 lines, single feature/API change): up to 3 lines — one-sentence summary, 1-2 bullets max, PR link.
- **Large** (>300 lines, multi-file feature, infra rollout, project milestone): **build and deploy a marketing page** with the deploy skill, then post 1 line of summary + page URL + PR link(s). Long content lives on the page, not in the Slack thread.

Composition rules (all tiers):

- Always lead with `:chart_with_upwards_trend:` as the visual signature
- Bold the change name in Slack format (`*name*`)
- Never include open questions, bullets, or sub-sections in the Slack message itself — those belong on the page or in the PR description
- Never reference file paths or function names in the broadcast
- Always confirm the draft with the user before sending (work-broadcast skill step 6 is mandatory)

If unsure which tier applies, ask the user once with a one-line summary. Do not default to verbose.

## Rationale

Verbose channel posts get ignored, clog the channel, and bury follow-up replies. The work-broadcast skill exists precisely to enforce this discipline — but only enforces it if read FIRST. A previous broadcast composed without reading the skill produced a 30+ line post that the user immediately deleted; the redo (1-line summary + deployed marketing page + PR link) was the format that should have been used from the start. The skill defines tier sizing, message templates, and the marketing page flow — there is no excuse for not consulting it before posting.
