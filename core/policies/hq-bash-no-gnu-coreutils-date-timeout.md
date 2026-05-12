---
id: hq-bash-no-gnu-coreutils-date-timeout
title: No GNU-only coreutils in HQ scripts — macOS ships BSD userland
scope: global
trigger: when writing or editing any shell script in scripts/, .claude/hooks/, workers/, or companies/*/ that may run on a developer Mac
enforcement: hard
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

NEVER use GNU-only coreutils features in HQ scripts. macOS ships BSD coreutils by default; the two most common gotchas observed in practice are:

**`date +%s%3N` (millisecond epoch)** — BSD `date` does NOT understand `%3N`; it emits the literal character `N` appended to the seconds. A script expecting `1729742400123` (13 digits) receives `1729742400N` and silently corrupts every downstream calculation.

**`timeout <secs> <cmd>`** — BSD userland has no `timeout` binary at all. Scripts using `timeout` fail with `command not found` the moment they leave a Linux CI runner.

### Required portable patterns

**Millisecond timestamp** — use Node (guaranteed on every HQ developer machine):
```bash
now_ms=$(node -e 'process.stdout.write(String(Date.now()))')
```

**Timeout wrapper** — most of the time you don't need one:
- Playwright has per-test `timeout` in `playwright.config.ts`
- `curl` has `--max-time <secs>` and `--connect-timeout <secs>`
- `fetch`/`node --input-type=module` can use `AbortController`

If you truly need a shell-level timeout (e.g. wrapping an opaque binary with no built-in ceiling), fall through to `gtimeout` (GNU `timeout` from `brew install coreutils`) with a runtime probe:

```bash
if command -v gtimeout >/dev/null 2>&1; then
  gtimeout 30 some_opaque_binary
elif command -v timeout >/dev/null 2>&1; then
  timeout 30 some_opaque_binary
else
  some_opaque_binary &
  pid=$!
  ( sleep 30 && kill -TERM "$pid" 2>/dev/null ) &
  wait "$pid"
fi
```

Never assume `timeout` exists. Never assume `date +%s%3N` produces a number.

### Other common BSD/GNU divergences to avoid

- `sed -i` — BSD requires `-i ''` (empty extension); GNU takes `-i` alone. Use `sed -i.bak '...' file && rm file.bak` or switch to `gsed` with probe.
- `readlink -f` — BSD doesn't support `-f`. Use `python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"` or `perl -MCwd -e 'print Cwd::abs_path(shift)' "$1"`.
- `stat -c %Y file` (GNU) vs `stat -f %m file` (BSD). Prefer `python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))'` for portability.

### Relationship to `hq-bash-portable-no-bash4`

This policy and `hq-bash-portable-no-bash4` cover orthogonal axes:
- `hq-bash-portable-no-bash4` — bash *interpreter* version (3.2 vs 4+) — `mapfile`, `declare -A`, `${var,,}`
- This policy — coreutils *userland* (BSD vs GNU) — `date`, `timeout`, `sed -i`, `readlink -f`

Scripts must be valid on *both* axes to run reliably on a fresh Mac.

## Rationale

Observed in the signup-safeguards arc (lr-proj-384) 2026-04-22: a pre-push gate emitted `date +%s%3N` into a "duration_ms" field, and downstream telemetry showed `duration_ms=1729742400N` entries that broke every dashboard. In the same session, a `timeout 60 pnpm playwright test` line died on `command not found: timeout` before the test runner even started — obscuring a more interesting failure and wasting a debug cycle.

These are silent-success failures on Linux CI (where both features work) and noisy, late-binding failures on Mac (where scripts fail after some work has already happened). Keeping the scripts portable eliminates an entire category of "works on CI, fails on developer laptop" drift.
