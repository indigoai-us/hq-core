#!/usr/bin/env bash
# Regression (hq-core-staging #2029 review): /handoff passed --company and
# --deficiencies-json to `hq core handoff run`, and hq-cli 5.345.231 rejects
# both with "Unknown arg" before any thread is written, so every handoff failed
# with no thread. This test runs the skill's own Step 3 command line against a
# stub whose argument parser copies 5.345.231, and checks that a thread is still
# written, through core/scripts/handoff-run.sh, with both flags kept.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
SKILL="$ROOT/.claude/skills/handoff/SKILL.md"
WRAPPER="$ROOT/core/scripts/handoff-run.sh"
FINALIZE="$ROOT/core/scripts/handoff-finalize.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handoff-run-compat.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Flags `hq core handoff run` accepts in hq-cli 5.345.231 (src/commands/
# core-handoff.ts: runHandoffFlow's own options, then resolveFinalizeOptions'
# map). Anything else stops finalize with "Unknown arg: <flag>", exit 2.
RUN_FLAGS="--no-post --no-autofile --no-builder-route --learnings-file --files-touched-json-file"
FINALIZE_FLAGS="--title --summary --message --next-steps-json --files-touched-json --files-touched-json-file --learnings-json --tags-json --slug --next-command"

hq_root="$TMP/hq"
mkdir -p "$hq_root/core/scripts" "$hq_root/workspace/threads/.handoff-tmp" "$TMP/bin"
cp "$WRAPPER" "$hq_root/core/scripts/handoff-run.sh"
LOG="$TMP/calls.log"

# Stub hq: `core handoff run` parses like 5.345.231. HQ_TEST_CLI_MODE picks
# what happens: ok (payload, exit 0), commit-failed (payload, exit 4),
# knowledge-failed (no payload, exit 3), no-thread (exit 0, no thread_path),
# auth-failed (exit 1 before parsing), no-run-subcommand (commander's
# "unknown command 'run'", exit 1).
cat > "$TMP/bin/hq" <<STUB
#!/usr/bin/env bash
run_flags=" $RUN_FLAGS "
finalize_flags=" $FINALIZE_FLAGS "
STUB
cat >> "$TMP/bin/hq" <<'STUB'
log="$HQ_TEST_LOG"
if [ "$1 $2 $3" = "core handoff post" ]; then shift 3; printf 'post %s\n' "$*" >> "$log"; exit 0; fi
[ "$1 $2 $3" = "core handoff run" ] || { echo "stub hq: unexpected $*" >&2; exit 64; }
shift 3
printf 'cli-run %s\n' "$*" >> "$log"
case "${HQ_TEST_CLI_MODE:-ok}" in
  no-run-subcommand) echo "error: unknown command 'run'" >&2; exit 1 ;;
  auth-failed) echo "hq: not signed in; run hq login" >&2; exit 1 ;;
esac
files=""; fin=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-post|--no-autofile|--no-builder-route) shift; continue ;;
    --learnings-file) shift 2; continue ;;
    --files-touched-json-file) files="$2"; fin+=("$1" "$2"); shift 2; continue ;;
  esac
  fin+=("$1"); shift
done
[ -n "$files" ] || { echo "Usage: hq core handoff run --files-touched-json-file <path> ..." >&2; exit 2; }
if [ "${HQ_TEST_CLI_MODE:-ok}" = knowledge-failed ]; then echo "knowledge commit failed" >&2; exit 3; fi
echo "cli-knowledge-commit" >> "$log"
i=0
while [ $i -lt ${#fin[@]} ]; do
  key="${fin[$i]}"
  case "$finalize_flags" in *" $key "*) ;; *) echo "Unknown arg: $key" >&2; exit 2 ;; esac
  i=$((i + 2))
done
case "${HQ_TEST_CLI_MODE:-ok}" in
  ok) printf '{"thread_id":"T-cli","thread_path":"workspace/threads/T-cli.json","post":{"launched":true,"skipped":false,"error":null}}\n'; exit 0 ;;
  commit-failed) printf '{"thread_id":"T-cli","thread_path":"workspace/threads/T-cli.json","hq_commit_status":"failed"}\n'; exit 4 ;;
  no-thread) printf '{"ok":true}\n'; exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/hq"

