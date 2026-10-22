#!/usr/bin/env bash
# handoff-finalize-stage-error.test.sh — a rejected `git add` must surface git's
# own error and say why (feedback_98f2ce49-5065-4670-8544-1a3dccd9985e).
#
# The finalizer sent git-add stderr to /dev/null, so a sandboxed run that may
# not write .git reported "git add failed for 614 path(s)" with no cause, and
# the same command succeeded outside the sandbox. A `git` shim on PATH stands
# in for the denial: it fails every `add` with the message a sandbox produces
# and passes everything else to the real git.

set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
REAL_GIT="$(command -v git)"
export REAL_GIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

mkdir -p "$TMP_ROOT/shim"
cat > "$TMP_ROOT/shim/git" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_GIT_ADD_ERR:-}" ]]; then
  for a in "$@"; do
    if [[ "$a" == "add" ]]; then
      printf '%s\n' "$FAKE_GIT_ADD_ERR" >&2
      exit 128
    fi
    case "$a" in -*) continue ;; *) break ;; esac
  done
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP_ROOT/shim/git"

scaffold_repo() {
  local repo="$1"
  mkdir -p "$repo/core/scripts/lib" "$repo/workspace/baseline" "$repo/workspace/threads" "$repo/workspace/orchestrator"
  cp "$SRC_ROOT/scripts/handoff-finalize.sh" "$repo/core/scripts/handoff-finalize.sh"
  cp "$SRC_ROOT/scripts/lib/session-id.sh" "$repo/core/scripts/lib/session-id.sh"
  cp "$SRC_ROOT/scripts/hq-status-summary.sh" "$repo/core/scripts/hq-status-summary.sh"
  cp "$SRC_ROOT/scripts/lib/forwarder.sh" "$repo/core/scripts/lib/forwarder.sh"
  cp "$SRC_ROOT/scripts/lib/hq-cli-floor.sh" "$repo/core/scripts/lib/hq-cli-floor.sh"
  cat > "$repo/core/scripts/rebuild-threads-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/threads
echo "# Threads" > workspace/threads/INDEX.md
echo "- recent" > workspace/threads/recent.md
SH
  cat > "$repo/core/scripts/rebuild-orchestrator-index.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p workspace/orchestrator
echo "# Orchestrator" > workspace/orchestrator/INDEX.md
SH
  chmod +x "$repo/core/scripts/"*.sh
  cat > "$repo/workspace/baseline/hq-local-baseline.json" <<'JSON'
{"categories":[{"name":"baseline","patterns":["companies/*","workspace/*","repos/*","core/settings/*",".hq/*"]}]}
JSON
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Handoff Stage Error Test"
  echo "base" > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt core/scripts workspace/baseline/hq-local-baseline.json
  git -C "$repo" commit -qm "base"
}

# run_finalize <repo> <slug> <fake add error or empty> — prints the payload;
# the exit code lands in $TMP_ROOT/rc.
run_finalize() {
  local repo="$1" slug="$2" err="$3" rc=0 out
  echo "changed $slug" > "$repo/tracked.txt"
  out="$(cd "$repo" && FAKE_GIT_ADD_ERR="$err" PATH="$TMP_ROOT/shim:$PATH" \
    bash core/scripts/handoff-finalize.sh \
      --title "Handoff: $slug" --summary "$slug" --message "$slug" \
      --files-touched-json '["tracked.txt"]' --slug "$slug" 2>"$TMP_ROOT/$slug.err")" || rc=$?
  printf '%s' "$rc" > "$TMP_ROOT/rc"
  printf '%s' "$out"
}

# 1. Sandbox-style permission denial.
REPO="$TMP_ROOT/perm"
scaffold_repo "$REPO"
out="$(run_finalize "$REPO" perm "fatal: Unable to create '$REPO/.git/index.lock': Operation not permitted")"
assert_eq "$(cat "$TMP_ROOT/rc")" "4" "permission exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "stage-failed" "permission hq_commit_status"
assert_eq "$(jq -r '.stage_failure_class' <<<"$out")" "permission" "permission stage_failure_class"
err="$(jq -r '.hq_commit_error' <<<"$out")"
[[ "$err" == *"Operation not permitted"* ]] || fail "permission hq_commit_error must carry git's error, got: $err"
[[ "$err" == *"sandbox"* ]] || fail "permission hq_commit_error must name the sandbox cause, got: $err"
grep -Fq "Operation not permitted" "$TMP_ROOT/perm.err" || fail "stderr must show git's error"

# 2. Another process holds index.lock.
REPO="$TMP_ROOT/lock"
scaffold_repo "$REPO"
out="$(run_finalize "$REPO" lock "fatal: Unable to create '$REPO/.git/index.lock': File exists.")"
assert_eq "$(cat "$TMP_ROOT/rc")" "4" "index-lock exit code"
assert_eq "$(jq -r '.stage_failure_class' <<<"$out")" "index-lock" "index-lock stage_failure_class"
[[ "$(jq -r '.hq_commit_error' <<<"$out")" == *"File exists"* ]] || fail "index-lock hq_commit_error must carry git's error"

# 3. Unclassified failure still carries the message.
REPO="$TMP_ROOT/other"
scaffold_repo "$REPO"
out="$(run_finalize "$REPO" other "fatal: synthetic unexpected failure")"
assert_eq "$(jq -r '.stage_failure_class' <<<"$out")" "other" "other stage_failure_class"
[[ "$(jq -r '.hq_commit_error' <<<"$out")" == *"synthetic unexpected failure"* ]] || fail "other hq_commit_error must carry git's error"

# 4. Healthy run: no class, no error.
REPO="$TMP_ROOT/ok"
scaffold_repo "$REPO"
out="$(run_finalize "$REPO" ok "")"
assert_eq "$(cat "$TMP_ROOT/rc")" "0" "healthy exit code"
assert_eq "$(jq -r '.hq_commit_status' <<<"$out")" "committed" "healthy hq_commit_status"
assert_eq "$(jq -r '.stage_failure_class' <<<"$out")" "" "healthy stage_failure_class"

echo "PASS: handoff-finalize surfaces and classifies git add errors"
