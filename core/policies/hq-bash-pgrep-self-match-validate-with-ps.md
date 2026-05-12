---
id: hq-bash-pgrep-self-match-validate-with-ps
title: Validate pgrep matches with ps to avoid self-matching the harness
scope: global
trigger: A Claude session uses `pgrep -f` to find a running process whose command-line could match the agent's own bash invocation (e.g. searching for the very script the agent just discussed or executed)
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-26
updated: 2026-04-26
source: session-learning
---

## Rule

NEVER trust a `pgrep -f <pattern>` result without a second-stage `ps` validation. `pgrep -f` matches the FULL command line of every process, including the bash invocation the Claude agent itself is running. If the agent's prompt or recent shell history mentions the pattern (e.g. `run-project.sh.*curriculum-expansion`), pgrep will return the agent's own bash PID and any tool wrapper PIDs alongside (or instead of) the real target.

Required two-stage idiom:

```bash
# Stage 1: candidate PIDs
candidates=$(pgrep -f 'run-project.sh.*<project>')

# Stage 2: confirm each is the orchestrator, not the harness
for pid in $candidates; do
  cmd=$(ps -p "$pid" -o command= 2>/dev/null)
  case "$cmd" in
    *bash*-c*|*claude*--prompt*|*Claude*Code*)
      # harness/agent self-match — skip
      continue
      ;;
    */run-project.sh*<project>*)
      echo "$pid"  # real orchestrator
      ;;
  esac
done
```

Or, when killing, pre-filter by parent PID being `init` / `1` (true daemon) rather than the agent's session leader.

## Rationale

`pgrep -f` is a regex match against `/proc/<pid>/cmdline`. The agent's own bash subshell — spawned by the Bash tool to run the very pgrep command — has a command line that includes the search pattern as a literal argument. The race is that pgrep sees this sibling process and returns its PID. Killing it terminates the agent's shell mid-tool-call, leaving the orchestrator running and the agent confused about whether the kill succeeded.

The cheap fix is to validate every candidate PID with `ps -p <pid> -o command=` and reject anything whose command matches a known harness pattern (bash `-c`, claude binary, the Claude Code wrapper). This costs one syscall per candidate and is robust against future harness changes because the allowlist (the orchestrator's full path) is narrower than the rejectlist.

## Examples

### Wrong

```bash
# Kills the agent's own bash AND the orchestrator
pkill -TERM -f 'run-project.sh.*curriculum-expansion'
```

### Right

```bash
for pid in $(pgrep -f 'run-project.sh.*curriculum-expansion'); do
  ps -p "$pid" -o command= | grep -q 'run-project.sh' && \
    ps -p "$pid" -o command= | grep -qv 'bash -c' && \
    kill -TERM "$pid"
done
```

## Related

- `.claude/policies/hq-bash-pgrep-no-hardcode-pids.md` — sibling rule on PID stability across cron firings
- `.claude/policies/hq-cmd-run-project-ralph-hard-pause-procedure.md` — caller of this idiom in step 2
