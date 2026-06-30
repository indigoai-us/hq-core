#!/usr/bin/env bash
# hq-core: public
# Regression test: README team tables must not drift from person ontology names.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$ROOT/core/scripts/ontology-readme-drift.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ontology-readme-drift-test.XXXXXX")"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL[$1]: $2" >&2
}

assert_status() {
  local got="$1" want="$2" label="$3"
  if [ "$got" -eq "$want" ]; then
    pass
  else
    fail "$label" "exit=$got want=$want"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) pass ;;
    *) fail "$label" "missing '$needle'" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) fail "$label" "unexpected '$needle'" ;;
    *) pass ;;
  esac
}

make_root() {
  local case_name="$1"
  local root="$TMP_ROOT/$case_name"
  mkdir -p "$root/companies/acme/ontology/entities/person"
  printf '%s\n' "$root"
}

write_person() {
  local root="$1" slug="$2" canonical="$3"
  cat > "$root/companies/acme/ontology/entities/person/$slug.md" <<EOF
---
type: person
canonical_name: $canonical
aliases: []
status: draft
---
# $canonical
EOF
}

write_readme() {
  local root="$1" rows="$2"
  cat > "$root/companies/acme/README.md" <<EOF
# Acme

## Team

| Role | Name | Focus |
|------|------|-------|
$rows

## Notes
EOF
}

run_detector() {
  local root="$1"
  set +e
  RUN_OUT="$(bash "$SCRIPT" acme --root "$root" 2>&1)"
  RUN_STATUS=$?
  set -e
}

root="$(make_root seeded-mismatch)"
write_readme "$root" '| CEO | Corey Epstein | Strategy |
| Engineering | Keyana | Engineering |
| Alumni | Ghost McDeparted | Unknown |'
write_person "$root" corey-epstein "Corey Epstein"
write_person "$root" keyana "Keyana"
run_detector "$root"
assert_status "$RUN_STATUS" 1 "seeded mismatch exits with drift"
assert_contains "$RUN_OUT" 'DRIFT: "Ghost McDeparted"' "seeded mismatch flags ghost"
assert_not_contains "$RUN_OUT" 'DRIFT: "Corey Epstein"' "seeded mismatch does not flag corey"
assert_not_contains "$RUN_OUT" 'DRIFT: "Keyana"' "seeded mismatch does not flag keyana"

root="$(make_root clean)"
write_readme "$root" '| CEO | Corey Epstein | Strategy |
| Engineering | Keyana | Engineering |'
write_person "$root" corey-epstein "Corey Epstein"
write_person "$root" keyana "Keyana"
run_detector "$root"
assert_status "$RUN_STATUS" 0 "clean exits zero"
assert_contains "$RUN_OUT" "no drift" "clean prints no drift"

root="$(make_root subset-match)"
write_readme "$root" '| CEO | Corey Epstein | Strategy |'
write_person "$root" corey "Corey"
run_detector "$root"
assert_status "$RUN_STATUS" 0 "subset match exits zero"
assert_not_contains "$RUN_OUT" 'DRIFT: "Corey Epstein"' "subset match does not flag corey epstein"

root="$(make_root html-comment)"
write_readme "$root" '| CTO | Johnson <!-- TODO: first name --> | Engineering |'
write_person "$root" johnson "Johnson"
run_detector "$root"
assert_status "$RUN_STATUS" 0 "html comment exits zero"
assert_not_contains "$RUN_OUT" 'DRIFT: "Johnson' "html comment does not flag johnson"

root="$TMP_ROOT/missing-ontology"
mkdir -p "$root/companies/acme"
write_readme "$root" '| CEO | Corey Epstein | Strategy |'
run_detector "$root"
assert_status "$RUN_STATUS" 2 "missing ontology exits two"

echo "ontology-readme-drift: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
