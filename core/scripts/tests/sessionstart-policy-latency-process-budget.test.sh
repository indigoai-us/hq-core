#!/usr/bin/env bash
# The 300-policy PreToolUse and migration paths must not fork once per policy
# while evaluating policy output or checking trigger frontmatter.
set -euo pipefail

TEST_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
STRACE="$(type -P strace || true)"
[ -n "$STRACE" ] || { echo 'FAIL: strace is required for the hook process-budget test' >&2; exit 1; }

# Keep this pinned to the pre-optimization source. A moving PR base becomes the
# optimized candidate after merge and would make the improvement assertion fail.
# Staging's backmerge cead9f4f and hq-core's v15.0.172 commit 64179657 carry
# byte-identical copies of the compared files; each exists in only one repo.
BASE_SHA="${HQ_HOOK_PERF_BASE_SHA:-}"
if [ -z "$BASE_SHA" ]; then
  for candidate in cead9f4fce5f762ee08d169d4d47e912c1ef0bee 641796571f18e870a2e4cdd24575fda6b93dc4c3; do
    if timeout 20s git -C "$ROOT" cat-file -e "$candidate^{commit}" 2>/dev/null; then
      BASE_SHA="$candidate"
      break
    fi
  done
  BASE_SHA="${BASE_SHA:-cead9f4fce5f762ee08d169d4d47e912c1ef0bee}"
fi
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL: invalid HQ_HOOK_PERF_BASE_SHA' >&2; exit 1; }
timeout 20s git -C "$ROOT" cat-file -e "$BASE_SHA^{commit}" \
  || { echo "FAIL: base commit is unavailable: $BASE_SHA" >&2; exit 1; }

TMP="$ROOT/workspace/.sessionstart-policy-latency-test.$$"
BASE_SOURCE="$TMP/base-source"
CANDIDATE_SOURCE="$TMP/candidate-source"
mkdir -p "$BASE_SOURCE" "$CANDIDATE_SOURCE"
trap 'rm -rf "$TMP"' EXIT

for relative in \
  .claude/hooks/inject-policy-on-trigger.sh \
  core/scripts/migrate-policy-triggers.sh; do
  mkdir -p "$BASE_SOURCE/${relative%/*}" "$CANDIDATE_SOURCE/${relative%/*}"
  timeout 20s git -C "$ROOT" show "$BASE_SHA:$relative" > "$BASE_SOURCE/$relative" \
    || { echo "FAIL: base is missing $relative" >&2; exit 1; }
  cp "$ROOT/$relative" "$CANDIDATE_SOURCE/$relative"
done

write_registry() {
  cat > "$1/.claude/hooks/hook-registry.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"id":"migrate-policy-triggers","script":"core/scripts/migrate-policy-triggers.sh","timeout":60,"gated":false},{"id":"inject-policy-on-trigger","script":".claude/hooks/inject-policy-on-trigger.sh","timeout":60,"gated":false}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"id":"inject-policy-on-trigger","script":".claude/hooks/inject-policy-on-trigger.sh","timeout":60,"gated":false},{"id":"block-hq-root-git-mutation","script":".claude/hooks/block-hq-root-git-mutation.sh","timeout":60,"gated":false}]}]}}
JSON
}

make_fixture() {
  local root="$1" count="$2" i=1
  mkdir -p "$root/.claude/hooks" "$root/core/scripts/lib" \
    "$root/core/hooks/SessionStart" "$root/core/hooks/PreToolUse" \
    "$root/personal/policies" "$root/workspace" "$root/home/.local/state"
  for relative in \
    .claude/hooks/master-hook.sh \
    .claude/hooks/hook-timeout-probe.sh \
    .claude/hooks/hook-timeout-watchdog.sh \
    .claude/hooks/hook-gate.sh \
    .claude/hooks/block-hq-root-git-mutation.sh; do
    cp "$ROOT/$relative" "$root/$relative"
  done
  cp "$ROOT/core/core.yaml" "$root/core/core.yaml"
  cp "$ROOT/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  cp "$ROOT/core/scripts/derive-trigger-facts.sh" "$root/core/scripts/derive-trigger-facts.sh"
  cp "$ROOT/core/scripts/eval-trigger.sh" "$root/core/scripts/eval-trigger.sh"
  cp -R "$ROOT/core/scripts/lib/." "$root/core/scripts/lib/"
  write_registry "$root"
  while [ "$i" -le "$count" ]; do
      printf -- '---\nid: c138-fixture-%03d\ntitle: "c138 fixture %03d"\nscope: test\nwhen: always\non: [SessionStart, PreToolUse]\nenforcement: soft\n---\n\n## Rule\n\nFixture rule %03d.\n' \
      "$i" "$i" "$i" > "$root/personal/policies/c138-fixture-$(printf '%03d' "$i").md"
    i=$((i + 1))
  done
  git -C "$root" init -q
}

