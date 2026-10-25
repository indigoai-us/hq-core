#!/bin/bash
# Regression test for .claude/hooks/inject-local-context.sh (SessionStart):
# the Companies line groups companies by owner_role, suffixes on-hold and
# handover-pending companies, hides `system` companies, drops companies with
# no owner_role into Unclassified, and prints owner_summary only when present.
# Hermetic: a synthetic HQ root under mktemp, the hook resolved via
# CLAUDE_PROJECT_DIR. No real manifest touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../inject-local-context.sh"
pass=0; fail=0
check() { if [ "$2" -eq 0 ]; then printf 'ok   - %s\n' "$1"; pass=$((pass+1)); else printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d /tmp/local-context-test.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/hq"; mkdir -p "$ROOT/companies" "$ROOT/core/workers"
MANIFEST="$ROOT/companies/manifest.yaml"
run() { env -i PATH="$PATH" HOME="$TMP" CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK" </dev/null; }

cat > "$MANIFEST" <<'YML'
# owner_role: self | operate | side | client | family | system | unclassified
owner_summary: "CEO at Acme (acme), Co-CEO at Beta (beta). Not Gamma staff."
companies:
  _template:
    owner_role: side
    name: Template
  me:
    owner_role: self
    owner_status: active
    name: Me
  acme:
    owner_role: operate
    owner_status: active
    name: Acme
  beta:
    owner_role: 'operate'
    owner_status: active
  hobby:
    owner_role: side
    owner_status: on-hold
    name: Hobby
  gamma:
    owner_role: client
    owner_status: handover-pending
    owner_note: 'Consultant only.'
  kin:
    owner_role: family
    owner_status: active
  workspace:
    owner_role: system
    owner_status: active
  legacy:
    name: Legacy
    goal: ''
unaffiliated_repos:
  - repos/public/x
YML

out="$(run)"; rc=$?
check "hook exits 0" "$rc"
contains "$out" "Companies (8), grouped by the owner's relationship:"; check "count includes system, excludes _template" "$?"
contains "$out" $'\nSelf: me\n'; check "self group" "$?"
contains "$out" $'\nJobs (operate): acme, beta\n'; check "operate group, quoted role value accepted" "$?"
contains "$out" $'\nSide projects: hobby (hold)\n'; check "on-hold suffix" "$?"
contains "$out" $'\nClient / consulting: gamma (handover)\n'; check "handover-pending suffix" "$?"
contains "$out" $'\nFamily: kin\n'; check "family group" "$?"
contains "$out" $'\nUnclassified (confirm): legacy\n'; check "missing owner_role falls into Unclassified" "$?"
groups="${out%%QMD collections:*}"
if contains "$groups" "workspace"; then check "system company hidden from the groups" 1; else check "system company hidden from the groups" 0; fi
contains "$out" $'\nOwner jobs: CEO at Acme (acme), Co-CEO at Beta (beta). Not Gamma staff.\n'; check "owner_summary line printed, quotes stripped" "$?"
contains "$out" "QMD collections: hq, me, acme, beta, hobby, gamma, kin, workspace, legacy"; check "QMD collections still list every company" "$?"

# No owner_summary and no owner_role anywhere → one Unclassified line, no Owner jobs line.
cat > "$MANIFEST" <<'YML'
companies:
  alpha:
    name: Alpha
  bravo:
    name: Bravo
YML
out="$(run)"
contains "$out" $'\nUnclassified (confirm): alpha, bravo\n'; check "legacy manifest groups everything as Unclassified" "$?"
if contains "$out" "Owner jobs:"; then check "no Owner jobs line without owner_summary" 1; else check "no Owner jobs line without owner_summary" 0; fi
if contains "$out" "Jobs (operate)"; then check "empty groups are omitted" 1; else check "empty groups are omitted" 0; fi

# No manifest → no Companies block, exit 0.
rm "$MANIFEST"
out="$(run)"; rc=$?
if [ "$rc" -eq 0 ] && ! contains "$out" "Companies ("; then check "missing manifest is fail-soft" 0; else check "missing manifest is fail-soft" 1; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]
