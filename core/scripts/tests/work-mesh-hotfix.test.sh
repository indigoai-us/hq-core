#!/usr/bin/env bash
# hq-core: public
# US-001 acceptance: "stop the bleeding" hotfixes in the work-mesh hook layer.
#
# Covers three surgical fixes and asserts ONLY on observable artifacts
# (marker files, spool JSONL events, capability-cache contents, helper argv,
# stdout contracts) — never on internals.
#
#   AC1 core/hooks/work-mesh-close.sh
#        A PERMANENT no_uid (authoritative /membership/me that does not list the
#        slug) writes a terminal marker + spools reconcile-skipped/
#        no_uid_permanent; transient failures stay retryable with no marker.
#   AC2 core/hooks/work-mesh-ground.sh
#        The helper's `ground` capability is probed (cached by path+mtime) BEFORE
#        any node spawn, so an incapable helper costs zero node startups.
#   AC3 core/hooks/work-mesh-done.sh
#        The project comes from THIS session's workspace/sessions/<id>/meta.yaml,
#        never the machine-global PID-keyed ~/.hq/work-mesh/cache/sessions-bind.json.
#
# Cases:
#   1  permanent no_uid       -> terminal marker + reconcile-skipped/no_uid_permanent
#   2  transient (empty body) -> reconcile-pending/no_uid, NO marker
#   3  transient (malformed)  -> reconcile-pending/no_uid, NO marker
#   3b transient (no token)   -> reconcile-pending/no_token, NO marker
#   4  terminal marker present-> sweep re-run is a total no-op (no spool, no HTTP)
#   5  incapable helper       -> zero node spawns, silent, cache "<mtime> no"
#   6  cached "no" reused     -> helper not re-probed, still zero node spawns
#   7  helper mtime change    -> cache invalidated, probe re-runs, flips to yes
#   8  capable helper         -> exact hookSpecificOutput JSON + board snapshot
#   9  done hook              -> meta.yaml project wins over global sessions-bind
#   10 done hook unbound      -> silent exit 0, helper never invoked
#   11 kill switches          -> all three hooks short-circuit
#
# Hermetic: curl + node stubbed on PATH (no network, no node startup); HOME and
# every HQ root live inside an mktemp sandbox; the operator's real ~/.hq and
# workspace/metrics/work-sessions.jsonl are never touched. bash-3.2 + CI
# (ubuntu-latest) compatible: no mapfile, no associative arrays, no ${var,,}.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SRC_CLOSE="$REPO_ROOT/core/hooks/work-mesh-close.sh"
SRC_GROUND="$REPO_ROOT/core/hooks/work-mesh-ground.sh"
SRC_DONE="$REPO_ROOT/core/hooks/work-mesh-done.sh"
SRC_LIB="$REPO_ROOT/core/scripts/work-mesh-lib.sh"
SRC_HOOKLIB="$REPO_ROOT/core/scripts/hook-lib.sh"
SRC_SESSION="$REPO_ROOT/core/scripts/hq-session.sh"
SRC_SESSION_LIB="$REPO_ROOT/core/scripts/lib"

for f in "$SRC_CLOSE" "$SRC_GROUND" "$SRC_DONE" "$SRC_LIB" "$SRC_HOOKLIB" "$SRC_SESSION"; do
  [ -f "$f" ] || { echo "FATAL: missing source under test: $f" >&2; exit 1; }
done
[ -d "$SRC_SESSION_LIB" ] || { echo "FATAL: missing $SRC_SESSION_LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required for these tests" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$SANDBOX/stubbin" "$SANDBOX/home"

# Ambient session/company env must never leak into a hermetic run.
unset HQ_WORK_MESH_COMPANY_UID HQ_COMPANY_UID HQ_WORK_MESH_TOKEN \
      HQ_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
      CODEX_SESSION_ID CODEX_THREAD_ID HQ_WORK_MESH_DISABLED HQ_DISABLED_HOOKS \
      HQ_WORK_MESH_PROJECT_ID 2>/dev/null || true

export HOME="$SANDBOX/home"
export HQ_HQ_SESSION_NO_CLI=1
export HQ_WORK_MESH_API_URL="http://127.0.0.1:9/wm-test"
export HQ_WORK_MESH_CLAUDE_PROJECTS_DIR="$SANDBOX/home/.claude/projects"
mkdir -p "$HQ_WORK_MESH_CLAUDE_PROJECTS_DIR"

# --- curl stub: no network. Records argv; answers /membership/me from a seam. --
cat > "$SANDBOX/stubbin/curl" <<'STUB'
#!/usr/bin/env bash
set -u
method="GET"; url=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a" ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
if [ -n "${WM_STUB_DIR:-}" ]; then
  mkdir -p "$WM_STUB_DIR" 2>/dev/null || true
  printf '%s\n' "$*" >> "$WM_STUB_DIR/argv.txt"
fi
if [ -n "${WM_STUB_FAIL:-}" ] && [ "${WM_STUB_FAIL}" != "0" ]; then exit 7; fi
if [ "$method" = "POST" ]; then printf '%s' "${WM_STUB_POST_CODE:-201}"; exit 0; fi
case "$url" in
  *"/membership/me"*)    printf '%s' "${WM_STUB_MEMBERSHIP:-}" ;;
  *"/v1/consent/gates"*) printf '%s' "${WM_STUB_GATES:-}" ;;
  *)                     printf '%s' "" ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/stubbin/curl"

# --- node stub: records every spawn so "zero node spawns" is assertable. ------
cat > "$SANDBOX/stubbin/node" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -n "${WM_NODE_SPY:-}" ]; then
  mkdir -p "$(dirname "$WM_NODE_SPY")" 2>/dev/null || true
  printf '%s\n' "$*" >> "$WM_NODE_SPY"
