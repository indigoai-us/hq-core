#!/usr/bin/env bash
# hq-core: public
# Smoke tests for silent HQ-local autosave.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP_PARENT="$(mktemp -d)"
TMP="$TMP_PARENT/hq"
trap 'rm -rf "$TMP_PARENT"' EXIT
mkdir -p "$TMP"

# The hook keys its cross-process mutex off TMPDIR. Point it at the sandbox so
# this suite can neither be blocked by, nor block, a real autosave on the host.
export TMPDIR="$TMP_PARENT/tmp"
mkdir -p "$TMPDIR"

mkdir -p "$TMP/.claude/hooks" "$TMP/core" "$TMP/repos/public/app"
cp "$ROOT/.claude/hooks/hq-autocommit.sh" "$TMP/.claude/hooks/hq-autocommit.sh"
chmod +x "$TMP/.claude/hooks/hq-autocommit.sh"
printf 'hqVersion: "test"\n' > "$TMP/core/core.yaml"

git -C "$TMP" init -q
git -C "$TMP" config user.email "hq-autocommit-test"
git -C "$TMP" config user.name "HQ Autocommit Test"
git -C "$TMP" add core/core.yaml .claude/hooks/hq-autocommit.sh
git -C "$TMP" commit -q -m "init"

printf 'one\n' > "$TMP/notes.md"
payload='{"tool_name":"Edit","tool_input":{"file_path":"notes.md"}}'
(cd "$TMP" && printf '%s' "$payload" | .claude/hooks/hq-autocommit.sh)

git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): notes.md"
git -C "$TMP" show --name-only --format= HEAD | grep -q "^notes.md$"

printf 'repo\n' > "$TMP/repos/public/app/file.txt"
payload_repo='{"tool_name":"Edit","tool_input":{"file_path":"repos/public/app/file.txt"}}'
(cd "$TMP" && printf '%s' "$payload_repo" | .claude/hooks/hq-autocommit.sh)

if git -C "$TMP" show --name-only --format= HEAD | grep -q "repos/public/app/file.txt"; then
  echo "repo path should not be autocommitted" >&2
  exit 1
fi

REAL_GIT="$(command -v git)"
SHIM_DIR="$TMP/git-shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

real_git="${HQ_AUTOCOMMIT_TEST_REAL_GIT:?}"
show_toplevel=0
previous=""

for arg in "$@"; do
  if [[ "$previous" == "rev-parse" && "$arg" == "--show-toplevel" ]]; then
    show_toplevel=1
    break
  fi
  previous="$arg"
done

if [[ "$show_toplevel" == "1" ]]; then
  top="$("$real_git" "$@")"
  printf 'C:%s\n' "$top"
else
  exec "$real_git" "$@"
fi
SHIM
chmod +x "$SHIM_DIR/git"
cat > "$SHIM_DIR/python3" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
chmod +x "$SHIM_DIR/python3"

printf 'windows\n' > "$TMP/windows-path.txt"
payload_windows='{"tool_name":"Edit","tool_input":{"file_path":"windows-path.txt"}}'
(
  cd "$TMP"
  export HQ_AUTOCOMMIT_TEST_REAL_GIT="$REAL_GIT"
  export PATH="$SHIM_DIR:$PATH"
  printf '%s' "$payload_windows" | .claude/hooks/hq-autocommit.sh
)

git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): windows-path.txt"
git -C "$TMP" show --name-only --format= HEAD | grep -q "^windows-path.txt$"

