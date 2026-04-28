---
id: hq-bash-discipline
title: HQ bash discipline — IFS, BSD/GNU portability, pgrep validation, set -e returns
scope: global
trigger: when writing or editing any shell script in scripts/, .claude/hooks/, workers/, companies/*, or any HQ-targeted shell code that may run on a developer Mac
enforcement: hard
public: true
version: 1
created: 2026-04-27
updated: 2026-04-27
source: consolidation
merged_from:
  - hq-bash-ifs-tsv-ansi-c-escape
  - hq-bash-no-ifs-colon-read-path-corruption
  - hq-bash-no-gnu-coreutils-date-timeout
  - hq-bash-portable-no-bash4
  - hq-bash-pgrep-no-hardcode-pids
  - hq-bash-pgrep-self-match-validate-with-ps
  - hq-bash-set-e-status-returns
merged_at: 2026-04-27
---

## Rule

Seven independent hard rules covering bash hygiene on macOS+BSD userland. Each one is a real failure mode with its own remedy; do not collapse the failure modes when reading.

### 1. IFS — use ANSI-C `$'\t'`, never locale-translation `$"\t"`

ALWAYS use `IFS=$'\t'` (single quotes, leading `$`) when splitting tab-separated records. NEVER use `IFS=$"\t"`. The two forms look identical but `$'...'` is ANSI-C quoting (a real TAB byte 0x09); `$"..."` is bash locale-translation (with no catalog, IFS becomes the literal characters `\` and `t`, splitting input on every backslash and every letter `t`). The failure is silent — fields truncate at every `t` in payload (e.g. filenames like `aws-credentials-safety.md` arrive as `aws-creden`).

Verify with `printf '%q\n' "$IFS"` — correct prints `$'\t'`; broken prints `\\t`.

### 2. IFS — never `IFS=":" read` over path-bearing data

NEVER use `IFS=":" read` (or `while IFS=":" read -r a b c`) when any field can contain a colon, when any field is a filesystem path, or when the script may run under zsh. Two failure modes:

- **Field corruption** — `PATH`-like values, ISO timestamps, and URLs all contain `:`. Splits silently truncate.
- **Subshell `PATH` corruption** — modified `IFS` is inherited by subshells (`$(...)`, pipes, command substitution). Subsequent `git`/`gh`/`jq`/`head` calls do `PATH`-walks against the corrupted `IFS` and pick wrong binaries or fail with cryptic "command not found" several lines after the original mistake.

Use array iteration, a non-colliding delimiter (`$'\t'`, `|`), reset `IFS=$' \t\n'` immediately after the read, or prefer `jq -r` over hand-rolled IFS parsing when the data is JSON.

### 3. No GNU-only coreutils — macOS ships BSD userland

NEVER use GNU-only coreutils features. The two most common gotchas:

- `date +%s%3N` — BSD `date` does not understand `%3N`; emits literal character `N`. A 13-digit ms epoch becomes `1729742400N`, silently corrupting downstream calculations.
- `timeout <secs> <cmd>` — BSD has no `timeout` binary. Scripts fail with `command not found` the moment they leave Linux CI.

Required portable substitutes:

```bash
# millisecond timestamp — Node is on every HQ machine
now_ms=$(node -e 'process.stdout.write(String(Date.now()))')

# timeout — prefer the tool's own ceiling (curl --max-time, playwright config,
# AbortController). If shell-level is required, probe for gtimeout/timeout
# and fall through to a kill-after-sleep wrapper.
```

Other BSD/GNU divergences to avoid:

- `sed -i` — BSD requires `-i ''` (empty extension); GNU takes `-i` alone. Use `sed -i.bak '...' file && rm file.bak`, or probe for `gsed`.
- `readlink -f` — BSD lacks `-f`. Use `python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"`.
- `stat -c %Y` (GNU) vs `stat -f %m` (BSD). Prefer `python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))'`.

### 4. No Bash 4+ builtins — macOS `/bin/bash` is 3.2.57

NEVER use `mapfile`, `readarray`, `declare -A` (associative arrays), `${var,,}`/`${var^^}`, or any other Bash-4+ builtin. macOS ships `/bin/bash` 3.2.57, frozen at that version since 2007 for GPLv3 reasons. A script with `#!/bin/bash` fails on a user's Mac even when the developer has Homebrew bash 5.x on `$PATH`.

Required patterns:

```bash
# array from command output — portable read loop, not mapfile
arr=()
while IFS= read -r line; do
  arr+=("$line")
done < <(some_command)

# lowercase — tr, not ${var,,}
lower=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
```

Prefer `#!/usr/bin/env bash` over `#!/bin/bash`. If a script legitimately needs Bash 4+, add a preflight: `(( BASH_VERSINFO[0] >= 4 )) || { echo "requires bash 4+" >&2; exit 1; }`.

This rule and rule 3 are orthogonal: rule 3 is BSD vs GNU userland; rule 4 is bash interpreter version. Scripts must be valid on both axes.

### 5. Never hardcode `pgrep` PIDs across cron firings or relaunches

NEVER persist a PID discovered by `pgrep` (or `ps`) into a follow-up cron body, state file, or shell variable that survives across orchestrator relaunches. The `/run-project --ralph-mode` parent PID changes on every relaunch; per-story swarm-worker PIDs change every batch; the cron monitor itself can re-exec.

Always rediscover the target on each cron firing via `pgrep -f <pattern>`, then validate with `ps -p <pid> -o command=` per rule 6. Persist only the **search pattern**, never the resolved PID. macOS PID space is 99999 and rolls over within hours on a busy system — a stale PID kill can hit `launchd` or an unrelated user shell.

### 6. Validate `pgrep` matches with `ps` to avoid self-matching the harness

NEVER trust a `pgrep -f <pattern>` result without a second-stage `ps` validation. `pgrep -f` matches against the full `/proc/<pid>/cmdline`, including the bash invocation the Claude agent itself is running. If the agent's prompt or recent shell history mentions the pattern, pgrep returns the agent's own bash PID and tool wrapper PIDs alongside (or instead of) the real target — and a `pkill` then terminates the agent's shell mid-tool-call.

Required two-stage idiom:

```bash
candidates=$(pgrep -f 'run-project.sh.*<project>')
for pid in $candidates; do
  cmd=$(ps -p "$pid" -o command= 2>/dev/null)
  case "$cmd" in
    *bash*-c*|*claude*--prompt*|*Claude*Code*) continue ;;  # harness self-match
    */run-project.sh*<project>*) echo "$pid" ;;             # real target
  esac
