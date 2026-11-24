#!/usr/bin/env bash
# handoff-run.sh — run `hq core handoff run`, and still write the thread when
# the installed CLI cannot.
#
# Usage: bash core/scripts/handoff-run.sh <the same arguments as hq core handoff run>
#
# /handoff passes --company and --deficiencies-json. hq-cli 5.345.231 (and hq-cli
# main as of 2026-11-18) rejects both with "Unknown arg" inside finalize, after
# the knowledge commit and before any thread is written. Dropping the two flags
# is not safe on that CLI: its finalize then derives the owner company from the
# touched paths and stores no deficiencies, so auto-file and the builder route
# never see an item.
#
# So this wrapper tries `hq core handoff run` with every argument first. When it
# exits with a payload that names a thread (success, or a later failure such as
# exit 4 after the thread exists), its stdout, stderr and exit code pass through
# unchanged. The wrapper falls back only when the CLI cannot take this handoff
# at all and wrote no thread:
#   - it exits non-zero with "Unknown arg: --company" or
#     "Unknown arg: --deficiencies-json" on stderr;
#   - it exits non-zero with "error: unknown command 'core'|'handoff'|'run'"
#     (a CLI without `hq core handoff run`);
#   - HQ_BIN is not on PATH.
# Any other CLI failure (a failed knowledge commit, a finalize error, a usage
# error, an auth failure) passes through with the CLI's own output and exit
# code, and no helper runs. A CLI that exits 0 with no thread exits 1.
# In the fallback cases the wrapper finishes the same steps with the
# core/scripts helpers, which accept both flags:
#   1. handoff-knowledge-commit.sh (a no-op when the CLI already committed);
#   2. handoff-finalize.sh with every finalize argument;
#   3. the detached post through hq-detach.sh, unless --no-post;
#   4. handoff-autofile.sh, unless --no-autofile;
#   5. handoff-builder-route.sh, unless --no-builder-route.
# It stops at the first failing step with that step's exit code, and prints one
# JSON line in the `hq core handoff run` shape plus "cli_fallback" (the CLI's
# exit code and first stderr line), so a handoff never ends with no thread.
#
# Env: HQ_BIN (default hq) names the CLI; tests point it at a stub.
set -uo pipefail

USAGE="Usage: bash core/scripts/handoff-run.sh --files-touched-json-file <path> [--learnings-file <path>] [--no-post] [--no-autofile] [--no-builder-route] [finalize args...]"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_BIN="${HQ_BIN:-hq}"
ROOT="$PWD"

learnings_file=""
files_file=""
no_post=0
no_autofile=0
no_builder=0
finalize_args=()
argv=("$@")
i=0
while [ "$i" -lt "${#argv[@]}" ]; do
  token="${argv[$i]}"
  case "$token" in
    --no-post) no_post=1 ;;
    --no-autofile) no_autofile=1 ;;
    --no-builder-route) no_builder=1 ;;
    --learnings-file) learnings_file="${argv[$((i + 1))]:-}"; i=$((i + 1)) ;;
    --files-touched-json-file)
      files_file="${argv[$((i + 1))]:-}"
      finalize_args+=("$token" "$files_file")
      i=$((i + 1))
      ;;
    *) finalize_args+=("$token") ;;
  esac
  i=$((i + 1))