# Stub helpers record their argv. Finalize writes a thread file and accepts
# every flag the real handoff-finalize.sh parses.
cat > "$hq_root/core/scripts/handoff-knowledge-commit.sh" <<'STUB'
printf 'knowledge %s\n' "$*" >> "$HQ_TEST_LOG"
[ -z "${HQ_TEST_KNOWLEDGE_RC:-}" ] || { echo "knowledge helper failed" >&2; exit "$HQ_TEST_KNOWLEDGE_RC"; }
echo "SKIPPED-COMPANY-KNOWLEDGE: no bound company"
STUB
cat > "$hq_root/core/scripts/handoff-finalize.sh" <<'STUB'
printf 'finalize' >> "$HQ_TEST_LOG"; printf ' [%s]' "$@" >> "$HQ_TEST_LOG"; printf '\n' >> "$HQ_TEST_LOG"
printf '{"thread_id":"T-shell"}\n' > workspace/threads/T-shell.json
printf '{"thread_id":"T-shell","thread_path":"workspace/threads/T-shell.json","hq_committed":true}\n'
STUB
cat > "$hq_root/core/scripts/hq-detach.sh" <<'STUB'
printf 'detach %s\n' "$*" >> "$HQ_TEST_LOG"
while [ "$1" != "--" ]; do shift; done; shift
"$@"
STUB
cat > "$hq_root/core/scripts/handoff-autofile.sh" <<'STUB'
printf 'autofile %s\n' "$*" >> "$HQ_TEST_LOG"; echo "skipped: no hq-core deficiencies"
STUB
cat > "$hq_root/core/scripts/handoff-builder-route.sh" <<'STUB'
printf 'route %s\n' "$*" >> "$HQ_TEST_LOG"; printf 'route: public (no staging checkout)\n'
STUB

# The skill's Step 3 fenced block, with every {placeholder} filled in.
step_three="$(sed -n '/^### 3\./,/^### 4\./p' "$SKILL")"
command_block="$(awk '/^```bash$/ { if (!done) { inside = 1; next } } /^```$/ { if (inside) { inside = 0; done = 1 } } inside' <<<"$step_three")"
[[ "$command_block" == *"bash core/scripts/handoff-run.sh"* ]] || fail "Step 3 does not run hq core handoff run through core/scripts/handoff-run.sh"
filled="$(perl -pe 's/\{[^{}\n]*\}/x/g' <<<"$command_block")"
printf '%s\n' "$filled" > "$TMP/step3.sh"
printf '[]\n' > "$hq_root/workspace/threads/.handoff-tmp/.handoff-changeset-x-x.json"
printf '[]\n' > "$hq_root/x"

# 1. Which skill flags would 5.345.231 reject? Record them; the wrapper must cope.
skill_flags="$(grep -oE '(^|[[:space:]])--[a-z][a-z-]*' <<<"$command_block" | tr -d ' ' | sort -u)"
rejected=""
for flag in $skill_flags; do
  case " $RUN_FLAGS $FINALIZE_FLAGS " in *" $flag "*) ;; *) rejected="$rejected $flag" ;; esac
done
# Every flag the skill passes must be one the helper finalizer parses, so the
# fallback can carry it.
for flag in $skill_flags; do
  case " $RUN_FLAGS " in *" $flag "*) continue ;; esac
  grep -Eq "^[[:space:]]*${flag}\)" "$FINALIZE" || fail "core/scripts/handoff-finalize.sh does not parse $flag, which the skill passes"
done
pass "every Step 3 flag is parsed by handoff-finalize.sh (5.345.231 rejects:${rejected:- none})"

# 2. The regression: the skill's command against the 5.345.231 parser.
: > "$LOG"
out="$TMP/step3.out"
rc=0
(cd "$hq_root" && PATH="$TMP/bin:$PATH" HQ_TEST_LOG="$LOG" bash "$TMP/step3.sh" >"$out" 2>"$TMP/step3.err") || rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/step3.err" >&2; fail "Step 3 exited $rc against the 5.345.231 parser"; }
[ -f "$hq_root/workspace/threads/T-shell.json" ] || fail "no thread file was written"
jq -e '.thread_path == "workspace/threads/T-shell.json"' "$out" >/dev/null || fail "payload lacks thread_path: $(cat "$out")"
if [ -n "$rejected" ]; then
  first_rejected="$(awk '{print $1}' <<<"$rejected")"
  jq -e --arg f "$first_rejected" '.cli_fallback.code == 2 and (.cli_fallback.reason | contains("Unknown arg"))' "$out" >/dev/null \
    || fail "cli_fallback does not report the Unknown arg: $(cat "$out")"