fi
printf '%s' '{}'
exit 0
STUB
chmod +x "$SANDBOX/stubbin/node"

export PATH="$SANDBOX/stubbin:$PATH"

# --- assertions --------------------------------------------------------------
PASS=0; FAIL=0
pass()  { PASS=$((PASS + 1)); echo "  ok:   $1"; }
failc() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
assert_eq()           { if [ "$2" = "$3" ]; then pass "$1"; else failc "$1 (expected '$3', got '$2')"; fi; }
assert_true()         { local l="$1"; shift; if "$@"; then pass "$l"; else failc "$l"; fi; }
assert_false()        { local l="$1"; shift; if "$@"; then failc "$l (expected failure)"; else pass "$l"; fi; }
assert_contains()     { case "$2" in *"$3"*) pass "$1" ;; *) failc "$1 (missing '$3')" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) failc "$1 (unexpected '$3')" ;; *) pass "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then pass "$1"; else failc "$1 (expected empty, got '$2')"; fi; }

# keyfrag mirrors wm_keyfrag() — the marker/cache filename derivation.
keyfrag() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_'; }

# file_ident mirrors wm_file_ident() in work-mesh-lib.sh. It MUST agree with the
# library byte-for-byte or the cache-content assertions below compare garbage.
# GNU coreutils `stat -f` means --file-system: it exits 0 and prints multi-line
# human-readable text, so a bare `stat -f ... || stat -c ...` never falls through
# on Linux. Accept a probe only when it is a strictly numeric space-separated
# triple, exactly as the library does.
file_ident() {
  local f="${1:-}" value
  value="$(stat -f '%m %z %i' "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9\ ]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  value="$(stat -c '%Y %s %i' "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9\ ]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  value="$(stat -f %m "$f" 2>/dev/null)" || value=""
  case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$value"; return 0 ;;
  esac
  stat -c %Y "$f" 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------------------
# Isolated HQ roots. Every case gets its own root so one case's spool lines can
# never make another case's sweep do work (and so nothing outside $SANDBOX is
# ever written).
# ---------------------------------------------------------------------------
new_close_root() {  # <name> -> prints root path
  local name="$1" root="$SANDBOX/root-$1"
  mkdir -p "$root/core/hooks" "$root/core/scripts" \
           "$root/workspace/sessions" "$root/workspace/metrics" \
           "$root/workspace/logs" "$root/workspace/work-mesh/cache"
  cp "$SRC_CLOSE" "$root/core/hooks/work-mesh-close.sh"
  cp "$SRC_LIB"   "$root/core/scripts/work-mesh-lib.sh"
  chmod +x "$root/core/hooks/work-mesh-close.sh"
  printf '%s' "$root"
}

# Fabricate a US-003 registration (marker + attempt spool line + meta.yaml).
# The attempt line deliberately carries NO companyUid so uid resolution has to
# consult /membership/me — the seam the permanent/transient split lives on.
register_session() {  # <root> <sid> <slug>
  local root="$1" sid="$2" slug="$3" sd
  sd="$root/workspace/sessions/$sid"
  mkdir -p "$sd"
  printf 'company_slug: %s\nproject: proj_demo\n' "$slug" > "$sd/meta.yaml"
  : > "$sd/work-mesh-registered-$(keyfrag "$slug")"
  jq -nc --arg s "$sid" --arg c "$slug" \
    '{ts:"t",event:"attempt",sessionId:$s,companySlug:$c,harness:"claude-code"}' \
    >> "$root/workspace/metrics/work-sessions.jsonl"
}

spool_of()      { printf '%s/workspace/metrics/work-sessions.jsonl' "$1"; }
term_marker()   { printf '%s/workspace/sessions/%s/work-mesh-terminal-%s' "$1" "$2" "$(keyfrag "$3")"; }
recon_marker()  { printf '%s/workspace/sessions/%s/work-mesh-reconciled-%s' "$1" "$2" "$(keyfrag "$3")"; }
copy_marker()   { printf '%s/workspace/sessions/%s/work-mesh-copied-%s' "$1" "$2" "$(keyfrag "$3")"; }

# count spool lines matching event+reason for a sid
count_reason() {  # <root> <sid> <event> <reason>
  local spf n
  spf="$(spool_of "$1")"
  [ -f "$spf" ] || { printf '0'; return 0; }
  n="$(jq -c --arg s "$2" --arg e "$3" --arg r "$4" \
        'select(.sessionId==$s and .event==$e and (.reason // "")==$r)' \
        "$spf" 2>/dev/null | wc -l | tr -d '[:space:]')" || n=0
  printf '%s' "${n:-0}"
}
line_count() { if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else printf '0'; fi; }

MEMBERSHIP_OTHER='{"memberships":[{"companySlug":"other-co"}]}'

# ===========================================================================
echo "CASE 1: permanent no_uid -> terminal marker + reconcile-skipped/no_uid_permanent"
# ===========================================================================
r1="$(new_close_root perm)"; sid=sid-perm; slug=notcloudco
register_session "$r1" "$sid" "$slug"
HQ_ROOT="$r1" WM_ROOT="$r1" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-perm" \
  WM_STUB_MEMBERSHIP="$MEMBERSHIP_OTHER" \
  bash "$r1/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "permanent: reconcile-skipped/no_uid_permanent spooled once" \
  "$(count_reason "$r1" "$sid" reconcile-skipped no_uid_permanent)" "1"
assert_eq   "permanent: NOT spooled as retryable reconcile-pending" \
  "$(count_reason "$r1" "$sid" reconcile-pending no_uid)" "0"