mkdir -p "$TMP/workspace/nested"
git -C "$TMP/workspace/nested" init -q
git -C "$TMP/workspace/nested" config user.email "hq-autocommit-test"
git -C "$TMP/workspace/nested" config user.name "HQ Autocommit Test"
printf 'nested\n' > "$TMP/workspace/nested/file.txt"
head_before_nested="$(git -C "$TMP" rev-parse HEAD)"
payload_nested='{"tool_name":"Edit","tool_input":{"file_path":"workspace/nested/file.txt"}}'
(cd "$TMP" && printf '%s' "$payload_nested" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_nested" ]]; then
  echo "nested repo path should not be autocommitted" >&2
  exit 1
fi

# A file under workspace/worktrees/ (a live project worktree) is never autosaved
# into the HQ root. (feedback_2ada615f)
mkdir -p "$TMP/workspace/worktrees/proj"
printf 'wt\n' > "$TMP/workspace/worktrees/proj/notes.md"
head_before_wt="$(git -C "$TMP" rev-parse HEAD)"
payload_wt='{"tool_name":"Edit","tool_input":{"file_path":"workspace/worktrees/proj/notes.md"}}'
(cd "$TMP" && printf '%s' "$payload_wt" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_wt" ]]; then
  echo "workspace/worktrees path should not be autocommitted" >&2
  exit 1
fi

# Gitlink guard: a directory add that would sweep a nested repo into the HQ root
# as an embedded gitlink (mode 160000) is refused — no commit, nothing staged.
# (feedback_2ada615f)
mkdir -p "$TMP/holder/inner"
git -C "$TMP/holder/inner" init -q
git -C "$TMP/holder/inner" config user.email "hq-autocommit-test"
git -C "$TMP/holder/inner" config user.name "HQ Autocommit Test"
printf 'inner\n' > "$TMP/holder/inner/f.txt"
git -C "$TMP/holder/inner" add -A
git -C "$TMP/holder/inner" commit -q -m "inner"
printf 'plain\n' > "$TMP/holder/plain.txt"
head_before_gitlink="$(git -C "$TMP" rev-parse HEAD)"
payload_gitlink='{"tool_name":"Edit","tool_input":{"file_path":"holder"}}'
(cd "$TMP" && printf '%s' "$payload_gitlink" | .claude/hooks/hq-autocommit.sh)

if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_gitlink" ]]; then
  echo "directory add sweeping a gitlink should not be autocommitted" >&2
  exit 1
fi
if git -C "$TMP" ls-files --stage | awk '$1 == "160000" { exit 0 } END { exit 1 }'; then
  echo "gitlink (mode 160000) must not remain staged in the HQ root" >&2
  exit 1
fi

# ── Failure visibility (B4) ─────────────────────────────────────────────────
# The hook used to end every git call with `|| exit 0` and funnel all output to
# /tmp, so an orphaned .git/index.lock stopped autosave for hours while printing
# nothing anywhere. A git failure must now leave a durable record and say so.

LOG_REL="workspace/logs/hq-autocommit.log"
LOG="$TMP/$LOG_REL"

run_hook() {
  # run_hook <session-id> <rel-path> [env assignments...] -> stdout, sets HOOK_RC
  local session="$1" rel="$2"
  shift 2
  local payload
  payload="$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s"}}' "$session" "$rel")"
  HOOK_RC=0
  HOOK_OUT="$(cd "$TMP" && printf '%s' "$payload" | env "$@" bash .claude/hooks/hq-autocommit.sh 2>/dev/null)" || HOOK_RC=$?
}

printf 'blocked\n' > "$TMP/wedged.md"
: > "$TMP/.git/index.lock"
head_before_fail="$(git -C "$TMP" rev-parse HEAD)"

run_hook "sess-a" "wedged.md"
if [[ "$HOOK_RC" -ne 0 ]]; then
  echo "a git failure must not block the editor (expected exit 0, got $HOOK_RC)" >&2
  exit 1
fi
if [[ "$HOOK_OUT" != *"HQ autosave failed"* ]]; then
  echo "a git failure must emit a visible warning; got: '$HOOK_OUT'" >&2
  exit 1
fi
if [[ ! -f "$LOG" ]]; then
  echo "a git failure must be recorded in $LOG_REL" >&2
  exit 1
fi
if ! grep -q "FAIL stage=add" "$LOG"; then
  echo "failure log must name the git stage that failed" >&2
  exit 1
fi
if ! grep -q "index.lock" "$LOG"; then
  echo "failure log must retain git's own error text" >&2
  exit 1
fi
if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_fail" ]]; then
  echo "nothing should have been committed while the index was locked" >&2
  exit 1
fi

# Same session, same cause: logged again, but warned about only once. A wedged
# repo fails on every edit and a warning per edit trains the user to ignore it.
fail_lines_before="$(grep -c "FAIL stage=add" "$LOG" || true)"
printf 'blocked again\n' > "$TMP/wedged.md"
run_hook "sess-a" "wedged.md"
if [[ -n "$HOOK_OUT" ]]; then
  echo "repeat failure in the same session must not re-warn; got: '$HOOK_OUT'" >&2
  exit 1
