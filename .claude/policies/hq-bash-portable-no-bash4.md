---
id: hq-bash-portable-no-bash4
title: No Bash 4+ builtins in HQ scripts — macOS /bin/bash is 3.2.57
scope: global
trigger: when writing or editing any shell script in scripts/, .claude/hooks/, workers/, or companies/*/ that may run on macOS
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

NEVER use `mapfile`, `readarray`, associative arrays (`declare -A`), `${var,,}`/`${var^^}` case-conversion, or any other Bash 4+ builtin in HQ scripts. macOS ships `/bin/bash` 3.2.57 (frozen at that version since 2007 for GPLv3 reasons), and any script that shebangs `#!/bin/bash` will fail on a user's Mac even though the developer's machine may have Homebrew bash 5.x on `$PATH`.

Required patterns:

**Array from command output** — use a portable read loop, not `mapfile`:
```bash
arr=()
while IFS= read -r line; do
  arr+=("$line")
done < <(some_command)
```

**Prefer `#!/usr/bin/env bash` over `#!/bin/bash`** — users who install Homebrew bash (5.x) get the modern interpreter; users without it still get 3.2.57 but your portable-3.2 code works there too. The `env` shebang is the safe default for HQ.

**Lowercase/uppercase** — use `tr`, not `${var,,}`:
```bash
lower=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
```

**Associative arrays** — use parallel indexed arrays or `jq`-backed JSON state files for anything non-trivial. `declare -A` is a hard no.

If a script legitimately requires Bash 4+ (e.g. performance-critical hot loop), pin it with `#!/usr/bin/env bash` AND add a preflight `(( BASH_VERSINFO[0] >= 4 )) || { echo "requires bash 4+; install via brew install bash" >&2; exit 1; }` so the failure mode is a clear error, not a cryptic syntax abort.

## Rationale

Observed 2026-04-18 during the handoff-post.sh rewrite: a `mapfile -t threads < <(find ...)` call crashed on a collaborator's Mac even though it ran cleanly in development, because the dev had Homebrew bash 5.x earlier on `$PATH` while the target machine did not. macOS will never ship a newer `/bin/bash`, so any script committed to HQ that may execute under `/bin/bash` must be valid Bash 3.2 syntax.

The portable read-loop pattern is only a handful of characters longer than `mapfile`, and the `#!/usr/bin/env bash` shebang gives users with Homebrew bash the upgraded interpreter automatically — so there is effectively zero cost to writing portable code, and a real cost to writing Bash 4-only code that silently breaks on fresh installs.
