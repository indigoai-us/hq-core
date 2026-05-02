---
id: hq-zsh-status-readonly-loop-var
title: Never use $status as a loop variable in zsh scripts
scope: global
trigger: writing a shell for/while loop in a script that may run under zsh (the default macOS login shell)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

**NEVER** use `status` as a local variable name in a shell `for` or `while` loop (or any zsh script context). In zsh, `$status` is a **readonly** special parameter that mirrors `$?` (the exit status of the last foreground pipeline). Assigning to it aborts the script with:

```
zsh: read-only variable: status
```

…and if the assignment lives inside a `for` loop, the loop terminates on the first iteration — silently if `set -e` is off, loudly if it's on.

**Forbidden:**

```bash
for f in workspace/orchestrator/state-*.json; do
  status=$(jq -r .status "$f")       # ABORTS under zsh
  if [[ "$status" == "running" ]]; then
    ...
  fi
done
```

**Correct — rename the variable:**

```bash
for f in workspace/orchestrator/state-*.json; do
  pstatus=$(jq -r .status "$f")      # fine under bash AND zsh
  if [[ "$pstatus" == "running" ]]; then
    ...
  fi
done
```

**Other zsh readonly parameters to avoid as local names:** `status`, `pipestatus`, `signals`, `ZSH_NAME`, `ZSH_VERSION`, `EGID`, `EUID`, `GID`, `UID`, `LINENO`, `PPID`, `SECONDS` (when `typeset -h` not used). When in doubt, prefix with a short namespace (`st_`, `p_`, `_`) or use an obviously scoped name (`run_status`, `job_status`, `pstatus`).

**Shebangs do not save you.** A `#!/usr/bin/env bash` shebang only applies when the script is executed directly. If the script is `source`d or run via `zsh script.sh`, the shebang is ignored and you are in zsh. Portable scripts assume neither shell is guaranteed.

## Rationale

The enclosing script's shebang was bash, but a caller had `source`d it from a zsh interactive session. The first iteration aborted with `read-only variable: status`, and because `set -e` was not enabled, the loop exited silently with an empty result set — the pipeline reported "no running projects" when three were active.

Root cause: zsh reserves `status` as a synonym for `?` (exit status). Bash does not. Any cross-shell script that assigns to `status` is a time bomb: it works on Linux CI (bash default), works when run with `./script.sh` on macOS (shebang honored), and fails silently when `source`d from the user's zsh shell — which is the default macOS login shell and therefore the most common HQ runtime.

Universal fix: don't use shell-reserved names as locals. `pstatus` or `run_status` are one keystroke away and portable everywhere.
