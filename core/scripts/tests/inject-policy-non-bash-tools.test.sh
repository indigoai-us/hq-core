#!/usr/bin/env bash
# hq-core: public
# Regression contract: policy `when:` triggers fire on PostToolUse for the
# non-Bash text tools, from the action text only.
#   Agent/Task                            -> description + prompt
#   Write/Edit/MultiEdit/NotebookEdit     -> file path + new content (bounded)
#   Read                                  -> file path
# Other tools, non-Bash PreToolUse, tool output, old_string and content past
# the bound never contribute. The hook stays fail-open (exit 0).
# The registry must also dispatch the injector for these tools on PostToolUse.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOOK="${HQ_TEST_INJECT_POLICY_HOOK:-$ROOT/.claude/hooks/inject-policy-on-trigger.sh}"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/core/policies" "$TMP/bin" "$TMP/log"

# Stub `hq`: the forwarder execs `hq core derive-trigger-facts <event>` with
# the payload on stdin. The stub prints `always` plus every word token of
# tool_input.command and logs what it was handed, so the test can see the
# exact action text the hook derived for each tool.
cat > "$TMP/bin/hq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'hq 5.342.5'
  exit 0
fi
payload="$(cat)"
command_text="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
printf '%s' "$command_text" > "$STUB_LOG_DIR/command"
printf '%s' "$payload" | jq -r 'if has("tool_response") then "present" else "absent" end' > "$STUB_LOG_DIR/response"
facts="$(printf '%s' "$command_text" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '\n' | grep -E '^[a-z][a-z0-9_-]+$' | sort -u | tr '\n' ' ' || true)"
printf 'always %s\n' "$facts"
EOF
chmod +x "$TMP/bin/hq"

mkpolicy() { # <slug> <when>
  printf -- '---\nid: %s\nenforcement: soft\nwhen: %s\n---\n## Rule\nFixture rule for %s.\n' "$1" "$2" "$1" \
    > "$TMP/core/policies/$1.md"
}
mkpolicy agent-prompt-rule zebrafinch
mkpolicy agent-description-rule quokka
mkpolicy write-path-rule ocelot
mkpolicy write-content-rule narwhal
mkpolicy edit-new-rule pangolin
mkpolicy edit-old-rule axolotl
mkpolicy multiedit-rule wombat
mkpolicy notebook-rule capybara
mkpolicy read-path-rule tapir
mkpolicy read-output-rule manatee
mkpolicy glob-rule gecko
mkpolicy bound-head-rule lemur
mkpolicy bound-tail-rule okapi

failures=0
check() {
  if [ "$2" = 1 ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); fi
}
run_hook() { # <output-file> <payload>
  local rc=0
  printf '%s' "$2" | PATH="$TMP/bin:$PATH" STUB_LOG_DIR="$TMP/log" HQ_ROOT="$TMP" CLAUDE_PROJECT_DIR="$TMP" \
    HQ_HARNESS=claude HQ_POLICY_TOOL_STOP_WORDS= bash "$HOOK" > "$1" 2>"$1.stderr" || rc=$?
  printf '%s' "$rc" > "$1.rc"
}
payload() { # <sid> <event> <tool> <tool_input-json> [tool_response]
  jq -cn --arg sid "$1" --arg ev "$2" --arg tool "$3" --argjson input "$4" --arg resp "${5:-ok}" \
    '{session_id:$sid,hook_event_name:$ev,tool_name:$tool,cwd:"/tmp",tool_input:$input,tool_response:$resp}'
}
has() { grep -q -- "$2" "$1" && echo 1 || echo 0; }
lacks() { grep -q -- "$2" "$1" && echo 0 || echo 1; }
exit0() { [ "$(cat "$1.rc")" = 0 ] && echo 1 || echo 0; }

# Agent: prompt and description are both trigger text.
run_hook "$TMP/agent" "$(payload s-agent PostToolUse Agent '{"description":"Quokka audit","prompt":"Check the zebrafinch module for drift.","subagent_type":"general-purpose"}')"
check 'Agent prompt word fires its policy' "$(has "$TMP/agent" agent-prompt-rule)"
check 'Agent description word fires its policy' "$(has "$TMP/agent" agent-description-rule)"
check 'Agent output is a PostToolUse additionalContext envelope' "$(jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' "$TMP/agent" >/dev/null 2>&1 && echo 1 || echo 0)"
check 'tool_response is not handed to the fact helper' "$(grep -qx absent "$TMP/log/response" && echo 1 || echo 0)"

# Dedupe: the same Agent call again in the same session prints no new line.
run_hook "$TMP/agent-again" "$(payload s-agent PostToolUse Agent '{"description":"Quokka audit","prompt":"Check the zebrafinch module for drift."}')"
check 'repeat Agent call is deduped for the session' "$(lacks "$TMP/agent-again" 'Fixture rule for agent-prompt-rule')"

# Task is the older name of the Agent tool.
run_hook "$TMP/task" "$(payload s-task PostToolUse Task '{"description":"plain","prompt":"Look at zebrafinch."}')"
check 'Task prompt word fires its policy' "$(has "$TMP/task" agent-prompt-rule)"

