---
id: hq-core-main-gated-by-ruleset-not-classic-protection
title: hq-core main is gated by a repository RULESET, not classic branch protection
when: pr && merge
on: [PreToolUse, UserPromptSubmit]
enforcement: hard
public: true
vendor_public_ok: true
version: 1
created: 2026-05-28
updated: 2026-05-28
source: user-correction
tags: [hq-core, promotion, github, rulesets]
---

## Rule

ALWAYS: hq-core main is gated by a repository RULESET (main_protect), not classic branch protection — toggling enforce_admins / using gh pr merge --admin does NOT bypass it. Merge requires either being a listed ruleset bypass actor or a genuine approving review from indigoai-us/core-review. For bot-authored promote PRs, approve as a core-review maintainer (self-approval rule doesn't apply to bot authors), then squash-merge.

## Rationale

GitHub repository rulesets (the newer protection mechanism, configured under repo → Rules → Rulesets) are evaluated independently of classic branch protection. They have their own bypass-actor list and ignore the `enforce_admins` flag and the `--admin` merge override. On indigoai-us/hq-core, the `main_protect` ruleset requires an approving review from a member of the `indigoai-us/core-review` team. The standard escape hatches that work on classic-protected branches (admin-merge, toggling enforce_admins) fail silently here — the merge attempt is rejected by the ruleset, not the branch protection.

For human-authored PRs, GitHub's self-approval block prevents the author from satisfying the review requirement themselves. For bot-authored promote PRs (e.g. hq-audit-bot opening the promote PR), the self-approval rule doesn't apply because the reviewer is a different identity from the bot author — a core-review maintainer can approve and squash-merge in one step.

Distinct from `hq-core-staging-promote-pr-needs-second-approver.md` (covers hq-core-**staging** with classic protection + enforce_admins=true) and `hq-core-protect-bypass-inline.md` (covers local HQ core file protection, unrelated to GitHub merges).