fi
if [[ "$(grep -c "FAIL stage=add" "$LOG" || true)" -le "$fail_lines_before" ]]; then
  echo "every failure must still be logged, even when the warning is deduped" >&2
  exit 1
fi

# HQ_AUTOCOMMIT_STRICT makes "did autosave work" machine-readable.
run_hook "sess-b" "wedged.md" HQ_AUTOCOMMIT_STRICT=1
if [[ "$HOOK_RC" -eq 0 ]]; then
  echo "HQ_AUTOCOMMIT_STRICT=1 must exit non-zero on a git failure" >&2
  exit 1
fi

rm -f "$TMP/.git/index.lock"

# A stale index lock with no live holder is recovered automatically. The
# probe seam returns non-zero for "unowned" so this remains deterministic on
# CI images that do not install lsof/fuser.
printf 'recovered index\n' > "$TMP/recovered-index.md"
: > "$TMP/.git/index.lock"
touch -t 202001010000 "$TMP/.git/index.lock"
run_hook "sess-index-recover" "recovered-index.md" \
  HQ_AUTOCOMMIT_LOCK_PROBE=false
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "an unowned stale index lock should self-heal silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ -e "$TMP/.git/index.lock" ]]; then
  echo "the recovered stale index lock must be removed" >&2
  exit 1
fi
if ! git -C "$TMP" show --name-only --format= HEAD | grep -q '^recovered-index.md$'; then
  echo "autosave must continue after recovering a stale index lock" >&2
  exit 1
fi
if ! grep -q "RECOVER stage=index-lock" "$LOG"; then
  echo "stale index-lock recovery must be recorded in $LOG_REL" >&2
  exit 1
fi

# A healthy commit stays completely silent and adds no failure record.
fail_lines_healthy="$(grep -c "FAIL " "$LOG" || true)"
printf 'healthy\n' > "$TMP/healthy.md"
run_hook "sess-c" "healthy.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a successful autosave must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
git -C "$TMP" show --name-only --format=%s HEAD | grep -q "autosave(hq): healthy.md"
if [[ "$(grep -c "FAIL " "$LOG" || true)" -ne "$fail_lines_healthy" ]]; then
  echo "a successful autosave must not write a failure record" >&2
  exit 1
fi

# An unchanged file is "nothing to commit", not a failure.
run_hook "sess-c" "healthy.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a no-op autosave must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ "$(grep -c "FAIL " "$LOG" || true)" -ne "$fail_lines_healthy" ]]; then
  echo "a no-op autosave must not write a failure record" >&2
  exit 1
fi

# Live contention is normal and silent; an orphaned lock suppresses every
# autosave indefinitely, so it gets said out loud once.
printf 'contended\n' > "$TMP/contended.md"
mkdir -p "$TMPDIR/hq-autocommit.lock"
run_hook "sess-d" "contended.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "fresh lock contention must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi

owner_birth="$(LC_ALL=C ps -p "$$" -o lstart= 2>/dev/null | tr -d '[:space:]' || true)"
printf 'pid=%s\nbirth=%s\n' "$$" "$owner_birth" > "$TMPDIR/hq-autocommit.lock/owner"
touch -t 202001010000 "$TMPDIR/hq-autocommit.lock"
run_hook "sess-live-lock" "contended.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a stale-looking lock with a live owner must stay untouched and silent" >&2
  exit 1
fi
if [[ ! -d "$TMPDIR/hq-autocommit.lock" ]]; then
  echo "a live owner's autosave lock must never be recovered" >&2
  exit 1
fi

if [[ -n "$owner_birth" ]]; then
  # A stale lock carrying a live but reused PID must be recoverable when the
  # process birth token does not match the original owner.
  printf 'pid=%s\nbirth=%s\n' "$$" "different-process" > "$TMPDIR/hq-autocommit.lock/owner"
  touch -t 202001010000 "$TMPDIR/hq-autocommit.lock"
  run_hook "sess-reused-pid" "contended.md"
  if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
    echo "a reused PID lock should self-heal silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
    exit 1
  fi
  if [[ -d "$TMPDIR/hq-autocommit.lock" ]]; then
    echo "a reused PID must not keep an orphaned autosave lock alive" >&2
    exit 1
  fi
