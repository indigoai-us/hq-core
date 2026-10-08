#!/usr/bin/env bash
# Shared payload and entrypoint helpers for the two HP-5 benchmark views.

bench_runtime_valid() {
  case "${1:-}" in claude|codex|grok|hq-agent) return 0 ;; *) return 1 ;; esac
}

bench_runtime_agent_root() {
  local source_root="${1:-}" destination="${2:-}" path
  [ -n "$source_root" ] && [ -n "$destination" ] || return 2
  mkdir -p "$destination" || return 1
  if git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local -a paths=()
    for path in core .claude AGENTS.md; do
      [ -e "$source_root/$path" ] && paths+=("$path")
    done
    git -C "$source_root" archive HEAD "${paths[@]}" | tar -x -C "$destination" || return 1
  else
    for path in core .claude AGENTS.md; do
      [ -e "$source_root/$path" ] || continue
      cp -a "$source_root/$path" "$destination/" || return 1
    done
  fi
  mkdir -p "$destination/companies/hp11-benchmark" "$destination/workspace" || return 1
  if [ ! -f "$destination/companies/hp11-benchmark/CLAUDE.md" ]; then
    printf '# HP-11 benchmark company fixture\n' > "$destination/companies/hp11-benchmark/CLAUDE.md"
  fi
}

bench_runtime_contract_version() {
  local root="${1:-}" version=""
  if [ -f "$root/core/core.yaml" ]; then
    version="$(awk -F: '/^[[:space:]]*agentSessionContractVersion[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$root/core/core.yaml")"
  fi
  version="${version//\"/}"
  case "$version" in ''|*[!0-9]*) version=1 ;; esac
  printf '%s' "$version"
}

bench_runtime_payload() {
  local runtime="${1:-}" event="${2:-}" root="${3:-}" sid="${4:-}" tool="${5:-Bash}"
  local command_text="${6:-echo bench}" prompt="${7:-bench prompt}" contract
  case "$runtime" in
    hq-agent)
      contract="$(bench_runtime_contract_version "$root")"
      jq -nc --argjson cv "$contract" --arg sid "$sid" --arg prompt "$prompt" \
        '{contractVersion:$cv,agentUid:"agt_hp11_bench",companySlug:"hp11-benchmark",
          channel:"task",convKey:("hp11-bench:"+$sid),messageText:$prompt,
          provider:"codex",sender:{verified:true}}'
      ;;
    claude|codex|grok)
      case "$event" in
        PreToolUse)
          jq -nc --arg sid "$sid" --arg ev "$event" --arg t "$tool" --arg c "$command_text" --arg cwd "$root" \
            '{session_id:$sid,hook_event_name:$ev,tool_name:$t,cwd:$cwd,
              tool_input:(if $t=="Bash" then {command:$c,description:"bench"}
                          else {file_path:($cwd+"/workspace/bench-scratch.md"),content:"bench"} end),
              sessionId:$sid,hookEventName:$ev,toolName:$t,toolInput:(if $t=="Bash" then {command:$c,description:"bench"}
                          else {file_path:($cwd+"/workspace/bench-scratch.md"),content:"bench"} end)}'
          ;;
        PostToolUse)
          jq -nc --arg sid "$sid" --arg ev "$event" --arg t "$tool" --arg c "$command_text" --arg cwd "$root" \
            '{session_id:$sid,hook_event_name:$ev,tool_name:$t,cwd:$cwd,
              tool_input:(if $t=="Bash" then {command:$c,description:"bench"}
                          else {file_path:($cwd+"/workspace/bench-scratch.md"),content:"bench"} end),
              tool_response:(if $t=="Bash" then {stdout:"bench\n",stderr:"",interrupted:false}
                             else {filePath:($cwd+"/workspace/bench-scratch.md"),success:true} end),
              sessionId:$sid,hookEventName:$ev,toolName:$t,toolInput:(if $t=="Bash" then {command:$c,description:"bench"}
                          else {file_path:($cwd+"/workspace/bench-scratch.md"),content:"bench"} end),
              toolResponse:(if $t=="Bash" then {stdout:"bench\n",stderr:"",interrupted:false}
                             else {filePath:($cwd+"/workspace/bench-scratch.md"),success:true} end)}'
          ;;
        UserPromptSubmit)
          jq -nc --arg sid "$sid" --arg ev "$event" --arg cwd "$root" --arg p "$prompt" \
            '{session_id:$sid,hook_event_name:$ev,cwd:$cwd,prompt:$p,
              sessionId:$sid,hookEventName:$ev}'
          ;;
        SessionStart)
          jq -nc --arg sid "$sid" --arg ev "$event" --arg cwd "$root" \
            '{session_id:$sid,hook_event_name:$ev,source:"startup",cwd:$cwd,
              sessionId:$sid,hookEventName:$ev}'
          ;;
        AgentSession)
          jq -nc --arg sid "$sid" --arg ev "$event" --arg cwd "$root" --arg p "$prompt" \
            '{session_id:$sid,hook_event_name:$ev,cwd:$cwd,prompt:$p}'
          ;;
        *) jq -nc --arg sid "$sid" --arg ev "$event" --arg cwd "$root" \
            '{session_id:$sid,hook_event_name:$ev,cwd:$cwd,sessionId:$sid,hookEventName:$ev}' ;;
      esac
      ;;
    *) return 2 ;;
  esac
}

bench_runtime_dispatch() {
  local runtime="${1:-}" root="${2:-}" event="${3:-}" payload="${4:-}"
  local out="${5:-}" err="${6:-}" home="${7:-${HOME:-/tmp}}" timeout="${8:-30}"
  local response run_dir rc=0
  case "$runtime" in
    claude)
      printf '%s' "$payload" | perl -e 'alarm shift; exec @ARGV' "$timeout" \
        env BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$root" HQ_ROOT="$root" \
        bash "$root/.claude/hooks/master-hook.sh" "$event" > "$out" 2> "$err" || rc=$?
      ;;
    codex)
      printf '%s' "$payload" | perl -e 'alarm shift; exec @ARGV' "$timeout" \
        env BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$root" HQ_ROOT="$root" \
        bash "$root/.codex/hooks/hq-codex-hook-adapter.sh" > "$out" 2> "$err" || rc=$?
      ;;
    grok)
      printf '%s' "$payload" | perl -e 'alarm shift; exec @ARGV' "$timeout" \
        env BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$root" HQ_ROOT="$root" \
        GROK_WORKSPACE_ROOT="$root" GROK_HOOK_EVENT="$event" \
        bash "$root/.grok/hooks/hq-grok-hook-adapter.sh" > "$out" 2> "$err" || rc=$?
      ;;
    hq-agent)
      response="${out}.response.json"
      printf '%s' "$payload" | perl -e 'alarm shift; exec @ARGV' "$timeout" \
        env BASH_ENV=/dev/null CLAUDE_PROJECT_DIR="$root" HQ_ROOT="$root" \
        HQ_AGENT_WORKDIR="$root" HQ_AGENT_SESSION_SKIP_PROVIDER=1 HOME="$home" \
        bash "$root/core/scripts/hq-agent-session.sh" > "$response" 2> "$err" || rc=$?
      run_dir="$(jq -r '.runDir // empty' "$response" 2>/dev/null || true)"
      if [ -n "$run_dir" ] && [ -f "$run_dir/system.txt" ]; then
        cat "$run_dir/system.txt" > "$out"
      else
        jq -r '.text // empty' "$response" > "$out" 2>/dev/null || :
      fi
      ;;
    *) return 2 ;;
  esac
  return "$rc"
}