install_source() {
  local root="$1" source="$2"
  cp "$source/.claude/hooks/inject-policy-on-trigger.sh" "$root/.claude/hooks/inject-policy-on-trigger.sh"
  cp "$source/core/scripts/migrate-policy-triggers.sh" "$root/core/scripts/migrate-policy-triggers.sh"
}

reset_runtime_state() {
  local root="$1"
  rm -rf "$root/workspace" "$root/home"
  mkdir -p "$root/workspace" "$root/home/.local/state"
}

run_measured_injector() {
  local root="$1" name="$2" payload="$3" rc calls
  local trace="$TMP/$name.strace" out="$TMP/$name.out" err="$TMP/$name.err"
  reset_runtime_state "$root"
  set +e
  timeout 90s "$STRACE" -f -c -e trace=execve -o "$trace" \
    env -u BASH_ENV -u ENV -u HQ_POLICY_WORKER_DIR PATH=/usr/bin:/bin HOME="$root/home" \
      XDG_STATE_HOME="$root/home/.local/state" HQ_ROOT="$root" \
      CLAUDE_PROJECT_DIR="$root" HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
      env -u HQ_POLICY_EMIT bash "$root/.claude/hooks/inject-policy-on-trigger.sh" \
      <<<"$payload" >"$out" 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { echo "FAIL: $name policy injector exited $rc" >&2; cat "$err" >&2; exit 1; }
  calls="$(awk '$NF == "execve" { print $4; found=1 } END { if (!found) exit 1 }' "$trace")" \
    || { echo "FAIL: $name strace recorded no execve summary" >&2; exit 1; }
  printf '%s\n' "$calls"
}

run_measured_migrator() {
  local root="$1" name="$2" rc calls
  local trace="$TMP/$name-migrate.strace" out="$TMP/$name-migrate.out" err="$TMP/$name-migrate.err"
  reset_runtime_state "$root"
  set +e
  timeout 90s "$STRACE" -f -c -e trace=execve -o "$trace" \
    env -u BASH_ENV -u ENV -u HQ_POLICY_WORKER_DIR PATH=/usr/bin:/bin HOME="$root/home" \
      XDG_STATE_HOME="$root/home/.local/state" HQ_ROOT="$root" \
      CLAUDE_PROJECT_DIR="$root" HQ_MIGRATE_POLICY_TRIGGERS_COOLDOWN_SECONDS=0 \
      bash "$root/core/scripts/migrate-policy-triggers.sh" --dry-run \
      >"$out" 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { echo "FAIL: $name policy migrator exited $rc" >&2; cat "$err" >&2; exit 1; }
  calls="$(awk '$NF == "execve" { print $4; found=1 } END { if (!found) exit 1 }' "$trace")" \
    || { echo "FAIL: $name migrator strace recorded no execve summary" >&2; exit 1; }
  printf '%s\n' "$calls"
}

run_equivalence_case() {
  local root="$1" payload="$2" event="$3" name="$4" variant="$5" rc
  local out="$TMP/$name.$variant.out" err="$TMP/$name.$variant.err"
  reset_runtime_state "$root"
  set +e
  timeout 30s env -u BASH_ENV -u ENV -u HQ_POLICY_WORKER_DIR PATH=/usr/bin:/bin HOME="$root/home" \
    XDG_STATE_HOME="$root/home/.local/state" HQ_ROOT="$root" \
    CLAUDE_PROJECT_DIR="$root" HQ_HOOK_PROFILE=standard HQ_HOOK_TIMEOUT_SENTRY=0 \
    bash "$root/.claude/hooks/master-hook.sh" "$event" \
    <<<"$payload" >"$out" 2>"$err"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$TMP/$name.$variant.rc"
}

PROCESS_ROOT="$TMP/process-hq"
make_fixture "$PROCESS_ROOT" 300
PROCESS_INPUT="$(jq -cn --arg cwd "$PROCESS_ROOT" '{hook_event_name:"PreToolUse",session_id:"c138-process-budget",tool_name:"Bash",cwd:$cwd,tool_input:{command:"true"}}')"
install_source "$PROCESS_ROOT" "$BASE_SOURCE"
BASE_EXECS="$(run_measured_injector "$PROCESS_ROOT" base "$PROCESS_INPUT")"
BASE_MIGRATE_EXECS="$(run_measured_migrator "$PROCESS_ROOT" base)"
install_source "$PROCESS_ROOT" "$CANDIDATE_SOURCE"
CANDIDATE_EXECS="$(run_measured_injector "$PROCESS_ROOT" candidate "$PROCESS_INPUT")"
CANDIDATE_MIGRATE_EXECS="$(run_measured_migrator "$PROCESS_ROOT" candidate)"

