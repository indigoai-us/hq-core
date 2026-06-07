---
id: hq-claude-code-default-mode-plan-not-auto
title: "Claude Code defaults to plan mode; auto mode is operator opt-in, advised against"
scope: global
trigger: Configuring Claude Code permission mode in a shipped HQ .claude/settings.json, or auditing a teammate's HQ install for permission posture
when: settings.json || settings.local.json
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 2
created: 2026-05-28
updated: 2026-05-28
source: user-correction
---

## Rule

ALWAYS: HQ-shipped `.claude/settings.json` MUST set, exactly:

```json
{
  "useAutoModeDuringPlan": false,
  "permissions": {
    "defaultMode": "plan"
  }
}
```

- `permissions.defaultMode: "plan"` — every new HQ session boots into Plan mode (position 3 in the Shift+Tab picker). **Hard.**
- `useAutoModeDuringPlan: false` — Plan mode does NOT inherit Auto-mode classifier semantics. Plan stays Plan: nothing mutates until the plan is approved. **Hard.**

NEVER: ship `"acceptEdits"`, `"auto"`, `"bypassPermissions"`, `"dontAsk"`, or `"default"` as `permissions.defaultMode` in the HQ-shipped `.claude/settings.json`. Plan-as-default is the conservative boot posture every new HQ install needs.

SHOULD AVOID (advisory, not mechanically enforced): running HQ in Auto mode (Shift+Tab position 4). Auto's classifier is an opaque second policy engine that can disagree with HQ's hooks and deny-lists, creating confusing UX (Auto-approved → hook-blocked). It is not strictly *less* safe than Bypass mode, which HQ also allows; the case against Auto is consistency-of-policy-source, not safety. Operators who want Auto mode may opt in per-machine via `.claude/settings.local.json` (see below) — the shipped default does not mechanically remove it from the picker.

Per-machine `.claude/settings.local.json` MAY override `defaultMode` for an individual operator with explicit, considered intent (owner running `"bypassPermissions"` on their personal machine, power user trying Auto on a specific workload, etc.). Local override is not a violation of this rule; shipping a permissive project default IS.

## Rationale

HQ's runtime safety surface — deploy preview confirmations, share-session URL minting, destructive-op gates, cross-company credential isolation, irreversible-action protocols, sub-agent commit discipline — assumes Claude will pause and surface choices to a human when the model encounters one of those gates. Auto mode and the accept/bypass modes systematically skip those surfaces. Auto-during-Plan (default-on upstream) lets Auto semantics leak into Plan mode, so even "plan mode" wasn't safe without the explicit override. The combined effect of the unshipped defaults: a teammate runs `npx create-hq`, drops into Claude Code with no further config, and starts shipping mutations through HQ's confirmation-required flows without seeing them. That defeats the rest of HQ.

Plan mode is the conservative shipped default because (a) it forces a written plan before any file mutation, which composes with HQ's "Vague → Verifiable" core principle and with `/plan`, `/prd`, `/brainstorm`, `/architect`; (b) the operator downgrades per-session with one keystroke (Shift+Tab → 1, 2, 4, or 5) when they want execution, but new operators never start in an execute-first posture.

**Why this policy does NOT mechanically disable Auto mode** (via `permissions.disableAutoMode: "disable"`): HQ allows Bypass mode (Shift+Tab position 5), which is *more* permissive than Auto (position 4). Bypass skips all prompts; Auto skips some based on a classifier. If Bypass is acceptable in HQ because the hook layer fences the danger surface, then Auto is acceptable by the same reasoning. Mechanically disabling the less-permissive of the two while allowing the more-permissive one is internally inconsistent and paternalistic. The Auto-mode concern is real but smaller than its picker placement implies: it is a *coherence* concern (two competing policy engines: HQ's hooks/deny-lists vs Auto's classifier) rather than a *safety* concern. We surface it here as advisory and trust operators to make the call.

**HQ's hook layer is the safety floor, not the permission picker.** The mechanical guarantees that survive any Claude Code permission mode:

- `permissions.deny` Read-blocks on `~/.ssh/**`, `~/.aws/credentials`, `~/.gnupg/**`, `~/.env`, `~/.netrc`, all rc files
- PreToolUse hooks: secret-scan on every Bash, `core/` write protection, every git mutation requires explicit `git -C` anchor, cross-company credential warnings, package-install vetting, env-file safety
- Hard policies loaded into model context every session: share-session URL discipline, no-push-HQ-to-remote, cross-company isolation, hq-share token redaction, auto-checkpoint, image-context isolation
- HQ autocommit: every change in HQ is committed locally as it happens — anything bad is reversible

Vanilla Claude Code + permissive mode = trust the model. HQ + permissive mode = trust the model + the hooks + the deny list + the policy layer. Different threat model.

Precedence (Claude Code, as of v2.1.142+): managed enterprise policy → CLI `--permission-mode` → `.claude/settings.local.json` → `.claude/settings.json` (project) → `~/.claude/settings.json` (user). Shipping at project scope therefore overrides any permissive user-scope default an operator may have set globally, while preserving per-machine override via `settings.local.json`. There is no env-var equivalent for `defaultMode`; settings.json is the only configuration surface.

Note: as of Claude Code v2.1.142, `defaultMode: "auto"` is ignored when set in project or local scope (anti-supply-chain). The threat surface is therefore narrower than it first appears — but Plan-as-shipped-default still matters because the upstream default has shifted toward more permissive postures in recent versions, and a user-scope `~/.claude/settings.json` *can* set permissive defaults that this project-scope shipped value overrides.

Captured as a user correction: HQ owner explicitly directed that users default to Plan mode and Plan stays Plan. The original v1 of this policy also mechanically disabled Auto mode; v2 softened that to advisory after the consistency-with-Bypass argument was raised.

## How to comply

- Project `.claude/settings.json` shipped with HQ: include the two keys above. Verify via `jq '.permissions.defaultMode, .useAutoModeDuringPlan' .claude/settings.json` — must print `"plan"` and `false`.
- Per-machine override (operator-personal, never committed): `.claude/settings.local.json` may set any value the operator wants, including `permissions.defaultMode: "bypassPermissions"` or `"auto"` at the local scope. That is the operator's choice; the shipped project default is the policy concern.
- Audits (`/harness-audit`, `/garden`, manual review of a teammate's HQ install): flag any HQ project `.claude/settings.json` whose `permissions.defaultMode` is not `"plan"`, or whose root `useAutoModeDuringPlan` is not `false`. Replace and prompt the operator to move their preferred mode to `settings.local.json` if they want a permissive default on their own machine.

## References

- Claude Code settings reference: https://code.claude.com/docs/en/settings.md
- Claude Code IAM / permissions: https://code.claude.com/docs/en/iam.md
- Parallel precedent: `core/policies/hq-disable-claude-code-auto-memory.md`