# Write: file path and new content.
run_hook "$TMP/write" "$(payload s-write PostToolUse Write '{"file_path":"/work/ocelot/plan.md","content":"The narwhal section."}')"
check 'Write file path fires its policy' "$(has "$TMP/write" write-path-rule)"
check 'Write content fires its policy' "$(has "$TMP/write" write-content-rule)"

# Edit: new_string counts, old_string does not.
run_hook "$TMP/edit" "$(payload s-edit PostToolUse Edit '{"file_path":"/work/a.txt","old_string":"axolotl","new_string":"pangolin"}')"
check 'Edit new_string fires its policy' "$(has "$TMP/edit" edit-new-rule)"
check 'Edit old_string does not fire' "$(lacks "$TMP/edit" edit-old-rule)"

# MultiEdit: every edit's new_string.
run_hook "$TMP/multiedit" "$(payload s-multi PostToolUse MultiEdit '{"file_path":"/work/b.txt","edits":[{"old_string":"x","new_string":"first"},{"old_string":"axolotl","new_string":"wombat"}]}')"
check 'MultiEdit later new_string fires its policy' "$(has "$TMP/multiedit" multiedit-rule)"
check 'MultiEdit old_string does not fire' "$(lacks "$TMP/multiedit" edit-old-rule)"

# NotebookEdit: notebook path plus new_source.
run_hook "$TMP/notebook" "$(payload s-nb PostToolUse NotebookEdit '{"notebook_path":"/work/c.ipynb","new_source":"capybara = 1"}')"
check 'NotebookEdit new_source fires its policy' "$(has "$TMP/notebook" notebook-rule)"

# Read: the file path only, never the file contents in tool_response.
run_hook "$TMP/read" "$(payload s-read PostToolUse Read '{"file_path":"/work/tapir/guide.md"}' 'manatee manatee manatee')"
check 'Read file path fires its policy' "$(has "$TMP/read" read-path-rule)"
check 'Read file contents do not fire' "$(lacks "$TMP/read" read-output-rule)"
check 'Read hands only the path to the fact helper' "$([ "$(cat "$TMP/log/command")" = /work/tapir/guide.md ] && echo 1 || echo 0)"

# No match: a text tool whose text names no policy word prints nothing.
run_hook "$TMP/nomatch" "$(payload s-nomatch PostToolUse Write '{"file_path":"/work/plain.txt","content":"nothing relevant here"}')"
check 'no-match Write prints nothing' "$([ ! -s "$TMP/nomatch" ] && echo 1 || echo 0)"
check 'no-match Write exits 0' "$(exit0 "$TMP/nomatch")"

