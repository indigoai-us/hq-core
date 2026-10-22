#!/usr/bin/env bash
# hq-core: public
# Regression (feedback_0f8ccfc1): worktree.sh --source accepts an HQ-relative
# repo path from any cwd, plus absolute and cwd-relative paths. Uses a throwaway
# HQ root and a stub `hq` that records the --source value it receives.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

HQ="$TMP/hq"
mkdir -p "$HQ/core/scripts" "$HQ/repos/private/demo" "$TMP/bin" "$TMP/elsewhere"
cp "$ROOT/core/scripts/worktree.sh" "$HQ/core/scripts/worktree.sh"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    --source) printf '%s\n' "$2" > "$HQ_TEST_SEEN"; shift 2 ;;
    --source=*) printf '%s\n' "${1#--source=}" > "$HQ_TEST_SEEN"; shift ;;
    *) shift ;;
  esac
done
exit 0
STUB
chmod +x "$TMP/bin/hq"

PASS=0; FAIL=0
run_case() { # label cwd want args...
  local label="$1" dir="$2" want="$3" got
  shift 3
  rm -f "$TMP/seen"
  (cd "$dir" && PATH="$TMP/bin:$PATH" HQ_TEST_SEEN="$TMP/seen" HQ_ROOT= \
    bash "$HQ/core/scripts/worktree.sh" "$@" >/dev/null 2>&1) || true
  got="$(cat "$TMP/seen" 2>/dev/null || echo '<none>')"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$label]: got '$got', want '$want'" >&2; fi
}

run_case "hq-relative from other cwd"  "$TMP/elsewhere" "$HQ/repos/private/demo" --name t --source repos/private/demo
run_case "hq-relative --source= form"  "$TMP/elsewhere" "$HQ/repos/private/demo" --name t --source=repos/private/demo
run_case "hq-relative from hq root"    "$HQ"            "$HQ/repos/private/demo" --name t --source repos/private/demo
run_case "cwd-relative wins"           "$HQ/repos"      "$HQ/repos/private/demo" --name t --source private/demo
run_case "absolute passes through"     "$TMP/elsewhere" "$HQ/repos/private/demo" --name t --source "$HQ/repos/private/demo"
run_case "unknown path passes through" "$TMP/elsewhere" "repos/private/nope"     --name t --source repos/private/nope

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