assert_true  "permanent: terminal marker written" test -f "$(term_marker "$r1" "$sid" "$slug")"
assert_false "permanent: NO reconciled marker (nothing was reconciled)" test -f "$(recon_marker "$r1" "$sid" "$slug")"
assert_false "permanent: NO copied marker" test -f "$(copy_marker "$r1" "$sid" "$slug")"

# ===========================================================================
echo "CASE 2: transient no_uid (empty membership body) -> pending, no marker"
# ===========================================================================
r2="$(new_close_root transient-empty)"; sid=sid-empty; slug=maybecloudco
register_session "$r2" "$sid" "$slug"
HQ_ROOT="$r2" WM_ROOT="$r2" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-empty" \
  WM_STUB_MEMBERSHIP="" \
  bash "$r2/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "transient-empty: reconcile-pending/no_uid spooled" \
  "$(count_reason "$r2" "$sid" reconcile-pending no_uid)" "1"
assert_eq   "transient-empty: never marked permanent" \
  "$(count_reason "$r2" "$sid" reconcile-skipped no_uid_permanent)" "0"
assert_false "transient-empty: NO terminal marker (stays retryable)" test -f "$(term_marker "$r2" "$sid" "$slug")"

# ===========================================================================
echo "CASE 3: transient no_uid (malformed body) -> pending, no marker"
# ===========================================================================
r3="$(new_close_root transient-malformed)"; sid=sid-malformed; slug=maybecloudco
register_session "$r3" "$sid" "$slug"
HQ_ROOT="$r3" WM_ROOT="$r3" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-malformed" \
  WM_STUB_MEMBERSHIP='<html>oops' \
  bash "$r3/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "transient-malformed: reconcile-pending/no_uid spooled" \
  "$(count_reason "$r3" "$sid" reconcile-pending no_uid)" "1"
assert_false "transient-malformed: NO terminal marker" test -f "$(term_marker "$r3" "$sid" "$slug")"

# curl transport failure is transient too.
r3b="$(new_close_root transient-curlfail)"; sid=sid-curlfail
register_session "$r3b" "$sid" "$slug"
HQ_ROOT="$r3b" WM_ROOT="$r3b" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-curlfail" WM_STUB_FAIL=1 \
  bash "$r3b/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "transient-curlfail: reconcile-pending/no_uid spooled" \
  "$(count_reason "$r3b" "$sid" reconcile-pending no_uid)" "1"
assert_false "transient-curlfail: NO terminal marker" test -f "$(term_marker "$r3b" "$sid" "$slug")"

# No token at all is transient as well (and must make no HTTP call).
r3c="$(new_close_root transient-notoken)"; sid=sid-notoken
register_session "$r3c" "$sid" "$slug"
HQ_ROOT="$r3c" WM_ROOT="$r3c" WM_SID="$sid" WM_HARNESS=claude-code \
  WM_STUB_DIR="$SANDBOX/stub-notoken" \
  bash "$r3c/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "no-token: reconcile-pending/no_token spooled" \
  "$(count_reason "$r3c" "$sid" reconcile-pending no_token)" "1"
assert_false "no-token: NO terminal marker" test -f "$(term_marker "$r3c" "$sid" "$slug")"
assert_false "no-token: no HTTP call attempted" test -f "$SANDBOX/stub-notoken/argv.txt"

# ===========================================================================
echo "CASE 4: terminal marker present -> sweep + close re-runs are total no-ops"
# ===========================================================================
# Reuse the permanent root: the terminal marker from CASE 1 is in place.
spf1="$(spool_of "$r1")"
before_lines="$(line_count "$spf1")"
rm -f "$SANDBOX/stub-perm2/argv.txt" 2>/dev/null || true
# .current must not name this session, or the sweep skips it for the wrong reason.
printf '%s' 'some-other-live-session' > "$r1/workspace/sessions/.current"
HQ_ROOT="$r1" WM_ROOT="$r1" HQ_WORK_MESH_TOKEN=tok \
  WM_STUB_DIR="$SANDBOX/stub-perm2" WM_STUB_MEMBERSHIP="$MEMBERSHIP_OTHER" \
  bash "$r1/core/hooks/work-mesh-close.sh" __sweep_bg__ </dev/null
HQ_ROOT="$r1" WM_ROOT="$r1" WM_SID=sid-perm WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-perm2" \
  WM_STUB_MEMBERSHIP="$MEMBERSHIP_OTHER" \
  bash "$r1/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq "idempotent: sweep+close after terminal marker spool nothing new" \
  "$(line_count "$spf1")" "$before_lines"
assert_eq "idempotent: still exactly one no_uid_permanent line" \
  "$(count_reason "$r1" sid-perm reconcile-skipped no_uid_permanent)" "1"
assert_false "idempotent: no HTTP call made on the re-run" test -f "$SANDBOX/stub-perm2/argv.txt"
assert_true  "idempotent: terminal marker still present" test -f "$(term_marker "$r1" sid-perm notcloudco)"

# ---------------------------------------------------------------------------
# Ground-hook sandbox
# ---------------------------------------------------------------------------
GROOT="$SANDBOX/root-ground"
mkdir -p "$GROOT/core/hooks" "$GROOT/core/scripts" \
         "$GROOT/workspace/sessions/gsid" "$GROOT/workspace/work-mesh/cache" \
         "$GROOT/companies/indigo/projects/work-desktop-dogfood"
