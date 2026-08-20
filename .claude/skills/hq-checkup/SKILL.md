---
name: hq-checkup
description: Check that HQ is working and fix what can be fixed safely — updates HQ, starts the app if it's closed, backs up work that hasn't saved, turns safety checks back on. Reports anything left in plain language.
allowed-tools: Bash, Bash(bash .claude/skills/hq-checkup/hq-checkup.sh:*), Read, AskUserQuestion
---

# HQ Checkup

Run this when someone asks "is my HQ okay?", "is HQ up to date?", "why isn't my
work saving?", or when they just want a once-over. It checks HQ, **fixes what it
safely can**, and tells the person what's left.

**Assume the person does not know how HQ works inside.** They should never have
to read a file path, a version number, a process name, or the word "hook" to
understand what you told them.

## How to run it

```bash
bash .claude/skills/hq-checkup/hq-checkup.sh
```

That checks and fixes. Other modes: `--check` (look only, change nothing),
`--quick` (fast, skips internet checks), `--json`.

Exit `0` = nothing left for them to do. Exit `1` = something needs them.

## What it fixes on its own

No need to ask first — these are safe and reversible:

- HQ is missing or out of date → installs the current version
- The HQ app is closed → opens it
- Work hasn't backed up in over a week → backs it up, one workspace at a time
- HQ's safety checks are off → turns them back on (it makes a backup first)

After each fix it **re-checks**, so it only ever claims something is fixed when
it actually is. If a fix didn't take, it says so instead of pretending.

## What it deliberately leaves to the person

These can't be done for someone, so the script only reports them:

| What's wrong | Why it's not automatic |
|---|---|
| Signed out | Signing in happens in a browser |
| Saving is paused | Only they can flip the switch in the menu bar |
| Two copies of a file | Only they know which version they want |
| A new version of HQ's setup | It rewrites HQ while it's running — needs a fresh chat |

## What you say afterwards

Relay the script's output as-is. It's already written for a non-technical
reader — rewriting it usually makes it worse.

Add at most one sentence of your own about what it means for them. Then stop.

If nothing needs them, say so in one line. Don't pad a clean result.

If something needs them, offer to do it — one thing at a time, most important
first. For the ones you *can* run (`/resolve-conflicts`, `hq login`), offer to
start it. For `/update-hq`, tell them to open a new chat; never run it here.

### Words to avoid

Never say these to the person. Say the plain version instead.

| Don't say | Say |
|---|---|
| CLI, binary, package, npm | HQ / the HQ app |
| hook, guardrail, gate | HQ's safety checks |
| sync journal, vault, prefix | your work / where your work is saved |
| conflict | two copies of the same file |
| stale, drift, divergence | hasn't saved in a while |
| core, scaffold, release, version 15.0.104 | a newer version of HQ |
| exit code, FAIL, WARN | just describe what's wrong |

## Rules

- Never claim something is fixed without re-checking that it is.
- Never run `/update-hq` in the current session — always a fresh one.
- Never chain the person's decisions together — ask once, act, then stop.
- If a fix fails, say plainly that it didn't work and what to try instead.
  Don't retry the same command in a loop.
- Don't reimplement checks inline. If a check is missing, add it to the script.
- Reassurance is part of the job: unresolved copies and unused workspaces are
  normal on an older setup, and nothing is lost. Say so.
