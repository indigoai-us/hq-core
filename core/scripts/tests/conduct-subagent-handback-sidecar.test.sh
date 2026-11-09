#!/usr/bin/env bash
# Regression (feedback_49f72048): a /conduct subagent's hand-back must be
# readable by the parent. The Agent tool's own transcript (<agent-id>.output
# JSONL under ~/.claude/tasks/) grows to many MB and the Read tool refuses it,
# so a parent that only had that file could not write its final report.
#
# Guards on the subagent dispatch contract in dispatch.md:
#   1. The subagent prompt asks for a small plain-text report.md beside the
#      envelope, with a line cap.
#   2. The envelope has a size cap and long test/build output goes to a
#      sidecar log named from the envelope, never inlined.
#   3. The closing reply names the report path.
#   4. Completion handling reads report.md and the envelope, and says never to
#      Read the harness .output transcript.
#   5. A missing report is a failed delivery, handled like a missing envelope.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MODULE="$ROOT/.claude/skills/conduct/dispatch.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$MODULE" ] || fail "missing $MODULE"

# Prose wraps at 80 columns, so collapse runs of whitespace (including newlines)
# to one space before matching phrases.
section="$(awk '/^## Subagent dispatch$/{p=1} /^## /&&!/^## Subagent dispatch$/{if(p)exit} p' "$MODULE" | tr -s '[:space:]' ' ')"
[ -n "$section" ] || fail 'dispatch.md lost the "## Subagent dispatch" section'

# 1. report.md sidecar with a line cap
printf '%s' "$section" | grep 'report\.md' >/dev/null || fail 'subagent prompt does not ask for a report.md sidecar'
printf '%s' "$section" | grep -E 'at most [0-9]+ lines to <report path>' >/dev/null || fail 'report.md has no line cap'

# 2. envelope size cap and sidecar log for long output
printf '%s' "$section" | grep -E 'envelope under [0-9]+ KB' >/dev/null || fail 'envelope has no size cap'
printf '%s' "$section" | grep -E 'log file beside the envelope' >/dev/null || fail 'long test output is not routed to a sidecar log'
printf '%s' "$section" | grep 'never inline it' >/dev/null || fail 'prompt does not forbid inlining long output in the envelope'

# 3. closing reply names the report path
printf '%s' "$section" | grep 'names the envelope path and the report path' >/dev/null || fail 'closing reply does not name the report path'

# 4. completion reads report + envelope, never the harness .output transcript
# shellcheck disable=SC2016 # Match literal Markdown backticks; no shell expansion intended.
printf '%s' "$section" | grep -E 'read `report\.md` and the envelope file' >/dev/null || fail 'completion step does not read report.md'
printf '%s' "$section" | grep 'Never Read the harness' >/dev/null || fail 'completion step does not forbid reading the harness transcript'
printf '%s' "$section" | grep '\.output' >/dev/null || fail 'completion step does not name the .output transcript file'
printf '%s' "$section" | grep 'feedback_49f72048' >/dev/null || fail 'completion step does not cite the originating row'

# 5. missing report is a failed delivery
printf '%s' "$section" | grep 'A missing envelope or' >/dev/null || fail 'a missing report is not treated as a failed delivery'
printf '%s' "$section" | grep 'asking for both files' >/dev/null || fail 'resume does not ask for both files'

printf '%s' "$section" | grep 'Name the report path' >/dev/null || fail 'brief does not define report path'
printf '%s' "$section" | grep 'envelope path, report path, worktree' >/dev/null || fail 'run record omits report path'

# 6. Regression (feedback_01e64023): the Agent tool's built-in subagent
# instructions tell a child not to write report/summary .md files, so subagents
# refused to write report.md and the report came only in the closing reply. No
# hook refuses the path (workspace/ is open to an unbound subagent); the brief
# prompt must say the parent requires report.md and that this overrides the
# default.
printf '%s' "$section" | grep -E 'requires this file' >/dev/null || fail 'prompt does not say the parent requires report.md'
printf '%s' "$section" | grep -E 'overrides any default' >/dev/null || fail 'prompt does not override the default against writing report .md files'
printf '%s' "$section" | grep -E 'only (file|path) outside' >/dev/null || fail 'prompt does not limit the override to the named paths'

# 7. Regression: the Write tool itself can refuse a subagent's report.md
# ("Subagents should return findings as text, not write report files"), and the
# brief's override cannot lift a tool refusal. The prompt must route a refused
# write to the closing reply without working around the tool, and the parent
# must rebuild report.md from that reply without resuming the subagent.
printf '%s' "$section" | grep -E 'If the Write tool itself refuses the report file' >/dev/null || fail 'prompt does not cover a Write tool refusal of the report'
printf '%s' "$section" | grep -E 'do not retry it through Bash or under another name' >/dev/null || fail 'prompt does not forbid working around a refused report write'
printf '%s' "$section" | grep -E 'put the report in that reply' >/dev/null || fail 'prompt does not route a refused report to the closing reply'
printf '%s' "$section" | grep -E 'write `report\.md` yourself from that reply and do not resume the subagent' >/dev/null || fail 'parent does not rebuild report.md after a refused write'
echo "conduct-subagent-handback-sidecar: ok (report.md sidecar with line cap, envelope size cap, sidecar log, parent reads report+envelope and never the harness .output transcript)"
