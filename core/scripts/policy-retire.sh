#!/usr/bin/env bash
# hq-core: public
# policy-retire.sh — retire (or restore) a policy without deleting it (2026-09-07).
#
# Why: nothing retired policies, so the corpus only grew. Retirement is a
# frontmatter state, not a deletion: the file stays where it is (history,
# grep-ability, restore), and every consumer skips `status: retired` — the
# trigger loader, the company-bind digest, the age report.
#
# Usage:
#   policy-retire.sh <slug-or-path> --reason "<why>" [--by <who>]
#   policy-retire.sh <slug-or-path> --restore
#   policy-retire.sh --from-report <age-report.json> --class <never-fired|dormant|stale-refs|single-incident-old> --reason "<why>" [--yes]
#   policy-retire.sh --auto [--dir <policies-dir>]... [--classes a,b] [--report-dir <dir>] [--dry-run]
#
# --auto is the human-ON-the-loop mode (2026-09-07): it runs the age report,
# retires every candidate with a per-policy reason, and writes a dated report
# (default workspace/reports/policy-retirement-<date>.md) so a wrong call can
# be found and reversed with --restore. Nobody approves in advance. Classes and
# reasons:
#   never-fired          never emitted in any session ledger, older than 30 days
#   dormant              last emitted more than 90 days ago
#   stale-refs           its Rule text points at HQ paths that no longer exist
#   single-incident-old  a one-off correction, older than 60 days, fired at most once
# Defaults to personal/policies plus the bound company's policies; core/ is
# release-owned and is retired only in the hq-core-staging tree.
#
# <slug-or-path>: a policy file path, or a slug looked up under personal/policies,
# core/policies, and companies/*/policies (first match). Symlinked overlay
# mirrors are resolved to their source file.
# --from-report: batch mode over `policy-age-report.sh --json --candidates`
# output; lists what would change and requires --yes to write.
set -uo pipefail
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
TARGET=""; REASON=""; BY="${HQ_SESSION_ID:-${USER:-unknown}}"; RESTORE=0; REPORT=""; CLASS=""; YES=0
AUTO=0; DRY=0; AUTO_DIRS=(); REPORT_DIR=""; CLASSES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --dir) AUTO_DIRS+=("$2"); shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --classes) CLASSES="$2"; shift 2 ;;   # comma list; default: all classes
    --reason) REASON="$2"; shift 2 ;;
    --by) BY="$2"; shift 2 ;;
    --restore) RESTORE=1; shift ;;
    --from-report) REPORT="$2"; shift 2 ;;
    --class) CLASS="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n 2,22p "$0"; exit 0 ;;
    -*) echo "policy-retire: unknown arg $1" >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done
