#!/usr/bin/env bash
# Receipt-backed enforcement for requirements that prompt priority cannot prove.
# UserPromptSubmit declares requirements and surfaces instruction conflicts;
# PostToolUse records reads; PreToolUse gates governed outbound actions.

set -uo pipefail

INPUT="$(cat 2>/dev/null || echo '{}')"
command -v jq >/dev/null 2>&1 || exit 0

EVENT="${1:-$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)}"
ROOT="${CLAUDE_PROJECT_DIR:-${HQ_ROOT:-}}"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SID" ] || exit 0

STATE_DIR="$ROOT/workspace/orchestrator/policy-enforcement"
STATE="$STATE_DIR/${SID}.json"
POLICIES="$STATE_DIR/${SID}.policies.tsv"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
ACTIVE_LOCK=""
cleanup_active_lock() {
  [ -z "$ACTIVE_LOCK" ] || { rm -f "$ACTIVE_LOCK/pid" "$ACTIVE_LOCK/time"; rmdir "$ACTIVE_LOCK" 2>/dev/null || true; }
}
trap cleanup_active_lock EXIT

json_block() {
  jq -nc --arg reason "$1" '{decision:"block",reason:$reason}'
}

atomic_update() {
  local filter="$1" tmp lock attempts rc owner age now moved owner_alive created
  shift
  lock="${STATE}.lock"
  attempts=0
  until mkdir "$lock" 2>/dev/null; do
    owner=""
    [ -f "$lock/pid" ] && IFS= read -r owner < "$lock/pid" || true
    owner_alive=2
    case "$owner" in ''|*[!0-9]*) ;; *) if kill -0 "$owner" 2>/dev/null; then owner_alive=1; else owner_alive=0; fi ;; esac
    now="$(date +%s 2>/dev/null || printf 0)"
    created="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || printf '%s' "$now")"
    if [ -f "$lock/time" ]; then
      IFS= read -r created < "$lock/time" || created=0
      case "$created" in *[!0-9]*|'') created=0 ;; esac
    fi
    age=$((now - created))
    if [ "$owner_alive" -eq 0 ] || [ "$age" -gt 300 ]; then
      moved="${lock}.stale.$$"
      if mv "$lock" "$moved" 2>/dev/null; then rm -rf "$moved" 2>/dev/null || true; fi
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.02
  done
  ACTIVE_LOCK="$lock"
  printf '%s\n' "$$" > "$lock/pid"
  date +%s > "$lock/time" 2>/dev/null || true
  tmp="$(mktemp)"
  rc=0
  jq "$@" "$filter" "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" || rc=$?
  [ "$rc" -eq 0 ] || rm -f "$tmp"
  rm -f "$lock/pid" "$lock/time"
  rmdir "$lock" 2>/dev/null || true
  ACTIVE_LOCK=""
  return "$rc"
}

extract_prompt() {
  printf '%s' "$INPUT" | jq -r '.prompt // .message // .user_prompt // empty' 2>/dev/null
}