# Unchanged scope: other tools and non-Bash PreToolUse stay skipped.
run_hook "$TMP/glob" "$(payload s-glob PostToolUse Glob '{"pattern":"gecko/**"}')"
check 'Glob stays skipped' "$([ ! -s "$TMP/glob" ] && echo 1 || echo 0)"
run_hook "$TMP/pre-write" "$(payload s-pre PreToolUse Write '{"file_path":"/work/ocelot.md","content":"narwhal"}')"
check 'non-Bash PreToolUse stays skipped' "$([ ! -s "$TMP/pre-write" ] && echo 1 || echo 0)"

# Oversized content: only a bounded slice is scanned.
jq -cn '{session_id:"s-big",hook_event_name:"PostToolUse",tool_name:"Write",cwd:"/tmp",
         tool_input:{file_path:"/work/big.md",content:("lemur " + ("x" * 200000) + " okapi")},tool_response:"ok"}' \
  > "$TMP/big.json"
run_hook "$TMP/big" "$(cat "$TMP/big.json")"
big_len="$(wc -c < "$TMP/log/command" | tr -d ' ')"
check 'oversized Write: word at the start fires' "$(has "$TMP/big" bound-head-rule)"
check 'oversized Write: word past the bound does not fire' "$(lacks "$TMP/big" bound-tail-rule)"
check "oversized Write: scanned text is bounded (got $big_len bytes)" "$([ "$big_len" -le 9300 ] && echo 1 || echo 0)"
check 'oversized Write exits 0' "$(exit0 "$TMP/big")"

# Fail-open: a malformed tool_input never fails the tool call.
run_hook "$TMP/malformed" '{"session_id":"s-bad","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":"not an object"}'
check 'malformed tool_input exits 0 with no output' "$([ ! -s "$TMP/malformed" ] && [ "$(cat "$TMP/malformed.rc")" = 0 ] && echo 1 || echo 0)"

# Registry: the injector is dispatched exactly once on PostToolUse for every
# text tool, and Bash still resolves to exactly one injector row (a second
# matching row would run the injector twice per Bash call).
for tool in Bash Agent Task Write Edit MultiEdit NotebookEdit Read; do
  wired="$(jq -r --arg t "$tool" '[.hooks.PostToolUse[] | select((.matcher // "") as $m | $m == "" or $m == "*" or ($t | test("^(" + $m + ")$"))) | .hooks[] | select(.id == "inject-policy-on-trigger")] | length' "$REGISTRY")"
  check "registry dispatches the injector exactly once on PostToolUse $tool (got $wired)" "$([ "$wired" -eq 1 ] && echo 1 || echo 0)"
done

# master-hook's policy-vocabulary prefilter tests the same bounded text the
# injector scans for a text tool, so a Read whose file contents hold a policy
# word (but whose path does not) skips the injector without starting it.
MH="$TMP/mh"
mkdir -p "$MH/.claude/hooks" "$MH/core/scripts/lib" "$MH/core/policies" "$MH/workspace/orchestrator/policy-trigger-state"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$ROOT/.claude/hooks/hook-timeout-watchdog.sh" "$ROOT/.claude/hooks/hook-gate.sh" "$MH/.claude/hooks/"
cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$ROOT/core/scripts/lib/trigger-fact-text.awk" "$MH/core/scripts/lib/"
printf 'hqVersion: "15.0.131"\n' > "$MH/core/core.yaml"
printf -- '---\nid: mh-word\non: [PostToolUse]\nenforcement: soft\nwhen: manatee\n---\n## Rule\nFixture.\n' > "$MH/core/policies/mh-word.md"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$MH/.claude/hooks/injector.sh"
chmod +x "$MH/.claude/hooks/injector.sh"
jq -n --argjson real "$(jq '[.hooks.PostToolUse[] | select(.hooks[].id == "inject-policy-on-trigger") | .matcher]' "$REGISTRY")" \
  '{hooks:{PostToolUse:[$real[] | {matcher:., hooks:[{id:"inject-policy-on-trigger",script:".claude/hooks/injector.sh",timeout:30,gated:false,prefilter:{policy_vocab:true}}]}]}}' \
  > "$MH/.claude/hooks/hook-registry.json"
: > "$MH/workspace/orchestrator/policy-trigger-state/mh-sid.txt"
run_master() { # <output-file> <tool> <tool_input-json> <tool_response>
  jq -cn --arg root "$MH" --arg tool "$2" --argjson input "$3" --arg resp "$4" \
    '{session_id:"mh-sid",hook_event_name:"PostToolUse",tool_name:$tool,cwd:$root,tool_input:$input,tool_response:$resp}' \
    | CLAUDE_PROJECT_DIR="$MH" HQ_ROOT="$MH" HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 HQ_HOOK_DEDUPE=0 \
      bash "$MH/.claude/hooks/master-hook.sh" PostToolUse > /dev/null 2> "$1" || true
}
run_master "$TMP/mh-read-body" Read '{"file_path":"/work/notes.md"}' 'manatee manatee manatee'
check 'master-hook skips the injector when only the Read contents hold a policy word' "$(has "$TMP/mh-read-body" 'skip inject-policy-on-trigger (policy-vocab)')"
run_master "$TMP/mh-read-path" Read '{"file_path":"/work/manatee/notes.md"}' 'plain'
check 'master-hook runs the injector when the Read path holds a policy word' "$(has "$TMP/mh-read-path" 'run inject-policy-on-trigger')"
run_master "$TMP/mh-edit-old" Edit '{"file_path":"/work/a.txt","old_string":"manatee","new_string":"plain"}' 'ok'
check 'master-hook skips the injector when only old_string holds a policy word' "$(has "$TMP/mh-edit-old" 'skip inject-policy-on-trigger (policy-vocab)')"
run_master "$TMP/mh-agent" Agent '{"description":"audit","prompt":"Check the manatee module."}' 'report'
check 'master-hook runs the injector when the Agent prompt holds a policy word' "$(has "$TMP/mh-agent" 'run inject-policy-on-trigger')"
run_master "$TMP/mh-bash-out" Bash '{"command":"echo done"}' 'manatee'
check 'master-hook still tests Bash output for policy words' "$(has "$TMP/mh-bash-out" 'run inject-policy-on-trigger')"

# A row with both policy_vocab and re keeps the full-text prefilter: a Read
# whose policy word appears only in the tool output still runs the injector.
jq -n --argjson real "$(jq '[.hooks.PostToolUse[] | select(.hooks[].id == "inject-policy-on-trigger") | .matcher]' "$REGISTRY")" \
  '{hooks:{PostToolUse:[$real[] | {matcher:., hooks:[{id:"inject-policy-on-trigger",script:".claude/hooks/injector.sh",timeout:30,gated:false,prefilter:{policy_vocab:true,re:"manatee"}}]}]}}' \
  > "$MH/.claude/hooks/hook-registry.json"
run_master "$TMP/mh-read-body-re" Read '{"file_path":"/work/notes.md"}' 'manatee manatee manatee'
check 'master-hook policy_vocab plus re row still runs on a Read word only in the output' "$(has "$TMP/mh-read-body-re" 'run inject-policy-on-trigger')"

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'all inject-policy non-Bash tool checks passed\n'
