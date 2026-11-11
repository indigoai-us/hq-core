#!/usr/bin/env bash
# hq-core: public
# block-hq-glob denies a Glob of the HQ root however the path spells it:
# "./" segments, repeated or trailing slashes, and ".." traversal that lands
# back on the root. Subfolders, siblings and relative paths stay allowed.
# Each case runs with HQ_ROOT set and with the root found by git, and with
# HQ_HOOK_TOOL_NAME exported (master-hook's fast path) and unset.
#
# Usage: block-hq-glob-root-normalize.test.sh [hook] [bash]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
hook=${1:-"$here/../../../.claude/hooks/block-hq-glob.sh"}
hook=$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook")
shell=${2:-bash}
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
# A caller's git variables (a git hook, a worktree script) must not move the
# toplevel the hook finds in git mode.
unset GIT_DIR GIT_WORK_TREE GIT_CEILING_DIRECTORIES GIT_COMMON_DIR GIT_INDEX_FILE
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
hq=$(cd "$tmp" && pwd -P)/hq
mkdir -p "$hq/core/workers" "$hq/workspace" "$hq-other"
git -C "$hq" init -q

pass=0
fail=0

# run <expect allow|deny> <path> <mode env|git> <fast on|off>
run() {
  local want=$1 path=$2 mode=$3 fast=$4 payload code got
  payload=$(jq -cn --arg p "$path" '{tool_name:"Glob",tool_input:{pattern:"**/*.md",path:$p}}')
  set +e
  if [ "$mode" = env ]; then
    if [ "$fast" = on ]; then
      (cd "$hq/workspace" && printf '%s' "$payload" | HQ_ROOT=$hq HQ_HOOK_TOOL_NAME=Glob "$shell" "$hook" >/dev/null 2>&1)
    else
      (cd "$hq/workspace" && printf '%s' "$payload" | env -u HQ_HOOK_TOOL_NAME HQ_ROOT="$hq" "$shell" "$hook" >/dev/null 2>&1)
    fi
  else
    if [ "$fast" = on ]; then
      (cd "$hq/core" && printf '%s' "$payload" | env -u HQ_ROOT HQ_HOOK_TOOL_NAME=Glob "$shell" "$hook" >/dev/null 2>&1)
    else
      (cd "$hq/core" && printf '%s' "$payload" | env -u HQ_ROOT -u HQ_HOOK_TOOL_NAME "$shell" "$hook" >/dev/null 2>&1)
    fi
  fi
  code=$?
  set -e
  case $code in 0) got=allow ;; 2) got=deny ;; *) got="exit $code" ;; esac
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (%s, fast %s): want %s, got %s\n' "$path" "$mode" "$fast" "$want" "$got" >&2
  fi
}

deny_paths=(
  "$hq"
  "$hq/"
  "$hq//"
  "$hq///"
  "$hq/."
  "$hq/./"
  "$hq/./."
  "$hq/.//./"
  "$hq/core/.."
  "$hq/core/../"
  "$hq/core/workers/../.."
  "$hq/core/workers/../../"
  "$hq/missing/.."
  "$hq/../hq"
  "$hq/../hq/."
  "$hq/core/../workspace/../."
  "$(dirname "$hq")/./hq"
  "$(dirname "$hq")//hq//"
  "/$hq"
)
allow_paths=(
  "$hq/core"
  "$hq/core/"
  "$hq/core/."
  "$hq/core/workers/.."
  "$hq/core/../workspace"
  "$hq/./workspace/"
  "$hq/.."
  "$hq/../"
  "$hq-other"
  "$hq-other/."
  "$hq/../hq-other"
  "$hq/core/../../hq-other"
  "$hq/..."
  "$hq/.hidden/.."/x
  "."
  "./"
  ".."
  "core/.."
  "../hq"
)

for mode in env git; do
  for fast in on off; do
    for p in "${deny_paths[@]}"; do run deny "$p" "$mode" "$fast"; done
    for p in "${allow_paths[@]}"; do run allow "$p" "$mode" "$fast"; done
  done
done

# HQ_ROOT spelled with a trailing slash or a "." segment still names the root.
for root in "$hq/" "$hq/." "$hq//"; do
  for p in "$hq" "$hq/"; do
    payload=$(jq -cn --arg p "$p" '{tool_name:"Glob",tool_input:{pattern:"*",path:$p}}')
    set +e
    (cd "$hq/workspace" && printf '%s' "$payload" | HQ_ROOT=$root HQ_HOOK_TOOL_NAME=Glob "$shell" "$hook" >/dev/null 2>&1)
    code=$?
    set -e
    if [ "$code" -eq 2 ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf 'FAIL: HQ_ROOT=%s path=%s: want deny, got exit %s\n' "$root" "$p" "$code" >&2
    fi
  done
done

# HQ_ROOT names the root even when the working folder is outside it, where git
# would find no repository (or another one).
for p in "$hq/./" "$hq//" "$hq/core/.."; do
  payload=$(jq -cn --arg p "$p" '{tool_name:"Glob",tool_input:{pattern:"*",path:$p}}')
  set +e
  (cd "$tmp" && printf '%s' "$payload" | HQ_ROOT=$hq HQ_HOOK_TOOL_NAME=Glob "$shell" "$hook" >/dev/null 2>&1)
  code=$?
  set -e
  if [ "$code" -eq 2 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL: HQ_ROOT from outside, path=%s: want deny, got exit %s\n' "$p" "$code" >&2
  fi
done

# The deny message is unchanged.
payload=$(jq -cn --arg p "$hq/./" '{tool_name:"Glob",tool_input:{pattern:"*.md",path:$p}}')
set +e
msg=$(cd "$hq/workspace" && printf '%s' "$payload" | HQ_ROOT=$hq HQ_HOOK_TOOL_NAME=Glob "$shell" "$hook" 2>&1 >/dev/null)
set -e
case $msg in
  'BLOCKED: Glob from HQ root causes timeouts'*'Glob pattern="*.md" path="companies/"'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL: deny message changed:\n%s\n' "$msg" >&2 ;;
esac

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: %d of %d checks\n' "$fail" "$((pass + fail))" >&2
  exit 1
fi
printf 'PASS: %d root-normalization checks\n' "$pass"
