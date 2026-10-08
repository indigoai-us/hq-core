#!/usr/bin/env bash
# startwork-context.test.sh — the /startwork capability block reads only the
# bound company plus shared manifest, registry and integrations cache; lists
# repos, knowledge, sources, cached integrations, recent projects, company
# workers and the skill index; stays small; never touches the network; and
# resolves aliases and repo names to a company.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../startwork-context.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/hq"
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$FIX/companies/acme/projects/alpha" "$FIX/companies/acme/projects/beta" "$FIX/companies/acme/projects/_archive/old" \
  "$FIX/companies/acme/knowledge/brand" "$FIX/companies/acme/knowledge/_private" "$FIX/companies/acme/sources/meetings" \
  "$FIX/companies/acme/workers/helper" "$FIX/companies/other/projects/zeta" "$FIX/core/workers" "$FIX/.hq/usable-integrations" \
  "$FIX/.claude/skills/acme:crm" "$FIX/.claude/skills/other:crm" "$FIX/core/settings"
cat > "$FIX/companies/manifest.yaml" <<'YAML'
companies:
  acme:
    name: Acme Corp
    goal: ''
    path: companies/acme
    sources: []
    repos:
    - repos/private/acme-site
    - repos/public/acme-cli
    knowledge: companies/acme/knowledge/
    qmd_collections: [acme, acme-projects]
    cloud_uid: cmp_123
  other:
    name: Other
    path: companies/other
    repos:
    - repos/private/other-site
    knowledge: companies/other/knowledge/
YAML
printf '{"name":"alpha","metadata":{"stage":"build","branchName":"feature/alpha"},"goal":"Ship alpha","userStories":[{"id":"A1","status":"done"},{"id":"A2","status":"queued"}]}\n' > "$FIX/companies/acme/projects/alpha/prd.json"
sleep 1
printf '{"name":"beta","userStories":[{"id":"B1","passes":true},{"id":"B2"},{"id":"B3"}]}\n' > "$FIX/companies/acme/projects/beta/prd.json"
printf '{"name":"old","userStories":[]}\n' > "$FIX/companies/acme/projects/_archive/old/prd.json"
printf '{"name":"zeta","userStories":[{"id":"Z1"}]}\n' > "$FIX/companies/other/projects/zeta/prd.json"
cat > "$FIX/core/workers/registry.yaml" <<'YAML'
workers:
  - id: "acme-helper"
    path: "companies/acme/workers/helper/"
    type: "OpsWorker"
    status: "active"
    description: "Helps Acme with ops"
  - id: "generic"
    path: "core/workers/public/generic/"
    status: "active"
    description: "Generic worker"
  - id: "acme-by-field"
    path: "core/workers/public/acme-by-field/"
    company: "acme"
    status: "active"
    description: "Tagged to acme by company field"
  - id: "other-helper"
    path: "companies/other/workers/helper/"
    status: "active"
    description: "Other company worker"
  - id: "acme-retired"
    path: "companies/acme/workers/retired/"
    status: "retired"
    description: "Retired"
YAML
printf '{"company":"acme","apps":[{"name":"Slack","selector":"--integration slack"},{"name":"Linear","selector":"--integration linear"}]}\n' > "$FIX/.hq/usable-integrations/acme.json"
printf '{"company":"other","apps":[{"name":"Notion","selector":"--integration notion"}]}\n' > "$FIX/.hq/usable-integrations/other.json"
touch "$FIX/core/settings/intent-index.yaml"

run() { HQ_ROOT="$FIX" bash "$SCRIPT" "$@"; }

