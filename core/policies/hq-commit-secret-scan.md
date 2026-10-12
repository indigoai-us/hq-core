---
id: hq-commit-secret-scan
title: Scan code for secrets before it is committed or proposed, and keep secrets in the HQ vault
when: (secret && scan) || (secret && scanner) || no-verify || ggshield || gitleaks || (commit && hook) || core.hooksPath || (pull && request && secret) || (.env && (commit || secret))
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 1
created: 2026-10-11
updated: 2026-10-11
source: owner-request
public: true
---

## Rule

1. **Before every pull request, scan the branch.** Run
   `bash core/scripts/commit-secret-scan.sh pr-check <base>` from inside the
   repo (the `/review` skill does this in Step 3b). It checks the branch's
   final files and every version its commits added. Treat any finding as a
   blocking issue. Treat a scan that could not run (exit 2) as blocking too,
   never as clean.
2. **Recommend commit-time scanning.** It is off by default because it changes
   the machine-wide git setup. When it is off, recommend turning it on with
   `bash core/scripts/commit-secret-scan.sh enable`; `/hq-checkup` does this.
   Never turn it on or off for the user without their go.
3. **Never skip the scan without the owner's explicit OK.** That covers
   `git commit --no-verify`, unsetting `core.hooksPath`, and `disable`. If the
   scan finds a possible secret, stop and report it; do not route around it.
4. **Keep secrets in the HQ vault, not in local files.** Store them with
   `hq secrets set` and load them at run time with `hq run` (repos with a
   `.env.schema`) or `hq secrets exec`. Suggest this whenever a secret shows up
   in code, a committed `.env`, or a scan finding. If a secret was ever pushed,
   rotate it: deleting it in a later commit leaves it in git history.
5. A known false positive can carry a `gitleaks:allow` comment on that line.
   Never use it on a real credential.

## How it works

- `hq scan secrets` (hq CLI 5.345.86+) is HQ's own offline scanner: gitleaks'
  default rules ported into the CLI plus HQ's token patterns. It needs no
  account, network or quota, and prints rule, file and line, never the value.
- `core/scripts/commit-secret-scan.sh enable` points the global git hook at
  `~/.hq/git-hooks`, adds a block to `~/.config/husky/init.sh` for husky repos,
  and chains repos under `repos/` that set their own hook folder (a repo
  elsewhere with its own hook folder is not covered). Their own
  hooks still run after the scan, and a previous global hook folder keeps
  running unless `--replace` is given. Everything changed is backed up;
  `disable` restores it. The setting lives in
  `core/settings/commit-secret-scan.yaml` (default) and
  `personal/settings/commit-secret-scan.yaml` (your choice).

## Rationale

A secret is cheapest to stop before it is committed: once it is in history it
must be rotated and the history rewritten. A cloud scanner with an API quota
fails exactly when it is needed and invites skipping the check, so HQ ships
its own offline scanner. Scanning again before the pull request catches
commits made with the hook skipped or on another machine.
