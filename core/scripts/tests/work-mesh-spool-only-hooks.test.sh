#!/usr/bin/env bash
# hq-core-rust US-038 c1 / e2e1: session events go through the spool only.
#
# 1. No hook (core/hooks, .claude/hooks, .codex/hooks, .grok/hooks), and no
#    core/scripts helper a hook sources or runs (followed transitively), starts
#    an `hq mesh session <verb>` post, a retiring mesh thread verb
#    (`hq mesh start|progress|blocked|done|note`), or posts to a session-event
#    endpoint itself. The program may be `hq`, a path ending in /hq, or any
#    shell variable; argv-array spawns ('mesh', 'session', ...) and
#    backslash-continued lines count. Comment lines (#, //, rem) are skipped.
#    Planted fixtures prove each form is caught before the real tree is scanned.
# 2. Given a turn ending, when the Stop event fires, the turn-end hook writes
#    exactly one turn_end line to the spool and starts no hq process: an `hq`
#    stub first on PATH records every call, and the record stays empty.
# 3. No shipped caller names `hq daemon doctor` or `hq daemon service mesh`,
#    which no released CLI at the core.yaml floor has yet.
#
# HQ_SPOOL_ONLY_HOOKS_ROOT points the scan at another tree (used to show the
# scan fails on a planted direct post).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCAN_ROOT="${HQ_SPOOL_ONLY_HOOKS_ROOT:-$REPO_ROOT}"
TURN_END="$SCAN_ROOT/core/hooks/Stop/70-work-mesh-turn-end.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }
[ -f "$TURN_END" ] || { echo "FATAL: missing $TURN_END" >&2; exit 1; }

# --- 1. no direct session-event post from any hook --------------------------
VERBS='(start|turn-start|turn-end|end|task-status|blocked|note)'
THREAD='(start|progress|blocked|done|note)'
Q="[\"']?"
END_RE='([^A-Za-z0-9_-]|$)'
PROG='(([^[:space:]"'"'"']*/)?hq|"?\$\{?[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}?"?)'
DIRECT_RE="(^|[^A-Za-z0-9_.-])${PROG}[[:space:]]+mesh[[:space:]]+(session[[:space:]]+${Q}${VERBS}${Q}|${Q}${THREAD}${Q})${END_RE}"
AQ="[\"']"
DIRECT_RE="$DIRECT_RE|${AQ}mesh${AQ}[[:space:]]*,[[:space:]]*(${AQ}session${AQ}[[:space:]]*,[[:space:]]*${AQ}${VERBS}${AQ}|${AQ}${THREAD}${AQ})"
DIRECT_RE="$DIRECT_RE"'|/v1/mesh/events|/v1/work-mesh/session-events'
# A line that sources or runs a core/scripts helper.
INVOKE_RE='(^|[:;&|({`[:space:]])(\.|source|bash|sh|exec|node|python3?)[[:space:]]+[^;&|]*core/scripts/[A-Za-z0-9_./-]+'

# Print "<line>:<text>" with backslash-continued lines joined onto their first line.
joined_lines() {
  awk '{ if (buf == "") start = NR; line = $0
         if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf line " "; next }
         print start ":" buf line; buf = "" }
       END { if (buf != "") print start ":" buf }' "$1"
}

# scan_tree ROOT: sets SCAN_HITS and SCAN_COUNT.
scan_tree() {
  local root="$1" list queue next file rel found helper dir
  list="$(mktemp)"; queue="$(mktemp)"; next="$(mktemp)"
  SCAN_HITS=""; SCAN_COUNT=0
  for dir in core/hooks .claude/hooks .codex/hooks .grok/hooks; do
    [ -d "$root/$dir" ] || continue
    find "$root/$dir" -type f ! -name '*.md' ! -name '.gitkeep' >>"$queue"
  done
  while [ -s "$queue" ]; do
    : >"$next"
    while IFS= read -r file; do
      grep -Fxq -- "$file" "$list" && continue
      printf '%s\n' "$file" >>"$list"
      SCAN_COUNT=$((SCAN_COUNT + 1))
      found="$(joined_lines "$file" | grep -E "$DIRECT_RE" \
        | grep -vE '^[0-9]+:[[:space:]]*(#|//|rem[[:space:]]|::)' || true)"
      rel="${file#"$root"/}"
      [ -n "$found" ] && SCAN_HITS="$SCAN_HITS$rel: $found"$'\n'
      { joined_lines "$file" | grep -vE '^[0-9]+:[[:space:]]*(#|//)' | grep -oE "$INVOKE_RE" \
        | grep -oE 'core/scripts/[A-Za-z0-9_./-]+' || true; } | while IFS= read -r helper; do
          if [ -f "$root/$helper" ]; then printf '%s\n' "$root/$helper"; fi
        done >>"$next"
    done <"$queue"
    sort -u "$next" >"$queue"
  done
  rm -f "$list" "$queue" "$next"
}