fi
grep -q '^cli-run ' "$LOG" || fail "the wrapper did not try hq core handoff run first"
grep -Fq 'finalize' "$LOG" || fail "the fallback did not run handoff-finalize.sh"
for flag in --company --deficiencies-json --files-touched-json-file --title --slug; do
  grep '^finalize' "$LOG" | grep -Fq "[$flag]" || fail "the fallback dropped $flag"
done
grep '^finalize' "$LOG" | grep -Fq '[--learnings-file]' && fail "the fallback passed the run-only --learnings-file to finalize"
grep -q '^knowledge --files-touched-json-file workspace/threads/.handoff-tmp/.handoff-changeset-x-x.json$' "$LOG" || fail "the fallback skipped the knowledge commit"
grep -q '^detach --handoff ' "$LOG" || fail "the fallback did not detach the post through hq-detach.sh --handoff"
grep -q '^post workspace/threads/T-shell.json x$' "$LOG" || fail "the post did not get the thread and learnings file"
jq -e '.post.launched == true and .autofile == "skipped: no hq-core deficiencies" and .builder_route == "route: public (no staging checkout)" and .builder_brief == null and .knowledge_commit.code == 0' "$out" >/dev/null \
  || fail "fallback payload is not in the hq core handoff run shape: $(cat "$out")"
[ ! -e "$hq_root/workspace/threads/.handoff-tmp/.handoff-changeset-x-x.json" ] || fail "Step 3 left the changeset file behind"
pass "the skill's Step 3 writes a thread on hq-cli 5.345.231 and keeps --company and --deficiencies-json"

run_wrapper() {
  : > "$LOG"
  wrc=0
  (cd "$hq_root" && PATH="$TMP/bin:$PATH" HQ_TEST_LOG="$LOG" "$@" >"$TMP/w.out" 2>"$TMP/w.err") || wrc=$?
}
base_args=(--files-touched-json-file workspace/threads/.handoff-tmp/c.json --learnings-file l.json --title t --slug s)

# 3. A CLI that accepts every argument: its output passes through, no helpers run.
run_wrapper bash core/scripts/handoff-run.sh "${base_args[@]}"
[ "$wrc" -eq 0 ] || fail "accepted run exited $wrc"
jq -e '.thread_path == "workspace/threads/T-cli.json" and (has("cli_fallback") | not)' "$TMP/w.out" >/dev/null || fail "CLI payload was not passed through: $(cat "$TMP/w.out")"
grep -Eq '^(knowledge|finalize|detach|autofile|route)' "$LOG" && fail "helpers ran although the CLI wrote the thread"
pass "a CLI that accepts the flags is used as is"

# 4. A CLI failure after the thread exists (exit 4) is not retried.
run_wrapper env HQ_TEST_CLI_MODE=commit-failed bash core/scripts/handoff-run.sh "${base_args[@]}"
[ "$wrc" -eq 4 ] || fail "exit 4 from the CLI became $wrc"
grep -Eq '^(knowledge|finalize)' "$LOG" && fail "the wrapper wrote a second thread after a CLI commit failure"
pass "exit 4 with a thread passes through without a second thread"

# 5. Regression (#2029 R2): an unrelated CLI failure with no thread is not
# turned into a fallback handoff. Its exit code and stderr pass through, and no
# helper runs.
assert_no_fallback() { # assert_no_fallback <want-rc> <stderr-text> <label>
  [ "$wrc" -eq "$1" ] || fail "$3 exited $wrc, want $1"
  grep -Fq "$2" "$TMP/w.err" || fail "$3 lost the CLI's stderr: $(cat "$TMP/w.err")"
  grep -Eq '^(knowledge|finalize|detach|autofile|route)' "$LOG" && fail "helpers ran after $3"
  grep -q 'finishing with the core/scripts helpers' "$TMP/w.err" && fail "$3 announced a fallback"
  [ ! -s "$TMP/w.out" ] || ! jq -e 'has("cli_fallback")' "$TMP/w.out" >/dev/null 2>&1 || fail "$3 produced a cli_fallback payload"
  return 0
}
run_wrapper env HQ_TEST_CLI_MODE=knowledge-failed bash core/scripts/handoff-run.sh "${base_args[@]}"
assert_no_fallback 3 "knowledge commit failed" "a CLI knowledge-commit failure"
pass "a CLI knowledge-commit failure keeps exit 3 and runs no helper"

