#!/bin/bash
# lint-policy-triggers.sh — audit every policy file's `when:` / `on:` trigger
# and the injected size of every `enforcement: hard` policy.
#
# The authoring hook (validate-policy-frontmatter.sh) only sees files as they
# are written, so it cannot see a tree that drifted before it existed, that was
# populated by a script, or that was edited on a host where hooks do not fire.
# This is the sweep that does: run it over the whole install and get every
# malformed trigger, every loose hard trigger, and every oversized hard body in
# one pass.
#
# Why it matters: a `when:` the evaluator cannot parse is not a no-op. Until it
# is repaired the policy cannot be matched against the event at all, so it is
# either injected as an unconditional fallback (hard) or not injected at all
# (soft) — never for the reason its author intended.
#
# Findings:
#   MALFORMED  `when:` is outside the documented grammar — quoted phrases,
#              flags, globs, sigils, or two identifiers with no operator
#              between them (`merge || pull request`, which the parser reads as
#              `merge || pull` and silently discards the rest).
#   MISSING    no `when:` or no `on:` in the frontmatter.
#   LOOSE      `enforcement: hard` with an unconditional `when:` on a reactive
#              event — TRUE for every command and prompt, so it is ranked as an
#              event-specific match and takes the session cap slot of a policy
#              that actually matched.
#   OVERSIZE   `enforcement: hard` whose injected span exceeds
#              HQ_POLICY_HARD_RULE_MAX_BYTES (default 6144). Hard policies are
#              quoted verbatim into the session, so this is recurring context
#              cost.
#
# Usage:
#   bash core/scripts/lint-policy-triggers.sh [--quiet] [--strict] [dir ...]
#
#   (no dirs)  scan the standard policy roots under HQ_ROOT
#   --quiet    print only the summary counts
#   --strict   also exit non-zero for LOOSE/OVERSIZE, not just MALFORMED/MISSING
#
# Exit: 0 clean, 1 findings (see --strict), 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives under core/scripts, so its repository/HQ root is two levels
# up. Resolving only one level made no-argument invocations look under
# core/core/policies and report that no policy directories existed.
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
EVAL="$SCRIPT_DIR/eval-trigger.sh"

HARD_RULE_MAX="${HQ_POLICY_HARD_RULE_MAX_BYTES:-6144}"
QUIET=0
STRICT=0
DIRS=()

