#!/usr/bin/env bash
# conduct-default-no-runner-calls.test.sh — default /conduct (conduct.runner
# subagent) never runs a runner-lane command. Runner lanes (`hq runners create`,
# `message`, `keep-alive`, `interrupt`, `wait`, `watch`) belong to
# /conduct-runners. Shipped core calls `hq runners` (US-035): hq-cli 5.345.210
# added it and `requiresHqCli` is above that. `hq lanes` is its deprecated
# alias, so both spellings count. Only `hq runners link` / `hq lanes link`
# (conduct child sessions) is allowed on the default path, plus one cleanup:
# `conduct-standing.sh close` ends runner lanes this session already opened (keep-alive off, show,
# interrupt). It never creates or messages a lane.
#
# Three checks:
#   1. The default-mode text of every file the default path loads (the conduct
#      skill, the _shared files it and /run-project, /execute-task use,
#      /run-project, /execute-task, /super-conductor, /overnight,
#      /conduct-join, /decision-queue, /decision-desk, the workers README, and
#      core/policies) names no `hq runners <sub>` or `hq lanes <sub>` other
#      than `link`. /super-conductor may also read lanes it is senior of
#      (`list`, `show`, `questions list`, `questions answer`), and
#      /decision-queue may list and answer lane questions. Text is scanned
#      per paragraph, list item, table row, or code line, so a command wrapped
#      across a markdown line is still one match, flags before the
#      subcommand (`hq lanes --json create`) are skipped, and a wrapper binary
#      (`"$HQ_BIN" lanes`, `${HQ_BIN:-hq} lanes`) counts as hq. Frontmatter and text
#      between `<!-- advanced-mode:start -->` and `<!-- advanced-mode:end -->`
#      lines are not scanned. Headings or paragraphs that merely mention
#      advanced mode are scanned. Each marker block must sit on lines of its
#      own, close, not nest, and say "advanced mode"; a malformed block is
#      reported as a hit.
#   2. The helper scripts the default skill runs, called directly in subagent
#      mode, make no hq call other than `runners link` (or `lanes link`). A stub hq is first on
#      PATH and set as HQ_BIN; it logs every call and fails anything else.
#   3. With a leftover runner-lane record for the session, default close ends
#      that lane and makes no other lanes call.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }

echo "default-mode text names no runner-lane command"
# scan_default FILE: one line per runner-lane command in the file's default-mode
# text, as FILE:LINE:<lanes|runners> <sub> [<next word>].
scan_default() {
  awk -v F="$1" '
    function emit(s,   m, n, w, i, sub1, nxt) {
      while (match(s, /(hq|[$][{]?HQ_BIN(:-hq)?[}]?"?) +(lanes|runners)( +--?[A-Za-z][A-Za-z0-9=-]*)* +[a-z][a-z-]*( +[a-z][a-z-]*)?/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        n = split(m, w, / +/); sub1 = ""; nxt = ""
        for (i = 3; i <= n; i++) {
          if (w[i] ~ /^-/) continue
          if (sub1 == "") sub1 = w[i]; else if (nxt == "") nxt = w[i]
        }
        print F ":" ul ":" w[2] " " sub1 (nxt == "" ? "" : " " nxt)
      }
    }
    function flush() {
      if (u != "") emit(u)
      u = ""
    }
    function bad(l, why) { print F ":" l ":marker " why }
    function add(s) { sub(/^[ \t]+/, "", s); if (u == "") { u = s; ul = NR } else u = u " " s }
    NR == 1 && /^---[ \t]*$/ { fm = 1; next }
    fm { if ($0 ~ /^---[ \t]*$/) fm = 0; next }
    /^[ \t]*<!-- advanced-mode:start -->[ \t]*$/ {
      flush(); if (adv) bad(NR, "advanced-mode:start inside an open block")
      adv = 1; advl = NR; advt = ""; next
    }
    /^[ \t]*<!-- advanced-mode:end -->[ \t]*$/ {
      flush()
      if (!adv) bad(NR, "advanced-mode:end without a start")
      else if (tolower(advt) !~ /advanced mode/) bad(advl, "advanced-mode block does not say advanced mode")
      adv = 0; next
    }
    /advanced-mode:(start|end)/ { bad(NR, "advanced-mode marker not on a line of its own") }
    adv { advt = advt " " $0; next }
    /^[ \t]*(```|~~~)/ { flush(); fence = !fence; next }
    fence { l = $0; c = sub(/\\[ \t]*$/, "", l); add(l); if (!c) flush(); next }
    /^#+ / {
      flush(); add($0); flush(); next
    }
    /^[ \t]*$/ { flush(); next }
    /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ || /^[ \t]*\|/ { flush() }
    { add($0) }
    END { flush(); if (adv) bad(advl, "advanced-mode:start never closed") }
  ' "$1"
}
# disallowed: drop the commands default mode may run. `link` is allowed
# everywhere; /super-conductor may also read lanes it is senior of, and
# /decision-queue may list and answer their questions.
disallowed() {
  grep -vE ':(lanes|runners) link( |$)' \
    | grep -vE '/super-conductor/SKILL\.md:[0-9]+:(lanes|runners) ((list|show)( |$)|questions (list|answer)$)' \
    | grep -vE '/decision-queue/SKILL\.md:[0-9]+:(lanes|runners) questions (list|answer)$' || true
}
files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$ROOT/.claude/skills/conduct" -type f | sort)
[ "${#files[@]}" -ge 5 ] || fail "expected the conduct skill files, found ${#files[@]}"
files+=("$ROOT/.claude/skills/_shared/conduct-dispatch-core.md"
        "$ROOT/.claude/skills/_shared/work-mesh-live-bind.md"
        "$ROOT/.claude/skills/run-project/SKILL.md"
        "$ROOT/.claude/skills/execute-task/SKILL.md"
        "$ROOT/.claude/skills/super-conductor/SKILL.md"
        "$ROOT/.claude/skills/overnight/SKILL.md"
        "$ROOT/.claude/skills/conduct-join/SKILL.md"
        "$ROOT/.claude/skills/decision-queue/SKILL.md"
        "$ROOT/.claude/skills/decision-desk/SKILL.md"
        "$ROOT/core/knowledge/public/workers/README.md")
npol=0
while IFS= read -r f; do files+=("$f"); npol=$((npol + 1)); done < <(find "$ROOT/core/policies" -maxdepth 1 -type f -name '*.md' | sort)
[ "$npol" -ge 10 ] || fail "expected core/policies files, found $npol"
for f in "${files[@]}"; do [ -f "$f" ] || fail "missing $f"; done
hits="$(for f in "${files[@]}"; do scan_default "$f"; done | disallowed)"
[ -z "$hits" ] || fail "default-mode text names runner-lane commands:
$hits"

# The scanner has to find what it is meant to find.
PROBE_DIR="$(mktemp -d)"
mkdir -p "$PROBE_DIR/super-conductor"
cat > "$PROBE_DIR/probe.md" <<'MD'
---
allowed-tools: Bash(hq lanes create:*)
---
Run `hq lanes create --keep-alive` first.

- Then `hq lanes --json message` it.
- Wrapped: run `hq
  lanes interrupt` now.
- Also `hq runners create --runner subagent`.
- Child: `hq lanes link send`.

```bash
hq lanes \
  wait --json
```

<!-- advanced-mode:start -->
## Advanced mode: runners

`hq lanes watch` is fine here.
<!-- advanced-mode:end -->

## Advanced notes

Run `hq lanes create` here: a heading that sounds advanced is not a marker.

Unlike advanced mode, open every lane with `hq lanes create`.

   <!-- advanced-mode:start -->
   In advanced mode, `hq lanes reap` is fine.
   <!-- advanced-mode:end -->

But `hq lanes list --json` is not, outside /super-conductor.

Wrapped binary: `"$HQ_BIN" lanes keep-alive` and `${HQ_BIN:-hq} runners list`.
MD
probe="$(scan_default "$PROBE_DIR/probe.md" | disallowed | sed "s#^$PROBE_DIR/probe.md:##" | tr '\n' ',')"
eq "$probe" '4:lanes create,6:lanes message,7:lanes interrupt,9:runners create,13:lanes wait,25:lanes create,27:lanes create,33:lanes list,35:lanes keep-alive,35:runners list,' \
  'scanner catches flags, wrapped lines, wrapper binaries, runners, code lines, and advanced-sounding headings and paragraphs outside a marker block; skips link, frontmatter and marker blocks'
# Marker blocks are checked: each one must close, must not nest, must sit on
# its own line, and must say "advanced mode".
cat > "$PROBE_DIR/markers.md" <<'MD'
<!-- advanced-mode:end -->

<!-- advanced-mode:start -->
Plain text, no mode named, with `hq lanes stop`.
<!-- advanced-mode:end -->

Inline <!-- advanced-mode:start --> marker.

<!-- advanced-mode:start -->
In advanced mode, `hq lanes reap`.
<!-- advanced-mode:start -->
In advanced mode too.
MD
probe="$(scan_default "$PROBE_DIR/markers.md" | disallowed | sed "s#^$PROBE_DIR/markers.md:##" | tr '\n' ',')"
eq "$probe" '1:marker advanced-mode:end without a start,3:marker advanced-mode block does not say advanced mode,7:marker advanced-mode marker not on a line of its own,11:marker advanced-mode:start inside an open block,11:marker advanced-mode:start never closed,' \
  'malformed advanced-mode marker blocks are reported'
# The review mutation: a runner-lane command under an advanced-sounding
# heading in the default dispatch file is caught.
cp "$ROOT/.claude/skills/conduct/dispatch.md" "$PROBE_DIR/dispatch.md"
printf '\n## Advanced notes\n\nOpen the worker with `hq lanes create`.\n' >> "$PROBE_DIR/dispatch.md"
probe="$(scan_default "$PROBE_DIR/dispatch.md" | disallowed | sed 's#^.*:[0-9]*:##' | tr '\n' ',')"
eq "$probe" 'lanes create,' 'hq lanes create under ## Advanced notes in the default dispatch file is caught'
printf 'Read `hq lanes list --json`, `hq lanes show x`, `hq lanes questions list`.\nThen `hq lanes create` is not allowed.\n' \
  > "$PROBE_DIR/super-conductor/SKILL.md"
probe="$(scan_default "$PROBE_DIR/super-conductor/SKILL.md" | disallowed | sed 's#^.*:##' | tr '\n' ',')"
eq "$probe" 'lanes create,' '/super-conductor may read its lanes and nothing else'
mkdir -p "$PROBE_DIR/decision-queue"
printf 'Answer with `hq lanes questions answer`.\nNever `hq lanes show x` or `hq lanes create`.\n' \
  > "$PROBE_DIR/decision-queue/SKILL.md"
probe="$(scan_default "$PROBE_DIR/decision-queue/SKILL.md" | disallowed | sed 's#^.*:##' | tr '\n' ',')"
eq "$probe" 'lanes show x,lanes create,' '/decision-queue may answer lane questions and nothing else'
rm -rf "$PROBE_DIR"
# The detached board record moved to /conduct-runners. The earlier ban on
# naming `hq runners` (CLIs before hq-cli 5.345.210 lack it) is lifted because
# `requiresHqCli` is at least 5.345.210; this check keeps that true (US-035).
grep -q 'hq runners create --runner subagent' "$ROOT/.claude/skills/conduct-runners/SKILL.md" \
  || fail '/conduct-runners no longer documents the board record'
floor="$(sed -n 's/^requiresHqCli: *">=\([0-9][0-9.]*\)".*/\1/p' "$ROOT/core/core.yaml")"
[ -n "$floor" ] || fail 'requiresHqCli floor not found in core/core.yaml'
[ "$(printf '%s\n%s\n' 5.345.210 "$floor" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = 5.345.210 ] \
  || fail "requiresHqCli $floor is below 5.345.210, the first hq-cli with hq runners"

echo "default helper scripts make no hq call other than runners link"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/core/scripts/lib" "$T/core/settings" "$T/personal/settings" "$T/bin" "$T/agents" \
  "$T/workspace/sessions/s1" "$T/.claude/skills/conduct/roles" "$T/.claude/agents" \
  "$T/core/workers/public/dev-team/backend-dev/skills"
cp "$ROOT/core/scripts/conduct-standing.sh" "$ROOT/core/scripts/lanes-workers.sh" \
  "$ROOT/core/scripts/hq-session.sh" "$ROOT/core/scripts/conduct-runner-resolve.sh" "$T/core/scripts/"
cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$ROOT/core/scripts/lib/session-id.sh" "$T/core/scripts/lib/"
cp "$ROOT/core/settings/orchestrator.yaml" "$T/core/settings/"
cp "$ROOT/.claude/skills/conduct/roles/"*.md "$T/.claude/skills/conduct/roles/"
printf 'session_id: s1\n' > "$T/workspace/sessions/s1/meta.yaml"
printf 'workers:\n  - id: "backend-dev"\n    path: "core/workers/public/dev-team/backend-dev/"\n    status: "active"\n' \
  > "$T/core/workers/registry.yaml"
printf 'id: backend-dev\nskills:\n  - id: implement-endpoint\n    file: skills/implement-endpoint.md\n' \
  > "$T/core/workers/public/dev-team/backend-dev/worker.yaml"
printf 'Add the /health endpoint.\n' > "$T/brief.md"

# Stub hq: logs every call; only `runners link` (or `lanes link`) succeeds. With STUB_CLOSE=1 it
# also answers the three close-of-existing calls.
cat > "$T/bin/hq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "${1:-}" in lanes|runners) group=1 ;; *) group=0 ;; esac
if [ "$group" = 1 ] && [ "${2:-}" = link ]; then echo '{"ok":true}'; exit 0; fi
if [ "${STUB_CLOSE:-}" = 1 ] && [ "$group" = 1 ]; then
  case "${2:-} ${4:-}" in
    "keep-alive --off") echo '{"ok":true}'; exit 0 ;;
    "show --json") echo '{"ok":true,"lane":{"state":"running"}}'; exit 0 ;;
    "interrupt --reason") echo '{"ok":true}'; exit 0 ;;
  esac
fi
printf '%s\n' "$*" >> "$STUB_BAD"
echo "stub hq: refused: $*" >&2
exit 1
STUB
chmod +x "$T/bin/hq"
export PATH="$T/bin:$PATH" HQ_BIN="$T/bin/hq" HQ_ROOT="$T" HQ_SESSION_ID=s1 HQ_CLAUDE_AGENTS_DIR="$T/agents"
export STUB_LOG="$T/hq.log" STUB_BAD="$T/hq.bad" HQ_CLI_CAPS_CACHE="$T/core-caps"
unset CLAUDE_PROJECT_DIR
: > "$STUB_LOG"
: > "$STUB_BAD"
C() { bash "$T/core/scripts/conduct-standing.sh" "$@"; }
W() { bash "$T/core/scripts/lanes-workers.sh" "$@"; }

# The stub is what the scripts would reach.
[ "$(command -v hq)" = "$T/bin/hq" ] || fail 'stub hq is not first on PATH'
hq runners create --probe >/dev/null 2>&1 && fail 'stub hq accepted runners create'
hq runners link list >/dev/null || fail 'stub hq refused runners link'
: > "$STUB_LOG"
: > "$STUB_BAD"

eq "$(C route --kind lookup | jq -r .runner)" subagent 'the shipped setting resolves to subagent'
eq "$(C route --kind answer | jq -r .route)" inline 'answer routes inline'
eq "$(C route --kind status | jq -r .route)" inline 'status routes inline'
eq "$(C route --kind small | jq -r .route)" subagent 'small task routes to a one-off subagent'
eq "$(C route --kind lookup | jq -r .route)" subagent 'lookup routes to a one-off subagent'
eq "$(C route --kind ongoing | jq -r .route)" subagent 'ongoing with no worker routes to a subagent'
eq "$(C route --kind small --worker backend-dev --company acme | jq -r .route)" standing-subagent 'worker task routes to a standing subagent'
eq "$(C route --kind ongoing --worker backend-dev --company acme | jq -r .route)" standing-subagent 'ongoing worker area routes to a standing subagent'
eq "$(C route --kind ongoing --outlives | jq -r .route)" child-session 'work that outlives the turn routes to a child session'
eq "$(C route --kind ongoing --worker backend-dev --company acme --outlives | jq -r .route)" child-session 'outliving worker work routes to a child session'
eq "$(C route --kind small --engine codex | jq -r .route)" needs-runners 'a non-Claude engine needs /conduct-runners'
eq "$(C route --kind small --worker backend-dev --company acme --engine codex | jq -r .route)" needs-runners 'a non-Claude worker task needs /conduct-runners'
C agent-type --worker backend-dev --company acme >/dev/null
rc=0; C send --worker backend-dev --company acme --brief-file "$T/brief.md" --no-story test >/dev/null 2>&1 || rc=$?
eq "$rc" 4 'send is refused under the default runner'
C list >/dev/null
C close >/dev/null
C close --dry-run >/dev/null

W setup --session-id s1 --workers 'frontend,qa' >/dev/null
W roles --session-id s1 >/dev/null
W template --role qa >/dev/null
W needs-qa --role frontend >/dev/null || true
[ -s "$T/workspace/orchestrator/conduct-subagents/s1/runs.json" ] || fail 'setup did not record standing subagents in runs.json'

lane_calls="$(grep -E '^(lanes|runners)( |$)' "$STUB_LOG" | grep -vE '^(lanes|runners) link( |$)' || true)"
[ -z "$lane_calls" ] || fail "default helpers ran a runner-lane command: $(printf '%s' "$lane_calls" | tr '\n' ';')"
# hq-session.sh probes `hq core --help` (read-only, to pick the CLI-hosted
# session store); the stub refuses it and the in-tree path runs. Any other
# hq call is new and has to be reviewed here.
other="$(grep -vE '^(lanes|runners) link( |$)' "$STUB_LOG" | grep -vxF 'core --help' || true)"
[ -z "$other" ] || fail "default helpers made an unexpected hq call: $(printf '%s' "$other" | tr '\n' ';')"

echo "default close ends this session's leftover runner lane and nothing else"
printf '{"schema":"conduct-standing-lanes.v1","lanes":[{"worker":"backend-dev","company":"acme","lane":"OLD1","opened_at":"2026-01-01T00:00:00Z"}]}\n' \
  > "$T/workspace/sessions/s1/conduct-standing-lanes.json"
: > "$STUB_LOG"
: > "$STUB_BAD"
STUB_CLOSE=1 C close >/dev/null || fail 'default close of a leftover lane failed'
grep -qx 'runners keep-alive OLD1 --off --json' "$STUB_LOG" || fail 'default close did not turn keep-alive off'
grep -q '^runners interrupt OLD1 --reason ' "$STUB_LOG" || fail 'default close did not interrupt the leftover lane'
bad="$(grep -vxF 'core --help' "$STUB_BAD" || true)"
[ -z "$bad" ] || fail "default close made a refused hq call: $(printf '%s' "$bad" | tr '\n' ';')"
extra="$(grep -vE '^runners (keep-alive OLD1 --off|show OLD1|interrupt OLD1)( |$)' "$STUB_LOG" | grep -vxF 'core --help' || true)"
[ -z "$extra" ] || fail "default close made a call other than closing the lane: $(printf '%s' "$extra" | tr '\n' ';')"
eq "$(C list)" '[]' 'default close cleared the record'

echo "conduct-default-no-runner-calls: ok"
