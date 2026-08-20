#!/usr/bin/env bash
# hq-checkup.sh — Check that HQ is working, and fix what can be fixed safely.
#
# Written for someone who does not know how HQ works inside. Every line it
# prints says what is wrong in plain words and what happens next.
#
# It fixes the safe things on its own (updating HQ, starting the app, backing
# up your work). Anything that needs a decision from you is listed at the end
# instead of being done behind your back.
#
# Usage:
#   bash .claude/skills/hq-checkup/hq-checkup.sh           # check and fix
#   bash .claude/skills/hq-checkup/hq-checkup.sh --check   # look only, change nothing
#   bash .claude/skills/hq-checkup/hq-checkup.sh --quick   # fast, skip internet checks
#   bash .claude/skills/hq-checkup/hq-checkup.sh --json    # machine-readable
#
# Exit: 0 = nothing left for you to do, 1 = something needs you, 2 = bad usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
HQ_CLI_PKG="@indigoai-us/hq-cli"
HQ_CLI_FLOOR="5.35.0"
HQ_STATE="${HOME}/.hq"

FIX=1
OFFLINE=0
NO_HOOKS=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --check|--dry-run) FIX=0; shift ;;
    --quick)   OFFLINE=1; NO_HOOKS=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --no-hooks) NO_HOOKS=1; shift ;;
    --json)    JSON=1; shift ;;
    *) echo "hq-checkup: don't know the option '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# GOOD  = fine, nothing to say
# FIXED = was broken, this script already fixed it
# YOU   = needs the person to do something
# INFO  = worth knowing, but not a problem to act on
# SKIP  = couldn't check (offline / skipped) — never shown
LINES=""
N_YOU=0
N_FIXED=0

say() { # status  headline  what-to-do
  LINES="${LINES}${1}"$'\t'"${2}"$'\t'"${3:-}"$'\n'
  [ "$1" = "YOU" ]   && N_YOU=$((N_YOU + 1))
  [ "$1" = "FIXED" ] && N_FIXED=$((N_FIXED + 1))
  return 0
}

commas() { printf '%s' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }

newer() { # newer A B → true when A is a later version than B
  [ "$1" = "$2" ] && return 1
  local a b
  a=$(printf '%s' "$1" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  b=$(printf '%s' "$2" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
  [ "$a" \> "$b" ]
}

capped() { local s="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  elif command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  else "$@"; fi
}

# ===================== HQ tools (the `hq` command) ===========================
CLI_VER=""
install_cli() { capped 180 npm install -g "${HQ_CLI_PKG}@latest" >/dev/null 2>&1; }

if command -v hq >/dev/null 2>&1; then
  CLI_VER=$(HQ_NO_UPDATE_CHECK=1 hq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi

if [ -z "$CLI_VER" ]; then
  if [ "$FIX" -eq 1 ] && command -v npm >/dev/null 2>&1 && install_cli; then
    CLI_VER=$(HQ_NO_UPDATE_CHECK=1 hq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    say FIXED "Installed HQ — it was missing" ""
  else
    say YOU "HQ isn't installed on this computer" "Run: npm install -g ${HQ_CLI_PKG}"
  fi
elif newer "$HQ_CLI_FLOOR" "$CLI_VER"; then
  if [ "$FIX" -eq 1 ] && install_cli; then
    say FIXED "Updated HQ — the old version had parts switched off" ""
  else
    say YOU "Your HQ is too old and parts of it are switched off" "Run: npm install -g ${HQ_CLI_PKG}@latest"
  fi
elif [ "$OFFLINE" -eq 1 ]; then
  say SKIP "Didn't check for an HQ update" ""
else
  LATEST=$(capped 25 npm view "${HQ_CLI_PKG}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -z "$LATEST" ]; then
    say SKIP "Couldn't reach the internet to check for an HQ update" ""
  elif newer "$LATEST" "$CLI_VER"; then
    if [ "$FIX" -eq 1 ] && install_cli; then
      say FIXED "Updated HQ to the newest version" ""
    else
      say YOU "There's a newer version of HQ" "Run: npm install -g ${HQ_CLI_PKG}@latest"
    fi
  fi
fi

# ===================== The rest of HQ ========================================
CORE_YAML="${HQ_ROOT}/core/core.yaml"
LOCAL_CORE=$(grep -E '^hqVersion:' "$CORE_YAML" 2>/dev/null | head -1 \
  | sed -E 's/^hqVersion:[[:space:]]*["'"'"']?([0-9]+\.[0-9]+\.[0-9]+)["'"'"']?.*/\1/')

if [ -n "$LOCAL_CORE" ] && [ "$OFFLINE" -eq 0 ] \
   && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  LATEST_CORE=$(capped 25 gh release view -R indigoai-us/hq-core --json tagName -q .tagName 2>/dev/null \
    | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  if [ -n "$LATEST_CORE" ] && newer "$LATEST_CORE" "$LOCAL_CORE"; then
    # Deliberately never automatic: this rewrites HQ underneath a running session.
    say YOU "There's a newer version of HQ's setup, with new features" \
      "Run /update-hq in a NEW chat — it can't safely run in this one"
  fi
fi

# ===================== Signed in =============================================
if [ -n "$CLI_VER" ]; then
  if HQ_NO_UPDATE_CHECK=1 capped 20 hq whoami 2>/dev/null | grep -qi 'logged in as'; then
    :
  else
    # Interactive browser login — cannot be done for them.
    say YOU "You're signed out, so nothing can save or share right now" "Run: hq login"
  fi
fi

# ===================== The HQ app ============================================
if [ "$(uname -s)" = "Darwin" ]; then
  APP_UP=0; DAEMON_UP=0
  pgrep -f 'hq-sync-menubar' >/dev/null 2>&1 && APP_UP=1
  pgrep -f 'hq-sync-runner'  >/dev/null 2>&1 && DAEMON_UP=1

  if [ "$APP_UP" -eq 0 ] && [ -d "/Applications/HQ.app" ]; then
    if [ "$FIX" -eq 1 ] && open -a HQ >/dev/null 2>&1; then
      sleep 3
      pgrep -f 'hq-sync-menubar' >/dev/null 2>&1 && APP_UP=1
      if [ "$APP_UP" -eq 1 ]; then
        say FIXED "Started the HQ app — it wasn't running, so nothing was saving" ""
      else
        say YOU "The HQ app won't start" "Open HQ from your Applications folder"
      fi
    else
      say YOU "The HQ app isn't running, so your work isn't being saved" "Open HQ from your Applications folder"
    fi
  elif [ "$APP_UP" -eq 0 ]; then
    say YOU "The HQ app isn't installed on this computer" "Ask whoever set up your HQ for the app installer"
  elif [ "$DAEMON_UP" -eq 0 ]; then
    say YOU "The HQ app is open but not saving in the background" "Quit HQ and open it again"
  fi
fi

# --- paused switch: only the person can flip this ---
if [ -f "${HQ_STATE}/menubar.json" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "
import json
print('paused' if json.load(open('${HQ_STATE}/menubar.json')).get('cloudPaused') else 'on')
" 2>/dev/null | grep -q paused; then
    say YOU "Saving is paused, so nothing is leaving this computer" \
      "Click the HQ icon in your menu bar and turn saving back on"
  fi
fi

# ===================== Is your work backed up? ===============================
# Emits "slug<TAB>days" for anything that hasn't backed up in over a week.
stale_list() {
  [ -d "$HQ_STATE" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  for j in "${HQ_STATE}"/sync-journal.*.json; do
    [ -f "$j" ] || continue
    n=$(basename "$j" | sed -E 's/^sync-journal\.(.*)\.json$/\1/')
    t=$(grep -oE '"lastSync"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
    [ -n "$t" ] && printf '%s\t%s\n' "$n" "$t"
  done | python3 -c "
import sys, datetime
now=datetime.datetime.now(datetime.timezone.utc)
out=[]
for line in sys.stdin:
    p=line.rstrip('\n').split('\t')
    if len(p)!=2: continue
    for f in ('%Y-%m-%dT%H:%M:%S.%fZ','%Y-%m-%dT%H:%M:%SZ'):
        try:
            dt=datetime.datetime.strptime(p[1],f).replace(tzinfo=datetime.timezone.utc)
            d=(now-dt).days
            if d > 7: out.append((p[0],d))
            break
        except ValueError: pass
out.sort(key=lambda r:-r[1])
for n,d in out: print(f'{n}\t{d}')
" 2>/dev/null
}

# Turn "a,b,c" into "a, b and c" so the sentence reads like a sentence.
join_names() {
  printf '%s' "$1" | python3 -c "
import sys
n=[x for x in sys.stdin.read().split(',') if x]
print(n[0] if len(n)==1 else ', '.join(n[:-1])+' and '+n[-1])
" 2>/dev/null
}

STALE_BEFORE=$(stale_list)

if [ -n "$STALE_BEFORE" ]; then
  if [ "$FIX" -eq 1 ] && [ -n "$CLI_VER" ]; then
    # Back up each one individually. --on-conflict keep matches what the HQ app
    # does, so this never stops to ask a question the script can't answer.
    printf '%s\n' "$STALE_BEFORE" | while IFS=$'\t' read -r slug _days; do
      [ -n "$slug" ] || continue
      HQ_NO_UPDATE_CHECK=1 capped 180 hq sync now --company "$slug" --on-conflict keep >/dev/null 2>&1
    done

    # Say what actually happened, not what we hoped would happen.
    STALE_AFTER=$(stale_list)
    N_BEFORE=$(printf '%s\n' "$STALE_BEFORE" | grep -c . 2>/dev/null || echo 0)
    N_AFTER=$(printf '%s\n' "$STALE_AFTER"  | grep -c . 2>/dev/null || echo 0)

    if [ "${N_AFTER:-0}" -eq 0 ] 2>/dev/null; then
      say FIXED "Backed up work that hadn't saved in a while" ""
    else
      [ "${N_BEFORE:-0}" -gt "${N_AFTER:-0}" ] 2>/dev/null \
        && say FIXED "Backed up some work that hadn't saved in a while" ""
      NAMES=$(printf '%s\n' "$STALE_AFTER" | cut -f1 | paste -sd, - 2>/dev/null)
      say INFO "These haven't backed up in a while and didn't respond: $(join_names "$NAMES"). If you don't use them, nothing is wrong." ""
    fi
  else
    NAMES=$(printf '%s\n' "$STALE_BEFORE" | cut -f1 | paste -sd, - 2>/dev/null)
    say YOU "These haven't backed up in over a week: $(join_names "$NAMES")" "Run: hq sync now --company <name>"
  fi
fi

# ===================== Files with two versions ===============================
CONFLICTS="${HQ_ROOT}/.hq-conflicts/index.json"
if [ -f "$CONFLICTS" ] && command -v python3 >/dev/null 2>&1; then
  N=$(python3 -c "
import json
try: print(len(json.load(open('${CONFLICTS}')).get('conflicts') or []))
except Exception: print(0)
" 2>/dev/null)
  if [ "${N:-0}" -gt 0 ] 2>/dev/null; then
    # Only the person knows which version they want — never guessable.
    say YOU "$(commas "$N") files were changed in two places, so there are two copies of each" \
      "Run /resolve-conflicts to pick which one to keep (nothing is lost until you do)"
  fi
fi

# ===================== HQ's own safety checks ================================
if [ "$NO_HOOKS" -eq 0 ] && [ -n "$CLI_VER" ]; then
  DFAIL=$(HQ_NO_UPDATE_CHECK=1 capped 150 hq doctor --json 2>/dev/null | python3 -c "
import json,sys
try: print(sum(1 for x in (json.load(sys.stdin).get('results') or []) if x.get('status')=='FAIL'))
except Exception: print(-1)
" 2>/dev/null)
  if [ "${DFAIL:--1}" -gt 0 ] 2>/dev/null; then
    if [ "$FIX" -eq 1 ] && HQ_NO_UPDATE_CHECK=1 capped 150 hq doctor --fix --yes >/dev/null 2>&1; then
      AFTER=$(HQ_NO_UPDATE_CHECK=1 capped 150 hq doctor --json 2>/dev/null | python3 -c "
import json,sys
try: print(sum(1 for x in (json.load(sys.stdin).get('results') or []) if x.get('status')=='FAIL'))
except Exception: print(-1)
" 2>/dev/null)
      if [ "${AFTER:--1}" -eq 0 ] 2>/dev/null; then
        say FIXED "Turned HQ's safety checks back on" ""
      elif [ "${AFTER:--1}" -gt 0 ] 2>/dev/null && [ "${AFTER}" -lt "${DFAIL}" ]; then
        say YOU "Some of HQ's safety checks are still switched off" "Run: hq doctor    (to see which ones)"
      else
        say YOU "Some of HQ's safety checks are switched off" "Run: hq doctor    (to see which ones)"
      fi
    else
      say YOU "Some of HQ's safety checks are switched off" "Run: hq doctor --fix"
    fi
  fi
fi

# ===================== Report ================================================
if [ "$JSON" -eq 1 ]; then
  printf '%s' "$LINES" | python3 -c "
import sys, json
items=[]
for line in sys.stdin:
    line=line.rstrip('\n')
    if not line: continue
    p=line.split('\t')
    while len(p)<3: p.append('')
    items.append({'status':p[0],'headline':p[1],'action':p[2]})
print(json.dumps({'schemaVersion':2,'hqRoot':'''${HQ_ROOT}''',
  'summary':{'needsYou':sum(1 for i in items if i['status']=='YOU'),
             'fixed':sum(1 for i in items if i['status']=='FIXED')},
  'items':items}, indent=2))
"
  [ "$N_YOU" -gt 0 ] && exit 1 || exit 0
fi

printf '\n'
if [ "$N_FIXED" -eq 0 ] && [ "$N_YOU" -eq 0 ] && ! printf '%s' "$LINES" | grep -q '^INFO'; then
  printf '  Your HQ is working properly. Nothing to do.\n\n'
  exit 0
fi

if [ "$N_FIXED" -gt 0 ]; then
  printf '  Fixed for you:\n'
  printf '%s' "$LINES" | while IFS=$'\t' read -r s head act; do
    [ "$s" = "FIXED" ] && printf '    • %s\n' "$head"
  done
  printf '\n'
fi

if printf '%s' "$LINES" | grep -q '^INFO'; then
  printf '  Worth knowing:\n'
  printf '%s' "$LINES" | while IFS=$'\t' read -r s head act; do
    [ "$s" = "INFO" ] && printf '    • %s\n' "$head"
  done
  printf '\n'
fi

if [ "$N_YOU" -gt 0 ]; then
  printf '  Needs you:\n'
  i=0
  printf '%s' "$LINES" | while IFS=$'\t' read -r s head act; do
    [ "$s" = "YOU" ] || continue
    i=$((i + 1))
    printf '    %d. %s\n' "$i" "$head"
    [ -n "$act" ] && printf '       %s\n' "$act"
  done
  printf '\n'
  exit 1
fi

printf '  Everything else looks fine.\n\n'
exit 0
