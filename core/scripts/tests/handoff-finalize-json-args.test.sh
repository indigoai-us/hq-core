#!/usr/bin/env bash
# Reject malformed inline JSON before creating any handoff files (DEV-4304).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT/core/scripts/handoff-finalize.sh" <<'PY_TEST'
import os, pathlib, subprocess, sys, tempfile
hook = sys.argv[1]
checks = 0
for flag in ("--next-steps-json", "--learnings-json", "--tags-json", "--files-touched-json"):
    for value in ('[invalid', '["bad\\$escape"]', '', '[] []'):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"PATH": os.environ["PATH"], "HQ_ROOT": tmp, "HQ_SESSION_ID": "json-args-test",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            result = subprocess.run(["bash", hook, flag, value], env=env, capture_output=True,
                                    text=True, timeout=15)
            assert result.returncode == 2, (flag, value, result.returncode, result.stderr)
            assert f"{flag} is not valid JSON" in result.stderr, (flag, result.stderr)
            assert not result.stdout, (flag, result.stdout)
            assert not list(pathlib.Path(tmp).iterdir()), (flag, list(pathlib.Path(tmp).iterdir()))
            checks += 1
# File input takes precedence over inline changeset JSON. An unused malformed
# inline value must not mask the more useful missing-file error.
with tempfile.TemporaryDirectory() as tmp:
    env = {"PATH": os.environ["PATH"], "HQ_ROOT": tmp, "HQ_SESSION_ID": "json-precedence-test",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    result = subprocess.run(["bash", hook, "--files-touched-json", "[invalid",
                             "--files-touched-json-file", "missing.json"], env=env,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 3, result.stderr
    assert "--files-touched-json-file not found" in result.stderr, result.stderr
    checks += 1
print(f"handoff-finalize-json-args: {checks} checks passed")
PY_TEST
