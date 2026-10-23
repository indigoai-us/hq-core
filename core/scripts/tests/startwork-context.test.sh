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

echo "block: Board line from this company's work mesh cache only"
MESH="$TMP/mesh"; mkdir -p "$MESH/cmp_123" "$MESH/cmp_other"
printf '{"projectId":"alpha","updatedAt":"2026-10-01T00:00:00Z","stories":[{"id":"A1","status":"done"},{"id":"A2","status":"queued","priority":2,"title":"Second"},{"id":"A3","status":"queued","priority":1,"title":"First up"},{"id":"A4","status":"in_progress"},{"id":"A5","status":"review"}]}\n' > "$MESH/cmp_123/alpha.json"
printf '{"projectId":"beta","stories":[{"id":"B9","status":"queued","title":"Other company"}]}\n' > "$MESH/cmp_other/beta.json"
out="$(HQ_WORK_MESH_CACHE_DIR="$MESH" run block --company acme)"
grep -q '^Board (work mesh cache): beta: no board; alpha: 2 queued, 1 in progress, 1 review, 1 done (next: A3 First up)$' <<<"$out" || fail "board line wrong: $(grep '^Board' <<<"$out")"
printf '{"projects":[{"id":"alpha","prd_path":"companies/acme/projects/alpha/prd.json","mesh_project_id":"proj-alpha"}]}\n' > "$FIX/companies/acme/board.json"
printf '{"projectId":"proj-alpha","updatedAt":"2026-10-02T00:00:00Z","stories":[{"id":"P1","status":"queued","title":"Newer board"}]}\n' > "$MESH/cmp_123/proj-alpha.json"
out="$(HQ_WORK_MESH_CACHE_DIR="$MESH" run block --company acme)"
grep -q 'alpha: 1 queued, 0 in progress, 0 review, 0 done (next: P1 Newer board) \[2 mesh boards: proj-alpha, alpha; newest shown\]' <<<"$out" || fail "duplicate boards should show the newest: $(grep '^Board' <<<"$out")"
rm "$FIX/companies/acme/board.json"
out="$(HQ_WORK_MESH_CACHE_DIR="$MESH" run block --company other)"
grep -q '^Board (work mesh cache): none (company has no cloud_uid)$' <<<"$out" || fail "no cloud_uid board line wrong: $(grep '^Board' <<<"$out")"
echo "  ok"

echo "orient: one call binds, renders and filters the last thread"
mkdir -p "$FIX/core/scripts/lib" "$FIX/workspace/threads" "$FIX/companies/acme/policies"
cp "$HERE/../hq-session.sh" "$HERE/../work-mesh-live-bind-trusted.sh" "$HERE/../startwork-context.sh" "$FIX/core/scripts/"
cp "$HERE/../lib/"*.sh "$FIX/core/scripts/lib/"
printf -- '---\nid: acme-rule\nenforcement: hard\n---\n## Rule\nAcme work stays in Acme services.\n' > "$FIX/companies/acme/policies/acme-rule.md"
printf '{"thread_id":"T-acme","conversation_summary":"Acme pricing shipped.","metadata":{"company":["acme"]}}\n' > "$FIX/workspace/threads/T-acme.json"
printf '{"thread_id":"T-other","conversation_summary":"Other plan.","metadata":{"company":"other"}}\n' > "$FIX/workspace/threads/T-other.json"
printf '{"thread_path":"workspace/threads/T-acme.json"}\n' > "$FIX/workspace/threads/handoff.json"
orient() { env -u HQ_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_SESSION_ID -u CODEX_THREAD_ID -u GROK_SESSION_ID \
  HQ_ROOT="$FIX" HQ_HQ_SESSION_NO_CLI=1 HQ_WORK_MESH_RECONCILE_STUB=1 TMPDIR="$TMP" HQ_WORK_MESH_CACHE_DIR="$MESH" \
  bash "$FIX/core/scripts/startwork-context.sh" orient "$@"; }
meta() { sed -n "s/^$2:[[:space:]]*//p" "$FIX/workspace/sessions/$1/meta.yaml" 2>/dev/null | tail -1; }
out="$(orient --company acme --session-id o-1)"
grep -q '^Bound: session o-1 company_slug=acme mode=Company' <<<"$out" || fail "orient bound line wrong: $(head -1 <<<"$out")"
grep -q '^Last thread: T-acme — Acme pricing shipped.$' <<<"$out" || fail "orient last thread wrong: $(grep '^Last thread' <<<"$out")"
grep -q '^<startwork-context company="acme">' <<<"$out" || fail "orient block missing"
grep -q '^Board (work mesh cache): ' <<<"$out" || fail "orient board line missing"
grep -q 'acme-rule' <<<"$out" || fail "orient policy digest missing"
[ "$(meta o-1 company_slug)" = acme ] || fail "orient did not bind company"
[ "$(meta o-1 mode)" = Company ] || fail "orient did not set mode"
out="$(orient --company acme --session-id o-2 --mode Project --project alpha)"
[ "$(meta o-2 project)" = alpha ] && [ "$(meta o-2 mode)" = Project ] || fail "orient --project/--mode not recorded"
grep -q '^Project: alpha' <<<"$out" || fail "orient --project should render the project line"
printf '{"thread_path":"workspace/threads/T-other.json"}\n' > "$FIX/workspace/threads/handoff.json"
out="$(orient --company acme --session-id o-3)"
grep -q '^Last thread: none for acme$' <<<"$out" || fail "other company's thread leaked: $(grep '^Last thread' <<<"$out")"
printf '{"thread_path":"workspace/threads/../threads/T-acme.json"}\n' > "$FIX/workspace/threads/handoff.json"
grep -q '^Last thread: none for acme$' <<<"$(orient --company acme --session-id o-4)" || fail "a thread path with .. must be ignored"
echo "  ok"

echo "orient: fail closed"
set +e
orient --company acmee --session-id o-5 >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 3 ] || fail "non-slug should exit 3 (got $rc)"
[ ! -e "$FIX/workspace/sessions/o-5" ] || fail "non-slug must not touch the session"
for bad in ACME acme-cli 'acme corp' ac; do
  orient --company "$bad" --session-id o-6 >/dev/null 2>&1 && fail "orient accepted '$bad'"
done
[ ! -e "$FIX/workspace/sessions/o-6" ] || fail "alias/repo/prefix must not bind"
printf 'o-7\n' > "$FIX/workspace/sessions/.current"
orient --company acme >/dev/null 2>&1 && fail "orient without a caller session id must fail"
[ ! -e "$FIX/workspace/sessions/o-7" ] || fail "orient must not bind through .current"
orient --company acme --session-id '../x' >/dev/null 2>&1 && fail "invalid session id accepted"
orient --company acme --session-id o-8 --mode Bogus >/dev/null 2>&1 && fail "invalid mode accepted"
[ ! -e "$FIX/workspace/sessions/o-8" ] || fail "invalid mode must not bind"
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
