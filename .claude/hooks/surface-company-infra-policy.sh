#!/bin/bash
# surface-company-infra-policy.sh — PreToolUse(Bash) hook.
#
# THE GAP THIS CLOSES:
#   Company policies are injected at SessionStart for the company known *at
#   start* (.claude/hooks/inject-policy-on-trigger.sh). When a company is
#   bound LATER in the session (e.g. `hq-session.sh set company_slug <co>`,
#   or working straight into a company task), nothing re-surfaces that
#   company's hard rules. An agent can then run company infra/deploy/credential
#   commands blind to hard policy — e.g. attempting an `sst deploy` with a
#   local AWS profile instead of the mandated `hq secrets exec` path, and
#   giving up at NoCredentials. (Real incident: a company cloud-infra deploy.)
#
#   hq-session.sh already emits the company hard-policy block on bind (for the
#   bind moment). THIS hook is the just-in-time backstop: when an
#   infra/credential command is about to run and a company is bound, surface
#   that company's deploy/credential hard policies right then.
#
# Input: PreToolUse JSON on stdin —
#   {"session_id":"abc","tool_name":"Bash","tool_input":{"command":"sst deploy ..."}}
# Output: a <company-policy-reminder> block on stdout when matched, else nothing.
# Dedupe: per (session, company); fires once per company per session.
# Exit: always 0 (advisory hook, never blocks). Never prints secret values.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

TOOL_NAME="$(extract tool_name)"
[ "$TOOL_NAME" = "Bash" ] || exit 0
CMD="$(extract tool_input.command)"
[ -z "$CMD" ] && exit 0

# Infra / credential command patterns. Matching one of these in a bound-company
# context is what triggers the reminder.
INFRA_RE='(^|[[:space:];&|(])(sst[[:space:]]+(deploy|remove)|pnpm[[:space:]]+deploy|cdk[[:space:]]+deploy|serverless[[:space:]]+deploy|sls[[:space:]]+deploy|terraform[[:space:]]+apply|aws[[:space:]]|hq[[:space:]]+secrets[[:space:]]+exec)'
printf '%s' "$CMD" | grep -Eq "$INFRA_RE" || exit 0

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"

# Resolve the bound company from the current session's meta.yaml — same path
# resolution hq-session.sh / inject-policy-on-trigger.sh use.
CO=""
CURRENT_FILE="$HQ_ROOT/workspace/sessions/.current"
if [ -f "$CURRENT_FILE" ]; then
  SID="$(tr -d '[:space:]' < "$CURRENT_FILE" 2>/dev/null || true)"
  META="$HQ_ROOT/workspace/sessions/$SID/meta.yaml"
  if [ -n "$SID" ] && [ -f "$META" ]; then
    CO="$(sed -nE 's/^company_slug:[[:space:]]*"?([A-Za-z0-9_-]+)"?[[:space:]]*$/\1/p' "$META" | head -1)"
  fi
fi
[ -z "$CO" ] && exit 0   # no company bound — nothing company-specific to surface

POLDIR="$HQ_ROOT/companies/$CO/policies"
[ -d "$POLDIR" ] || exit 0

# Pull the deploy/credential HARD policies straight from the company policy
# files (the pre-built digest was retired). Emit one `- [hard] **slug**: rule`
# line per hard policy, then restrict to slugs about deploy/aws/creds/secrets.
LINES="$(awk '
  function bn(p,  n,a,b){ n=split(p,a,"/"); b=a[n]; sub(/\.md$/,"",b); return b }
  function flush(){ if(enf=="hard" && rule!=""){ if(id=="")id=bn(fn); printf "- [hard] **%s**: %s\n", id, rule } }
  FNR==1 { if(seen) flush(); d=0;id="";enf="";rule="";rsec=0;rcap=0;fn=FILENAME;seen=1 }
  /^---[ \t]*$/ { d++; next }
  d==1 && /^id:/          { s=$0; sub(/^id:[ \t]*/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s); id=s; next }
  d==1 && /^enforcement:/ { s=$0; sub(/^enforcement:[ \t]*/,"",s); gsub(/[ \t]/,"",s); enf=s; next }
  d>=2 && /^## Rule[ \t]*$/ { rsec=1; next }
  d>=2 && rsec && /^## / { rsec=0 }
  d>=2 && rsec && !rcap && NF { line=$0; gsub(/\*\*/,"",line); if(length(line)>160)line=substr(line,1,157)"..."; rule=line; rcap=1 }
  END { if(seen) flush() }
' "$POLDIR"/*.md 2>/dev/null | grep -Ei '\*\*[a-z0-9-]*(deploy|aws|cred|secret)[a-z0-9-]*\*\*' || true)"
[ -z "$LINES" ] && exit 0

# Dedupe once per (session, company).
DEDUPE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
mkdir -p "$DEDUPE_DIR" 2>/dev/null || true
DEDUPE_FILE="$DEDUPE_DIR/${SID:-default}.txt"
touch "$DEDUPE_FILE" 2>/dev/null || true
STAMP="company-infra:$CO"
grep -Fxq "$STAMP" "$DEDUPE_FILE" 2>/dev/null && exit 0
printf '%s\n' "$STAMP" >> "$DEDUPE_FILE"

printf '<company-policy-reminder co="%s">\n' "$CO"
printf '> Infra/credential command in **%s** context. These HARD %s policies apply:\n\n' "$CO" "$CO"
printf '%s\n' "$LINES"
printf '\n> Full text: `companies/%s/policies/{slug}.md`. For AWS/prod: credentials come ONLY\n' "$CO"
printf '> via `hq secrets exec` — agent sessions have NO local profile fallback; never use\n'
printf '> another company'"'"'s profile, and on NoCredentials reach for the vault, do not give up.\n'
printf '</company-policy-reminder>\n'

exit 0