run_wrapper env HQ_TEST_CLI_MODE=auth-failed bash core/scripts/handoff-run.sh "${base_args[@]}"
assert_no_fallback 1 "not signed in" "a CLI auth failure"
pass "a CLI auth failure keeps exit 1 and runs no helper"

run_wrapper bash core/scripts/handoff-run.sh "${base_args[@]}" --bogus-flag v
assert_no_fallback 2 "Unknown arg: --bogus-flag" "an Unknown arg for a flag other than --company/--deficiencies-json"
pass "an Unknown arg for another flag keeps exit 2 and runs no helper"

run_wrapper env HQ_TEST_CLI_MODE=no-thread bash core/scripts/handoff-run.sh "${base_args[@]}"
[ "$wrc" -eq 1 ] || fail "a CLI exit 0 with no thread exited $wrc, want 1"
grep -Eq '^(knowledge|finalize)' "$LOG" && fail "helpers ran after a CLI exit 0 with no thread"
pass "a CLI exit 0 with no thread fails with exit 1 and runs no helper"

# 5b. Fallback cases: each rejected flag alone, and a CLI with no `handoff run`.
for flag in --company --deficiencies-json; do
  run_wrapper bash core/scripts/handoff-run.sh "${base_args[@]}" "$flag" v
  [ "$wrc" -eq 0 ] || { cat "$TMP/w.err" >&2; fail "Unknown arg $flag exited $wrc, want a fallback"; }
  jq -e --arg f "$flag" '.thread_path == "workspace/threads/T-shell.json" and .cli_fallback.code == 2 and .cli_fallback.reason == ("Unknown arg: " + $f)' "$TMP/w.out" >/dev/null \
    || fail "Unknown arg $flag fallback payload wrong: $(cat "$TMP/w.out")"
  grep '^finalize' "$LOG" | grep -Fq "[$flag]" || fail "the fallback dropped $flag"
done
pass "Unknown arg --company or --deficiencies-json falls back to the helpers"

run_wrapper env HQ_TEST_CLI_MODE=no-run-subcommand bash core/scripts/handoff-run.sh "${base_args[@]}"
[ "$wrc" -eq 0 ] || fail "a CLI without handoff run exited $wrc, want a fallback"
jq -e '.thread_path == "workspace/threads/T-shell.json" and .cli_fallback.code == 1 and (.cli_fallback.reason | contains("unknown command"))' "$TMP/w.out" >/dev/null \
  || fail "no-run-subcommand fallback payload wrong: $(cat "$TMP/w.out")"
pass "a CLI without hq core handoff run falls back to the helpers"

# 5c. Inside a fallback, a failing knowledge commit stops before finalize.
run_wrapper env HQ_TEST_KNOWLEDGE_RC=3 bash core/scripts/handoff-run.sh "${base_args[@]}" --company acme
[ "$wrc" -eq 3 ] || fail "fallback knowledge failure exited $wrc, want 3"
grep -q '^knowledge ' "$LOG" || fail "the fallback did not run the knowledge commit"
grep -q '^finalize' "$LOG" && fail "finalize ran after the knowledge commit failed"
pass "a failing knowledge commit stops the fallback with its exit code"

# 6. No hq on PATH: the helpers still write the thread; flags select the steps.
run_wrapper env HQ_BIN="$TMP/bin/no-such-hq" bash core/scripts/handoff-run.sh "${base_args[@]}" --no-post --no-builder-route --company acme
[ "$wrc" -eq 0 ] || fail "missing CLI exited $wrc"
jq -e '.thread_path and .cli_fallback.code == 127 and .post.skipped == true and .builder_route == null and .autofile != null' "$TMP/w.out" >/dev/null || fail "missing-CLI payload wrong: $(cat "$TMP/w.out")"
grep -Eq '^(detach|route)' "$LOG" && fail "--no-post or --no-builder-route was ignored"
pass "with no hq CLI the helpers write the thread and honor --no-post and --no-builder-route"

# 7. A missing --files-touched-json-file is a usage error, as in the CLI.
run_wrapper bash core/scripts/handoff-run.sh --title t
[ "$wrc" -eq 2 ] || fail "missing changeset exited $wrc, want 2"
pass "missing --files-touched-json-file exits 2"

echo "handoff-run CLI compat: all passed"