done
[ -n "$files_file" ] || { echo "$USAGE" >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/handoff-run.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

# A payload is a JSON object whose thread_path is a non-empty string.
has_thread() {
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object" and (.thread_path | type == "string" and length > 0)' "$1" >/dev/null 2>&1
  else
    grep -Eq '"thread_path":[[:space:]]*"[^"]' "$1"
  fi
}

cli_rc=0
: >"$tmp/cli.out"
: >"$tmp/cli.err"
if command -v "$HQ_BIN" >/dev/null 2>&1; then
  "$HQ_BIN" core handoff run "$@" >"$tmp/cli.out" 2>"$tmp/cli.err" || cli_rc=$?
else
  cli_rc=127
  echo "handoff-run: $HQ_BIN: command not found" >"$tmp/cli.err"
fi
if has_thread "$tmp/cli.out"; then
  cat "$tmp/cli.err" >&2
  cat "$tmp/cli.out"
  exit "$cli_rc"
fi

# Fall back only when the CLI cannot take these arguments, has no
# `handoff run`, or is not installed. Every other failure keeps its exit code.
fallback_ok() {
  [ "$cli_rc" -ne 0 ] || return 1
  if [ "$cli_rc" -eq 127 ] && ! command -v "$HQ_BIN" >/dev/null 2>&1; then return 0; fi
  grep -Eq '^Unknown arg: (--company|--deficiencies-json|--learnings-json-file)[[:space:]]*$' "$tmp/cli.err" && return 0
  grep -Eq "^error: unknown command '(core|handoff|run)'" "$tmp/cli.err" && return 0
  return 1
}
if ! fallback_ok; then
  cat "$tmp/cli.err" >&2
  cat "$tmp/cli.out"
  if [ "$cli_rc" -eq 0 ]; then
    echo "handoff-run: hq core handoff run exited 0 without a thread payload" >&2
    exit 1
  fi
  exit "$cli_rc"
fi

cli_reason="$(grep -m1 -v '^[[:space:]]*$' "$tmp/cli.err" 2>/dev/null || true)"
[ -n "$cli_reason" ] || cli_reason="exit $cli_rc with no thread"
cat "$tmp/cli.err" >&2
cat "$tmp/cli.out" >&2
echo "handoff-run: hq core handoff run wrote no thread (exit $cli_rc: $cli_reason); finishing with the core/scripts helpers" >&2

knowledge_rc=0
bash "$SCRIPTS/handoff-knowledge-commit.sh" --files-touched-json-file "$files_file" \
  >"$tmp/knowledge.out" 2>"$tmp/knowledge.err" || knowledge_rc=$?
cat "$tmp/knowledge.err" >&2
if [ "$knowledge_rc" -ne 0 ]; then
  cat "$tmp/knowledge.out" >&2
  exit "$knowledge_rc"
fi

finalize_rc=0
bash "$SCRIPTS/handoff-finalize.sh" "${finalize_args[@]}" >"$tmp/finalize.out" 2>"$tmp/finalize.err" || finalize_rc=$?
cat "$tmp/finalize.err" >&2
if ! has_thread "$tmp/finalize.out"; then
  cat "$tmp/finalize.out" >&2
  [ "$finalize_rc" -ne 0 ] || finalize_rc=1
  exit "$finalize_rc"
fi
if ! command -v jq >/dev/null 2>&1; then
  # Without jq the payload cannot be extended; the thread is durable, so hand
  # back the finalize payload and skip the follow-up steps.
  echo "handoff-run: jq not found; skipped post, auto-file and builder route" >&2
  cat "$tmp/finalize.out"
  exit "$finalize_rc"
fi
thread_path="$(jq -r '.thread_path' "$tmp/finalize.out")"

post_json='{"launched":false,"skipped":false,"error":null}'
autofile_line=""
route_line=""
brief_line=""
step_rc=0
emit() {
  jq -c \
    --argjson knowledge_code "$knowledge_rc" \
    --rawfile knowledge_out "$tmp/knowledge.out" \
    --argjson post "$post_json" \
    --arg autofile "$autofile_line" \
    --arg route "$route_line" \
    --arg brief "$brief_line" \
    --argjson cli_code "$cli_rc" \
    --arg cli_reason "$cli_reason" \
    '. + {
      knowledge_commit: {
        code: $knowledge_code,
        result: (($knowledge_out | sub("\\s+$"; "")) as $t | ($t | try fromjson catch $t))
      },
      post: $post,
      autofile: (if $autofile == "" then null else $autofile end),
      builder_route: (if $route == "" then null else $route end),
      builder_brief: (if $brief == "" then null else $brief end),
      cli_fallback: {code: $cli_code, reason: $cli_reason}
    }' "$tmp/finalize.out"
}

if [ "$finalize_rc" -ne 0 ]; then
  [ "$no_post" -eq 1 ] && post_json='{"launched":false,"skipped":true,"error":null}'
  emit
  exit "$finalize_rc"
fi

if [ "$no_post" -eq 1 ]; then
  post_json='{"launched":false,"skipped":true,"error":null}'
else
  post_rc=0
  bash "$SCRIPTS/hq-detach.sh" --handoff --pidfile /tmp/handoff-post.pid --logfile /tmp/handoff-post.log -- \
    "$HQ_BIN" core handoff post "$thread_path" "$learnings_file" >"$tmp/post.out" 2>"$tmp/post.err" || post_rc=$?
  cat "$tmp/post.out" "$tmp/post.err" >&2
  if [ "$post_rc" -eq 0 ]; then
    post_json='{"launched":true,"skipped":false,"error":null}'
  else
    post_error="$(cat "$tmp/post.err" "$tmp/post.out" | grep -m1 -v '^[[:space:]]*$' || true)"
    post_json="$(jq -cn --arg e "${post_error:-exit $post_rc}" '{launched:false,skipped:false,error:$e}')"
  fi
fi

if [ "$no_autofile" -eq 0 ]; then
  bash "$SCRIPTS/handoff-autofile.sh" --thread "$thread_path" --root "$ROOT" \
    >"$tmp/autofile.out" 2>"$tmp/autofile.err" || step_rc=$?
  cat "$tmp/autofile.err" >&2
  autofile_line="$(cat "$tmp/autofile.out")"   # $(...) drops trailing newlines, as the CLI does
  if [ "$step_rc" -ne 0 ]; then
    emit
    exit "$step_rc"
  fi
fi

if [ "$no_builder" -eq 0 ]; then
  bash "$SCRIPTS/handoff-builder-route.sh" --root "$ROOT" --thread "$thread_path" \
    >"$tmp/route.out" 2>"$tmp/route.err" || step_rc=$?
  cat "$tmp/route.err" >&2
  route_line="$(grep -m1 '^route:' "$tmp/route.out" || true)"
  brief_line="$(grep -m1 '^brief:' "$tmp/route.out" || true)"
  if [ "$step_rc" -ne 0 ]; then
    emit
    exit "$step_rc"
  fi
fi

emit
exit 0
