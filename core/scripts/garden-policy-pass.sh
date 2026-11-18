#!/usr/bin/env bash
# hq-core: public
# garden-policy-pass.sh — the /garden policies pass: pick retirement candidates
# by evidence and retire them through policy-retire.sh (hq core policy retire).
#
# Candidate rules (any one is enough):
#   unused       zero retrievals in --days (default 90) AND created more than
#                --days ago. Retrievals come from policy-retrieval-report.sh
#                (direct reads) AND from the trigger loader's per-session
#                ledgers in workspace/orchestrator/policy-trigger-state/
#                (injections), which is how most policies are used. Absence
#                is judged only when that evidence reaches back at least
#                --days: on a younger install the window is not observed, so
#                nothing is retired as unused (feedback_34db91b5).
#
# A policy read or injected within --days is never retired, whatever other
# candidate rule matches it; it is listed as "stay" with the reason.
#   superseded   status: superseded AND an active policy lists this id in its
#                supersedes: field (the replacement is live).
#   retire-when  retire_when: is present. The script cannot judge free text, so
#                these are listed as "judge". The agent decides; a condition it
#                judges met is passed back with --retire-when-met <id>=<reasoning>.
#
# Scope: only personal/policies and companies/<company>/policies are retired.
# Anything under core/policies is evaluated (when passed with --dir) but always
# skipped. Retired files stay where they are; nothing is moved or deleted.
#
# Usage:
#   garden-policy-pass.sh [--company <slug>] [--dir <policies-dir>]...
#                         [--days N] [--dry-run] [--report-dir <dir>]
#                         [--retire-when-met <id>=<reasoning>]...
#
# Output: one TSV line per evaluated policy (decision, id, path, reason), then
# a plain summary. The summary and the per-policy table are written to
# <report-dir>/policies-<YYYY-MM-DD>.md (default workspace/reports/garden).
# Test hook: GARDEN_NOW_EPOCH overrides the current time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

company="" days=90 dry_run=0 report_dir=""
dirs=() met_ids=() met_reasons=()
while [ $# -gt 0 ]; do
  case "$1" in
    --company) company="${2:?--company needs a slug}"; shift 2 ;;
    --dir) dirs+=("${2:?--dir needs a path}"); shift 2 ;;
    --days) days="${2:?--days needs a number}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --report-dir) report_dir="${2:?--report-dir needs a path}"; shift 2 ;;
    --retire-when-met)
      v="${2:?--retire-when-met needs <id>=<reasoning>}"
      case "$v" in *=?*) ;; *) echo "garden-policy-pass: --retire-when-met wants <id>=<reasoning>" >&2; exit 2 ;; esac
      met_ids+=("${v%%=*}"); met_reasons+=("${v#*=}"); shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "garden-policy-pass: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "${#dirs[@]}" -eq 0 ]; then
  if [ -z "$company" ] && [ -x "$HQ_ROOT/core/scripts/hq-session.sh" ]; then
    company="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
  fi
  [ -d "$HQ_ROOT/personal/policies" ] && dirs+=("$HQ_ROOT/personal/policies")
  if [ -n "$company" ] && [ -d "$HQ_ROOT/companies/$company/policies" ]; then
    dirs+=("$HQ_ROOT/companies/$company/policies")
  fi
fi
[ "${#dirs[@]}" -gt 0 ] || { echo "garden-policy-pass: no policy directories to evaluate" >&2; exit 2; }

now="${GARDEN_NOW_EPOCH:-$(date -u +%s)}"
today="$(date -u -r "$now" +%F 2>/dev/null || date -u -d "@$now" +%F)"
[ -n "$report_dir" ] || report_dir="$HQ_ROOT/workspace/reports/garden"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/garden-policy-pass.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Retrieval evidence: last_retrieved per policy path.
HQ_ROOT="$HQ_ROOT" bash "$SCRIPT_DIR/policy-retrieval-report.sh" "${dirs[@]}" \
  | tail -n +2 > "$tmp/retrieval.tsv"

# Injection evidence: ids the trigger loader delivered within --days. The
# per-session ledgers (<sid>.txt, .turn.txt, .full.txt) hold one id per line
# and are rewritten when a rule is delivered, so a file modified after the
# cutoff counts its ids as recent; .seen.tsv rows carry their own epoch.
# Footers and deferred queues are not deliveries and are left out.
state_dir="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
ledger_file="$HQ_ROOT/workspace/orchestrator/policy-retrieval-ledger.jsonl"
cutoff=$(( now - days * 86400 ))
cutoff_stamp="$(date -u -r "$cutoff" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$cutoff" +%Y%m%d%H%M.%S)"
TZ=UTC touch -t "$cutoff_stamp" "$tmp/cutoff-ref"
: > "$tmp/injected"
state_older=0
if [ -d "$state_dir" ]; then
  find "$state_dir" -maxdepth 1 -type f -name '*.txt' ! -name '*.footer.txt' ! -name '*.deferred-soft.txt' \
    -newer "$tmp/cutoff-ref" -exec awk 'NF { print $1 }' {} + >> "$tmp/injected" 2>/dev/null || true
  find "$state_dir" -maxdepth 1 -type f -name '*.seen.tsv' -newer "$tmp/cutoff-ref" \
    -exec awk -F'\t' -v c="$cutoff" '$2 ~ /^[0-9]+$/ && $2 + 0 >= c { print $1 }' {} + >> "$tmp/injected" 2>/dev/null || true
  [ -n "$(find "$state_dir" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.seen.tsv' \) ! -newer "$tmp/cutoff-ref" -print 2>/dev/null | head -n 1)" ] \
    && state_older=1
