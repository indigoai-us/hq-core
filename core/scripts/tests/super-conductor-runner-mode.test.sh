#!/usr/bin/env bash
# /super-conductor and /overnight route on conduct.runner (US-005).
# Default mode (subagent) reads the conduct link and each adopted session's
# runs.json, and never creates a lane: `hq runners create` and
# `hq runners message` are named only under an advanced-mode heading.
# The Executive opens its lanes with the conductor as senior in either mode,
# so both modes read those lanes and their pending questions, read-only.
# `hq runners link` stays the mailbox in both modes.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
ON="$ROOT/.claude/skills/overnight/SKILL.md"
SWEEP="$ROOT/core/scripts/super-conductor-sweep-check.mjs"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
for f in "$SC" "$ON" "$SWEEP"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# Section of a markdown file from a heading line (exact) to the next heading
# of the same or higher level.
section() {
  awk -v h="$2" '
    BEGIN { lvl = length(h) - length(substr(h, index(h, " "))) }
    $0 == h { on = 1; print; next }
    on && /^#+ / { n = index($0, " ") - 1; if (n <= lvl) exit }
    on { print }
  ' "$1"
}

# --- super-conductor: resolver and Runner mode section ---
grep -Fq 'Bash(sh core/scripts/conduct-runner-resolve.sh:*)' "$SC" \
  || bad "super-conductor allowed-tools lacks the shared resolver"
RM="$(section "$SC" '## Runner mode')"
[ -n "$RM" ] || bad "super-conductor has no '## Runner mode' section"
grep -Fq 'sh core/scripts/conduct-runner-resolve.sh --session-id' <<< "$RM" \
  || bad "Runner mode does not call the shared resolver"
grep -Fq 'once at the start of every wakeup' <<< "$RM" || bad "Runner mode must resolve once per wakeup"
grep -Fq 'hq runners link list' <<< "$RM" || bad "default mode must read hq runners link list"
grep -Fq 'hq runners link read' <<< "$RM" || bad "default mode must read hq runners link read"
grep -Fq 'conduct-subagents/<session-id>/runs.json' <<< "$RM" \
  || bad "default mode must read each adopted session's runs.json"
# Senior lanes are read in both modes, read-only (owner requirement).
RM_DEFAULT="$(awk '/^- Advanced mode/ { skip = 1 } skip && /^$/ { skip = 0 } !skip { print }' <<< "$RM")"
for cmd in 'hq runners list --json --senior session:<this session id>' 'hq runners show' \
  'hq runners questions list --status pending'; do
  grep -Fq "$cmd" <<< "$RM_DEFAULT" || bad "Runner mode must read $cmd outside the advanced bullet"
done
grep -Fq 'needs_decision' <<< "$RM_DEFAULT" || bad "Runner mode must read the Executive lanes' needs_decision questions"
grep -Fq 'never creates, messages, stops or reaps a lane' <<< "$(tr '\n' ' ' <<< "$RM_DEFAULT" | tr -s ' ')" \
  || bad "Runner mode must keep default-mode lane reads read-only"
grep -Fq 'Do not run `hq runners list`' <<< "$RM" && bad "Runner mode still forbids hq runners list in default mode"
grep -Fq 'Bash(hq runners show:*)' "$SC" || bad "super-conductor allowed-tools lacks hq runners show"
grep -Fq 'Bash(hq runners questions:*)' "$SC" || bad "super-conductor allowed-tools lacks hq runners questions"

# --- super-conductor: lane registration only under the advanced heading ---
S6B="$(section "$SC" '## Step 6b: Route work, with Work Mesh ownership')"
[ -n "$S6B" ] || bad "Step 6b section missing"
ADV="$(section "$SC" '### Advanced mode (conduct.runner runner)')"
[ -n "$ADV" ] || bad "Step 6b has no '### Advanced mode (conduct.runner runner)' heading"
DEFAULT_6B="$(awk '/^### Advanced mode \(conduct.runner runner\)$/ { exit } { print }' <<< "$S6B")"
if grep -Eq 'hq (runners|lanes) create' <<< "$DEFAULT_6B"; then
  bad "Step 6b default path still registers work with hq runners create"
fi
grep -Fq 'hq runners create --runner subagent' <<< "$ADV" \
  || bad "advanced mode must keep hq runners create --runner subagent"
grep -Fq 'runs.json' <<< "$DEFAULT_6B" || bad "Step 6b default path must record in runs.json"
grep -Fq 'hq runners list --json --senior session:<this session id>' <<< "$DEFAULT_6B" \
  || bad "Step 6b default sweep must list the Executive's senior lanes"
grep -Fq 'hq runners link read --link <link>' <<< "$DEFAULT_6B" || bad "Step 6b default sweep must read lane reports"
grep -Fq 'unknown child merely' <<< "$DEFAULT_6B" || bad "Step 6b default sweep must adopt Executive lanes as children"
# Outside the advanced subsection, hq runners create appears nowhere.
outside="$(awk '
  /^### Advanced mode \(conduct.runner runner\)$/ { skip = 1; next }
  skip && /^#{1,3} / { skip = 0 }
  !skip { print }
