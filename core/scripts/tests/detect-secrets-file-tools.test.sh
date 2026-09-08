#!/usr/bin/env bash
# hq-core: public
# Regression test for detect-secrets.sh file-tool coverage (2026-09-07).
#
# Before this change the hook scanned only Bash commands, and policy told agents
# to "use the Write tool instead" on a false positive — so a real secret written
# to a file was never scanned. These cases pin: Write/Edit/MultiEdit/NotebookEdit
# content is scanned with the same patterns, benign content passes, and the
# block message never echoes the matched value.
#
# The sample key is assembled from fragments so this file itself never contains
# a key-shaped literal (the hook now scans file writes too).

set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "detect-secrets-file-tools: skipped (jq missing)"; exit 0; }

ROOT="$(git rev-parse --show-toplevel)"
HOOK="$ROOT/.claude/hooks/detect-secrets.sh"
# Well-known AWS documentation example key, split so the literal never appears.
SECRET="AKIA""IOSFODNN7""EXAMPLE"
FAIL=0

run() { # run <payload-json> -> prints "rc|stderr"
  local rc=0 err
  err="$(printf '%s' "$1" | bash "$HOOK" 2>&1 1>/dev/null)" || rc=$?
  printf '%s|%s' "$rc" "$err"
}
expect_block() { # <label> <payload>
  local out; out="$(run "$2")"
  if [ "${out%%|*}" != "2" ]; then echo "FAIL: $1: expected exit 2, got ${out%%|*}" >&2; FAIL=1; fi
  if ! grep -q 'AWS access key' <<<"${out#*|}"; then echo "FAIL: $1: message did not name the pattern" >&2; FAIL=1; fi
  if grep -q "${SECRET:0:4}" <<<"${out#*|}"; then echo "FAIL: $1: message leaked the matched value" >&2; FAIL=1; fi
}
expect_allow() { # <label> <payload>
  local out; out="$(run "$2")"
  if [ "${out%%|*}" != "0" ]; then echo "FAIL: $1: expected exit 0, got ${out%%|*} (${out#*|})" >&2; FAIL=1; fi
}

expect_block "Write with secret" \
  "$(jq -n --arg s "$SECRET" '{tool_name:"Write", tool_input:{file_path:"/tmp/x/settings.env", content:("AWS_ACCESS_KEY_ID=" + $s + "\n")}}')"
expect_block "Edit with secret" \
  "$(jq -n --arg s "$SECRET" '{tool_name:"Edit", tool_input:{file_path:"/tmp/x/a.md", old_string:"KEY=", new_string:("KEY=" + $s)}}')"
expect_block "MultiEdit with secret in second edit" \
  "$(jq -n --arg s "$SECRET" '{tool_name:"MultiEdit", tool_input:{file_path:"/tmp/x/a.md", edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:("token " + $s)}]}}')"
expect_block "NotebookEdit with secret" \
  "$(jq -n --arg s "$SECRET" '{tool_name:"NotebookEdit", tool_input:{notebook_path:"/tmp/x/n.ipynb", new_source:("key = \"" + $s + "\"")}}')"

expect_allow "Write benign policy text" \
  "$(jq -n '{tool_name:"Write", tool_input:{file_path:"/tmp/x/p.md", content:"## Rule\n\nNever paste an OpenAI key (shape: sk-...) into a command. Use the vault.\n"}}')"
expect_allow "Write with a comment line that mentions a key shape" \
  "$(jq -n '{tool_name:"Write", tool_input:{file_path:"/tmp/x/s.sh", content:"# pattern: AKIA followed by 16 chars\necho ok\n"}}')"
expect_allow "Edit benign" \
  "$(jq -n '{tool_name:"Edit", tool_input:{file_path:"/tmp/x/a.md", old_string:"x", new_string:"y"}}')"
expect_allow "Unrelated tool ignored" \
  "$(jq -n '{tool_name:"Read", tool_input:{file_path:"/tmp/x/a.md"}}')"

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "detect-secrets-file-tools: ok"