cp "$SRC_GROUND"  "$GROOT/core/hooks/work-mesh-ground.sh"
cp "$SRC_HOOKLIB" "$GROOT/core/scripts/hook-lib.sh"
# The shared lib MUST be present, or the capability probe is fail-soft skipped
# and the guard under test is not actually exercised.
cp "$SRC_LIB"     "$GROOT/core/scripts/work-mesh-lib.sh"
cp "$SRC_SESSION" "$GROOT/core/scripts/hq-session.sh"
cp -R "$SRC_SESSION_LIB" "$GROOT/core/scripts/lib"
chmod +x "$GROOT/core/hooks/work-mesh-ground.sh" "$GROOT/core/scripts/hq-session.sh"
printf 'companies:\n  indigo:\n    name: Indigo\n' > "$GROOT/companies/manifest.yaml"
printf 'company_slug: indigo\nproject: work-desktop-dogfood\n' > "$GROOT/workspace/sessions/gsid/meta.yaml"
printf '%s' 'gsid' > "$GROOT/workspace/sessions/.current"

GHELPER="$GROOT/core/scripts/work-mesh-session.sh"
GCAPS="$GROOT/workspace/work-mesh/cache/caps-$(keyfrag ground)-$(keyfrag "$GHELPER")"
HELPER_SPY="$SANDBOX/ground-helper-spy.txt"
NODE_SPY="$SANDBOX/ground-node-spy.txt"
GPROMPT='{"hook_event_name":"UserPromptSubmit","prompt":"please ground me in the work desktop dogfood project board"}'

write_incapable_helper() {
  cat > "$GHELPER" <<'SH'
#!/usr/bin/env bash
[ -n "${WM_HELPER_SPY:-}" ] && printf '%s\n' "$*" >> "$WM_HELPER_SPY"
cat >&2 <<'USAGE'
usage: work-mesh.sh <command>
commands: check start progress blocked done watch
USAGE
exit 2
SH
  chmod +x "$GHELPER"
}
write_capable_helper() {
  cat > "$GHELPER" <<'SH'
#!/usr/bin/env bash
[ -n "${WM_HELPER_SPY:-}" ] && printf '%s\n' "$*" >> "$WM_HELPER_SPY"
if [ "${1:-}" = "help" ]; then
  printf '%s\n' 'usage: work-mesh.sh <command>'
  printf '%s\n' 'commands: check start progress blocked done ground watch'
  exit 0
fi
printf '%s\n' '{"ok":true,"action":"ground","projectId":"work-desktop-dogfood","bound":true,"stories":[{"id":"US-001","title":"Live row","status":"in_progress"},{"id":"US-004","title":"Queued row","status":"queued"}]}'
exit 0
SH
  chmod +x "$GHELPER"
}
run_ground() {  # extra env comes from the caller's environment
  HQ_ROOT="$GROOT" HQ_SESSION_ID=gsid WM_HELPER_SPY="$HELPER_SPY" \
    WM_NODE_SPY="$NODE_SPY" \
    bash "$GROOT/core/hooks/work-mesh-ground.sh" <<<"$GPROMPT"
}

# ===========================================================================
echo "CASE 5: incapable helper -> zero node spawns, silent, cache '<mtime> no'"
# ===========================================================================
write_incapable_helper
rm -f "$HELPER_SPY" "$NODE_SPY" "$GCAPS"
out5="$(run_ground)"; rc5=$?
assert_eq    "incapable: hook exits 0" "$rc5" "0"
assert_empty "incapable: hook emits nothing on stdout" "$out5"
assert_false "incapable: ZERO node spawns" test -s "$NODE_SPY"
assert_true  "incapable: capability cache written" test -f "$GCAPS"
mt5="$(file_ident "$GHELPER")"
assert_eq    "incapable: cache records '<helper ident> no'" "$(cat "$GCAPS" 2>/dev/null)" "$mt5 no"
assert_eq    "incapable: helper probed exactly once" "$(line_count "$HELPER_SPY")" "1"
assert_eq    "incapable: probe used the 'help' verb, never 'ground'" \
  "$(head -n1 "$HELPER_SPY" 2>/dev/null)" "help"
assert_false "incapable: no board snapshot written" test -f "$GROOT/.claude/state/work-mesh-board"

# ===========================================================================
echo "CASE 6: cached 'no' is reused -> helper not re-probed, still zero node"
# ===========================================================================
out6="$(run_ground)"
assert_empty "cached-no: still silent" "$out6"
assert_eq    "cached-no: helper NOT invoked a second time" "$(line_count "$HELPER_SPY")" "1"
assert_false "cached-no: still ZERO node spawns" test -s "$NODE_SPY"

# ===========================================================================
echo "CASE 7: helper mtime change invalidates the cache -> probe re-runs"
# ===========================================================================
sleep 1
write_capable_helper
mt7="$(file_ident "$GHELPER")"
if [ "$mt7" = "$mt5" ]; then failc "mtime-invalidate: helper identity did not change (test setup)"; else pass "mtime-invalidate: helper identity changed"; fi
out7="$(run_ground)"
assert_eq "mtime-invalidate: cache flipped to '<new mtime> yes'" "$(cat "$GCAPS" 2>/dev/null)" "$mt7 yes"
assert_contains "mtime-invalidate: board now injected" "$out7" "LIVE WORK MESH BOARD"

# Flip back: an mtime change in the other direction re-probes to 'no'.
sleep 1
write_incapable_helper
mt7b="$(file_ident "$GHELPER")"
out7b="$(run_ground)"
assert_eq    "mtime-invalidate: cache flipped back to '<mtime> no'" "$(cat "$GCAPS" 2>/dev/null)" "$mt7b no"
assert_empty "mtime-invalidate: incapable again => silent" "$out7b"

# ===========================================================================
echo "CASE 8: capable helper -> exact hookSpecificOutput contract + snapshot"
# ===========================================================================
sleep 1
write_capable_helper
rm -f "$NODE_SPY" "$GROOT/.claude/state/work-mesh-board"
out8="$(run_ground)"
assert_eq "capable: valid JSON on stdout" "$(printf '%s' "$out8" | jq -e 'type=="object"' 2>/dev/null)" "true"
assert_eq "capable: hookSpecificOutput.hookEventName" \
  "$(printf '%s' "$out8" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
