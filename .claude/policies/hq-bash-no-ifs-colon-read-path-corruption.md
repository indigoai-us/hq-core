---
id: hq-bash-no-ifs-colon-read-path-corruption
title: Never use IFS=":" read in bash loops over path-bearing data
scope: global
trigger: Looping over multi-field records in shell where any field can contain colons
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

NEVER use `IFS=":" read` (or `while IFS=":" read -r a b c`) inside a shell loop when any field can contain a colon, when any field is itself a filesystem path, or when the script may be executed under zsh.

Two failure modes observed:

1. **Field corruption.** `PATH`-like values, ISO timestamps, and URLs all contain `:`. `IFS=":" read` splits on every colon, silently truncating fields.
2. **Subshell `PATH` corruption.** When the loop body changes `IFS` and then forks a subshell (command substitution, pipe, `$(...)`), the modified `IFS` is inherited. Any subsequent `git`/`gh`/`head`/`jq` invocation that does an internal `PATH`-walk can break or pick the wrong binary, producing confusing "command not found" or wrong-version errors several lines later.

Use one of these alternatives instead:

- Iterate over arrays of independent variables: `for repo in "${repos[@]}"; do path="${paths[$i]}"; ...; done`.
- Use a non-colliding delimiter: `IFS=$'\t' read -r ...` or `IFS='|' read -r ...` and emit records with that delimiter.
- Reset `IFS` immediately after the read: `IFS=$' \t\n'` before any subshell call.
- Prefer `jq -r` over hand-rolled `IFS` parsing when the data is JSON.

## Rationale

Subshell `git` calls inside the loop intermittently failed with cryptic errors because `IFS=":"` leaked into the subshell environment and broke `PATH` lookup. The pattern is also subtly broken in zsh (where `$IFS` defaults differ) and on records where any field carries a colon. Composes with `hq-bash-portable-no-bash4.md` and `hq-zsh-status-readonly-loop-var.md` (the third item from the same batch — already covered).
