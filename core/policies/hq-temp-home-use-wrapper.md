---
id: hq-temp-home-use-wrapper
title: Run commands that need a throwaway HOME through with-temp-home.sh
when: mktemp || (temp && home)
on: [PreToolUse]
enforcement: hard
version: 2
created: 2026-10-18
updated: 2026-10-19
source: back-pressure-failure
public: true
---

## Rule

When a command needs an isolated, empty `$HOME`, run it through
`bash core/scripts/with-temp-home.sh -- <command> [args...]`. Do not assign
`HOME` from `mktemp` directly, in one step or through a variable; the
PreToolUse hook `.claude/hooks/block-raw-temp-home.sh` blocks those forms. The
wrapper points the toolchain and package caches at the real home, passes the
exit code through, and removes the temp home on exit (`--keep` leaves it for
`hq doctor --sweep-temp-homes`). For a run that must start with empty caches,
set `HQ_ALLOW_RAW_TEMP_HOME=1` as a prefix of the same command and delete the
folder yourself.

Raw temp homes re-download toolchains on every run and are never deleted, which fills the disk.