assert_eq "capable: exactly the two contract keys under hookSpecificOutput" \
  "$(printf '%s' "$out8" | jq -r '.hookSpecificOutput | keys | join(",")')" \
  "additionalContext,hookEventName"
assert_eq "capable: hookSpecificOutput is the only top-level key" \
  "$(printf '%s' "$out8" | jq -r 'keys | join(",")')" "hookSpecificOutput"
ctx8="$(printf '%s' "$out8" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains "capable: context carries the Board header" "$ctx8" "LIVE WORK MESH BOARD"
assert_contains "capable: context carries the live in_progress row" "$ctx8" "in_progress US-001"
assert_contains "capable: context carries the queued row" "$ctx8" "queued US-004"
assert_contains "capable: context keeps the prd fallback warning" "$ctx8" "prd.passes is not status"
assert_true  "capable: board snapshot written" test -f "$GROOT/.claude/state/work-mesh-board"
assert_contains "capable: snapshot carries the live row" \
  "$(cat "$GROOT/.claude/state/work-mesh-board" 2>/dev/null)" "in_progress US-001"
assert_false "capable: project came from meta.yaml, no node inference spawned" test -s "$NODE_SPY"
assert_contains "capable: helper called with the ground verb" \
  "$(tail -n1 "$HELPER_SPY" 2>/dev/null)" "ground --company indigo --project work-desktop-dogfood"

# ---------------------------------------------------------------------------
# Done-hook sandbox
# ---------------------------------------------------------------------------
DROOT="$SANDBOX/root-done"
mkdir -p "$DROOT/core/hooks" "$DROOT/core/scripts" \
         "$DROOT/workspace/sessions/dsid" "$DROOT/workspace/sessions/dsid-unbound"
cp "$SRC_DONE"    "$DROOT/core/hooks/work-mesh-done.sh"
cp "$SRC_SESSION" "$DROOT/core/scripts/hq-session.sh"
cp -R "$SRC_SESSION_LIB" "$DROOT/core/scripts/lib"
chmod +x "$DROOT/core/hooks/work-mesh-done.sh" "$DROOT/core/scripts/hq-session.sh"
DHELPER="$DROOT/core/scripts/work-mesh-session.sh"
cat > "$DHELPER" <<'SH'
#!/usr/bin/env bash
[ -n "${WM_HELPER_SPY:-}" ] && printf '%s\n' "$*" >> "$WM_HELPER_SPY"
exit 0
SH
chmod +x "$DHELPER"

# The machine-global, PID-keyed bind file names a DIFFERENT project. The hook
# must ignore it entirely (this is the cross-session misattribution bug).
mkdir -p "$HOME/.hq/work-mesh/cache"
jq -nc '{pid:99999,company:"indigo",project:"hq-pro-messaging-gaps",story:"US-003"}' \
  > "$HOME/.hq/work-mesh/cache/sessions-bind.json"

printf 'company_slug: indigo\nproject: work-mesh-presence-v2\ntask: US-001\n' \
  > "$DROOT/workspace/sessions/dsid/meta.yaml"
printf 'company_slug: indigo\n' > "$DROOT/workspace/sessions/dsid-unbound/meta.yaml"
printf '%s' 'dsid' > "$DROOT/workspace/sessions/.current"

DSPY="$SANDBOX/done-helper-spy.txt"
run_done() {  # <session id>
  HQ_ROOT="$DROOT" HQ_SESSION_ID="$1" WM_HELPER_SPY="$DSPY" \
    bash "$DROOT/core/hooks/work-mesh-done.sh" </dev/null
}

# ===========================================================================
echo "CASE 9: done hook uses THIS session's meta.yaml, not the global bind file"
# ===========================================================================
rm -f "$DSPY"
out9="$(run_done dsid)"; rc9=$?
assert_eq    "done: exits 0" "$rc9" "0"
assert_empty "done: silent on stdout" "$out9"
assert_eq    "done: helper invoked exactly once" "$(line_count "$DSPY")" "1"
argv9="$(cat "$DSPY" 2>/dev/null)"
assert_eq "done: exact helper invocation shape" "$argv9" \
  "report --company indigo --project work-mesh-presence-v2 --story US-001 --status done --silent"
assert_not_contains "done: global sessions-bind project NEVER used" "$argv9" "hq-pro-messaging-gaps"
assert_not_contains "done: global sessions-bind story NEVER used" "$argv9" "US-003"

# A session whose meta.yaml has no task reports without --story.
printf 'company_slug: indigo\nproject: work-mesh-presence-v2\n' \
  > "$DROOT/workspace/sessions/dsid/meta.yaml"
rm -f "$DSPY"
run_done dsid
assert_eq "done: no task => no --story flag" "$(cat "$DSPY" 2>/dev/null)" \
  "report --company indigo --project work-mesh-presence-v2 --status done --silent"

# ===========================================================================
echo "CASE 10: no project binding on this session -> silent exit 0, no helper"
# ===========================================================================
rm -f "$DSPY"
out10="$(run_done dsid-unbound)"; rc10=$?
assert_eq    "unbound: exits 0" "$rc10" "0"
assert_empty "unbound: silent on stdout" "$out10"
assert_false "unbound: helper NEVER invoked" test -f "$DSPY"

# Empty project value is treated the same as absent.
printf 'company_slug: indigo\nproject: \n' > "$DROOT/workspace/sessions/dsid-unbound/meta.yaml"
rm -f "$DSPY"
run_done dsid-unbound
assert_false "unbound: empty project => helper NEVER invoked" test -f "$DSPY"

