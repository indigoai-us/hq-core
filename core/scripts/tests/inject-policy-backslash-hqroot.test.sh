#!/usr/bin/env bash
# hq-core: public
# Regression for Beaker Windows bench 2026-11-08, defect 2 (feedback_8f4f6578).
# With HQ_ROOT and TMPDIR in a backslash form, the policy injector handed its
# cache and state paths to awk through -v, and awk processes backslash escapes
# in -v values ("escape sequence '\U' treated as plain 'U'", then "cannot
# redirect"). The parsed-policy cache was never written and SessionStart
# printed no <policy-reminder>.
#
# A Windows drive path does not resolve on macOS or Linux, so this suite covers
# both halves of the fix with paths that do:
#   1. A real directory whose name holds literal backslashes. Every path the
#      hook derives from HQ_ROOT or TMPDIR then carries backslashes into awk.
#      The hook must keep the path as spelled (POSIX allows the byte) and awk
#      must read and write it unmangled.
#   2. A drive-shaped HQ_ROOT (C:\Users\hqcold\hq) resolved relative to the
#      working directory. The hook must slash-normalize the Windows shape and
#      then find, cache, and emit the policies under C:/Users/hqcold/hq.
# Each case runs under the system awk and, when installed, under gawk (the awk
# Git for Windows ships), which is the implementation that prints the warning.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  ok %s\n' "$1"; }

[ -f "$HOOK" ] || fail "hook not found: $HOOK"
command -v jq >/dev/null || fail "jq required"

TMPROOT="$(mktemp -d)"
REAL_BASH="$(command -v bash)"
export REAL_BASH
trap 'rm -rf "$TMPROOT"' EXIT

write_policy() {
  # write_policy <root> <relative-path> <id> <enforcement> <rule> [body]
  local root="$1" rel="$2" id="$3" enforcement="$4" rule="$5" body="${6:-}"
  mkdir -p "$(dirname "$root/$rel")"
  cat >"$root/$rel" <<EOF
---
id: $id
title: "$id"
scope: test
when: always
on: [SessionStart]
enforcement: $enforcement
---

## Rule

$rule
$body
EOF
}

setup_tree() {
  # setup_tree <root>: a minimal HQ with one hard and one soft core policy and
  # a deterministic fact stub reached through the forwarder.
  local root="$1"
  mkdir -p "$root/core/policies" "$root/core/scripts" \
    "$root/workspace/orchestrator/policy-trigger-state"
  cp "$HQ_SRC/core/scripts/hook-lib.sh" "$root/core/scripts/hook-lib.sh"
  cat >"$root/core/scripts/derive-trigger-facts.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' always
EOF
  cat >"$root/core/scripts/eval-trigger.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$root/core/scripts/derive-trigger-facts.sh" "$root/core/scripts/eval-trigger.sh"
  write_policy "$root" core/policies/bs-hard.md bs-hard hard BS_HARD_RULE 'BS_HARD_BODY'
  write_policy "$root" core/policies/bs-soft.md bs-soft soft BS_SOFT_RULE
}

# PATH shims. bin/ forwards the derive script like the cache suite does;
# gawk-bin/ additionally makes `awk` resolve to gawk.
mkdir -p "$TMPROOT/bin" "$TMPROOT/gawk-bin"
cat >"$TMPROOT/bin/bash" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "${DERIVE_SCRIPT:-}" ]; then
  exec "$REAL_BASH" "$HQ_ROOT/core/scripts/derive-trigger-facts.sh" "${@:2}"
fi
exec "$REAL_BASH" "$@"
EOF
chmod +x "$TMPROOT/bin/bash"
GAWK="$(command -v gawk 2>/dev/null || true)"
[ -z "$GAWK" ] || ln -s "$GAWK" "$TMPROOT/gawk-bin/awk"