fi
sort -u "$tmp/injected" -o "$tmp/injected"

# Frontmatter of every policy: path, id, status, created, retire_when, supersedes.
fm() {
  awk -v path="$1" '
    NR==1 && $0!="---" { exit }
    NR==1 { next }
    $0=="---" { done=1; exit }
    /^[A-Za-z_]+:/ {
      k=$0; sub(/:.*/, "", k); v=$0; sub(/^[^:]*:[ \t]*/, "", v)
      gsub(/^["\x27]|["\x27]$/, "", v)
      if (k=="supersedes" && v=="") { inlist=1; f[k]=""; next }
      inlist=0; f[k]=v; next
    }
    inlist && /^[ \t]*-[ \t]*/ { v=$0; sub(/^[ \t]*-[ \t]*/, "", v); f["supersedes"]=f["supersedes"] (f["supersedes"]==""?"":",") v; next }
    END {
      id=f["id"]; if (id=="") { id=path; sub(/.*\//, "", id); sub(/\.md$/, "", id) }
      s=f["supersedes"]; gsub(/[\[\] ]/, "", s)
      st=f["status"]; if (st=="") st="active"
      printf "%s\037%s\037%s\037%s\037%s\037%s\n", path, id, st, f["created"], f["retire_when"], s
    }' "$1"
}
: > "$tmp/fm.tsv"; : > "$tmp/fm.all"
lookup_dirs=("${dirs[@]}")
[ -d "$HQ_ROOT/core/policies" ] && lookup_dirs+=("$HQ_ROOT/core/policies")
[ -d "$HQ_ROOT/personal/policies" ] && lookup_dirs+=("$HQ_ROOT/personal/policies")
for d in "${lookup_dirs[@]}"; do
  for f in "$d"/*.md; do [ -f "$f" ] && fm "$f" >> "$tmp/fm.all"; done
done
sort -u "$tmp/fm.all" > "$tmp/fm.lookup" 2>/dev/null || : > "$tmp/fm.lookup"
for d in "${dirs[@]}"; do
  for f in "$d"/*.md; do [ -f "$f" ] && fm "$f" >> "$tmp/fm.tsv"; done
done

# Ids that a live (active) policy supersedes.
awk -F'\037' '$3=="active" && $6!="" { n=split($6,a,","); for(i=1;i<=n;i++) print a[i] }' "$tmp/fm.lookup" | sort -u > "$tmp/live-superseded"

days_of() {  # YYYY-MM-DD... -> days since epoch (civil calendar, no date(1) dialects)
  awk -v d="$1" 'BEGIN {
    if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) { print ""; exit }
    y=substr(d,1,4)+0; m=substr(d,6,2)+0; dd=substr(d,9,2)+0
    if (m<=2) { y--; m+=12 }
    era=int(y/400); yoe=y-era*400; doy=int((153*(m-3)+2)/5)+dd-1
    doe=yoe*365+int(yoe/4)-int(yoe/100)+doy
    print era*146097+doe-719468 }'
}
today_days=$(( now / 86400 ))

# Evidence coverage: the window is observed only when some retrieval-ledger row
# or trigger-state ledger is at least --days old. Otherwise "no retrievals in
# --days" would be claimed over a shorter history (feedback_34db91b5: 90 days
# over a 17-day ledger).
evidence_covered=0
evidence_since=""
if [ -f "$ledger_file" ]; then
  evidence_since="$(jq -r '.ts // empty' "$ledger_file" 2>/dev/null | sort | head -n 1 || true)"
  first_days="$(days_of "$evidence_since")"
  [ -n "$first_days" ] && [ $((today_days - first_days)) -ge "$days" ] && evidence_covered=1
fi
[ "$state_older" = 1 ] && evidence_covered=1

# hq core policy retire needs hq-cli >= 5.341.3; a missing or older hq fails
# each retire with the floor message, as the forwarder did.
# shellcheck source=lib/hq-cli-floor.sh
. "$SCRIPT_DIR/lib/hq-cli-floor.sh"
retire() {  # path reason
  { hq_cli_floor_check policy-retire.sh 5.341.3 &&
    hq core --hq-root "$HQ_ROOT" policy retire "$1" --reason "$2" --by garden-policy-pass; } >/dev/null 2>"$tmp/err"
}

evaluated=0 retired=0 would=0 skipped=0 failed=0
: > "$tmp/rows"
while IFS=$'\037' read -r path id status created retire_when _supersedes; do
  evaluated=$((evaluated + 1))
  rel="${path#"$HQ_ROOT"/}"
  decision="stay" reason=""
  if [ "$status" = "retired" ]; then
    reason="already retired"
  else
    cand=""
    if [ "$status" = "superseded" ] && grep -qxF "$id" "$tmp/live-superseded"; then
      cand="superseded by a live policy"
    fi
    last="$(awk -F'\t' -v p="$path" -v r="$rel" '$3==p || $3==r { print $1; exit }' "$tmp/retrieval.tsv")"
    recent="" base="${path##*/}"; base="${base%.md}"
    if [ -n "$last" ] && [ "$last" != "never" ]; then
      ld="$(days_of "$last")"; [ -n "$ld" ] && [ $((today_days - ld)) -le "$days" ] && recent="read $last"
    fi
    if [ -z "$recent" ] && { grep -qxF "$id" "$tmp/injected" || grep -qxF "$base" "$tmp/injected"; }; then
      recent="injected by the trigger loader within $days days"
    fi
    if [ -z "$cand" ] && [ -z "$recent" ]; then
      cdays="$(days_of "$created")"
      if [ -n "$cdays" ] && [ $((today_days - cdays)) -gt "$days" ]; then
        if [ "$evidence_covered" = 1 ]; then
          cand="no retrievals in $days days and created $created"
        else
          reason="retrieval evidence starts ${evidence_since:-later than the install} and covers less than $days days; absence not judged"
        fi
      fi
    fi
    if [ -z "$cand" ] && [ -n "$retire_when" ]; then
      i=0; for m in "${met_ids[@]+"${met_ids[@]}"}"; do
        [ "$m" = "$id" ] && cand="retire_when met (${retire_when}): ${met_reasons[$i]}"; i=$((i + 1))
      done
      [ -z "$cand" ] && { decision="judge"; reason="retire_when: $retire_when"; }
    fi
    if [ -n "$cand" ] && [ -n "$recent" ]; then
      # A rule in use is never retired, whatever else matches it.
      decision="stay"; reason="in use ($recent); not retired although: $cand"
    elif [ -n "$cand" ]; then
      case "$rel" in
        core/policies/*|*/core/policies/*) decision="skip"; reason="core policy, never retired by garden ($cand)" ;;
        *)
          if [ "$dry_run" = 1 ]; then decision="would-retire"; reason="$cand"
          elif retire "$path" "garden: $cand"; then decision="retired"; reason="$cand"
          else decision="failed"; reason="$cand; $(tr '\n' ' ' < "$tmp/err")"; fi ;;
      esac
    elif [ "$decision" = "stay" ] && [ -z "$reason" ]; then
      if [ -n "$recent" ]; then reason="in use ($recent)"; else reason="no retirement evidence"; fi
    fi
  fi
  case "$decision" in
    retired) retired=$((retired + 1)) ;; would-retire) would=$((would + 1)) ;;
    failed) failed=$((failed + 1)) ;; *) skipped=$((skipped + 1)) ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$decision" "$id" "$rel" "$reason" | tee -a "$tmp/rows"
done < "$tmp/fm.tsv"

judge=$(grep -c '^judge	' "$tmp/rows" || true)
core_skip=$(grep -c '^skip	' "$tmp/rows" || true)
if [ "$dry_run" = 1 ]; then
  summary="Dry run: evaluated $evaluated policies; $would would be retired; $skipped left alone ($judge need a retire_when judgment, $core_skip are core policies garden never retires, the rest have no evidence or are already retired)."
else
  summary="Evaluated $evaluated policies; retired $retired; $failed failed; $skipped left alone ($judge need a retire_when judgment, $core_skip are core policies garden never retires, the rest have no evidence or are already retired)."
fi
echo "$summary"

mkdir -p "$report_dir"
report="$report_dir/policies-$today.md"
{
  echo "# Garden policies pass — $today"
  echo
  [ "$dry_run" = 1 ] && echo "Mode: dry run (nothing retired)." || echo "Mode: live. Retired files stay in place; restore with \`policy-retire.sh <id> --restore\`."
  echo
  echo "$summary"
  echo
  echo "| Decision | Policy | Path | Reason |"
  echo "|---|---|---|---|"
  awk -F'\t' '{ gsub(/\|/, "/", $4); printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$tmp/rows"
} > "$report"
echo "Report: $report"
[ "$failed" = 0 ]