done
```

Or pre-filter by parent PID being `init` / `1` (true daemon) rather than the agent's session leader.

### 7. `set -e` and intentional status-code returns — use `|| result=$?`

When a bash function intentionally returns non-zero exit codes as status signals (e.g. `handle_failure` returning 2=skip, 3=pause), NEVER call it directly under `set -e`. Use `cmd || result=$?` to suppress `set -e` for that call:

```bash
# WRONG — set -e kills script when handle_failure returns 2 or 3
handle_failure "$STORY_ID" "$attempt"
result=$?

# RIGHT — || suppresses set -e, captures the status code
result=0
handle_failure "$STORY_ID" "$attempt" || result=$?
```

This caused `run-project.sh` to silently exit instead of retrying failed stories — `handle_failure` returned 2 (skip), `set -e` intercepted it, and the script died before `result=$?` could capture the value.

## Rationale

All seven rules share the same failure shape: **silent success on the developer's machine, late-binding noisy failure on a fresh Mac, on CI rotation, or under load**. Each one was paid for in production:

- IFS-tab and IFS-colon corruption: bash auditing scripts and multi-repo loops in 2026-04-25/26.
- BSD coreutils: a `timeout 60 pnpm playwright test` that died on `command not found` before the test runner started; a `date +%s%3N` that emitted `1729742400N` into duration_ms telemetry.
- Bash 3.2: a `mapfile -t threads < <(find ...)` in `handoff-post.sh` that ran in dev and crashed on a collaborator's Mac.
- pgrep PID drift: a stale parent PID across a relaunch sent SIGTERM to the wrong process during the curriculum-expansion hard-pause sequence (2026-04-26).
- pgrep self-match: a `pkill -TERM -f 'run-project.sh.*curriculum-expansion'` that killed the agent's own bash shell mid-tool-call.
- `set -e` returns: `run-project.sh` silently terminating instead of retrying — direct `handle_failure` call without `|| result=$?`.

Keeping the rules on one page rather than seven separate files preserves the cross-references (rules 5 and 6 only work together; rule 4 is invalid without rule 3) and reduces cold-start digest weight without losing any failure mode.

## Provenance

Consolidated 2026-04-27 from seven prior policy files (see `merged_from`). Soft-enforcement counterpart `hq-bash-set-a-source-env-before-subprocess-heredoc` remains separate to preserve its soft status.

## Related

- `.claude/policies/hq-bash-set-a-source-env-before-subprocess-heredoc.md` — companion soft rule on `set -a` before sourcing dotenv for subprocess heredocs.
- `.claude/policies/hq-zsh-status-readonly-loop-var.md` — zsh-specific corollary to rule 2.
- `.claude/policies/hq-cmd-run-project-ralph-hard-pause-procedure.md` — caller of rules 5 and 6.
