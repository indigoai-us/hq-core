---
id: hq-claude-code-default-mode-plan-not-auto
title: "Claude Code shipped default permission mode is auto; Plan stays Plan; operators override per machine"
when: settings.json || settings.local.json
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 4
created: 2026-05-28
updated: 2026-09-18
source: user-correction
---

## Rule

ALWAYS: HQ-shipped `.claude/settings.json` MUST set, exactly:

```json
{
  "useAutoModeDuringPlan": false,
  "permissions": {
    "defaultMode": "auto"
  }
}
```

- `permissions.defaultMode: "auto"` is the shipped default. **Hard.** The release contract test (`core/scripts/tests/hook-settings-release-contract.test.sh`) fails on any other value.
- `useAutoModeDuringPlan: false` — when an operator is in Plan mode, Plan does NOT inherit Auto-mode classifier semantics. Plan stays Plan: nothing mutates until the plan is approved. **Hard.**

NEVER: change `permissions.defaultMode` in the shipped `.claude/settings.json` as a side effect of another change. A change to the shipped default is a product decision. It needs its own commit, a `CHANGELOG.md` entry, and a release note telling operators what changed and how to get their previous mode back.

NEVER: have `hq rescue`, `/update-hq`, `setup.sh`, or any healer script (`core/scripts/restore-hook-settings.sh`) rewrite `permissions.defaultMode`. Healers restore hook wiring; they do not touch the permission mode.

## Operator override

Operators pick their own mode per machine. What actually works:

1. **The mode picker in Claude Code** (Shift+Tab in the CLI; the mode menu by the message box in the desktop app). The desktop app remembers the last mode picked and can apply it to new sessions even when project `settings.json` says `auto`.
2. **User settings — `~/.claude/settings.json`.** This is the operator-writable file where `defaultMode: "auto"` takes effect. Merge `{"permissions":{"defaultMode":"auto"}}` into the existing file; do not replace it wholesale.
3. **`.claude/settings.local.json`** (per machine, never committed, preserved across `hq rescue` via `core/core.yaml` `preserve_subpaths`). May set `permissions.defaultMode` to `"default"`, `"acceptEdits"`, `"plan"`, or `"bypassPermissions"`. **It cannot set `"auto"`:** Claude Code (v2.1.142+) ignores `defaultMode: "auto"` at project and local scope as an anti-supply-chain measure. Do not tell operators to set `auto` in this file; it silently does nothing.

Do NOT edit the shipped `.claude/settings.json` to change your mode. It is release-owned, and `hq rescue` replaces it (moving your edited copy to `personal/` as drift), so the edit lasts until the next update.

## Rationale

**Why `auto` is the shipped default.** HQ ran with `auto` shipped through at least August 2026. On 2026-09-16 the value flipped to `plan` as an unrelated one-line change inside a hooks fix (`020f891f`, shipped in v15.0.146). It was not a knowing change. Within a day, operators who ran `hq rescue` were booted into Plan mode on every new session and reported the app as unusable. The author confirmed the intended value is `auto`, and it was restored on 2026-09-18. v2 of this policy documented Plan as the hard default; that text never matched what shipped, and v3 corrects the record.

**Why Plan stays Plan.** `useAutoModeDuringPlan` defaults on upstream, which lets Auto's classifier approve mutations while the operator believes they are in a read-only planning mode. When an operator chooses Plan, that choice must mean no mutations until the plan is approved. This composes with `/plan`, `/prd`, `/brainstorm`, `/architect`, and the "Vague → Verifiable" principle.

**Why the shipped value matters less than it looks.** Claude Code ignores `auto` at project scope, so the shipped `auto` mostly acts as a statement of intent and a guard against a permissive-or-restrictive value being smuggled in. The desktop app applies its own remembered mode. Neither fact excuses changing the shipped value silently: the September incident showed that the file is still applied in some paths and that a silent flip generates support load.

**HQ's hook layer is the safety floor, not the permission picker.** The mechanical guarantees that survive any Claude Code permission mode:

- `permissions.deny` Read-blocks on `~/.ssh/**`, `~/.aws/credentials`, `~/.gnupg/**`, `~/.env`, `~/.netrc`, all rc files
- PreToolUse hooks: secret-scan on every Bash, `core/` write protection, every git mutation requires explicit `git -C` anchor, cross-company credential warnings, package-install vetting, env-file safety
- Hard policies loaded into model context every session: share-session URL discipline, no-push-HQ-to-remote, cross-company isolation, hq-share token redaction, auto-checkpoint, image-context isolation
- HQ autocommit: every change in HQ is committed locally as it happens, so anything bad is reversible

Vanilla Claude Code + permissive mode = trust the model. HQ + permissive mode = trust the model + the hooks + the deny list + the policy layer. That is the threat model the shipped `auto` default relies on. Auto's classifier can disagree with HQ's hooks (Auto-approved → hook-blocked); that is a coherence annoyance, not a safety gap, and Bypass mode (which HQ also allows) is more permissive than Auto.

**Precedence** (Claude Code, v2.1.142+): managed enterprise policy → CLI `--permission-mode` → `.claude/settings.local.json` → `.claude/settings.json` (project) → `~/.claude/settings.json` (user). The desktop app's remembered picker mode sits alongside the CLI flag in practice. There is no env-var equivalent for `defaultMode`.

## How to comply

- Shipped `.claude/settings.json`: the two keys above. Verify with `jq '.permissions.defaultMode, .useAutoModeDuringPlan' .claude/settings.json` — must print `"auto"` and `false`.
- Changing the shipped default: own commit, `CHANGELOG.md` entry under Unreleased, release note with the recovery path. Update this policy and the release contract test in the same PR.
- Healer and rescue scripts: never read or write `permissions.defaultMode`. `core/scripts/tests/restore-hook-settings.test.sh` asserts the value is preserved.
- Audits (`/harness-audit`, `/garden`, review of a teammate's install): flag a shipped `.claude/settings.json` whose `permissions.defaultMode` is not `"auto"` or whose root `useAutoModeDuringPlan` is not `false`. If the operator edited the shipped file to change their mode, point them to the mode picker or `~/.claude/settings.json` instead.
- Support: an operator "stuck in Plan mode" should first switch the mode picker in a new session and confirm the next new session keeps it. If Plan still returns, set `permissions.defaultMode` to `"auto"` in `~/.claude/settings.json`. Never tell them that `.claude/settings.local.json` alone restores Auto.

## References

- Claude Code settings reference: https://code.claude.com/docs/en/settings.md
- Claude Code IAM / permissions: https://code.claude.com/docs/en/iam.md
- Incident: hq-core-staging `020f891f` (unintended flip), `3cdb7f12` / #772 (healer rewrite), #775 (restore); HQ feedback `feedback_01d256bb-8e7c-402a-b613-bbb0a99882e5`
- Parallel precedent: `core/policies/hq-disable-claude-code-auto-memory.md`
