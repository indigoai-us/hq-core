#!/usr/bin/env bash
set -euo pipefail
HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ROOT="$TMPROOT/hq"
mkdir -p "$ROOT/core/policies" "$ROOT/core/scripts/lib" "$ROOT/.claude/hooks"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/"
ln -s "$HQ_SRC/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/eval-trigger.sh"
ln -s "$HQ_SRC/core/scripts/lib/forwarder.sh" "$ROOT/core/scripts/lib/forwarder.sh"
ln -s "$HQ_SRC/core/scripts/lib/hq-cli-floor.sh" "$ROOT/core/scripts/lib/hq-cli-floor.sh"
cp "$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh" "$ROOT/.claude/hooks/"
printf '#!/bin/bash\nprintf "git push\\n"\n' > "$ROOT/core/scripts/derive-trigger-facts.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
for enforcement in soft hard; do
for style in lf crlf bom-lf bom-crlf; do
  python3 - "$ROOT/core/policies/parity.md" "$style" "$enforcement" <<'PY'
import pathlib, sys
data = b'---\nid: parity\nwhen: git && push\non: [UserPromptSubmit]\nenforcement: soft\n---\n\n## Rule\n\nENCODING_SUMMARY_MARKER\n'
data = data.replace(b'enforcement: soft', b'enforcement: ' + sys.argv[3].encode())
if 'crlf' in sys.argv[2]: data = data.replace(b'\n', b'\r\n')
if sys.argv[2].startswith('bom'): data = b'\xef\xbb\xbf' + data
pathlib.Path(sys.argv[1]).write_bytes(data)
PY
  output="$(jq -cn --arg sid "encoding-$enforcement-$style" --arg cwd "$ROOT" '{session_id:$sid,hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"git push"}' | env -i PATH="$PATH" HOME="$HOME" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" 2>&1)"
  grep -Fq 'ENCODING_SUMMARY_MARKER' <<<"$output" || fail "$style: missing injected summary: $output"
  python3 - "$ROOT" "$enforcement" <<'PY'
import pathlib, sys
files = list((pathlib.Path(sys.argv[1]) / 'workspace/orchestrator/hook-state/policy-trigger-cache').glob('*.cache'))
assert len(files) == 1, files
rows = files[0].read_text().split('\n')
fields = rows[1].split('\x1c')
assert fields[0] == 'parity', fields
assert fields[3] == 'git && push', fields
assert fields[4].strip() == 'UserPromptSubmit', fields
assert fields[5] == sys.argv[2], fields
assert fields[11] == 'ENCODING_SUMMARY_MARKER', fields
PY
  for engine in node jq; do
    validation="$(jq -cn --arg path "$ROOT/core/policies/parity.md" --rawfile content "$ROOT/core/policies/parity.md" '{tool_name:"Write",tool_input:{file_path:$path,content:$content}}' | HQ_ROOT="$ROOT" HQ_HOOK_ENGINE="$engine" bash "$HQ_SRC/.claude/hooks/validate-policy-frontmatter.sh" 2>&1)" || fail "$style/$engine: validator rejected policy: $validation"
    [ -z "$validation" ] || fail "$style/$engine: unexpected validation output: $validation"
  done
  if [ "$style" = lf ]; then baseline="$output"; else
    [ "$output" = "$baseline" ] || fail "$style: injected text differs from LF"
  fi
  lint="$(HQ_ROOT="$ROOT" bash "$HQ_SRC/core/scripts/lint-policy-triggers.sh" --strict "$ROOT/core/policies")" || fail "$style: lint failed: $lint"
  grep -Fq 'policies scanned: 1 | malformed when: 0' <<<"$lint" || fail "$style: unexpected lint findings: $lint"
done
done
printf 'PASS: LF, CRLF and BOM policy lint and injected summaries agree\n'
