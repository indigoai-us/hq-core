---
name: settings-override
description: Keep a Claude Code setting change across HQ updates by writing it to .claude/settings.local.json. Use when /update-hq reset a setting or a user wants one to stick.
allowed-tools: Read, Edit, Write, Bash, AskUserQuestion
---

# Settings override

`.claude/settings.json` ships with HQ and `/update-hq` replaces it, so a user's edit there is lost on the next update. `.claude/settings.local.json` is personal: HQ never ships it and `/update-hq` keeps it. Most plain keys in it override the same key in `.claude/settings.json`. `disableArtifact` does not: Claude ignores the local value, so `restore-hook-settings.sh` (run by `/update-hq`) copies a boolean `disableArtifact` from local.json into `.claude/settings.json`. Lists such as `permissions` and `hooks` are added to the shipped ones, not swapped for them, so shipped deny rules and hooks still apply.

## Steps

1. Find out which setting the user wants and its value. If they edited `.claude/settings.json` by hand, compare it with the shipped version (`git diff` in the HQ root if it is a git checkout) to find their changes.
2. Tell them in one or two sentences: edits to `.claude/settings.json` are overwritten by HQ updates; the same key in `.claude/settings.local.json` is kept and wins. Ask with AskUserQuestion whether to move the change there. Do nothing without a yes.
3. On yes, read `.claude/settings.local.json` (create it as `{}` if missing). Add or update only the requested keys. Keep every other key. For objects such as `permissions`, merge entries instead of replacing the object. Validate the JSON after writing.
4. Do not hand-edit `.claude/settings.json`. If the user had hand-edited it, say the next `/update-hq` will restore it. For `disableArtifact`, run `bash core/scripts/restore-hook-settings.sh` from the HQ root after writing local.json so the healer copies the boolean into `.claude/settings.json` now; `/update-hq` does the same after it replaces the shipped file.
5. Tell them to restart the Claude session so the change takes effect, and name the file and keys you changed.

## Rules

- Never put secrets, tokens or API keys in a settings file. Use `/hq-secrets`.
- Never weaken a deny rule or a hook from the shipped settings without the user naming that exact change.