run_session_start() {
  # run_session_start <hq_root_spelling> <tmpdir> <workdir> <out> <path-prefix> <sid>
  local root="$1" tmpdir="$2" workdir="$3" out="$4" prefix="$5" sid="$6" status=0
  jq -cn --arg sid "$sid" --arg cwd "$root" \
    '{hook_event_name:"SessionStart",session_id:$sid,source:"startup",cwd:$cwd}' \
    | (cd "$workdir" && env HQ_ROOT="$root" CLAUDE_PROJECT_DIR="$root" TMPDIR="$tmpdir" \
        HQ_POLICY_FACT_HELPER_DISABLE=1 HQ_HOOK_ENGINE=off \
        DERIVE_SCRIPT="$HQ_SRC/core/scripts/derive-trigger-facts.sh" \
        PATH="$prefix$TMPROOT/bin:$PATH" \
        bash "$HOOK" >"$out" 2>"$out.stderr") || status=$?
  [ "$status" -eq 0 ] || fail "hook exited $status: $(cat "$out.stderr")"
}

assert_case() {
  # assert_case <label> <physical_root> <workdir> <out>
  local label="$1" phys="$2" workdir="$3" out="$4" cache_dir cache_file mangled
  grep -Fq 'BS_HARD_BODY' "$out" \
    || fail "$label: SessionStart printed no hard policy reminder. stdout: $(cat "$out"); stderr: $(cat "$out.stderr")"
  grep -Fq 'BS_SOFT_RULE' "$out" \
    || fail "$label: SessionStart printed no soft policy reminder. stdout: $(cat "$out"); stderr: $(cat "$out.stderr")"
  if grep -Eiq 'escape sequence|cannot redirect|no hex digits' "$out.stderr"; then
    fail "$label: awk processed backslash escapes in a path: $(cat "$out.stderr")"
  fi
  cache_dir="$phys/workspace/orchestrator/hook-state/policy-trigger-cache"
  cache_file="$(find "$cache_dir" -maxdepth 1 -type f -name '*.cache' -print -quit 2>/dev/null || true)"
  [ -n "$cache_file" ] || fail "$label: parsed-policy cache was not written under $cache_dir"
  head -n 1 "$cache_file" | grep -Fq 'hq-policy-cache-v8' \
    || fail "$label: cache file is missing its complete header"
  grep -Fq 'BS_HARD_RULE' "$cache_file" \
    || fail "$label: cache file holds no parsed policy record"
  # An escape-mangled redirect target is a relative name such as
  # "C:Usershqcold...": it lands in the working directory, not the cache.
  mangled="$(find "$workdir" -maxdepth 1 -type f -name '*Users*' -print -quit 2>/dev/null || true)"
  [ -z "$mangled" ] || fail "$label: awk wrote an escape-mangled file: $mangled"
}

AWKS=("system:")
[ -z "$GAWK" ] || AWKS+=("gawk:$TMPROOT/gawk-bin:")
[ -n "$GAWK" ] || echo "  note gawk not installed; gawk variants skipped"

for entry in "${AWKS[@]}"; do
  name="${entry%%:*}"
  prefix="${entry#*:}"

  # 1. Literal backslashes in a POSIX directory name, for HQ_ROOT and TMPDIR.
  base="$TMPROOT/lit-$name"
  phys="$base/C:\\Users\\hqcold\\hq"
  tmpd="$base/C:\\Users\\hqcold\\AppData\\Local\\Temp"
  work="$base/work"
  mkdir -p "$phys" "$tmpd" "$work"
  setup_tree "$phys"
  run_session_start "$phys" "$tmpd" "$work" "$base/out" "$prefix" "lit-$name-1"
  assert_case "literal-backslash HQ_ROOT ($name awk)" "$phys" "$work" "$base/out"
  [ ! -e "$base/C:/Users/hqcold/hq" ] \
    || fail "literal-backslash HQ_ROOT was rewritten to a slash path on a POSIX host"
  ok "literal-backslash HQ_ROOT and TMPDIR: cache written, reminder printed ($name awk)"

  # 2. Windows drive shape, resolved relative to the working directory.
  base="$TMPROOT/drive-$name"
  work="$base"
  phys="$work/C:/Users/hqcold/hq"
  tmpd="$work/tmp"
  mkdir -p "$phys" "$tmpd"
  setup_tree "$phys"
  run_session_start 'C:\Users\hqcold\hq' "$tmpd" "$work" "$base/out" "$prefix" "drive-$name-1"
  assert_case "drive-shaped HQ_ROOT ($name awk)" "$phys" "$work" "$base/out"
  ok "drive-shaped HQ_ROOT is slash-normalized: cache written, reminder printed ($name awk)"
done

echo "PASS ($pass checks) inject-policy-backslash-hqroot"
