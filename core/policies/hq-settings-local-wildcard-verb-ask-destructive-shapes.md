---
id: hq-settings-local-wildcard-verb-ask-destructive-shapes
title: Fence destructive git shapes into `permissions.ask` when broadening a verb with `Bash(git:*)`
scope: global
trigger: When broadening a Bash verb with a wildcard (e.g. `Bash(git:*)`, `Bash(rm:*)`, `Bash(mkdir:*)`) in `.claude/settings.local.json` or `.claude/settings.json`
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

When broadening a permission verb with a wildcard like `Bash(git:*)` in `.claude/settings.local.json`, always add the destructive shapes for that verb to the `permissions.ask` array in the same edit. `ask` outranks `allow` in Claude Code's permission precedence, so you get speed on common ops and a confirm prompt on irreversible ones.

Minimum git destructive set:

```json
"permissions": {
  "allow": [
    "Bash(git:*)"
  ],
  "ask": [
    "Bash(git push:*)",
    "Bash(git push --force:*)",
    "Bash(git push -f:*)",
    "Bash(git push --force-with-lease:*)",
    "Bash(git reset --hard:*)",
    "Bash(git clean -fd:*)",
    "Bash(git clean -fdx:*)",
    "Bash(git branch -D:*)",
    "Bash(git rebase -i:*)",
    "Bash(git checkout --:*)",
    "Bash(git restore --staged --worktree:*)"
  ]
}
```

Apply the same pattern to other destructive verbs broadened by wildcard:
- `Bash(rm:*)` → ask on `rm -rf:*`, `rm -rf /:*`
- `Bash(docker:*)` → ask on `docker system prune:*`, `docker volume rm:*`
- `Bash(aws:*)` → ask on `aws s3 rm --recursive:*`, `aws iam delete-*`

The `ask` entries are the tripwire. Do not ship a broadened wildcard without them.

## Rationale

Discovered while auto-approving common git ops in `.claude/settings.local.json`. Adding `Bash(git:*)` to `permissions.allow` silences prompts for every git subcommand — including `git push --force`, `git reset --hard`, `git clean -fd`, and `git branch -D`, which can destroy local or remote work without confirmation. Claude Code's permission engine evaluates `ask` before `allow`, so listing the destructive shapes in `ask` restores a confirm gate on exactly those commands while leaving `git status`, `git diff`, `git log`, `git add`, `git commit`, `git fetch`, `git pull` fast.

This composes cleanly with `hq-announce-before-irreversible` (which requires an announce-and-confirm dance before irreversible actions) — the settings-level `ask` gate is the belt, the policy is the suspenders.