# The 300-policy fixture emits every matching row, exposing per-policy ledger
# work without relying on a wall-clock threshold.
[ "$BASE_EXECS" -gt 1000 ] || { echo "FAIL: 300-policy base fixture no longer exposes per-policy spawning ($BASE_EXECS execve)" >&2; exit 1; }
[ "$CANDIDATE_EXECS" -le 500 ] || { echo "FAIL: 300-policy candidate exceeded 500 execve calls ($CANDIDATE_EXECS)" >&2; exit 1; }
[ "$CANDIDATE_EXECS" -lt "$BASE_EXECS" ] || { echo "FAIL: candidate did not reduce the 300-policy process count ($BASE_EXECS -> $CANDIDATE_EXECS)" >&2; exit 1; }
[ "$BASE_MIGRATE_EXECS" -gt 500 ] || { echo "FAIL: 300-policy base migrator no longer exposes per-file spawning ($BASE_MIGRATE_EXECS execve)" >&2; exit 1; }
[ "$CANDIDATE_MIGRATE_EXECS" -le 100 ] || { echo "FAIL: candidate migrator exceeded 100 execve calls ($CANDIDATE_MIGRATE_EXECS)" >&2; exit 1; }
[ "$CANDIDATE_MIGRATE_EXECS" -lt "$BASE_MIGRATE_EXECS" ] || { echo "FAIL: candidate migrator did not reduce the process count ($BASE_MIGRATE_EXECS -> $CANDIDATE_MIGRATE_EXECS)" >&2; exit 1; }

EQUIV_ROOT="$TMP/equivalence-hq"
make_fixture "$EQUIV_ROOT" 3
SESSION_PAYLOAD="$(jq -cn --arg cwd "$EQUIV_ROOT" '{hook_event_name:"SessionStart",session_id:"equiv-session",source:"startup",cwd:$cwd}')"
ALLOW_PAYLOAD="$(jq -cn --arg cwd "$EQUIV_ROOT" --arg cmd "git -C $EQUIV_ROOT status --short" '{hook_event_name:"PreToolUse",session_id:"equiv-allow",tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
BLOCK_PAYLOAD="$(jq -cn --arg cwd "$EQUIV_ROOT" '{hook_event_name:"PreToolUse",session_id:"equiv-block",tool_name:"Bash",cwd:$cwd,tool_input:{command:"git push origin main"}}')"

install_source "$EQUIV_ROOT" "$BASE_SOURCE"
run_equivalence_case "$EQUIV_ROOT" "$SESSION_PAYLOAD" SessionStart session base
run_equivalence_case "$EQUIV_ROOT" "$ALLOW_PAYLOAD" PreToolUse allow base
run_equivalence_case "$EQUIV_ROOT" "$BLOCK_PAYLOAD" PreToolUse block base
install_source "$EQUIV_ROOT" "$CANDIDATE_SOURCE"
run_equivalence_case "$EQUIV_ROOT" "$SESSION_PAYLOAD" SessionStart session candidate
run_equivalence_case "$EQUIV_ROOT" "$ALLOW_PAYLOAD" PreToolUse allow candidate
run_equivalence_case "$EQUIV_ROOT" "$BLOCK_PAYLOAD" PreToolUse block candidate

for name in session allow block; do
  cmp -s "$TMP/$name.base.out" "$TMP/$name.candidate.out" \
    || { echo "FAIL: $name injected/guard stdout differs between base and candidate" >&2; exit 1; }
  cmp -s "$TMP/$name.base.err" "$TMP/$name.candidate.err" \
    || { echo "FAIL: $name guard stderr differs between base and candidate" >&2; exit 1; }
  cmp -s "$TMP/$name.base.rc" "$TMP/$name.candidate.rc" \
    || { echo "FAIL: $name block/allow exit differs between base and candidate" >&2; exit 1; }
done
[ "$(cat "$TMP/allow.candidate.rc")" -eq 0 ] || { echo 'FAIL: anchored read was not allowed' >&2; exit 1; }
[ "$(cat "$TMP/block.candidate.rc")" -eq 2 ] || { echo 'FAIL: unanchored root push was not blocked' >&2; exit 1; }

printf 'PASS: 300-policy PreToolUse execve count %s -> %s; migration execve count %s -> %s; output and allow/block decisions match base\n' \
  "$BASE_EXECS" "$CANDIDATE_EXECS" "$BASE_MIGRATE_EXECS" "$CANDIDATE_MIGRATE_EXECS"
