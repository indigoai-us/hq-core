---
id: hq-bash-set-a-source-env-before-subprocess-heredoc
title: Export env with `set -a` Before Sourcing for Subprocess Heredocs
scope: global
trigger: when sourcing a dotenv file and immediately spawning a python/node/etc. subprocess heredoc that reads those vars
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

ALWAYS wrap a dotenv `source` in `set -a` / `set +a` when the next command is a subprocess heredoc that depends on those variables:

```bash
set -a
source .env.local
set +a

python3 - <<'PY'
import os
print(os.environ["API_SECRET"])  # now visible
PY
```

A bare `source .env.local` assigns values as **shell variables** scoped to the current shell only. Spawned subprocesses (`python3 -c`, `node -e`, `bash -c`, any heredoc) inherit `environ` — not shell-local assignments — so `os.environ["API_SECRET"]` throws `KeyError` even though the shell can echo it fine.

`set -a` flips the default so every subsequent assignment is auto-exported; `set +a` restores normal behavior after the source.

## Rationale

Discovered 2026-04-23: a `source .env.local && python3 - <<'PY' ...` probe wasted an API round-trip because `API_SECRET` was a shell-local var, not an exported env var. The fix is one line (`set -a` / `set +a`) and avoids the whole class of "env var is set but subprocess can't see it" confusion.