# ===========================================================================
echo "CASE 11: kill switches short-circuit all three hooks"
# ===========================================================================
# close
r11="$(new_close_root killswitch)"; sid=sid-kill; slug=notcloudco
register_session "$r11" "$sid" "$slug"
spf11="$(spool_of "$r11")"; base11="$(line_count "$spf11")"
for kill_env in "HQ_WORK_MESH_DISABLED=1" "HQ_DISABLED_HOOKS=work-mesh-close"; do
  env "$kill_env" HQ_ROOT="$r11" WM_ROOT="$r11" WM_SID="$sid" WM_HARNESS=claude-code \
    HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-kill" \
    WM_STUB_MEMBERSHIP="$MEMBERSHIP_OTHER" \
    bash "$r11/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
  assert_eq   "kill-switch ($kill_env): close spooled nothing" "$(line_count "$spf11")" "$base11"
  assert_false "kill-switch ($kill_env): close wrote no terminal marker" test -f "$(term_marker "$r11" "$sid" "$slug")"
done
assert_false "kill-switch: close made no HTTP call" test -f "$SANDBOX/stub-kill/argv.txt"

# ground (helper is capable at this point, so a live hook WOULD emit a board)
rm -f "$HELPER_SPY" "$NODE_SPY"
for kill_env in "HQ_WORK_MESH_DISABLED=1" "HQ_DISABLED_HOOKS=work-mesh-ground"; do
  out11="$(env "$kill_env" HQ_ROOT="$GROOT" HQ_SESSION_ID=gsid \
    WM_HELPER_SPY="$HELPER_SPY" WM_NODE_SPY="$NODE_SPY" \
    bash "$GROOT/core/hooks/work-mesh-ground.sh" <<<"$GPROMPT")"
  assert_empty "kill-switch ($kill_env): ground emits nothing" "$out11"
done
assert_false "kill-switch: ground never invoked the helper" test -s "$HELPER_SPY"
assert_false "kill-switch: ground spawned no node" test -s "$NODE_SPY"

# done
printf 'company_slug: indigo\nproject: work-mesh-presence-v2\ntask: US-001\n' \
  > "$DROOT/workspace/sessions/dsid/meta.yaml"
for kill_env in "HQ_WORK_MESH_DISABLED=1" "HQ_DISABLED_HOOKS=work-mesh-done"; do
  rm -f "$DSPY"
  out11d="$(env "$kill_env" HQ_ROOT="$DROOT" HQ_SESSION_ID=dsid WM_HELPER_SPY="$DSPY" \
    bash "$DROOT/core/hooks/work-mesh-done.sh" </dev/null)"
  assert_empty "kill-switch ($kill_env): done emits nothing" "$out11d"
  assert_false "kill-switch ($kill_env): done never invoked the helper" test -f "$DSPY"
done

# ===========================================================================
echo "CASE 12: EMPTY membership listing is transient, never permanent"
# ===========================================================================
# Regression: `{"memberships":[]}` type-checks as an array and matches EVERY
# slug, so treating it as authoritative would terminally drop real work for a
# not-yet-provisioned account, a scoped token, or a degraded backend.
r12="$(new_close_root membership-empty-array)"; sid=sid-emptyarr; slug=maybecloudco
register_session "$r12" "$sid" "$slug"
HQ_ROOT="$r12" WM_ROOT="$r12" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-emptyarr" \
  WM_STUB_MEMBERSHIP='{"memberships":[]}' \
  bash "$r12/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "empty-array: reconcile-pending/no_uid spooled (stays retryable)" \
  "$(count_reason "$r12" "$sid" reconcile-pending no_uid)" "1"
assert_eq   "empty-array: NEVER spooled as no_uid_permanent" \
  "$(count_reason "$r12" "$sid" reconcile-skipped no_uid_permanent)" "0"
assert_false "empty-array: NO terminal marker (no permanent data loss)" \
  test -f "$(term_marker "$r12" "$sid" "$slug")"

# ===========================================================================
echo "CASE 13: membership match is ANCHORED, not substring"
# ===========================================================================
# The listing contains only `alive-two`; the slug under test is `alive`. A
# substring match would call this a HIT and keep the record retryable forever.
# The anchored (equality) match must still declare a correct permanent verdict.
r13="$(new_close_root membership-anchored)"; sid=sid-anchored; slug=alive
register_session "$r13" "$sid" "$slug"
HQ_ROOT="$r13" WM_ROOT="$r13" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-anchored" \
  WM_STUB_MEMBERSHIP='{"memberships":[{"companySlug":"alive-two","companyName":"Alive Two"}]}' \
  bash "$r13/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "anchored: 'alive' vs listing of 'alive-two' => no_uid_permanent" \
  "$(count_reason "$r13" "$sid" reconcile-skipped no_uid_permanent)" "1"
assert_eq   "anchored: not spooled as retryable" \
  "$(count_reason "$r13" "$sid" reconcile-pending no_uid)" "0"
assert_true "anchored: terminal marker written" test -f "$(term_marker "$r13" "$sid" "$slug")"

# The exact slug present in the listing is of course a HIT (stays retryable).
r13b="$(new_close_root membership-anchored-hit)"; sid=sid-anchored-hit; slug=alive-two
register_session "$r13b" "$sid" "$slug"
HQ_ROOT="$r13b" WM_ROOT="$r13b" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-anchored-hit" \
  WM_STUB_MEMBERSHIP='{"memberships":[{"companySlug":"alive-two","companyName":"Alive Two"}]}' \
  bash "$r13b/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "anchored: listed slug is NOT permanent" \
  "$(count_reason "$r13b" "$sid" reconcile-skipped no_uid_permanent)" "0"
