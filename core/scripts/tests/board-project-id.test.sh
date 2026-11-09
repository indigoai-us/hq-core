#!/usr/bin/env bash
# hq-core: public
# Regression tests for core/scripts/board-project-id.sh (feedback_2b8e4bc8).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/board-project-id.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/companies/acme" "$TMP/companies/clean" "$TMP/companies/fresh"

# Entries are not in id order: the highest id sits near the top, so
# "last entry + 1" would hand out ac-proj-151 a second time.
cat > "$TMP/companies/acme/board.json" <<'JSON'
{"projects":[
  {"id":"ac-proj-149","title":"First"},
  {"id":"ac-proj-151","title":"Inserted near the top"},
  {"id":"ac-proj-150","title":"Last entry"},
  {"id":"proj-usage-only-pricing","title":"Slug id"},
  {"id":"other-proj-900","title":"Other prefix"}
]}
JSON

echo "[1] next: one more than the highest number for the prefix, not last entry + 1"
out="$(HQ_ROOT="$TMP" bash "$SCRIPT" next acme)"
[ "$out" = "ac-proj-152" ] || fail "next acme: $out"

echo "[2] next --prefix: uses only that prefix's numbers"
out="$(HQ_ROOT="$TMP" bash "$SCRIPT" next acme --prefix other)"
[ "$out" = "other-proj-901" ] || fail "next --prefix other: $out"
out="$(HQ_ROOT="$TMP" bash "$SCRIPT" next acme --prefix zz)"
[ "$out" = "zz-proj-001" ] || fail "next --prefix zz: $out"

echo "[3] next: zero-pads to 3 digits; no board needs --prefix"
printf '{"projects":[{"id":"cl-proj-007","title":"Seven"}]}\n' > "$TMP/companies/clean/board.json"
out="$(HQ_ROOT="$TMP" bash "$SCRIPT" next clean)"
[ "$out" = "cl-proj-008" ] || fail "next clean: $out"
out="$(HQ_ROOT="$TMP" bash "$SCRIPT" next fresh --prefix fr)"
[ "$out" = "fr-proj-001" ] || fail "next fresh: $out"
rc=0; HQ_ROOT="$TMP" bash "$SCRIPT" next fresh >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "next with no board and no prefix should fail"
# A board with no <prefix>-proj-<NNN> ids and no --prefix: the message must
# say to pass --prefix, not that the board could not be read (#1865 review).
mkdir -p "$TMP/companies/noprefix"
printf '{"projects":[{"id":"proj-usage","title":"Usage"}]}\n' > "$TMP/companies/noprefix/board.json"
rc=0; err="$(HQ_ROOT="$TMP" bash "$SCRIPT" next noprefix 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "next on a board with no prefixed ids should exit 2, got $rc"
case "$err" in *"pass --prefix"*) ;; *) fail "next with no prefixed ids did not say to pass --prefix: $err" ;; esac
case "$err" in *"could not read"*) fail "next with no prefixed ids reported a read error: $err" ;; esac
out="$(HQ_ROOT="$TMP" bash "$SCRIPT" next noprefix --prefix np)"
[ "$out" = "np-proj-001" ] || fail "next noprefix --prefix np: $out"
# An unreadable board still reports a read error.
printf '{not json\n' > "$TMP/companies/noprefix/board.json"
rc=0; err="$(HQ_ROOT="$TMP" bash "$SCRIPT" next noprefix 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "next on malformed board should exit 2, got $rc"
case "$err" in *"could not read"*) ;; *) fail "malformed board message: $err" ;; esac

echo "[4] check: a clean board passes"
HQ_ROOT="$TMP" bash "$SCRIPT" check clean || fail "clean board should pass"

echo "[5] check: duplicate ids (different or identical entries) and empty titles fail, each named"
cat > "$TMP/companies/acme/board.json" <<'JSON'
{"projects":[
  {"id":"ac-proj-151","title":"White-label"},
  {"id":"ac-proj-151","title":"Sync journal"},
  {"id":"proj-usage-only-pricing","title":"Pricing","updated_at":"x"},
  {"id":"proj-usage-only-pricing","title":"Pricing","updated_at":"x"},
  {"id":"proj-desktop","title":""},
  {"id":"proj-ok","title":"Fine"}
]}
JSON
rc=0; err="$(HQ_ROOT="$TMP" bash "$SCRIPT" check acme 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "check should exit 1, got $rc: $err"
case "$err" in *"duplicate project id: ac-proj-151 (2 entries)"*) ;; *) fail "ac-proj-151 not named: $err" ;; esac
case "$err" in *"duplicate project id: proj-usage-only-pricing (2 entries)"*) ;; *) fail "pricing dup not named: $err" ;; esac
case "$err" in *"projects[4]: missing title (id proj-desktop)"*) ;; *) fail "empty title not named: $err" ;; esac
case "$err" in *"proj-ok"*) fail "clean entry reported: $err" ;; esac

echo "[6] check never writes the board"
before="$(cksum < "$TMP/companies/acme/board.json")"
HQ_ROOT="$TMP" bash "$SCRIPT" check acme >/dev/null 2>&1 || true
[ "$before" = "$(cksum < "$TMP/companies/acme/board.json")" ] || fail "check modified board.json"

echo "[7] bad arguments exit 2"
for args in "" "next" "next ../x" "bogus acme" "next acme --prefix Bad"; do
  rc=0
  # shellcheck disable=SC2086
  HQ_ROOT="$TMP" bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "args '$args' should exit 2, got $rc"
done

echo "board-project-id: ok"