else
  rm -f "$TMPDIR/hq-autocommit.lock/owner"
  rmdir "$TMPDIR/hq-autocommit.lock"
fi

# Recreate an ownerless stale lock to exercise the legacy recovery path too.
mkdir -p "$TMPDIR/hq-autocommit.lock"
printf 'contended-again\n' > "$TMP/contended.md"

rm -f "$TMPDIR/hq-autocommit.lock/owner"
touch -t 202001010000 "$TMPDIR/hq-autocommit.lock"
run_hook "sess-e" "contended.md"
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "an unowned stale autosave lock should self-heal silently; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ -d "$TMPDIR/hq-autocommit.lock" ]]; then
  echo "the recovered stale autosave lock must be removed after the hook exits" >&2
  exit 1
fi
if ! grep -q "RECOVER stage=lock" "$LOG"; then
  echo "stale autosave-lock recovery must be recorded in $LOG_REL" >&2
  exit 1
fi
if ! git -C "$TMP" show --name-only --format= HEAD | grep -q '^contended.md$'; then
  echo "autosave must continue after recovering its stale process lock" >&2
  exit 1
fi

# --- macOS Finder Icon\r / control-character paths -------------------------
# Finder writes a file literally named `Icon` + CR into every directory it
# renders a custom icon for, and a folder-level cloud-sync agent spreads them
# tree-wide. Once one is committed, Finder rewriting it makes it a tracked
# modification that autosave would re-commit forever. They also cannot sync:
# an S3 key may not contain a control character, so each is a permanent
# per-file upload failure. Autosave must never stage one.

icon_name="Icon"$'\r'

# Direct hit: the tool call names the control-char path itself. The JSON
# payload carries it as an escaped \r, which jq decodes back to a real CR.
printf 'finder cruft\n' > "$TMP/$icon_name"
head_before_icon="$(git -C "$TMP" rev-parse HEAD)"
HOOK_RC=0
HOOK_OUT="$(cd "$TMP" \
  && printf '{"tool_name":"Edit","session_id":"sess-icon","tool_input":{"file_path":"Icon\\r"}}' \
  | bash .claude/hooks/hq-autocommit.sh 2>/dev/null)" || HOOK_RC=$?
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "an Icon\\r autosave must be a silent no-op; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if [[ "$(git -C "$TMP" rev-parse HEAD)" != "$head_before_icon" ]]; then
  echo "an Icon\\r path must never be committed" >&2
  exit 1
fi
if git -C "$TMP" ls-files -z | tr '\0' '\n' | grep -q "^Icon"; then
  echo "an Icon\\r path must never become tracked" >&2
  exit 1
fi

# Directory sweep: the tool call names a DIRECTORY, so `git add -- <dir>`
# reaches every file beneath it. The legitimate file must still be committed
# and the control-char sibling must be left behind — this is the path that
# actually made `.agents/Icon\r` tracked on the reporting machine.
mkdir -p "$TMP/docs"
printf 'real content\n' > "$TMP/docs/page.md"
printf 'finder cruft\n' > "$TMP/docs/$icon_name"
HOOK_RC=0
HOOK_OUT="$(cd "$TMP" \
  && printf '{"tool_name":"Edit","session_id":"sess-icon-dir","tool_input":{"file_path":"docs"}}' \
  | bash .claude/hooks/hq-autocommit.sh 2>/dev/null)" || HOOK_RC=$?
if [[ "$HOOK_RC" -ne 0 || -n "$HOOK_OUT" ]]; then
  echo "a directory autosave alongside Icon\\r must stay silent; rc=$HOOK_RC out='$HOOK_OUT'" >&2
  exit 1
fi
if ! git -C "$TMP" show --name-only --format= HEAD | grep -q "^docs/page.md$"; then
  echo "the legitimate file in the directory must still be autosaved" >&2
  exit 1
fi
if git -C "$TMP" ls-files -z | tr '\0' '\n' | grep -q "^docs/Icon"; then
  echo "a directory add must not sweep in an Icon\\r sibling" >&2
  exit 1
fi
# The staged control-char entry is dropped, so it must not linger in the index.
if git -C "$TMP" diff --cached --name-only -z | tr '\0' '\n' | grep -q "Icon"; then
  echo "an Icon\\r path must not be left staged in the index" >&2
  exit 1
fi

echo "hq-autocommit smoke: ok"
