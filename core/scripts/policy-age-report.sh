#!/usr/bin/env bash
# hq-core: public
# policy-age-report.sh — measure policy usage and flag retirement candidates
# (2026-09-07).
#
# Why: nothing retired a policy. About 85% of one install's 1,251 personal
# policies were machine-written, and the only "usage" signal was that the
# loader printed them — which, above the host's output ceiling, meant nothing.
# This report gives the fade-out its inputs. It does NOT delete anything; it
# names candidates with the evidence, for a human (or /learn --retire) to act on.
#
# Signals per policy (from workspace/orchestrator/policy-trigger-state/*.txt,
# one ledger per session, and the policy files themselves):
#   fired          number of sessions whose ledger recorded the slug (emitted)
#   retrieved      number of sessions that pulled the full text (record-policy-retrieval.sh)
#   last_fired     newest ledger mtime that contains the slug (UTC date)
#   age_days       days since frontmatter `created:` (or file mtime)
#   stale_refs     backtick-quoted HQ-relative paths in the Rule text that no
#                  longer exist on disk (an inaccuracy proxy). Only core/,
#                  .claude/, companies/<co>/ paths are judged; lines that talk
#                  about a path being deleted/removed/legacy are not dependencies;
#                  a same-stem sibling (foo.sh -> foo.mjs) counts as renamed.
#   single_incident frontmatter source is a one-off (user-correction,
#                  session-learning, back-pressure-failure) AND version == 1
#
# Candidate classes (--candidates):
#   never-fired    fired == 0 and age_days >= --min-age (default 30)
#   dormant        fired > 0 but last_fired older than --dormant-days (default 90)
#   stale-refs     stale_refs > 0 (rule points at something that is gone)
#   single-incident-old   single_incident, age_days >= --incident-days (default 60), and fired <= 1
#
# Usage:
#   policy-age-report.sh [--dir <policies-dir>]... [--json] [--candidates] [--min-age N] [--dormant-days N] [--incident-days N]
# Defaults: personal/policies and core/policies (add --dir companies/<co>/policies when bound).
set -uo pipefail
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
LEDGERS="${HQ_POLICY_LEDGER_DIR:-$HQ_ROOT/workspace/orchestrator/policy-trigger-state}"
DIRS=(); JSON=0; CAND=0; MIN_AGE=30; DORMANT=90; INCIDENT=60
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIRS+=("$2"); shift 2 ;;
    --json) JSON=1; shift ;;
    --candidates) CAND=1; shift ;;
    --min-age) MIN_AGE="$2"; shift 2 ;;
    --dormant-days) DORMANT="$2"; shift 2 ;;
    --incident-days) INCIDENT="$2"; shift 2 ;;
    -h|--help) sed -n 2,32p "$0"; exit 0 ;;
    *) echo "policy-age-report: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ "${#DIRS[@]}" -gt 0 ] || DIRS=("$HQ_ROOT/personal/policies" "$HQ_ROOT/core/policies")
command -v jq >/dev/null 2>&1 || { echo "policy-age-report: jq required" >&2; exit 2; }
NOW_EPOCH="${HQ_POLICY_REPORT_NOW_EPOCH:-$(date +%s)}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# One pass over every ledger: slug<TAB>mtime, then reduce to count + max mtime.
HAVE_LEDGERS=0
if [ -d "$LEDGERS" ] && [ -n "$(find "$LEDGERS" -name '*.txt' -type f 2>/dev/null | head -1)" ]; then
  HAVE_LEDGERS=1
  find "$LEDGERS" -name '*.txt' -type f 2>/dev/null | while IFS= read -r f; do
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"
    awk -v m="$m" 'NF { print $1 "\t" m }' "$f"
  done | awk -F'\t' '{ c[$1]++; if ($2 > mx[$1]) mx[$1] = $2 } END { for (s in c) print s "\t" c[s] "\t" mx[s] }' > "$TMP/usage.tsv"
else
  : > "$TMP/usage.tsv"
fi
# Retrieval ledger (record-policy-retrieval.sh): sessions that PULLED the full text.
RETRIEVALS="${HQ_POLICY_RETRIEVAL_LEDGER_DIR:-$HQ_ROOT/workspace/orchestrator/policy-retrieval-state}"
if [ -d "$RETRIEVALS" ]; then
  cat "$RETRIEVALS"/*.txt 2>/dev/null | awk 'NF { c[$1]++ } END { for (s in c) print s "\t" c[s] }' > "$TMP/retrieved.tsv"
else
  : > "$TMP/retrieved.tsv"
fi

to_epoch() { # YYYY-MM-DD -> epoch (0 on failure)
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$1" +%s 2>/dev/null || echo 0
}

for dir in "${DIRS[@]}"; do
  case "$dir" in /*) ;; *) dir="$HQ_ROOT/$dir" ;; esac
  [ -d "$dir" ] || continue
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in README.md|example-policy.md|_digest*.md|*" "*|*.conflict-*|*.sync-conflict-*) continue ;; esac
    [ -L "$f" ] && continue   # personal overlay mirrors live in core/ as symlinks; count the source once
    grep -q '^status: retired' "$f" && continue   # already retired (policy-retire.sh)
    id="$(awk 'NR==1&&!/^---/{exit} /^---/{d++; if(d==2)exit; next} d==1&&/^id:/{sub(/^id:[ \t]*/,""); gsub(/^["'"'"']|["'"'"']$/,""); print; exit}' "$f")"
    [ -n "$id" ] || id="${b%.md}"
    enf="$(awk '/^---/{d++; if(d==2)exit; next} d==1&&/^enforcement:/{sub(/^enforcement:[ \t]*/,""); print; exit}' "$f")"
    src="$(awk '/^---/{d++; if(d==2)exit; next} d==1&&/^source:/{sub(/^source:[ \t]*/,""); gsub(/"/,""); print; exit}' "$f")"
    ver="$(awk '/^---/{d++; if(d==2)exit; next} d==1&&/^version:/{sub(/^version:[ \t]*/,""); print; exit}' "$f")"
    created="$(awk '/^---/{d++; if(d==2)exit; next} d==1&&/^created:/{sub(/^created:[ \t]*/,""); gsub(/"/,""); print substr($0,1,10); exit}' "$f")"
    if [ -n "$created" ]; then ce="$(to_epoch "$created")"; else ce=0; fi
    [ "$ce" -gt 0 ] || ce="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"
    age_days=$(( (NOW_EPOCH - ce) / 86400 ))
    fired=0; last=""
    row="$(awk -F'\t' -v s="$id" '$1==s{print; exit}' "$TMP/usage.tsv")"
    if [ -n "$row" ]; then fired="$(cut -f2 <<<"$row")"; last_e="$(cut -f3 <<<"$row")"; last="$(date -u -d "@$last_e" +%Y-%m-%d 2>/dev/null || date -u -r "$last_e" +%Y-%m-%d)"; last_age=$(( (NOW_EPOCH - last_e) / 86400 )); else last_age=-1; fi
    retrieved="$(awk -F'\t' -v s="$id" '$1==s{print $2; exit}' "$TMP/retrieved.tsv")"; retrieved="${retrieved:-0}"
    # stale refs: backtick paths in the Rule section that look HQ-relative and are missing
    stale=""; renamed=""
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      # Only release-owned or company-owned paths can make a rule inaccurate:
      # core/, .claude/, companies/<slug>/ (when that company exists here).
      # personal/, workspace/, repos/ are user- or environment-specific and are
      # never judged. A ref whose top-level dir is absent is not judged either.
      case "$ref" in
        .claude/state/*|.claude/worktrees/*|core/packages/*) continue ;;   # runtime / install-specific
        core/*|.claude/*) ;;
        companies/*) co_ref="${ref#companies/}"; co_ref="${co_ref%%/*}"; [ -d "$HQ_ROOT/companies/$co_ref" ] || continue ;;
        *) continue ;;
      esac
      # Placeholder examples in prose (`core/scripts/foo.sh`, `.claude/hooks/example.sh`) are not dependencies.
      case "$(basename "$ref")" in foo*|bar*|baz*|example*|placeholder*|sample*|your-*|my-*|x.sh|dummy*) continue ;; esac
      if [ ! -e "$HQ_ROOT/$ref" ]; then
        # A sibling with the same stem (renamed extension: foo.sh -> foo.mjs) means
        # the subject still exists and the rule needs a fix, not retirement.
        stem="${ref%.*}"
        if ls "$HQ_ROOT/$stem".* >/dev/null 2>&1; then renamed="${renamed:+$renamed,}$ref"; else stale="${stale:+$stale,}$ref"; fi
      fi
    done < <(awk '/^## Rule/{r=1;next} r&&/^## /{r=0} r' "$f" \
      | grep -viE '(deleted|removed|retired|deprecated|no longer|not exist|never (call|use|run|read)|do not (call|use|run|read)|must not|instead of|was renamed|old path|legacy)' \
      | grep -oE '`(core|personal|companies|repos|workspace|\.claude)/[A-Za-z0-9_./-]+`' | tr -d '`' | grep -vE '\{|\}|\*' | sort -u)
    stale_n=0; [ -n "$stale" ] && stale_n="$(tr ',' '\n' <<<"$stale" | wc -l | tr -d ' ')"
    judged_n="$(awk '/^## Rule/{r=1;next} r&&/^## /{r=0} r' "$f" | grep -viE '(deleted|removed|retired|deprecated|no longer|not exist|never (call|use|run|read)|do not (call|use|run|read)|must not|instead of|was renamed|old path|legacy)' | grep -oE '`(core|\.claude|companies)/[A-Za-z0-9_./-]+`' | tr -d '`' | grep -vE '\{|\}|\*|/(foo|bar|baz|example|placeholder|sample|your-|my-|dummy)|^\.claude/state/|^\.claude/worktrees/|^core/packages/' | sort -u | wc -l | tr -d ' ')"
    single=0; case "$src" in user-correction|session-learning|back-pressure-failure) [ "${ver:-1}" = "1" ] && single=1 ;; esac
    classes=""
    if [ "$fired" = 0 ] && [ "$age_days" -ge "$MIN_AGE" ] && [ "$HAVE_LEDGERS" = 1 ]; then classes="never-fired"; fi
    if [ "$fired" -gt 0 ] && [ "$last_age" -ge "$DORMANT" ]; then classes="${classes:+$classes,}dormant"; fi
    if [ "$stale_n" -gt 0 ]; then classes="${classes:+$classes,}stale-refs"; fi
    if [ -n "$renamed" ]; then classes="${classes:+$classes,}renamed-refs"; fi
    # A one-off rule that keeps firing has earned its place; only flag it when it never (or once) fired.
    if [ "$single" = 1 ] && [ "$age_days" -ge "$INCIDENT" ] && [ "$fired" -le 1 ]; then classes="${classes:+$classes,}single-incident-old"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${f#"$HQ_ROOT"/}" "${enf:-unset}" "$age_days" "$fired" "${last:--}" "$stale_n" "$stale" "$single" "$classes" "$retrieved" "$judged_n" "$renamed"
  done
done > "$TMP/rows.tsv"

if [ "$JSON" = 1 ]; then
  jq -R -s -c --argjson cand "$CAND" '
    split("\n") | map(select(length>0) | split("\t") | {id:.[0], path:.[1], enforcement:.[2], age_days:(.[3]|tonumber), fired:(.[4]|tonumber), last_fired:(if .[5]=="-" then null else .[5] end), stale_refs:(if .[7]=="" then [] else (.[7]|split(",")) end), single_incident:(.[8]=="1"), candidate_classes:(if .[9]=="" then [] else (.[9]|split(",")) end), retrieved:((.[10] // "0")|tonumber), refs_judged:((.[11] // "0")|tonumber), renamed_refs:(if (.[12] // "")=="" then [] else (.[12]|split(",")) end)})
    | if $cand == 1 then map(select(.candidate_classes|length>0)) else . end' "$TMP/rows.tsv"
  exit 0
fi
total="$(wc -l < "$TMP/rows.tsv" | tr -d ' ')"
never="$(awk -F'\t' '$5==0' "$TMP/rows.tsv" | wc -l | tr -d ' ')"
cands="$(awk -F'\t' '$10!=""' "$TMP/rows.tsv" | wc -l | tr -d ' ')"
stale_total="$(awk -F'\t' '$7>0' "$TMP/rows.tsv" | wc -l | tr -d ' ')"
echo "policy-age-report: $total policies, $never never fired, $stale_total with stale references, $cands retirement candidates (min-age ${MIN_AGE}d, dormant ${DORMANT}d, incident ${INCIDENT}d)"
if [ "$CAND" = 1 ]; then
  awk -F'\t' '$10!="" { printf "  %-14s %-60s fired=%-4s last=%-10s age=%-4sd %s%s\n", $10, $1, $5, $6, $4, ($7>0 ? "stale:" $8 : ""), "" }' "$TMP/rows.tsv" | sort
else
  echo "  (add --candidates to list them, --json for machine-readable rows)"
fi
exit 0