assert_false "anchored: listed slug wrote no terminal marker" \
  test -f "$(term_marker "$r13b" "$sid" "$slug")"

# ===========================================================================
echo "CASE 14: concurrent sweep + close on the same (sid, slug) -> one line"
# ===========================================================================
# The sweep claim must make exactly one of the two racers do the work; the
# other must find the claim (or the terminal marker) and do nothing.
r14="$(new_close_root concurrent)"; sid=sid-concurrent; slug=notcloudco
register_session "$r14" "$sid" "$slug"
printf '%s' 'some-other-live-session' > "$r14/workspace/sessions/.current"
HQ_ROOT="$r14" WM_ROOT="$r14" HQ_WORK_MESH_TOKEN=tok \
  WM_STUB_DIR="$SANDBOX/stub-concurrent" WM_STUB_MEMBERSHIP="$MEMBERSHIP_OTHER" \
  bash "$r14/core/hooks/work-mesh-close.sh" __sweep_bg__ </dev/null &
p14a=$!
HQ_ROOT="$r14" WM_ROOT="$r14" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-concurrent" \
  WM_STUB_MEMBERSHIP="$MEMBERSHIP_OTHER" \
  bash "$r14/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null &
p14b=$!
wait "$p14a" 2>/dev/null || true
wait "$p14b" 2>/dev/null || true
assert_eq   "concurrent: exactly ONE no_uid_permanent line (no duplicate work)" \
  "$(count_reason "$r14" "$sid" reconcile-skipped no_uid_permanent)" "1"
assert_eq   "concurrent: no retryable line alongside the permanent one" \
  "$(count_reason "$r14" "$sid" reconcile-pending no_uid)" "0"
assert_true "concurrent: terminal marker written exactly once" \
  test -f "$(term_marker "$r14" "$sid" "$slug")"
assert_eq   "concurrent: sweep claim released (no leaked claim dir)" \
  "$(test -d "$r14/workspace/sessions/$sid/work-mesh-sweep-claim-$(keyfrag "$slug")" && echo held || echo free)" "free"

# ===========================================================================
echo "CASE 15: normalization/aliasing must NOT yield a permanent verdict"
# ===========================================================================
# Codex review finding 1 (HIGH). A real company whose local slug differs from
# the server slug only by normalization (`acme_inc` locally vs `acme-inc` in
# the listing) was declared PERMANENT, minting a terminal marker that stopped
# the sweep forever — silent, unrecoverable data loss. Canonical-equal must
# count as PRESENT (retryable).
r15="$(new_close_root membership-underscore)"; sid=sid-underscore; slug=acme_inc
register_session "$r15" "$sid" "$slug"
HQ_ROOT="$r15" WM_ROOT="$r15" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-underscore" \
  WM_STUB_MEMBERSHIP='{"memberships":[{"companySlug":"acme-inc","companyName":"Acme Inc"}]}' \
  bash "$r15/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "canon: 'acme_inc' vs listed 'acme-inc' => NEVER permanent" \
  "$(count_reason "$r15" "$sid" reconcile-skipped no_uid_permanent)" "0"
assert_eq   "canon: stays retryable (reconcile-pending/no_uid)" \
  "$(count_reason "$r15" "$sid" reconcile-pending no_uid)" "1"
assert_false "canon: NO terminal marker written (no data loss)" \
  test -f "$(term_marker "$r15" "$sid" "$slug")"

# Case-only difference must be retryable too.
r15b="$(new_close_root membership-case)"; sid=sid-case; slug=acme-inc
register_session "$r15b" "$sid" "$slug"
HQ_ROOT="$r15b" WM_ROOT="$r15b" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-case" \
  WM_STUB_MEMBERSHIP='{"memberships":[{"companySlug":"ACME_Inc"}]}' \
  bash "$r15b/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "canon: mixed-case 'ACME_Inc' => NEVER permanent" \
  "$(count_reason "$r15b" "$sid" reconcile-skipped no_uid_permanent)" "0"
assert_false "canon: mixed-case wrote no terminal marker" \
  test -f "$(term_marker "$r15b" "$sid" "$slug")"

# A genuinely different company must still be permanent (no over-correction).
r15c="$(new_close_root membership-canon-miss)"; sid=sid-canonmiss; slug=zzz_other
register_session "$r15c" "$sid" "$slug"
HQ_ROOT="$r15c" WM_ROOT="$r15c" WM_SID="$sid" WM_HARNESS=claude-code \
  HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-canonmiss" \
  WM_STUB_MEMBERSHIP='{"memberships":[{"companySlug":"acme-inc"}]}' \
  bash "$r15c/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
assert_eq   "canon: a truly absent slug is still permanent" \
  "$(count_reason "$r15c" "$sid" reconcile-skipped no_uid_permanent)" "1"