resolve() { # slug-or-path -> real file path or empty
  local t="$1" f
  if [ -f "$t" ]; then f="$t"
  else
    for d in "$HQ_ROOT/personal/policies" "$HQ_ROOT/core/policies" "$HQ_ROOT"/companies/*/policies; do
      [ -f "$d/$t.md" ] && { f="$d/$t.md"; break; }
      [ -f "$d/$t" ] && { f="$d/$t"; break; }
    done
  fi
  [ -n "${f:-}" ] || return 1
  [ -L "$f" ] && f="$(cd "$(dirname "$f")" && realpath "$(readlink "$f")" 2>/dev/null || readlink "$f")"
  printf '%s' "$f"
}
set_status() { # <file> <retired|active> <reason>
  local f="$1" st="$2" why="$3" now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  head -1 "$f" | grep -q '^---' || { echo "policy-retire: $f has no frontmatter" >&2; return 1; }
  awk -v st="$st" -v why="$why" -v by="$BY" -v now="$now" '
    BEGIN { d=0; done=0 }
    /^---[ \t]*$/ { d++; if (d==2 && !done) {
        if (st=="retired") { print "status: retired"; print "retired_at: " now; print "retired_by: " by; print "retired_reason: \"" why "\"" }
        done=1 }
      print; next }
    d==1 && /^(status|retired_at|retired_by|retired_reason):/ { next }
    { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
if [ "$AUTO" = 1 ]; then
  AGE="$HQ_ROOT/core/scripts/policy-age-report.sh"; [ -x "$AGE" ] || AGE="$(dirname "${BASH_SOURCE[0]}")/policy-age-report.sh"
  if [ "${#AUTO_DIRS[@]}" -eq 0 ]; then
    AUTO_DIRS=("$HQ_ROOT/personal/policies")
    co="$(bash "$HQ_ROOT/core/scripts/hq-session.sh" get company_slug 2>/dev/null || true)"
    [ -n "$co" ] && [ "$co" != "personal" ] && [ -d "$HQ_ROOT/companies/$co/policies" ] && AUTO_DIRS+=("$HQ_ROOT/companies/$co/policies")
  fi
  dirargs=(); for d in "${AUTO_DIRS[@]}"; do dirargs+=(--dir "$d"); done
  json="$(HQ_ROOT="$HQ_ROOT" bash "$AGE" "${dirargs[@]}" --json --candidates 2>/dev/null)" || json="[]"
  n="$(jq 'length' <<<"$json")"
  today="$(date -u +%Y-%m-%d)"; [ -n "$REPORT_DIR" ] || REPORT_DIR="$HQ_ROOT/workspace/reports"
  out="$REPORT_DIR/policy-retirement-$today.md"; mkdir -p "$REPORT_DIR"
  # One file per day; each run appends its own section so nothing is overwritten.
  : > "$out.tmp"
  if [ ! -f "$out" ]; then
    {
      echo "# Automatic policy retirement — $today"; echo
      echo "Mode: human on the loop. Each policy below was retired by \`policy-retire.sh --auto\` with the reason shown."
      echo "Reverse any wrong call with \`bash core/scripts/policy-retire.sh <slug> --restore\` and fix the rule that produced it."
      echo
    } > "$out.tmp"
  fi
  { echo "## Run $(date -u +%H:%M:%SZ) — dirs: ${AUTO_DIRS[*]}"; echo; } >> "$out.tmp"
  retired=0; needfix=0
  while IFS=$'	' read -r id path classes fired last age stale judged stale_n renamed; do
    [ -n "$path" ] || continue
    f="$HQ_ROOT/$path"; [ -f "$f" ] || f="$path"; [ -f "$f" ] || continue
    grep -q '^status: retired' "$f" && continue
    if [ -n "$CLASSES" ]; then
      keep=""; for c in $(tr ',' ' ' <<<"$classes"); do case ",$CLASSES," in *,$c,*) keep="${keep:+$keep,}$c" ;; esac; done
      classes="$keep"; [ -n "$classes" ] || continue
    fi
    why=""
    # stale-refs retires only when EVERY judged reference is gone — the rule's
    # whole subject vanished. A partly stale rule is reported for a fix, not retired.
    case ",$classes," in *,renamed-refs,*) printf -- '- needs-fix (not retired) **%s** (%s): referenced file was renamed: %s\n' "$id" "$path" "$renamed" >> "$out.tmp"; needfix=$((needfix+1)) ;; esac
    case ",$classes," in *,stale-refs,*)
      if [ "${judged:-0}" -gt 0 ] && [ "${stale_n:-0}" -eq "${judged:-0}" ]; then why="every path the rule depends on is gone ($stale)"
      else printf -- '- needs-fix (not retired) **%s** (%s): references gone: %s\n' "$id" "$path" "$stale" >> "$out.tmp"; needfix=$((needfix+1)); fi ;;
    esac
    case ",$classes," in *,never-fired,*) why="${why:+$why; }never emitted in any session ledger over ${age} days" ;; esac
    case ",$classes," in *,dormant,*) why="${why:+$why; }last emitted $last, more than the dormant window ago" ;; esac
    case ",$classes," in *,single-incident-old,*) why="${why:+$why; }one-off correction, ${age} days old, fired ${fired}x" ;; esac
    [ -n "$why" ] || continue
    if [ "$DRY" = 1 ]; then echo "would retire: $id — $why"
    else set_status "$f" retired "auto: $why" && echo "retired: $id — $why"; fi
    printf -- '- **%s** (%s): %s
' "$id" "$path" "$why" >> "$out.tmp"
    retired=$((retired+1))
  done < <(jq -r '.[] | [.id, .path, (.candidate_classes|join(",")), (.fired|tostring), (.last_fired // "never"), (.age_days|tostring), (.stale_refs|join(", ")), ((.refs_judged // 0)|tostring), ((.stale_refs|length)|tostring), ((.renamed_refs // [])|join(", "))] | @tsv' <<<"$json")
  if [ "$DRY" = 1 ]; then rm -f "$out.tmp"; echo "policy-retire --auto: $retired of $n candidates would be retired (dry run)"
  else
    if [ "$retired" -gt 0 ] || [ "$needfix" -gt 0 ]; then cat "$out.tmp" >> "$out"; rm -f "$out.tmp"; echo "policy-retire --auto: $retired retired, $needfix need a fix; report ${out#"$HQ_ROOT"/}"; else rm -f "$out.tmp"; echo "policy-retire --auto: nothing to retire"; fi
  fi
  exit 0
fi
if [ -n "$REPORT" ]; then
  [ -n "$CLASS" ] && [ -n "$REASON" ] || { echo "--from-report needs --class and --reason" >&2; exit 2; }
  [ -r "$REPORT" ] || { echo "cannot read $REPORT" >&2; exit 2; }
  n=0
  while IFS=$'\t' read -r id path; do
    [ -n "$path" ] || continue
    f="$HQ_ROOT/$path"; [ -f "$f" ] || continue
    grep -q '^status: retired' "$f" && continue
    n=$((n+1))
    if [ "$YES" = 1 ]; then set_status "$f" retired "$REASON [$CLASS]" && echo "retired: $id ($path)"
    else echo "would retire: $id ($path)"; fi
  done < <(jq -r --arg c "$CLASS" '.[] | select(.candidate_classes | index($c)) | "\(.id)\t\(.path)"' "$REPORT")
  [ "$YES" = 1 ] && echo "policy-retire: $n retired [$CLASS]" || echo "policy-retire: $n would be retired [$CLASS] (add --yes)"
  exit 0
fi
[ -n "$TARGET" ] || { sed -n 2,22p "$0"; exit 2; }
F="$(resolve "$TARGET")" || { echo "policy-retire: no policy found for '$TARGET'" >&2; exit 3; }
if [ "$RESTORE" = 1 ]; then
  set_status "$F" active "" && echo "policy-retire: restored ${F#"$HQ_ROOT"/}"
else
  [ -n "$REASON" ] || { echo "policy-retire: --reason is required" >&2; exit 2; }
  set_status "$F" retired "$REASON" && echo "policy-retire: retired ${F#"$HQ_ROOT"/} — $REASON"
fi