die() { printf '%s\n' "$*" >&2; exit 1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lint-policy-triggers.XXXXXX")" \
  || { echo "failed to create temporary directory" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) DIRS+=("$1") ;;
  esac
  shift
done

if [ "${#DIRS[@]}" -eq 0 ]; then
  for d in "$HQ_ROOT/core/policies" "$HQ_ROOT/personal/policies"; do
    [ -d "$d" ] && DIRS+=("$d")
  done
  if [ -d "$HQ_ROOT/companies" ]; then
    find "$HQ_ROOT/companies" -maxdepth 2 -type d -name policies -print0 \
      > "$TMPROOT/company-policy-dirs" \
      || die "failed to discover policy directories under $HQ_ROOT/companies"
    while IFS= read -r -d '' d; do DIRS+=("$d"); done < "$TMPROOT/company-policy-dirs"
  fi
  if [ -d "$HQ_ROOT/repos" ]; then
    find "$HQ_ROOT/repos" -maxdepth 4 -type d -path '*/.claude/policies' -print0 \
      > "$TMPROOT/repo-policy-dirs" \
      || die "failed to discover policy directories under $HQ_ROOT/repos"
    while IFS= read -r -d '' d; do DIRS+=("$d"); done < "$TMPROOT/repo-policy-dirs"
  fi
fi
if [ "${#DIRS[@]}" -eq 0 ]; then
  echo "no policy directories found under $HQ_ROOT" >&2
  exit 2
fi
if [ ! -f "$EVAL" ]; then
  echo "missing evaluator: $EVAL" >&2
  exit 2
fi

# Collect the files first so both passes see exactly the same set. Keep the
# list NUL-delimited: policy paths are filesystem data, not shell arguments.
FILES_NUL="$TMPROOT/policy-files.nul"
: > "$FILES_NUL"
for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || { echo "policy directory not found: $dir" >&2; exit 2; }
  find "$dir" -maxdepth 1 -type f -name '*.md' \
    ! -name 'README.md' ! -name 'example-policy.md' ! -path '*/audit/*' -print0 \
    >> "$FILES_NUL" \
    || die "failed to enumerate policy files under $dir"
done
[ -s "$FILES_NUL" ] || die "policy directories were found but no policy files were scanned"

# ── Pass 1: one awk over every file → path <TAB> when <TAB> on <TAB> enf <TAB> bytes
# `bytes` is the span inject-policy-on-trigger.sh would actually quote: body
# after the frontmatter, stopping at the first archival heading. Keep this list
# in sync with BODY_STOP in that hook and STOP in validate-policy-frontmatter.sh.
STOP='^#+[ \t]*(rationale|rationale and context|background|change history|changelog|history|examples?|references?|related|see also|sources?|provenance|evidence)[ \t]*$'

FACTS_TSV="$TMPROOT/policy-facts.tsv"
if ! xargs -0 awk -v stop="$STOP" '
    function flush() {
      if (fn != "") printf "%s\t%s\t%s\t%s\t%s\n", fn, w, o, tolower(enf), bytes+0
    }
    function reset() { d=0; w=""; o=""; enf=""; bytes=0; stopped=0 }
    FNR==1 { flush(); reset(); fn=FILENAME }
    /^---[ \t]*$/ && d < 2 { d++; next }
    d==1 {
      line=$0
      if (line ~ /^when:[ \t]*[^ \t]/)        { sub(/^when:[ \t]*/,"",line); sub(/[ \t]+#.*/,"",line); gsub(/^["'"'"']|["'"'"']$/,"",line); w=line }
      else if (line ~ /^on:[ \t]*[^ \t]/)     { sub(/^on:[ \t]*/,"",line); o=line }
      else if (line ~ /^enforcement:[ \t]*[^ \t]/) { sub(/^enforcement:[ \t]*/,"",line); sub(/[ \t]+#.*/,"",line); gsub(/^["'"'"']|["'"'"']$/,"",line); enf=line }
      next
    }
    d>=2 {
      probe=tolower($0); sub(/^[ \t]+/,"",probe); sub(/[ \t]+$/,"",probe)
      if (stopped || probe ~ stop) { stopped=1; next }
      bytes += length($0) + 1
    }
    END { flush() }
  ' < "$FILES_NUL" > "$FACTS_TSV"; then
  die "failed to extract policy facts"
fi
[ -s "$FACTS_TSV" ] || die "policy files were found but no policy facts were extracted"

# ── Pass 2: one batched syntax check through the canonical evaluator, joined
# back onto the records by line number — so the whole tree costs one awk and
# one evaluator process, not one of each per policy. There is deliberately no
# second copy of the grammar here: --check runs the same parser the runtime does.
CHECK_INPUT="$TMPROOT/trigger-check-input.tsv"
CHECK_OUTPUT="$TMPROOT/trigger-check-output.tsv"
RECORDS="$TMPROOT/policy-records.tsv"
if ! awk -F'\t' '$2 != "" { print NR "\t" $2 }' "$FACTS_TSV" > "$CHECK_INPUT"; then
  die "failed to prepare policy trigger checks"
fi
if ! bash "$EVAL" --check < "$CHECK_INPUT" > "$CHECK_OUTPUT"; then
  die "policy trigger evaluator failed"
fi
if ! awk -F'\t' -v status_file="$CHECK_OUTPUT" '
  FILENAME == status_file {
    if ($1 !~ /^[1-9][0-9]*$/ || ($2 != "ok" && $2 != "malformed") || NF != 2) {
      print "invalid evaluator output: " $0 > "/dev/stderr"
      failed = 1
      next
    }
    if ($1 in state) {
      print "duplicate evaluator result for record " $1 > "/dev/stderr"
      failed = 1
      next
    }
    state[$1] = $2
    next
  }
  {
    rows[FNR] = $0
    split($0, fields, FS)
    if (fields[2] != "") expected[FNR] = 1
    count = FNR
  }
  END {
    for (id in expected) {
      if (!(id in state)) {
        print "evaluator produced no result for record " id > "/dev/stderr"
        failed = 1
      }
    }
    for (id in state) {
      if (!(id in expected)) {
        print "evaluator produced an unexpected result for record " id > "/dev/stderr"
        failed = 1
      }
    }
    if (failed) exit 1
    for (i = 1; i <= count; i++) {
      split(rows[i], fields, FS)
      print rows[i] "\t" (fields[2] != "" ? state[i] : "ok")
    }
  }
' "$CHECK_OUTPUT" "$FACTS_TSV" > "$RECORDS"; then
  die "failed to join policy trigger evaluator results"
fi
[ -s "$RECORDS" ] || die "policy facts were found but no policy records were produced"

REACTIVE_EVENTS="PreToolUse PostToolUse UserPromptSubmit AssistantIntent"
total=0; bad_when=0; loose=0; oversized=0; no_trigger=0
say() { [ "$QUIET" = "1" ] || printf '%s\n' "$1"; }

while IFS=$'\t' read -r path when on enf bytes state; do
  [ -n "$path" ] || continue
  total=$((total + 1))
  rel="${path#"$HQ_ROOT"/}"

  if [ -z "$when" ] || [ -z "$on" ]; then
    no_trigger=$((no_trigger + 1))
    miss=""
    [ -z "$when" ] && miss="when:"
    [ -z "$on" ] && miss="${miss:+$miss and }on:"
    say "MISSING   $rel — no $miss in frontmatter"
    continue
  fi

  if [ "$state" = "malformed" ]; then
    bad_when=$((bad_when + 1))
    say "MALFORMED $rel — when: $when"
    continue
  fi

  if [ "$enf" = "hard" ]; then
    # A pure OR-chain containing `always` is TRUE for every event; && / ! make
    # the expression conditional, so those are left alone.
    case "$when" in
      *'&'*|*'!'*) : ;;
      *)
        case " $when " in
          *[!A-Za-z0-9_./-]always[!A-Za-z0-9_./-]*)
            hit=""
            for e in $REACTIVE_EVENTS; do
              case "$on" in *"$e"*) hit="$hit${hit:+, }$e" ;; esac
            done
            if [ -n "$hit" ]; then
              loose=$((loose + 1))
              say "LOOSE     $rel — when: always on reactive event(s) $hit (move to on: [SessionStart], or name a real signal)"
            fi
            ;;
        esac
        ;;
    esac

    if [ "${bytes:-0}" -gt "$HARD_RULE_MAX" ]; then
      oversized=$((oversized + 1))
      say "OVERSIZE  $rel — ${bytes} bytes injected verbatim (limit $HARD_RULE_MAX)"
    fi
  fi
done < "$RECORDS"

[ "$total" -gt 0 ] || die "policy records were produced but zero policies were scanned"

printf 'policies scanned: %s | malformed when: %s | missing trigger: %s | loose hard trigger: %s | oversized hard body: %s\n' \
  "$total" "$bad_when" "$no_trigger" "$loose" "$oversized"

if [ "$bad_when" -gt 0 ] || [ "$no_trigger" -gt 0 ]; then exit 1; fi
if [ "$STRICT" = "1" ] && { [ "$loose" -gt 0 ] || [ "$oversized" -gt 0 ]; }; then exit 1; fi
exit 0