echo "block: content"
out="$(run block --company acme --project alpha)"
grep -q '^<startwork-context company="acme">' <<<"$out" || fail "missing opening tag"
grep -q '^Company: Acme Corp (acme) · qmd: -c acme, acme-projects · vault: cloud' <<<"$out" || fail "company line wrong: $(grep '^Company' <<<"$out")"
grep -q '^Repos (2): acme-site, acme-cli' <<<"$out" || fail "repos line wrong: $(grep '^Repos' <<<"$out")"
grep -q 'Knowledge: companies/acme/knowledge/ \[brand\]' <<<"$out" || fail "knowledge folders wrong (should skip _private): $(grep '^Knowledge' <<<"$out")"
grep -q 'Sources: companies/acme/sources/ \[meetings\]' <<<"$out" || fail "sources folders wrong"
grep -q '^Integrations: Slack (--integration slack), Linear (--integration linear)  \[cached' <<<"$out" || fail "integrations line wrong: $(grep '^Integrations' <<<"$out")"
grep -q 'Notion' <<<"$out" && fail "another company's integrations leaked"
grep -q '^Projects (recent, local counts): beta \[prd\] 2/3 open; alpha \[build\] 1/2 open$' <<<"$out" || fail "projects line wrong: $(grep '^Projects' <<<"$out")"
grep -q 'zeta' <<<"$out" && fail "another company's project leaked"
grep -q 'old' <<<"$out" && fail "archived project listed"
grep -q '^Workers (2): acme-helper - Helps Acme with ops, acme-by-field - Tagged to acme by company field$' <<<"$out" || fail "workers line wrong: $(grep '^Workers' <<<"$out")"
grep -q 'other-helper\|generic\|acme-retired' <<<"$out" && fail "worker filter leaked"
grep -q '^Skills: 1 company skills (/acme:\*) · full index: core/settings/intent-index.yaml' <<<"$out" || fail "skills line wrong: $(grep '^Skills' <<<"$out")"
grep -q '^Project: alpha · Ship alpha · branch: feature/alpha · board: work mesh' <<<"$out" || fail "project line wrong: $(grep '^Project:' <<<"$out")"
grep -q '^</startwork-context>$' <<<"$out" || fail "missing closing tag"
bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
[ "$bytes" -lt 3072 ] || fail "block is $bytes bytes; budget is 3 KB"
echo "  ok"

echo "block: missing cache and missing project degrade to pointers"
out="$(run block --company other)"
grep -q 'Integrations: Notion' <<<"$out" || fail "other company's own cache not used"
rm "$FIX/.hq/usable-integrations/other.json"
out="$(run block --company other --project nope)"
grep -q '^Integrations: not cached; run: core/scripts/usable-integrations.sh show --company other' <<<"$out" || fail "missing cache pointer wrong"
grep -q '^Project: nope (no prd.json' <<<"$out" || fail "missing project pointer wrong"
grep -q 'vault: local-only' <<<"$out" || fail "no cloud_uid should read local-only"
echo "  ok"

echo "block: list cap"
out="$(HQ_STARTWORK_MAX_LIST=1 run block --company acme)"
grep -q '^Repos (2): acme-site (+1 more)$' <<<"$out" || fail "list cap not applied: $(grep '^Repos' <<<"$out")"
echo "  ok"

echo "block: no network"
mkdir -p "$TMP/bin"; for b in hq curl; do printf '#!/bin/sh\necho "NETWORK CALL $0 $*" >&2; exit 97\n' > "$TMP/bin/$b"; chmod +x "$TMP/bin/$b"; done
err="$(PATH="$TMP/bin:$PATH" run block --company acme 2>&1 >/dev/null || true)"
grep -q 'NETWORK CALL' <<<"$err" && fail "block reached for hq or curl"
echo "  ok"

echo "block: argument errors"
run block >/dev/null 2>&1 && fail "missing --company accepted"
run block --company nosuch >/dev/null 2>&1 && fail "unknown company accepted"
run block --company '../acme' >/dev/null 2>&1 && fail "path-like slug accepted"
echo "  ok"

echo "resolve: slug, repo name, alias, miss"
[ "$(run resolve --arg acme)" = '{"company":"acme","via":"slug"}' ] || fail "slug resolve"
[ "$(run resolve --arg ACME)" = '{"company":"acme","via":"slug"}' ] || fail "slug resolve is case-insensitive"
[ "$(run resolve --arg acme-cli)" = '{"company":"acme","via":"repo"}' ] || fail "repo-name resolve: $(run resolve --arg acme-cli)"
[ "$(run resolve --arg 'acme corp')" = '{"company":"acme","via":"alias"}' ] || fail "company-name alias resolve: $(run resolve --arg 'acme corp')"
[ "$(run resolve --arg ac)" = '{"company":"acme","via":"alias"}' ] || fail "unique prefix resolve"
set +e; out="$(run resolve --arg zzz)"; rc=$?; set -e
[ "$rc" -eq 3 ] || fail "miss should exit 3 (got $rc)"
[ "$out" = '{"company":"","candidates":[]}' ] || fail "miss payload: $out"
echo "  ok"

echo "startwork-context: all checks passed"