canonical_path() {
  local path="$1" dir base
  case "$path" in /*) ;; *) path="$ROOT/$path" ;; esac
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [ -d "$dir" ] || return 1
  printf '%s/%s' "$(cd "$dir" 2>/dev/null && pwd -P)" "$base"
}

gate_policy_data() {
  node - "$1" <<'NODE'
const fs = require("fs");
const text = fs.readFileSync(process.argv[2], "utf8");
const fm = text.match(/^---\s*\n([\s\S]*?)\n---(?:\s|$)/);
if (!fm) { console.log(JSON.stringify({ valid: false, error: "frontmatter missing" })); process.exit(0); }
const lines = fm[1].split(/\r?\n/), idx = lines.findIndex((line) => /^gate:\s*(?:#.*)?$/.test(line));
const enforcement = (lines.find((line) => /^enforcement:\s*/.test(line)) || "").replace(/^enforcement:\s*/, "").trim().replace(/^['"]|['"]$/g, "").toLowerCase();
if (enforcement !== "gate" && idx < 0) { console.log(JSON.stringify({ valid: false, error: "gate block missing" })); process.exit(0); }
if (idx < 0) { console.log(JSON.stringify({ valid: false, error: "enforcement: gate requires a gate block" })); process.exit(0); }
const fields = {}, blockLists = {};
for (let i = idx + 1; i < lines.length; i++) {
  const line = lines[i]; if (!/^\s+\S/.test(line)) break;
  const m = line.match(/^\s{2}([A-Za-z_]+):\s*(.*?)\s*$/);
  if (m) { fields[m[1]] = m[2].replace(/\s+#.*$/, "").replace(/^['"]|['"]$/g, ""); continue; }
  const item = line.match(/^\s{4}-\s*(.*?)\s*$/);
  if (item) { const prev = lines.slice(0, i).reverse().find((x) => /^\s{2}[A-Za-z_]+:\s*$/.test(x)); if (!prev) { console.log(JSON.stringify({valid:false,error:"orphan list item"})); process.exit(0); } const key = prev.match(/^\s{2}([A-Za-z_]+)/)[1]; (blockLists[key] ||= []).push(item[1].replace(/^['"]|['"]$/g, "")); continue; }
  if (/^\s{2}\S/.test(line)) { console.log(JSON.stringify({valid:false,error:"malformed gate field"})); process.exit(0); }
}
const allowed = new Set(["tools", "bash", "requires", "freshness", "override"]);
const unknown = Object.keys(fields).find((key) => !allowed.has(key));
if (unknown) { console.log(JSON.stringify({valid:false,error:`unknown gate field ${unknown}`})); process.exit(0); }
function list(key) { const raw = fields[key]; if (blockLists[key]) return blockLists[key]; if (raw === undefined || raw === "") return []; const match = raw.match(/^\[(.*)\]$/); if (!match) return [raw.replace(/^['"]|['"]$/g, "")]; return match[1].split(",").map((x) => x.trim().replace(/^['"]|['"]$/g, "")).filter(Boolean); }
const tools = list("tools"), bash = list("bash"), requires = list("requires"), freshness = fields.freshness, override = fields.override || "allowed";
const facts = new Set(["sending_account_confirmed", "recipients_confirmed", "draft_approved", "humanize_passed", "enforcement_observed"]);
if (!tools.length && !bash.length) { console.log(JSON.stringify({valid:false,error:"gate needs tools or bash"})); process.exit(0); }
if (!requires.length || requires.some((fact) => !facts.has(fact))) { console.log(JSON.stringify({valid:false,error:"gate requires invalid or missing facts"})); process.exit(0); }
if (tools.some((name) => !name || /[?\[\]]/.test(name)) || bash.some((prefix) => !prefix)) { console.log(JSON.stringify({valid:false,error:"gate tools or bash entries are invalid"})); process.exit(0); }
if (freshness !== undefined && !/^\d+$/.test(freshness)) { console.log(JSON.stringify({valid:false,error:"gate freshness must be whole minutes"})); process.exit(0); }
if (!new Set(["allowed", "denied"]).has(override)) { console.log(JSON.stringify({valid:false,error:"gate override is invalid"})); process.exit(0); }
process.stdout.write(JSON.stringify({valid:true,tools,bash,requires,freshness:freshness || "",override}));
NODE
}

enforce_gate_policies() {
  local tool="$1" command="$2" id scope path enf excerpt kind data matches entry fact freshness override missing token token_at token_epoch now age
  [ -s "$POLICIES" ] || return 0
  while IFS=$'\t' read -r id scope path enf excerpt kind; do
    [ "$enf" = gate ] || continue
    [ -n "$path" ] && [ -f "$path" ] || { json_block "POLICY ENFORCEMENT BLOCK: gate policy $id cannot be inspected safely."; return 2; }
    data="$(gate_policy_data "$path" 2>/dev/null)"
    if [ -z "$data" ] || ! printf '%s' "$data" | jq -e '.valid == true' >/dev/null 2>&1; then
      entry="$(printf '%s' "$data" | jq -r '.error // "gate schema is invalid"' 2>/dev/null || printf 'gate schema is invalid')"
      json_block "POLICY ENFORCEMENT BLOCK: gate policy $id is invalid ($entry). Repair the policy before delivery."
      return 2
    fi
    matches="$(printf '%s' "$data" | jq -r --arg tool "$tool" --arg command "$command" '
      ([.tools[]? | gsub("\\*"; ".*") as $pattern | ($tool | test("^" + $pattern + "$"))] | any) or
      ([.bash[]? as $prefix | select($command | startswith($prefix))] | length > 0)')"
    [ "$matches" = true ] || continue
    freshness="$(printf '%s' "$data" | jq -r '.freshness')"
    override="$(printf '%s' "$data" | jq -r '.override')"
    missing=""
    while IFS= read -r fact; do
      [ -n "$fact" ] || continue
      if [ -n "$freshness" ]; then
        if ! hq_gate_fact_present "$fact" "$freshness"; then
          missing="${missing}${missing:+, }$fact"
        fi
      elif ! hq_gate_fact_present "$fact"; then
        missing="${missing}${missing:+, }$fact"
      fi
    done < <(printf '%s' "$data" | jq -r '.requires[]')
    if [ -n "$missing" ]; then
      token="$(hq_hook_state_dir "$ROOT")/gate-overrides/$SID/$id.json"
      token_at=""
      if [ "$override" = allowed ] && [ -f "$token" ] \
         && jq -e --arg id "$id" --arg sid "$SID" '
           .policy_id == $id and .session_id == $sid and .source == "askuserquestion" and
           (.answer | type == "string" and test("^(override once|allow once)$";"i")) and
           (.confirmed_at | type == "string")
         ' "$token" >/dev/null 2>&1; then
        token_at="$(jq -r '.confirmed_at' "$token")"
        token_epoch="$(date -u -d "$token_at" +%s 2>/dev/null || true)"
        case "$token_epoch" in *[!0-9]*|'') token_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$token_at" +%s 2>/dev/null || true)" ;; esac
        now="$(date -u +%s 2>/dev/null || printf 0)"
        case "$token_epoch:$now" in *[!0-9:]*|:*) token_epoch="" ;; esac
        if [ -n "$token_epoch" ]; then
          age=$((now - token_epoch))
          if [ "$age" -ge 0 ] && [ "$age" -lt 300 ]; then rm -f "$token"; continue; fi
        fi
        rm -f "$token"
      fi
      json_block "POLICY ENFORCEMENT BLOCK: gate policy $id requires ${freshness:+fresh }facts $missing; no valid one-time override is available."
      return 2
    fi
  done < "$POLICIES"
  return 0
}

candidate_reads_exact_path() {
  local required="$1" required_abs
  required_abs="$(canonical_path "$required" 2>/dev/null || true)"
  if [ "$CANDIDATE_KIND" = "path" ]; then
    local used_abs
    used_abs="$(canonical_path "$PATH_USED" 2>/dev/null || true)"
    [ -n "$required_abs" ] && [ -f "$required_abs" ] && [ -r "$required_abs" ] && [ "$used_abs" = "$required_abs" ]
    return
  fi
  jq -nc --arg command "$CANDIDATE" --arg relative "$required" --arg absolute "$required_abs" \
    '{command:$command,targets:[$relative,$absolute]|map(select(length>0))}' | node -e '
      let s=""; process.stdin.on("data",c=>s+=c).on("end",()=>{
        const x=JSON.parse(s), text=x.command, tokens=[]; let word="", quote="", escaped=false;
        const push=()=>{if(word){tokens.push({value:word,redir:false});word="";}};
        for(let i=0;i<text.length;i++){const c=text[i]; if(escaped){word+=c;escaped=false;continue;} if(c==="\\"&&quote!=="\x27"){escaped=true;continue;} if(quote){if(c===quote)quote="";else word+=c;continue;} if(c==="\""||c==="\x27"){quote=c;continue;} if(/\s/.test(c)){push();continue;} if(c===">"){push();tokens.push({value:">",redir:true});if(text[i+1]===">"){tokens[tokens.length-1].value=">>";i++;}continue;} if(c==="<"||c==="|"||c===";"){push();tokens.push({value:c,redir:true});continue;} word+=c;} push();
        if(!tokens.length||!new Set(["cat","sed","head","tail","less","rg","grep"]).has(tokens[0].value))process.exit(1);
        let ok=false; for(let i=1;i<tokens.length;i++){if(tokens[i].redir)break;if(x.targets.includes(tokens[i].value)){ok=true;break;}}
        process.exit(ok?0:1);
      });'
}

case "$EVENT" in
  UserPromptSubmit)
    PROMPT="$(extract_prompt)"
    REQUIRED_SKILLS="$(printf '%s\n' "$PROMPT" | awk '
      {
        line=tolower($0)
        if (line ~ /(^|[^a-z])(broadcast|post an? update to slack|slack broadcast)([^a-z]|$)/) print "work-broadcast"
        if (match(line, /(use|run|load|read)[[:space:]]+(the[[:space:]]+)?[a-z0-9_-]+[[:space:]]+skill/)) {
          s=substr(line,RSTART,RLENGTH); sub(/^(use|run|load|read)[[:space:]]+(the[[:space:]]+)?/,"",s); sub(/[[:space:]]+skill.*/,"",s); print s
        }
      }
    ' | awk 'NF && !seen[$0]++' | jq -Rsc 'split("\n") | map(select(length>0))')"
    [ -n "$REQUIRED_SKILLS" ] || REQUIRED_SKILLS='[]'

    POLICY_SKILLS='[]'
    POLICY_BRIEFS='[]'
    if [ -s "$POLICIES" ]; then
      POLICY_SKILLS="$(while IFS=$'\t' read -r id scope path enf excerpt kind; do
        [ -n "$path" ] && [ -f "$path" ] || continue
        sed -n 's/^required-skill:[[:space:]]*//p' "$path" | tr ',' '\n'
      done < "$POLICIES" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF&&!seen[$0]++' | jq -Rsc 'split("\n")|map(select(length>0))')"
      POLICY_BRIEFS="$(while IFS=$'\t' read -r id scope path enf excerpt kind; do
        [ -n "$path" ] && [ -f "$path" ] || continue
        sed -n 's/^required-brief:[[:space:]]*//p' "$path"
      done < "$POLICIES" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF&&!seen[$0]++' | jq -Rsc 'split("\n")|map(select(length>0))')"
    fi
    REQUIRED_SKILLS="$(jq -nc --argjson a "$REQUIRED_SKILLS" --argjson b "$POLICY_SKILLS" '$a+$b|unique')"

    ATTACHMENTS="$(printf '%s' "$INPUT" | jq -c '
      [(.attachments[]? | .path? // .file_path? // .name? // empty),
       (.files[]? | .path? // .file_path? // .name? // empty)]
      | map(select(type=="string" and length>0)) | unique' 2>/dev/null || echo '[]')"
    PROMPT_PATHS='[]'
    DECLARES_BRIEF=0
    if printf '%s' "$PROMPT" | grep -Eqi '\b(attached|attachment)\b.{0,40}\b(brief|spec|document|file)\b|\b(brief|spec)\b.{0,40}\b(attached|attachment)\b'; then
      DECLARES_BRIEF=1
      PROMPT_PATHS="$( { printf '%s\n' "$PROMPT" | grep -Eo '[/A-Za-z0-9_.-]+\.(md|txt|pdf|docx)' 2>/dev/null || true; } | jq -Rsc 'split("\n") | map(select(length>0)) | unique')"
    fi
    BRIEFS="$(jq -nc --argjson a "$ATTACHMENTS" --argjson p "$PROMPT_PATHS" --argjson d "$POLICY_BRIEFS" '$a + $p + $d | unique')"
    if [ "$DECLARES_BRIEF" -eq 1 ]; then
      if [ "$(printf '%s' "$BRIEFS" | jq 'length')" -eq 0 ]; then
        BRIEFS='["<declared-attachment-without-resolvable-path>"]'
      fi
    fi

    INSTRUCTIONS="$(printf '%s' "$INPUT" | jq -r '[.prompt?,.message?,.user_prompt?,.system_prompt?,.developer_instructions?,(.instructions[]?)] | map(select(type=="string")) | join("\n")' 2>/dev/null || printf '%s' "$PROMPT")"
    HARD_JSON='[]'
    if [ -s "$POLICIES" ]; then
      HARD_JSON="$(while IFS=$'\t' read -r id scope path enf excerpt kind; do
        [ "$enf" = "hard" ] || continue
        rule="$excerpt"
        if [ -n "$path" ] && [ -f "$path" ]; then
          full="$(awk '/^## Rule[[:space:]]*$/{on=1;next} on&&/^## /{exit} on{print}' "$path" 2>/dev/null)"
          [ -n "$full" ] && rule="$full"
        fi
        jq -nc --arg id "$id" --arg text "$rule" '{id:$id,text:$text}'
      done < "$POLICIES" | jq -sc '.')"
    fi
    CONFLICT_INPUT="$(jq -nc --argjson policies "$HARD_JSON" --arg instructions "$INSTRUCTIONS" \
      '{policies:$policies,instructions:$instructions}')"
    CONFLICTS="$(printf '%s' "$CONFLICT_INPUT" | node -e '
      let p=""; process.stdin.on("data",c=>p+=c).on("end",()=>{
        const input=JSON.parse(p||"{}"), policies=input.policies||[], ins=input.instructions||"";
        const stop=new Set("a an and are as at be by for from in is it of on or that the this to with your you".split(" "));
        const polarity=s=>/\b(never|must not|do not|forbid(?:den)?|banned)\b/i.test(s)?-1:/\b(always|must|required|require|shall)\b/i.test(s)?1:0;
        const toks=s=>new Set((s.toLowerCase().match(/[a-z0-9_-]+/g)||[]).filter(x=>x.length>2&&!stop.has(x)&&!/^(never|must|always|required|require|shall|not|dont|do)$/.test(x)));
        const statements=s=>s.split(/\n|(?<=[.!?])\s+/).map(x=>x.trim()).filter(x=>polarity(x));
        const out=[];
        for(const pol of policies) for(const a of statements(pol.text)) for(const b of statements(ins)) {
          if(polarity(a)===polarity(b)) continue;
          const A=toks(a),B=toks(b), shared=[...A].filter(x=>B.has(x));
          const score=shared.length/Math.max(1,Math.min(A.size,B.size));
          if(shared.length>=3 && score>=0.45) out.push({policyId:pol.id,policy:a,instruction:b,sharedTerms:shared});
        }
        process.stdout.write(JSON.stringify(out.slice(0,8)));
      });' 2>/dev/null)"
    [ -n "$CONFLICTS" ] || CONFLICTS='[]'

    jq -nc --arg prompt "$PROMPT" --argjson skills "$REQUIRED_SKILLS" --argjson briefs "$BRIEFS" --argjson conflicts "$CONFLICTS" \
      '{prompt:$prompt,requiredSkills:$skills,briefs:$briefs,receipts:{skills:[],briefs:[]},conflicts:$conflicts}' > "$STATE"

    CONTEXT=""
    if [ "$(jq '.requiredSkills|length' "$STATE")" -gt 0 ] || [ "$(jq '.briefs|length' "$STATE")" -gt 0 ]; then
      CONTEXT="GOVERNANCE RECEIPTS REQUIRED before any governed outbound action. Required skills: $(jq -r '.requiredSkills|join(", ")' "$STATE"). Declared briefs: $(jq -r '.briefs|join(", ")' "$STATE"). Read each source first; prompt acknowledgement is not a receipt."
    fi
    if [ "$(jq '.conflicts|length' "$STATE")" -gt 0 ]; then
      SUMMARY="$(jq -r '.conflicts[] | "- " + .policyId + ": policy says [" + .policy + "] but instruction says [" + .instruction + "]"' "$STATE")"
      CONTEXT="${CONTEXT}${CONTEXT:+$'\n\n'}INSTRUCTION CONFLICTS SURFACED - resolve these before execution:\n$SUMMARY"
    fi
    [ -n "$CONTEXT" ] && jq -nc --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
    ;;

  PostToolUse)
    [ -f "$STATE" ] || exit 0
    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
    PATH_USED="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // empty')"
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    SUCCESS="$(printf '%s' "$INPUT" | jq -r '
      if (.tool_response.is_error? == true or .tool_response.error? != null or
          .tool_response.success? == false or ((.tool_response.exit_code? // 0) != 0))
      then "false" else "true" end')"
    [ "$SUCCESS" = "true" ] || exit 0
    if [ "$TOOL" = "AskUserQuestion" ]; then
      PROOF_ROWS="$(printf '%s' "$INPUT" | jq -r '
        (.tool_input.questions // []) as $questions |
        (.tool_response.answers // .tool_response.responses // []) as $answers |
        [range(0; ([($questions|length),($answers|length)]|min)) as $i |
          ($questions[$i].header // "") as $header |
          ($answers[$i].answer // $answers[$i].label // $answers[$i] // "") as $answer |
          select(($header | test("^gate-fact:(sending_account_confirmed|recipients_confirmed|draft_approved)$") and ($answer|type)=="string" and ($answer|test("^(confirmed|yes|approved)$";"i"))) or
                 ($header | test("^gate-override:[A-Za-z0-9][A-Za-z0-9._-]*$") and ($answer|type)=="string" and ($answer|test("^(override once|allow once)$";"i")))) |
          (if $header | startswith("gate-fact:") then "fact" else "override" end) + "\t" + ($header | sub("^gate-(fact|override):";"")) + "\t" + $answer] | .[]' 2>/dev/null || true)"
      if [ -n "$PROOF_ROWS" ]; then
        HOOK_STATE_DIR="$(. "$ROOT/core/scripts/hook-lib.sh" && hq_hook_state_dir "$ROOT")"
        umask 077
        while IFS=$'\t' read -r proof_kind name answer; do
          [ -n "$name" ] || continue
          if [ "$proof_kind" = fact ]; then
            PROOF_DIR="$HOOK_STATE_DIR/gate-facts/$SID/proofs"
          else
            PROOF_DIR="$HOOK_STATE_DIR/gate-overrides/$SID"
          fi
          mkdir -p "$PROOF_DIR" 2>/dev/null || continue
          PROOF_TMP="$(mktemp "$PROOF_DIR/.proof.XXXXXX" 2>/dev/null)" || continue
          PROOF_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
          if [ "$proof_kind" = fact ]; then
            jq -nc --arg fact "$name" --arg sid "$SID" --arg answer "$answer" --arg confirmed_at "$PROOF_TIME" \
              '{fact:$fact,session_id:$sid,source:"askuserquestion",answer:$answer,confirmed_at:$confirmed_at}' > "$PROOF_TMP"
          else
            jq -nc --arg policy_id "$name" --arg sid "$SID" --arg answer "$answer" --arg confirmed_at "$PROOF_TIME" \
              '{policy_id:$policy_id,session_id:$sid,source:"askuserquestion",answer:$answer,confirmed_at:$confirmed_at}' > "$PROOF_TMP"
          fi
          chmod 600 "$PROOF_TMP" && mv -f "$PROOF_TMP" "$PROOF_DIR/$name.json" || rm -f "$PROOF_TMP"
        done <<< "$PROOF_ROWS"
      fi
      exit 0
    fi
    CANDIDATE=""
    CANDIDATE_KIND=""
    case "$TOOL" in
      Read|Grep|read_file|read_text_file) CANDIDATE="$PATH_USED"; CANDIDATE_KIND="path" ;;
      Bash|Shell|exec_command|run_terminal_command)
        if [ -n "$CMD" ] && ! printf '%s' "$CMD" | grep -Fq '||' \
           && printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(cat|sed|head|tail|less|rg|grep)[[:space:]]'; then
          CANDIDATE="$CMD"
          CANDIDATE_KIND="command"
        fi
        ;;
    esac
    [ -n "$CANDIDATE" ] || exit 0
    while IFS= read -r skill; do
      [ -n "$skill" ] || continue
      expected_skill="$(canonical_path "$ROOT/.claude/skills/$skill/SKILL.md" 2>/dev/null || true)"
      if [ -n "$expected_skill" ] && [ "$CANDIDATE_KIND" = "path" ] \
         && [ "$(basename "$CANDIDATE")" = "SKILL.md" ] \
         && [ -f "$CANDIDATE" ] && [ -r "$CANDIDATE" ] \
         && [ "$(canonical_path "$CANDIDATE" 2>/dev/null || true)" = "$expected_skill" ]; then
        atomic_update '(.receipts.skills // []) += [$v] | .receipts.skills |= unique' --arg v "$skill"
      elif [ -n "$expected_skill" ] && [ "$CANDIDATE_KIND" = "command" ] \
         && candidate_reads_exact_path "$ROOT/.claude/skills/$skill/SKILL.md"; then
        atomic_update '(.receipts.skills // []) += [$v] | .receipts.skills |= unique' --arg v "$skill"
      fi
    done < <(jq -r '.requiredSkills[]?' "$STATE")
    while IFS= read -r brief; do
      [ -n "$brief" ] || continue
      case "$brief" in '<declared-'*) continue ;; esac
      if candidate_reads_exact_path "$brief"; then
        atomic_update '(.receipts.briefs // []) += [$v] | .receipts.briefs |= unique' --arg v "$brief"
      fi
    done < <(jq -r '.briefs[]?' "$STATE")
    ;;

  PreToolUse)
    if [ ! -f "$STATE" ] && [ -s "$POLICIES" ]; then
      jq -nc '{prompt:"",requiredSkills:[],briefs:[],receipts:{skills:[],briefs:[]},conflicts:[]}' > "$STATE"
    fi
    [ -f "$STATE" ] || exit 0

    # A Bash policy can first match on the outbound command itself. The policy
    # selector invokes this gate again after persisting that match, so merge its
    # declarative requirements before deciding whether this action may proceed.
    if [ -s "$POLICIES" ]; then
      POLICY_SKILLS="$(while IFS=$'\t' read -r id scope path enf excerpt kind; do
        [ -n "$path" ] && [ -f "$path" ] || continue
        sed -n 's/^required-skill:[[:space:]]*//p' "$path" | tr ',' '\n'
      done < "$POLICIES" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF&&!seen[$0]++' | jq -Rsc 'split("\n")|map(select(length>0))')"
      POLICY_BRIEFS="$(while IFS=$'\t' read -r id scope path enf excerpt kind; do
        [ -n "$path" ] && [ -f "$path" ] || continue
        sed -n 's/^required-brief:[[:space:]]*//p' "$path"
      done < "$POLICIES" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF&&!seen[$0]++' | jq -Rsc 'split("\n")|map(select(length>0))')"
      if ! atomic_update '.requiredSkills = ((.requiredSkills // []) + $skills | unique) | .briefs = ((.briefs // []) + $briefs | unique)' \
        --argjson skills "${POLICY_SKILLS:-[]}" --argjson briefs "${POLICY_BRIEFS:-[]}"; then
        json_block "POLICY ENFORCEMENT BLOCK: policy requirements could not be refreshed safely; retry the outbound action."
        exit 2
      fi
    fi

    TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
    OUTBOUND=0
    if printf '%s' "$TOOL" | grep -Eqi '(^|_)(send|post|broadcast|message|email|dm)($|_)'; then OUTBOUND=1; fi
    if printf '%s' "$CMD" | grep -Eqi '(^|[^[:alnum:]_])hq[[:space:]]+(cowork[[:space:]]+)?dm([^[:alnum:]_]|$)|chat\.postMessage|send-broadcast|slack\.com/api/chat\.postMessage|/broadcasts'; then OUTBOUND=1; fi
    if [ -s "$POLICIES" ] && awk -F '\t' '$4 == "gate" { found=1 } END { exit !found }' "$POLICIES"; then
      . "$ROOT/core/scripts/hook-lib.sh" || {
        json_block "POLICY ENFORCEMENT BLOCK: the gate fact checker is unavailable; retry after repairing the installation."
        exit 2
      }
      HQ_ROOT="$ROOT"
      HQ_SESSION_ID="$SID"
      export HQ_ROOT
      export HQ_SESSION_ID
      if ! enforce_gate_policies "$TOOL" "$CMD"; then exit 2; fi
    fi
    [ "$OUTBOUND" -eq 1 ] || exit 0

    MISSING_SKILLS="$(jq -r '[.requiredSkills[]? as $x | select((.receipts.skills // []) | index($x) | not) | $x] | join(", ")' "$STATE")"
    MISSING_BRIEFS="$(jq -r '[.briefs[]? as $x | select((.receipts.briefs // []) | index($x) | not) | $x] | join(", ")' "$STATE")"
    if [ -n "$MISSING_SKILLS$MISSING_BRIEFS" ]; then
      json_block "POLICY ENFORCEMENT BLOCK: outbound action lacks required receipts. Missing skills: ${MISSING_SKILLS:-none}. Missing briefs: ${MISSING_BRIEFS:-none}. Read the exact SKILL.md/brief, then retry."
      exit 2
    fi

    BODY="$(printf '%s' "$INPUT" | jq -r '[.tool_input.message?,.tool_input.text?,.tool_input.body?,.tool_input.content?,.tool_input.details?,.tool_input.prompt?] | map(select(type=="string" and length>0)) | join("\n")')"
    if [ -z "$BODY" ] && [ -n "$CMD" ]; then
      BODY="$(printf '%s' "$CMD" | node -e '
        let s=""; process.stdin.on("data",c=>s+=c).on("end",()=>{
          const assignments=new Map();
          for(const m of s.matchAll(/(?:^|[;\n&|])[ \t]*([A-Za-z_][A-Za-z0-9_]*)=(?:(["\x27])([\s\S]*?)\2|([^\s;|&]+))/g)) assignments.set(m[1],m[3]??m[4]??"");
          const args=[...s.matchAll(/(?:--data(?:-raw)?|--message|--text|-d)(?:=|[ \t]+)(?:["\x27])?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(?:["\x27])?/g)];
          for(let i=args.length-1;i>=0;i--){const name=args[i][1];if(assignments.has(name)){process.stdout.write(assignments.get(name));return;}}
        });' 2>/dev/null || true)"
    fi
    if [ -n "$BODY" ] && jq -e '.requiredSkills | index("work-broadcast") != null' "$STATE" >/dev/null 2>&1; then
      LINES="$(printf '%s\n' "$BODY" | awk 'NF{n++} END{print n+0}')"
      if [ "$LINES" -gt 4 ]; then
        json_block "POLICY ENFORCEMENT BLOCK: work-broadcast content has $LINES non-empty lines; the delivery contract allows at most 4. Put detail in the linked artifact and retry with the short broadcast."
        exit 2
      fi
    fi

    if [ -z "$BODY" ] && jq -e '.requiredSkills | index("work-broadcast") != null' "$STATE" >/dev/null 2>&1; then
      json_block "POLICY ENFORCEMENT BLOCK: work-broadcast content is not mechanically inspectable. Supply the message in a structured tool field or a literal MESSAGE/BODY/TEXT shell assignment, then retry."
      exit 2
    fi

    if [ -s "$POLICIES" ]; then
      while IFS=$'\t' read -r id scope path enf excerpt kind; do
        [ -n "$path" ] && [ -f "$path" ] || continue
        forbid="$(sed -n 's/^delivery-forbid-regex:[[:space:]]*//p' "$path" | head -n1)"
        require="$(sed -n 's/^delivery-require-regex:[[:space:]]*//p' "$path" | head -n1)"
        if [ -z "$BODY" ] && { [ -n "$forbid" ] || [ -n "$require" ]; }; then
          json_block "POLICY ENFORCEMENT BLOCK: deterministic delivery gate $id cannot inspect this outbound body. Supply content in a structured tool field or literal MESSAGE/BODY/TEXT shell assignment."
          exit 2
        fi
        if [ -n "$forbid" ]; then
          printf '' | grep -Eq "$forbid" 2>/dev/null
          regex_rc=$?
          if [ "$regex_rc" -eq 2 ]; then
            json_block "POLICY ENFORCEMENT BLOCK: deterministic gate $id has an invalid delivery-forbid-regex. Repair the policy before delivery."
            exit 2
          fi
        fi
        if [ -n "$require" ]; then
          printf '' | grep -Eq "$require" 2>/dev/null
          regex_rc=$?
          if [ "$regex_rc" -eq 2 ]; then
            json_block "POLICY ENFORCEMENT BLOCK: deterministic gate $id has an invalid delivery-require-regex. Repair the policy before delivery."
            exit 2
          fi
        fi
        if [ -n "$forbid" ] && printf '%s' "$BODY" | grep -Eq "$forbid" 2>/dev/null; then
          json_block "POLICY ENFORCEMENT BLOCK: outbound content violates deterministic gate $id (forbidden pattern)."
          exit 2
        fi
        if [ -n "$require" ] && ! printf '%s' "$BODY" | grep -Eq "$require" 2>/dev/null; then
          json_block "POLICY ENFORCEMENT BLOCK: outbound content violates deterministic gate $id (required pattern missing)."
          exit 2
        fi
      done < "$POLICIES"
    fi
    ;;
esac

exit 0