# ===========================================================================
echo "CASE 16: a PAGINATED membership listing is never authoritative"
# ===========================================================================
# A partial page can omit the slug entirely. Any pagination indicator must
# force the retryable path even when the slug is absent from what we saw.
i=0
for page_body in \
  '{"memberships":[{"companySlug":"other-co"}],"nextCursor":"abc"}' \
  '{"memberships":[{"companySlug":"other-co"}],"hasMore":true}' \
  '{"memberships":[{"companySlug":"other-co"}],"next":"/membership/me?p=2"}' \
  '{"memberships":[{"companySlug":"other-co"}],"total":42}' \
  '{"memberships":[{"companySlug":"other-co"}],"pagination":{"nextCursor":"x"}}' ; do
  i=$(( i + 1 ))
  rp="$(new_close_root membership-page-$i)"; sid="sid-page-$i"; slug=notlisted
  register_session "$rp" "$sid" "$slug"
  HQ_ROOT="$rp" WM_ROOT="$rp" WM_SID="$sid" WM_HARNESS=claude-code \
    HQ_WORK_MESH_TOKEN=tok WM_STUB_DIR="$SANDBOX/stub-page-$i" \
    WM_STUB_MEMBERSHIP="$page_body" \
    bash "$rp/core/hooks/work-mesh-close.sh" __close_bg__ </dev/null
  assert_eq   "paginated[$i]: absent slug is NOT permanent" \
    "$(count_reason "$rp" "$sid" reconcile-skipped no_uid_permanent)" "0"
  assert_eq   "paginated[$i]: stays retryable" \
    "$(count_reason "$rp" "$sid" reconcile-pending no_uid)" "1"
  assert_false "paginated[$i]: NO terminal marker" \
    test -f "$(term_marker "$rp" "$sid" "$slug")"
done

# ===========================================================================
echo "CASE 17: truncated help output never pins a negative capability verdict"
# ===========================================================================
# Codex review finding 3 (MEDIUM). A long banner pushing the verb past the read
# cap must not cache a false 'no', which would silently disable work-mesh-ground
# after a helper upgrade.
CAPROOT="$SANDBOX/capcache"; mkdir -p "$CAPROOT/workspace/work-mesh/cache"
CAPHELPER="$CAPROOT/helper.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'awk "BEGIN{for(i=0;i<400;i++) print \\"banner padding line for the capability probe cap test\\"}"\n'
  printf 'printf "commands: ground\\n"\n'
} > "$CAPHELPER"
chmod +x "$CAPHELPER"
CAPCACHE="$CAPROOT/workspace/work-mesh/cache"
cap_probe() {
  HQ_ROOT="$CAPROOT" env "$@" bash -c \
    '. "$0"; wm_helper_supports_verb "$1" ground && echo yes || echo no' \
    "$SRC_LIB" "$CAPHELPER" 2>/dev/null
}
out17="$(cap_probe HQ_ROOT="$CAPROOT" HQ_WORK_MESH_HELP_CAP=64)"
assert_eq "truncated-help: verb past the cap reports unsupported (conservative)" "$out17" "no"
assert_eq "truncated-help: NO negative verdict cached" \
  "$(ls "$CAPCACHE" 2>/dev/null | grep -c '^caps-' | tr -d ' ')" "0"
# With the default cap the whole banner is read and the verdict is a real 'yes'.
out17b="$(cap_probe HQ_ROOT="$CAPROOT")"
assert_eq "truncated-help: full read sees the verb => yes" "$out17b" "yes"
assert_eq "truncated-help: positive verdict IS cached" \
  "$(ls "$CAPCACHE" 2>/dev/null | grep -c '^caps-' | tr -d ' ')" "1"

# ===========================================================================
echo "CASE 18: a killed claim holder releases its claim (no leaked claim dir)"
# ===========================================================================
# Codex review finding 2 (MEDIUM). Killed between claim and rmdir, the claim
# directory leaked and later close/sweep runs silently skipped that real work
# until HQ_WORK_MESH_CLAIM_STALE_SEC (up to 15 min) aged it out.
TRAPROOT="$SANDBOX/claimtrap"; mkdir -p "$TRAPROOT/workspace/sessions/tsid"
TRAPOUT="$SANDBOX/claimtrap.out"
cat > "$SANDBOX/claimtrap.sh" <<'TRAPEOF'
. "$1"
claim="$(wm_sweep_claim tsid tco)"
wm_sweep_try_claim tsid tco || exit 9
wm_hold_claim "$claim"
printf '%s\n' "$claim" > "$2"
while : ; do sleep 0.2; done
TRAPEOF
CLAIMPATH_FILE="$SANDBOX/claimtrap.path"
rm -f "$CLAIMPATH_FILE"
HQ_ROOT="$TRAPROOT" bash "$SANDBOX/claimtrap.sh" "$SRC_LIB" "$CLAIMPATH_FILE" \
  >"$TRAPOUT" 2>/dev/null &
trap_pid=$!
n=0; while [ ! -s "$CLAIMPATH_FILE" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$(( n + 1 )); done
CLAIMDIR="$(cat "$CLAIMPATH_FILE" 2>/dev/null)"
assert_true "claim-trap: claim was actually acquired" test -d "$CLAIMDIR"
kill -TERM "$trap_pid" 2>/dev/null || true
wait "$trap_pid" 2>/dev/null || true
assert_false "claim-trap: TERM released the claim (no leaked claim dir)" \
  test -d "$CLAIMDIR"
assert_empty "claim-trap: trap emitted nothing on stdout" "$(cat "$TRAPOUT" 2>/dev/null)"

# The trap must NOT release a claim this process does not hold.
OTHERROOT="$SANDBOX/claimtrap-other"; mkdir -p "$OTHERROOT/workspace/sessions/osid"
notmine="$(HQ_ROOT="$OTHERROOT" bash -c '. "$1"; wm_sweep_try_claim osid oco >/dev/null 2>&1; wm_sweep_claim osid oco' _ "$SRC_LIB")"
HQ_ROOT="$OTHERROOT" bash -c '. "$1"; wm_release_claim' _ "$SRC_LIB" >/dev/null 2>&1 || true
assert_true "claim-trap: unheld claim is left untouched" test -d "$notmine"
rmdir "$notmine" 2>/dev/null || true

# ===========================================================================
echo ""
echo "----------------------------------------------------------------------"
echo "work-mesh hotfix (US-001): ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: work-mesh-hotfix.test.sh" >&2
  exit 1
fi
echo "PASS: work-mesh-hotfix.test.sh"
exit 0