# Planted fixtures: each must be caught (and the clean ones must not be).
FIXTURES="$(mktemp -d)"
plant_case() { # name expect(hit|clean) relpath body [relpath body]...
  local name="$1" expect="$2" root
  shift 2
  root="$FIXTURES/$name"
  while [ "$#" -ge 2 ]; do
    mkdir -p "$(dirname "$root/$1")"
    printf '%s\n' "$2" >"$root/$1"
    shift 2
  done
  scan_tree "$root"
  if [ "$expect" = hit ] && [ -n "$SCAN_HITS" ]; then pass "fixture caught: $name"
  elif [ "$expect" = clean ] && [ -z "$SCAN_HITS" ]; then pass "fixture clean: $name"
  else fail "fixture $name expected $expect, got: ${SCAN_HITS:-no hits}"; fi
}
plant_case plain-core hit core/hooks/Stop/x.sh 'hq mesh session note --summary x'
plant_case plain-claude hit .claude/hooks/x.sh 'hq mesh session turn-end'
plant_case plain-codex hit .codex/hooks/x.sh 'hq mesh session end'
plant_case plain-grok hit .grok/hooks/x.sh 'hq mesh session start'
plant_case thread-verb hit core/hooks/x.sh 'hq mesh done --story s'
plant_case abs-path hit core/hooks/x.sh '/usr/local/bin/hq mesh session note'
plant_case any-var hit core/hooks/x.sh '"$hq_bin" mesh session blocked'
plant_case default-var hit core/hooks/x.sh '"${HQ_CMD:-hq}" mesh session note'
plant_case quoted-verb hit core/hooks/x.sh 'hq mesh session "note"'
plant_case continued hit core/hooks/x.sh "$(printf 'hq mesh \\\n  session note')"
plant_case argv-cjs hit .claude/hooks/x.cjs "spawn('hq', ['mesh', 'session', 'note'])"
plant_case argv-thread hit .claude/hooks/x.cjs "execFileSync(hqBin, [\"mesh\", \"progress\"])"
plant_case argv-py hit .codex/hooks/x.py 'subprocess.run(["hq","mesh","session","note"])'
plant_case no-extension hit .codex/hooks/x 'hq mesh session note'
plant_case endpoint hit .claude/hooks/x.cjs "fetch(base + '/v1/mesh/events')"
plant_case sourced-helper hit core/hooks/x.sh '. "$HQ_ROOT/core/scripts/lib/zz.sh"' \
  core/scripts/lib/zz.sh 'hq mesh session note'
plant_case run-helper-2-deep hit .claude/hooks/x.sh 'bash "$HQ_ROOT/core/scripts/a.sh"' \
  core/scripts/a.sh 'source "$HQ_ROOT/core/scripts/lib/b.sh"' \
  core/scripts/lib/b.sh '"$HQ_BIN" mesh session task-status'
plant_case comment-only clean core/hooks/x.sh '# hq mesh session note'
plant_case mentioned-helper clean .claude/hooks/x.sh 'echo "use `core/scripts/r.sh`."' \
  core/scripts/r.sh 'hq mesh session note'
plant_case other-mesh-verb clean core/hooks/x.sh 'hq mesh context reconcile --observation-file f'
rm -rf "$FIXTURES"

scan_tree "$SCAN_ROOT"
[ "$SCAN_COUNT" -gt 10 ] || fail "scanned only $SCAN_COUNT hook files under $SCAN_ROOT (positive control)"
if [ -z "$SCAN_HITS" ]; then
  pass "no hook or hook helper starts a direct session-event post ($SCAN_COUNT files scanned)"
else
  fail "hooks post session events directly instead of through the spool:"$'\n'"$SCAN_HITS"
fi

# --- 2. Stop writes one turn_end line and starts no hq ----------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/home" "$SANDBOX/bin"
CALLS="$SANDBOX/hq-calls.log"
: >"$CALLS"
cat >"$SANDBOX/bin/hq" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALLS"
exit 0
STUB
chmod +x "$SANDBOX/bin/hq"
SPOOL="$SANDBOX/home/.hq/work-mesh/spool.jsonl"

printf '%s' '{"session_id":"sid-us038-stop","hook_event_name":"Stop"}' \
  | env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" HQ_ROOT="$SCAN_ROOT" \
      HQ_HOOK_ASYNC=0 WORK_MESH_SPOOL="$SPOOL" WORK_MESH_SEQ_DIR="$SANDBOX/home/.hq/work-mesh/seq" \
      bash "$TURN_END" >/dev/null 2>&1 || true

lines=0
[ -f "$SPOOL" ] && lines="$(wc -l <"$SPOOL" | tr -d ' ')"
if [ "$lines" = 1 ] && jq -e '.kind == "turn_end" and .sessionId == "sid-us038-stop"' "$SPOOL" >/dev/null 2>&1; then
  pass "Stop wrote one turn_end line to the spool"
else
  fail "Stop spool: expected 1 turn_end line for sid-us038-stop, got $lines: $(cat "$SPOOL" 2>/dev/null || true)"
fi
if [ ! -s "$CALLS" ]; then
  pass "Stop started no hq process"
else
  fail "Stop ran hq: $(cat "$CALLS")"
fi

# --- 3. callers name only commands a CLI at the core.yaml floor has --------
# `hq daemon doctor` and `hq daemon service mesh` come with hq-cli #2873, which
# no released CLI has yet. Shipped files must not tell people to run them
# until core/core.yaml requiresHqCli moves to that release. Searched: tracked
# files under core/, .claude/, .codex/, .grok/ and AGENTS.md. Not searched:
# core/functions.yaml (it lists the coming commands), the generated CLI
# reference, changelogs, and test files. When the floor moves, drop this part.
unreleased='hq daemon (doctor|service mesh)'
hits="$(git -C "$SCAN_ROOT" grep -nE "$unreleased" -- core .claude .codex .grok AGENTS.md \
  ':!core/functions.yaml' ':!core/knowledge/public/hq-core/hq-cli-reference.md' \
  ':!*CHANGELOG*' ':!*MIGRATION*' ':!*/tests/*' ':!*.test.*' 2>/dev/null || true)"
if [ -z "$hits" ]; then
  pass "no shipped caller names an unreleased hq daemon command"
else
  fail "shipped callers name a command released CLIs do not have (keep hq mesh daemon doctor until the floor moves):
$hits"
fi

echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
