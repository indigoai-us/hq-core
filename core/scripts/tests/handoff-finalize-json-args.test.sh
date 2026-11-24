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
# --learnings-json-file takes precedence over inline --learnings-json, rejects
# missing files (exit 3) and invalid JSON files (exit 2) before writing anything.
with tempfile.TemporaryDirectory() as tmp:
    env = {"PATH": os.environ["PATH"], "HQ_ROOT": tmp, "HQ_SESSION_ID": "learnings-file-test",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    missing = subprocess.run(["bash", hook, "--learnings-json", "[invalid",
                              "--learnings-json-file", "missing-learnings.json"], env=env,
                             capture_output=True, text=True, timeout=15)
    assert missing.returncode == 3, missing.stderr
    assert "--learnings-json-file not found" in missing.stderr, missing.stderr
    assert not list(pathlib.Path(tmp).iterdir()), list(pathlib.Path(tmp).iterdir())
    checks += 1
with tempfile.TemporaryDirectory() as tmp:
    bad_file = pathlib.Path(tmp) / "bad-learnings.json"
    bad_file.write_text("[invalid", encoding="utf-8")
    env = {"PATH": os.environ["PATH"], "HQ_ROOT": tmp, "HQ_SESSION_ID": "learnings-file-bad-test",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    bad = subprocess.run(["bash", hook, "--learnings-json-file", str(bad_file)], env=env,
                         capture_output=True, text=True, timeout=15)
    assert bad.returncode == 2, (bad.returncode, bad.stderr)
    assert "--learnings-json-file is not valid JSON" in bad.stderr, bad.stderr
    assert not (pathlib.Path(tmp) / "workspace").exists()
    checks += 1
# End-to-end: a non-empty learnings array supplied via --learnings-json-file
# lands in the emitted thread JSON without passing braces on argv.
import json
with tempfile.TemporaryDirectory() as tmp:
    root_dir = pathlib.Path(tmp)
    subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
    subprocess.run(["git", "-C", tmp, "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", tmp, "config", "user.name", "Test"], check=True)
    (root_dir / "README.md").write_text("hi\n", encoding="utf-8")
    subprocess.run(["git", "-C", tmp, "add", "README.md"], check=True)
    subprocess.run(["git", "-C", tmp, "commit", "-q", "-m", "init"], check=True)
    learnings = [{"topic": "scope", "summary": "keep JSON arrays off argv"}, {"topic": "handoff", "summary": "use file flag"}]
    learnings_file = root_dir / "learnings.json"
    learnings_file.write_text(json.dumps(learnings), encoding="utf-8")
    env = {"PATH": os.environ["PATH"], "HQ_ROOT": tmp, "HQ_SESSION_ID": "learnings-e2e-test",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    res = subprocess.run(["bash", hook, "--title", "Learnings file e2e", "--summary", "s",
                          "--learnings-json-file", str(learnings_file), "--slug", "learnings-e2e"],
                         cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
    assert res.returncode == 0, (res.returncode, res.stdout, res.stderr)
    payload = json.loads(res.stdout)
    thread = json.loads((root_dir / payload["thread_path"]).read_text(encoding="utf-8"))
    assert thread["learnings"] == learnings, thread["learnings"]
    checks += 1
print(f"handoff-finalize-json-args: {checks} checks passed")
PY_TEST