' "$SC")"
if grep -Eq 'hq (runners|lanes) create --runner' <<< "$outside"; then
  bad "hq runners create --runner appears outside the advanced-mode subsection"
fi
# Any other hq runners create mention (Executive signal lanes) is marked advanced.
while IFS= read -r ln; do
  [ -z "$ln" ] && continue
  ctx="$(sed -n "$((ln > 2 ? ln - 2 : 1)),${ln}p" "$SC")"
  grep -Fqi 'advanced' <<< "$ctx" \
    || bad "line $ln names hq runners create outside an advanced-mode context"
done <<< "$(awk '
  /^### Advanced mode \(conduct.runner runner\)$/ { skip = 1; next }
  skip && /^#{1,3} / { skip = 0 }
  !skip && /hq (runners|lanes) create/ { print NR }
' "$SC")"

# --- Step 8: a pending lane question is surfaced in default mode ---
S8="$(section "$SC" '## Step 8: Everything, always, here — the continuous decision queue')"
[ -n "$S8" ] || bad "Step 8 section missing"
LQ="$(awk '/^- Lane questions/ { on = 1 } on && /^- / && !/^- Lane questions/ { exit } on { print }' <<< "$S8")"
[ -n "$LQ" ] || bad "Step 8 has no Lane questions bullet"
grep -Fq 'hq runners questions list --status pending' <<< "$LQ" || bad "Step 8 must list pending lane questions"
grep -Fiq 'both modes' <<< "$LQ" || bad "Step 8 lane questions must apply in both modes"
grep -Fiq 'advanced mode only' <<< "$LQ" && bad "Step 8 still limits lane questions to advanced mode"
grep -Fq "'senior_lanes'" "$SWEEP" || bad "sweep-check must sweep senior_lanes in every wakeup"
grep -Fq '`senior_lanes`' "$SC" || bad "sweep targets in the skill must include senior_lanes"

# --- area brief first line ---
grep -Fq 'first line is `/conduct` in default mode and `/conduct-runners`' "$SC" \
  || bad "area brief first line must be /conduct (default) or /conduct-runners (advanced)"
grep -Fq 'accepts `/conduct`, `/conduct-runners`' "$SC" \
  || bad "brief-first-line check must accept /conduct and /conduct-runners"

# --- sweep target ---
grep -Fq '`subagent_runs`' "$SC" || bad "sweep targets must include subagent_runs"
grep -Fq "'subagent_runs'" "$SWEEP" || bad "sweep-check script must sweep subagent_runs"

# --- status board ---
REND="$(section "$SC" '## Rendering')"
grep -Fq 'runs.json' <<< "$REND" || bad "Rendering must build default rows from runs.json"
grep -Fq '4 subagent rows and 1 child row' <<< "$REND" \
  || bad "Rendering must state the default-mode board example (4 subagent rows, 1 child row)"
REND_DEFAULT="$(awk '/^- Default mode/ { on = 1 } on && /^- Advanced mode/ { exit } on { print }' <<< "$REND")"
grep -Fq 'lane row per' <<< "$REND_DEFAULT" || bad "Rendering default mode must show a row per Executive lane"
grep -Fq 'hq runners list --json --senior session:<this session id>' <<< "$REND_DEFAULT" \
  || bad "Rendering default mode must read the senior lane list"

# --- link mailbox kept ---
for cmd in 'hq runners link list' 'hq runners link read' 'hq runners link send' 'Bash(hq runners link:*)'; do
  grep -Fq "$cmd" "$SC" || bad "super-conductor lost $cmd"
done

# --- overnight ---
grep -Fq 'sh core/scripts/conduct-runner-resolve.sh --session-id' "$ON" \
  || bad "overnight must resolve the runner with the shared resolver"
OADV="$(section "$ON" '### Advanced mode (conduct.runner runner)')"
[ -n "$OADV" ] || bad "overnight has no advanced-mode heading"
grep -Fq 'hq runners message <lane> --text' <<< "$OADV" \
  || bad "overnight advanced mode must route with hq runners message"
grep -Fq 'hq runners list --json' <<< "$OADV" \
  || bad "overnight advanced mode must list lanes with hq runners list --json"
o_outside="$(awk '
  /^### Advanced mode \(conduct.runner runner\)$/ { skip = 1; next }
  skip && /^#{1,3} / { skip = 0 }
  !skip { print }
' "$ON")"
if grep -Eq 'hq (runners|lanes) message <lane> --text' <<< "$o_outside"; then
  bad "overnight routes with hq runners message outside the advanced heading"
fi
if grep -Eq 'hq (runners|lanes) list --json' <<< "$o_outside"; then
  bad "overnight lists lanes with hq runners list --json outside the advanced heading"
fi
grep -Fq 'SendMessage' <<< "$o_outside" || bad "overnight default mode must route to subagents with SendMessage"
grep -Fq 'runs.json' <<< "$o_outside" || bad "overnight default mode must read runs.json"
grep -Fq 'Bash(hq runners link:*)' "$ON" || bad "overnight lost the hq runners link mailbox"
grep -Fq 'hq runners link send --child' "$ON" || bad "overnight lost hq runners link send"

[ "$fail" -eq 0 ] || exit 1
echo "super-conductor runner mode: ok"
