#!/usr/bin/env bash
# Windows Git Bash regressions for pipeline path equality and process identity.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE_ROOT="$(cd "$HERE/../.." && pwd)"
PC="$CORE_ROOT/scripts/pipeline-conductor.sh"
DRIVER="$CORE_ROOT/scripts/pipeline-driver.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-win.XXXXXX")" && pwd -P)"
driver_pid=""
cleanup() {
  if [ -n "$driver_pid" ]; then kill "$driver_pid" 2>/dev/null || true; wait "$driver_pid" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# The relative --repo spelling is how callers rooted at HQ invoke the command.
HQ="$T/hq"
REPO="$HQ/repos/repo-a"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Synthetic Pipeline Test"
git -C "$REPO" config user.email "pipeline-test@example.invalid"
git -C "$REPO" -c commit.gpgSign=false commit --allow-empty -m "synthetic base" >/dev/null
printf '{"name":"synthetic","metadata":{"baseBranch":"main"},"userStories":[]}\n' > "$T/prd.json"
mkdir -p "$HQ/workspace"
(cd "$HQ" && PC_HQ_ROOT="$HQ" "$PC" worktree --state "$T/state" --repo repos/repo-a --shared \
  --prd "$T/prd.json" --worktree "$HQ/repos/blocked-target" >"$T/path.out" 2>"$T/path.err")
path_status=$?
if [ "$path_status" = 2 ] && grep -q "refusing worktree" "$T/path.err" \
    && grep -q "core Write/Edit guard blocks editor-tool" "$T/path.err" \
    && [ ! -e "$HQ/repos/blocked-target" ]; then
  ok "relative --repo reaches the repos/ worktree refusal on Windows Git Bash"
else
  bad "relative --repo should reach the repos/ worktree refusal (status=$path_status): $(cat "$T/path.err")"
fi

# Default worktrees must stay under the HQ's workspace tree when real() returns
# a Win32 path on Windows; the POSIX realpath helper would prefix the root again.
default_target="$HQ/workspace/worktrees/synthetic/repo-a"
(cd "$HQ" && PC_HQ_ROOT="$HQ" "$PC" worktree --state "$T/default-state" \
  --repo repos/repo-a --shared --prd "$T/prd.json" >"$T/default.out" 2>"$T/default.err")
default_status=$?
if [ "$default_status" = 0 ] && [ -d "$default_target" ]; then
  ok "default worktree creation uses the Win32 HQ root exactly once"
else
  bad "default worktree creation should use the Win32 HQ root exactly once (status=$default_status): $(cat "$T/default.err")"
fi

# A real Windows caller may pass the 8.3 short spelling from os.tmpdir().
# Resolve that spelling in the embedded Node runtime before checking the repo.
cat > "$T/get-short-path.cmd" <<'EOF'
@echo off
for %%I in ("%~1") do @echo %%~sI
EOF
hq_win="$(cygpath -w "$HQ")"
hq_short="$(cmd.exe //c "$(cygpath -w "$T/get-short-path.cmd")" "$hq_win" | tr -d '\r')"
hq_short_posix="$(cygpath -u "$hq_short")"
short_target_posix="$hq_short_posix/workspace/worktrees/short-path"
short_target_win="$(cygpath -w "$short_target_posix")"
short_prd="$T/short-prd.json"
printf '{"name":"synthetic-short-path","metadata":{"baseBranch":"main","branchName":"feature/synthetic-short-path"},"userStories":[]}\n' > "$short_prd"
(cd "$hq_short_posix" && PC_HQ_ROOT="$hq_short" "$PC" worktree --state "$T/short-state" \
  --repo repos/repo-a --shared --prd "$short_prd" --worktree "$short_target_win" \
  >"$T/short.out" 2>"$T/short.err")
short_status=$?
if [ "$hq_short" = "$hq_win" ]; then
  bad "test fixture did not produce an 8.3 short HQ root: $hq_short"
elif [ "$short_status" = 0 ] && [ -d "$short_target_posix" ]; then
  ok "relative --repo resolves from an 8.3 short HQ root"
else
  bad "relative --repo should resolve from an 8.3 short HQ root (status=$short_status): $(cat "$T/short.err")"
fi

# Keep a synthetic process whose full command line contains the production marker.
cat > "$T/pipeline-driver-synthetic.sh" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 1; done
EOF
chmod +x "$T/pipeline-driver-synthetic.sh"
source_function="$(sed -n '/^is_driver() {/,/^}/p' "$DRIVER")"
if [ -z "$source_function" ]; then
  bad "pinned pipeline-driver.sh exposes is_driver() for its parity test"
else
  eval "$source_function"
  bash "$T/pipeline-driver-synthetic.sh" >/dev/null 2>&1 &
  driver_pid=$!
  tries=0
  while [ "$tries" -lt 20 ] && ! kill -0 "$driver_pid" 2>/dev/null; do
    sleep 0.1
    tries=$((tries+1))
  done
  if is_driver "$driver_pid"; then
    ok "is_driver recognizes a live synthetic pipeline-driver PID"
  else
    bad "is_driver failed to recognize live synthetic pipeline-driver PID $driver_pid"
  fi
fi

echo "Pipeline Windows path and lock tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
