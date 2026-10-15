#!/usr/bin/env bash
# Pins the super-conductor HQ DM sweep: never rely on `hq dm inbox --unread`
# (the desktop app auto-acknowledges DMs, so unread is always empty); sweep by
# a createdAt cursor kept in the save file and check each thread for an owner
# reply.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
fail=0

if grep -Eq '^hq dm inbox --unread' "$SC"; then
  echo "FAIL: Step 6 still sweeps with hq dm inbox --unread ($SC)" >&2; fail=1
fi
grep -Eq '^hq dm inbox --limit 100 --json' "$SC" || { echo "FAIL: Step 6 must list the full inbox ($SC)" >&2; fail=1; }
grep -q 'hq_dm_cursor' "$SC" || { echo "FAIL: save-file DM cursor missing ($SC)" >&2; fail=1; }
grep -q 'Never filter with `--unread`' "$SC" || { echo "FAIL: --unread warning missing ($SC)" >&2; fail=1; }
grep -q -- '--no-ack' "$SC" || { echo "FAIL: thread check must not ack ($SC)" >&2; fail=1; }

[[ "$fail" -eq 0 ]] || exit 1
echo "super-conductor dm sweep contract: ok"
