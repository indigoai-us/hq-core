#!/bin/bash
# inject-policy-on-trigger.sh — the sole policy-surfacing path.
#
# The pre-built policy digest (and its always-on / stack-filtered tiers) was
# retired; this hook now both injects every on:[SessionStart] policy whose
# `when:` matches at session start AND injects a short `<policy-reminder>` when a
# reactive policy's trigger fires mid-session (~150 bytes per match), deduped
# per session.
#
# TWO trigger sources, unified and deduped by slug:
#   (A) `when:`/`on:` frontmatter on policy files — boolean expressions over an
#       open token set, evaluated by core/scripts/eval-trigger.sh against facts
#       derived by core/scripts/derive-trigger-facts.sh. This is the primary,
#       data-driven path. Runs for whatever event fired (PreToolUse,
#       UserPromptSubmit, PostToolUse).
#   (B) Legacy hardcoded regex map (below) — for precise patterns a coarse
#       boolean token can't express (e.g. `git checkout {ref} -- .`, `pgrep`,
#       `IFS=":"`). PreToolUse only. Kept so migrating policies to `when:` is
#       incremental and never regresses coverage.
#
# Injection DEPTH is tiered by `enforcement:` (see the emit block at the bottom):
#   hard → the policy's whole body is injected verbatim, under a byte budget
#          whose overflow is reported, never silent.
#   soft/unset → the one-line `## Rule` excerpt, as always.
#
# Event: taken from `hook_event_name` in the stdin JSON (default PreToolUse).
# Scope (tenant-safe): global core/policies ALWAYS; the active repo's policies
#   ONLY when the session's cwd is in that repo; exactly ONE company's policies,
#   that company being the session's own active tenant — resolved as
#   HQ_POLICY_COMPANY > cwd companies/<slug> > session-meta company_slug (US-004,
#   see the DIRS block). The session-meta step is what lets an HQ-root session
#   load its bound company; it never widens scope to a second company.
# Dedupe: per session-id; a slug never fires twice in one session.
# Exit: always 0 (advisory hook, never blocks).

set -euo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS="$(cd "$SCRIPT_DIR/../.." && pwd)/core/scripts"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

JQ="$(command -v jq || true)"

. "$HELPERS/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

EVENT="$(extract hook_event_name)"; [ -z "$EVENT" ] && EVENT="PreToolUse"
SESSION_ID="$(extract session_id)"
TOOL_NAME="$(extract tool_name)"
CWD="$(extract cwd)"; [ -z "$CWD" ] && CWD="$HQ_ROOT"

# Tool-event trigger evaluation is scoped to CLI/Bash only — the frequent
# Read/Write/Edit/Glob tool calls don't pay the policy scan. The message path
# (UserPromptSubmit) is unaffected and still evaluates on every prompt.
if { [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "PostToolUse" ]; } && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Per-session dedupe ledger (unchanged location for continuity).
DEDUPE_DIR="$HQ_ROOT/workspace/orchestrator/policy-trigger-state"
mkdir -p "$DEDUPE_DIR" 2>/dev/null || true
DEDUPE_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.txt"
touch "$DEDUPE_FILE" 2>/dev/null || true

# Accumulate "slug<TAB>scope<TAB>abs_path<TAB>enforcement<TAB>rule<TAB>kind"
# matches. `kind` is internal metadata for the default interactive cap; the TSV
# contract remains its original five fields and retains its original ordering.
# Default emit still prints only slug+rule as <policy-reminder> prose; tsv mode
# (HQ_POLICY_EMIT=tsv, US-406) prints all five fields per line.
MATCHES=""
already() { grep -Fxq "$1" "$DEDUPE_FILE" 2>/dev/null; }
# Bash-native membership: a `printf "$MATCHES" | grep -q` pipe races under
# `set -o pipefail` — grep -q closes the pipe on first hit, printf takes SIGPIPE
# (141), and the pipeline fails the script before any reminder is emitted. The
# tab is the field delimiter, so match on "<slug><TAB>".
pending_has() { case "$MATCHES" in *"$1"$'\t'*) return 0 ;; *) return 1 ;; esac; }

add_match() {
  # add_match <slug> <scope> <abs_path> <enforcement> <rule> [reactive|baseline]
  # Back-compat: add_match <slug> <rule> → scope=core path= enf=unset
  local slug="$1" scope rule path enf kind
  if [ "$#" -ge 5 ]; then
    scope="$2"; path="$3"; enf="$4"; rule="$5"
    kind="${6:-reactive}"
  else
    scope="core"; path=""; enf="unset"; rule="${2:-}"; kind="reactive"
  fi
  [ -n "$slug" ] || return 0
  already "$slug" && return 0
  pending_has "$slug" && return 0
  [ -n "$enf" ] || enf="unset"
  [ "$kind" = "baseline" ] || kind="reactive"
  # Tabs inside rule would break the field layout — collapse them.
  rule="${rule//$'\t'/ }"
  MATCHES="${MATCHES}${slug}	${scope}	${path}	${enf}	${rule}	${kind}
"
}

# ── (A) Frontmatter when:/on: evaluation ──────────────────────────────────
if [ -n "$JQ" ] && [ -f "$HELPERS/eval-trigger.sh" ] && [ -f "$HELPERS/derive-trigger-facts.sh" ]; then
  FACTS="$(printf '%s' "$STDIN_JSON" | bash "$HELPERS/derive-trigger-facts.sh" "$EVENT" 2>/dev/null || true)"

  # AssistantIntent channel: AI-message-only facts, available where there is a
  # transcript look-back (PreToolUse + UserPromptSubmit). Policies with
  # `on: [AssistantIntent]` are evaluated against THIS set, not the event facts.
  INTENT_FACTS=""; INTENT_MODE=0
  if [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "UserPromptSubmit" ]; then
    INTENT_MODE=1
    INTENT_FACTS="$(printf '%s' "$STDIN_JSON" | bash "$HELPERS/derive-trigger-facts.sh" AssistantIntent 2>/dev/null || true)"
  fi

  # Policies whose `on:` includes SessionStart form an always-injected per-session
  # BASELINE: they are injected on the FIRST qualifying event of a session (the
  # SessionStart event itself, or — if that was missed or lost to resume/
  # compaction — the first prompt or Bash command), gated by their `when:`
  # (`when: always` matches everywhere) and the per-session dedup ledger so each
  # fires at most once. There is no separate digest to dedup against; this hook is
  # the sole policy-surfacing path.
  # personal/policies is read DIRECTLY (not via the old reindex symlink mirror
  # into core/policies): personal is now the sole read source for the personal
  # overlay. Both core (shipped) and personal surface — no override semantics.
  #
  # ORDER IS LOAD-BEARING (US-003): both match paths downstream are
  # first-match-wins on the policy id, so DIRS order IS the precedence order.
  # HQ's documented precedence is company > repo > global — company and repo
  # dirs must therefore precede core, or a core policy sharing an id silently
  # overrides the company copy (observed live with three core/indigo id
  # collisions; regression test: inject-policy-scope-precedence.test.sh).
  DIRS=()
  # Company-scope precedence (highest first), US-004 / US-406:
  #   HQ_POLICY_COMPANY env override  (caller outside companies/<slug>)
  #   > cwd companies/<slug>
  #   > session-meta company_slug     (HQ-root orchestration sessions — so the
  #                                    active tenant's guardrails still load in
  #                                    the sessions most likely to touch infra)
  # EXACTLY ONE branch ever sets co_scope, so the company policy dir is appended
  # AT MOST ONCE even when cwd and session meta agree — the dedupe is structural,
  # not a filter. Fail-open: any resolution miss leaves co_scope empty and the
  # behaviour identical to today's unresolved-company path.
  co_scope=""
  if [ -n "${HQ_POLICY_COMPANY:-}" ]; then
    co_scope="$HQ_POLICY_COMPANY"
  else
    case "$CWD" in
      *companies/*) co_scope="$(printf '%s' "$CWD" | sed -nE 's#.*companies/([^/]+).*#\1#p')" ;;
    esac
    if [ -z "$co_scope" ] && [ -n "${SESSION_ID:-}" ]; then
      # Read THIS session's own meta.yaml directly, keyed off the session id in
      # the hook payload. Do not shell out to hq-session.sh get: it resolves the
      # session from this process's environment, which on a hook path is the
      # host's, not necessarily the one that fired the event.
      # awk idiom lifted verbatim from master-hook.sh:119 so both paths resolve
      # the company identically. READ ONLY: master-hook.sh bootstraps meta.yaml;
      # a second writer here would race.
      META="$HQ_ROOT/workspace/sessions/$SESSION_ID/meta.yaml"
      [ -f "$META" ] && co_scope="$(awk '$1 == "company_slug:" { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$META")"
    fi
  fi
  [ -n "$co_scope" ] && DIRS+=("$HQ_ROOT/companies/$co_scope/policies")
  case "$CWD" in
    *repos/public/*|*repos/private/*)
      rscope="$(printf '%s' "$CWD" | sed -nE 's#.*repos/(public|private)/.*#\1#p')"
      rname="$(printf '%s' "$CWD" | sed -nE 's#.*repos/[^/]+/([^/]+).*#\1#p')"
      [ -n "$rscope" ] && [ -n "$rname" ] && DIRS+=("$HQ_ROOT/repos/$rscope/$rname/.claude/policies") ;;
  esac
  DIRS+=("$HQ_ROOT/personal/policies" "$HQ_ROOT/core/policies")

  # Collect in-scope policy files (skip generated/template/readme AND sync
  # conflict/drift copies). A real policy filename is a kebab-case slug —
  # `<slug>.md`, never containing a space or a sync-conflict marker. Cross-
  # machine sync (iCloud/Dropbox/Syncthing/hq-sync) mints conflict copies like
  # `foo 2.md`, `foo (conflicted copy).md`, `foo.sync-conflict-<host>.md`. A
  # single runaway can leave TENS OF THOUSANDS of these (observed live: 23k
  # copies in one core/policies, one slug alone at 1000+). Because this hook
  # awks EVERY matched file on every prompt and every Bash call, that bloat
  # pushed the scan past the 60s hook timeout, so UserPromptSubmit output was
  # discarded and every request stalled a full minute. Skipping conflict/drift
  # copies keeps the scan proportional to the real policy set. It is also safe:
  # no legitimate policy slug contains a space, so this can never drop a real
  # policy — a same-slug conflict copy is a stale duplicate of one still
  # collected under its canonical name.
  POLICY_FILES=()
  for dir in "${DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        example-policy.md|README.md) continue ;;
        *" "*) continue ;;              # any space => sync conflict/drift copy
        *.sync-conflict-*.md) continue ;;  # Syncthing-style conflict copy
      esac
      POLICY_FILES+=("$f")
    done
  done

  # SINGLE-PASS evaluator. One awk process parses every policy's frontmatter and
  # evaluates its `when:` boolean expression INTERNALLY — the eval-trigger.sh
  # recursive-descent grammar + safety gate are ported verbatim into evalexpr()
  # below, with identical semantics (0=TRUE, 1=FALSE, 2=empty/unsafe→fail-open).
  # It applies the per-session dedup itself and prints `slug<TAB>rule` per match.
  # This replaces a fork-per-policy loop
  # (~3 procs × N policies, one of them a `bash eval-trigger.sh` spawn) with a
  # SINGLE awk invocation. The hook runs on every Bash PreToolUse and every
  # prompt, so that fork count was the dominant latency. eval-trigger.sh itself
  # stays the spec'd standalone evaluator (tests + CLI); the hot path no longer
  # shells out to it.
  ALREADY="$(cat "$DEDUPE_FILE" 2>/dev/null || true)"
  if [ "${#POLICY_FILES[@]}" -gt 0 ]; then
    while IFS=$'\t' read -r slug scope path enf rule kind; do
      add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind"
    done < <(
      # ALREADY (the dedupe ledger) is NEWLINE-separated and, after SessionStart
      # injects every on:[SessionStart] policy, routinely has many lines. It is
      # passed via the environment, NOT `awk -v`: onetrueawk/mawk (the default
      # awk on macOS/BSD) abort with "newline in string" on a `-v` value that
      # contains a literal newline, which silently kills this whole evaluation
      # for the rest of the session. ENVIRON has no such restriction. Keep it on
      # the env — do NOT move it back to `-v ALREADY=`.
      # Emit: slug<TAB>scope<TAB>abs_path<TAB>enforcement<TAB>rule<TAB>kind.
      # `kind` is consumed only inside this hook before prose emission; the
      # public HQ_POLICY_EMIT=tsv path continues to print five fields below.
      HQ_ALREADY="$ALREADY" awk -v EVENT="$EVENT" -v INTENT_MODE="$INTENT_MODE" \
          -v EVFACTS="$FACTS" -v AIFACTS="$INTENT_FACTS" '
      function skipsp() { while (substr(E, pos, 1) == " ") pos++ }
      function pOr(  v){ v=pAnd(); skipsp(); while(substr(E,pos,2)=="||"){pos+=2; if(pAnd()||v)v=1;else v=0} return v }
      function pAnd(  v){ v=pNot(); skipsp(); while(substr(E,pos,2)=="&&"){pos+=2; if(pNot()&&v)v=1;else v=0} return v }
      function pNot(  c){ skipsp(); c=substr(E,pos,1); if(c=="!"){pos++; return (pNot()?0:1)} return pAtom() }
      function pAtom(  v,c){ skipsp(); c=substr(E,pos,1); if(c=="("){pos++; v=pOr(); skipsp(); if(substr(E,pos,1)==")")pos++; return v} pos++; return (c=="1")?1:0 }
      # evalexpr(expr, which) -> 0 TRUE | 1 FALSE | 2 fail-open. which: "ev"|"ai".
      function evalexpr(expr, which,   e,s,out,tok,present) {
        e=expr; gsub(/[ \t]/,"",e); if(e=="") return 2            # empty -> fail open
        s=expr; out=""
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH)
          present = (which=="ev") ? (tok in evh) : (tok in aih)
          out = out substr(s,1,RSTART-1) (present?"1":"0")
          s = substr(s,RSTART+RLENGTH)
        }
        out = out s
        if (out ~ /[^01&|!() ]/) return 2                          # unsafe -> fail open
        E=out; pos=1
        return (pOr() ? 0 : 1)
      }
      function base(p,   n,a,b){ n=split(p,a,"/"); b=a[n]; sub(/\.md$/,"",b); return b }
      function scopeof(p) {
        if (p ~ /\/companies\//) return "company"
        if (p ~ /\/repos\//) return "repo"
        if (p ~ /\/personal\//) return "personal"
        return "core"
      }
      # `always` is the documented canonical unconditional fact. A policy that
      # is eligible only through SessionStart and whose expression reduces to
      # TRUE once `always` is substituted is baseline; one with a real event
      # condition is reactive. This deliberately handles `always || token` as
      # baseline too, without making a non-tautological expression baseline.
      function cskipsp() { while (substr(C, cpos, 1) == " ") cpos++ }
      function cOr(   v,w) { v=cAnd(); cskipsp(); while(substr(C,cpos,2)=="||"){cpos+=2; w=cAnd(); if(v==1||w==1)v=1; else if(v==0&&w==0)v=0; else v=2} return v }
      function cAnd(  v,w) { v=cNot(); cskipsp(); while(substr(C,cpos,2)=="&&"){cpos+=2; w=cNot(); if(v==0||w==0)v=0; else if(v==1&&w==1)v=1; else v=2} return v }
      function cNot(  v,c) { cskipsp(); c=substr(C,cpos,1); if(c=="!"){cpos++; v=cNot(); return (v==2 ? 2 : (v ? 0 : 1))} return cAtom() }
      function cAtom( v,c) { cskipsp(); c=substr(C,cpos,1); if(c=="("){cpos++; v=cOr(); cskipsp(); if(substr(C,cpos,1)==")")cpos++; return v} cpos++; return (c=="1" ? 1 : (c=="0" ? 0 : 2)) }
      function unconditional(expr,   s,out,tok) {
        s=expr; out=""
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH)
          out=out substr(s,1,RSTART-1) (tok=="always" ? "1" : "x")
          s=substr(s,RSTART+RLENGTH)
        }
        out=out s
        if (out ~ /[^01x&|!() ]/) return 0
        C=out; cpos=1
        return (cOr()==1 && substr(C,cpos) ~ /^[ ]*$/)
      }
      function finalize(   onpad,ev_on,ai_on,ss_on,matched,r,sc,en,kind) {
        if (whenx=="") return
        if (id=="") id=base(fname)
        if (onx=="") onx="PreToolUse"                              # default when on: omitted
        onpad=" " onx " "
        ev_on = (index(onpad," " EVENT " ")>0)
        ai_on = (index(onpad," AssistantIntent ")>0)
        # on:[SessionStart] policies are an always-injected per-session BASELINE:
        # eligible on ANY triggering event, not just the SessionStart event, so a
        # session backfills any baseline slug not yet in the ledger on whatever
        # event fires first. Still gated by when: (vs the current event facts) and
        # the per-session dedup ledger, so each fires at most once per session.
        ss_on = (index(onpad," SessionStart ")>0)
        if (!ev_on && !ss_on && !(ai_on && INTENT_MODE)) return
        if (id in already) return                                  # per-session dedup ledger
        if (id in emitted) return                                  # de-dup within this run
        matched=0
        if (ev_on || ss_on) { r=evalexpr(whenx,"ev"); if(r==0||r==2) matched=1 }
        if (!matched && ai_on && INTENT_MODE) { r=evalexpr(whenx,"ai"); if(r==0||r==2) matched=1 }
        if (matched) {
          emitted[id]=1
          sc=scopeof(fname)
          en=(enf=="" ? "unset" : enf)
          # Policies whose current event is explicitly listed are reactive even
          # if they also carry SessionStart. Conditional SessionStart-only
          # policies are reactive as well: they matched facts from this event.
          # Only the unconditional SessionStart backfill is baseline.
          kind=((ss_on && !ev_on && !(ai_on && INTENT_MODE) && unconditional(whenx)) ? "baseline" : "reactive")
          gsub(/\t/," ",rule)
          print id "\t" sc "\t" fname "\t" en "\t" rule "\t" kind
        }
      }
      function reset_file(){ d=0; id=""; whenx=""; onx=""; enf=""; rule=""; rsec=0; rcap=0 }
      BEGIN {
        n=split(EVFACTS,fa,/[ ,]+/); for(i=1;i<=n;i++) if(fa[i]!="") evh[fa[i]]=1
        n=split(AIFACTS,ga,/[ ,]+/); for(i=1;i<=n;i++) if(ga[i]!="") aih[ga[i]]=1
        n=split(ENVIRON["HQ_ALREADY"],za,"\n"); for(i=1;i<=n;i++) if(za[i]!="") already[za[i]]=1
        reset_file()
      }
      FNR==1 { if (seen) finalize(); reset_file(); seen=1 }
      { fname=FILENAME }
      /^---[ \t]*$/ { if (d<2) { d++; next } }
      d==1 && /^id:/   { s=$0; sub(/^id:[ \t]*/,"",s);   gsub(/^["'"'"']|["'"'"']$/,"",s); id=s; next }
      d==1 && /^when:/ { s=$0; sub(/^when:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s); whenx=s; next }
      d==1 && /^on:/   { s=$0; sub(/^on:[ \t]*/,"",s);   gsub(/[][, ]/," ",s); onx=s; next }
      d==1 && /^enforcement:/ {
        s=$0; sub(/^enforcement:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s)
        gsub(/^["'"'"']|["'"'"']$/,"",s); enf=s; next
      }
      d>=2 && /^## Rule[ \t]*$/ { rsec=1; next }
      d>=2 && rsec && /^## / { rsec=0 }
      d>=2 && rsec && !rcap && NF { line=$0; gsub(/\*\*/,"",line); if(length(line)>160) line=substr(line,1,157)"..."; rule=line; rcap=1 }
      END { if (seen) finalize() }
      ' "${POLICY_FILES[@]}" | {
        # Byte-oriented awk can cut through a multibyte code point. Some iconv
        # implementations still return nonzero after -c repairs the output.
        iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true
      }
    )
  fi
fi

# ── (B) Legacy hardcoded regex map (Bash PreToolUse only) ─────────────────
# Precise command patterns a coarse boolean `when:` token can't express. Only
# Bash rows remain — per the CLI/bash-only scope, this hook no longer fires on
# Edit/Write/MultiEdit, so the former settings/core-path file rows are dropped
# (those cases stay covered mechanically by warn-cross-company-settings.sh and
# protect-core.sh / block-core-writes.sh).
#
# Rows are kept ONLY where path (A) cannot reach the same slug as broadly. The
# former git-checkout-not-a-probe row was removed — the policy now carries
# `when: git && checkout`, so path (A) injects that slug on every `git checkout`
# (a superset of the old `-- .` pattern) and dedup made the legacy row dead.
# The pnpm row STAYS: its `(install|i|add)` aliases are NOT all reachable by the
# policy's `when: install` token (`add` is a different word; `i` is too short to
# tokenize), so it still covers cases path (A) misses. Rule of thumb: drop a
# legacy row only when an equivalent `when:` covers the SAME command surface.
if [ "$EVENT" = "PreToolUse" ] && [ "$TOOL_NAME" = "Bash" ]; then
  ARG="$(extract tool_input.command)"
  if [ -n "$ARG" ]; then
    TAB=$'\t'
    TRIGGERS=$(printf '%s\n' \
      "(^|[[:space:]])find[[:space:]]${TAB}hq-glob-scoped-path${TAB}\`find\` is unrestricted but Glob is hook-blocked. Prefer qmd/Grep over \`find\`; scope \`find\` to a known sub-tree." \
      "(^|[[:space:]])pgrep[[:space:]]${TAB}hq-bash-discipline${TAB}Never hardcode a \`pgrep\`-discovered PID into a follow-up command — re-discover and validate with \`ps\` each invocation." \
      "(^|[[:space:]])git[[:space:]]+filter-repo[[:space:]]${TAB}hq-git-discipline${TAB}\`git filter-repo --path\` is case-sensitive. Run separate passes for case variants (e.g. \`Foo\` and \`foo\`)." \
      "(^|[[:space:]])git[[:space:]]+reflog[[:space:]]+expire[[:space:]]${TAB}hq-git-discipline${TAB}\`git reflog expire --all --expire=now\` permanently destroys stashes too. Stash explicitly first or filter the expire." \
      "IFS=\":\"${TAB}hq-bash-discipline${TAB}\`IFS=\":\" read\` corrupts paths. Use \`IFS=\$'\\''\\\\t'\\''\` or read fields by index instead." \
      "(^|[[:space:]])(npm|yarn|bun|pnpm)[[:space:]]+(install|i|add)[[:space:]]+[^-]${TAB}hq-pnpm-min-release-age-supply-chain${TAB}Supply-chain guard: prefer \`pnpm\` with \`minimum-release-age=1440\` (24h). Raw \`npm/yarn/bun install <pkg>\` is hard-blocked by block-unsafe-package-install.sh.")
    while IFS=$'\t' read -r t_pat t_slug t_rule; do
      [ -z "$t_pat" ] && continue
      if printf '%s' "$ARG" | grep -Eq "$t_pat"; then
        # Legacy rows have no on-disk path; scope=core, enforcement=unset.
        add_match "$t_slug" "core" "" "unset" "$t_rule"
      fi
    done <<< "$TRIGGERS"
  fi
fi

# ── Emit + record ─────────────────────────────────────────────────────────
[ -n "$MATCHES" ] || exit 0

# US-406: machine-readable records for the agent-session entrypoint. No prose
# wrapper, no interactive 16-cap (consumer applies HQ_SESSION_POLICY_MAX_*).
if [ "${HQ_POLICY_EMIT:-}" = "tsv" ]; then
  printf '%s' "$MATCHES" | while IFS=$'\t' read -r slug scope path enf rule kind; do
    [ -z "$slug" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$scope" "$path" "$enf" "$rule"
    printf '%s\n' "$slug" >> "$DEDUPE_FILE"
  done
  exit 0
fi

# Bound the SessionStart-heavy baseline so box preflight cannot fail closed
# (US-003 / former US-013). Crucially, stable-partition reactive matches ahead
# of the SessionStart baseline BEFORE applying the cap: scope order is preserved
# inside each group, but an event-specific policy must not lose its slot to a
# generic policy that would have fired on any event.
#
# This is Bash-native (portable to Bash 3.2) rather than sort -s so the stable
# ordering does not depend on GNU/BSD sort differences.
ORDERED_MATCHES=""
for match_kind in reactive baseline; do
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    case "$match" in
      *$'\t'"$match_kind") ORDERED_MATCHES="${ORDERED_MATCHES}${match}
" ;;
    esac
  done <<< "$MATCHES"
done
MATCHES="$ORDERED_MATCHES"

# Truncation is NEVER silent. In addition to naming withheld policies below,
# record them now: the SessionStart baseline is a one-time introduction, so a
# policy that lost the cap was considered and dropped, not deferred to the next
# event where it could crowd out new reactive work again.
SESSION_POLICY_CAP="${HQ_SESSION_POLICY_CAP:-16}"
MATCH_COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
WITHHELD=0
WITHHELD_MATCHES=""
if [ "$MATCH_COUNT" -gt "$SESSION_POLICY_CAP" ]; then
  WITHHELD=$((MATCH_COUNT - SESSION_POLICY_CAP))
  KEPT_MATCHES=""
  kept=0
  while IFS= read -r match; do
    [ -n "$match" ] || continue
    if [ "$kept" -lt "$SESSION_POLICY_CAP" ]; then
      KEPT_MATCHES="${KEPT_MATCHES}${match}
"
      kept=$((kept + 1))
    else
      WITHHELD_MATCHES="${WITHHELD_MATCHES}${match}
"
    fi
  done <<< "$MATCHES"
  MATCHES="$KEPT_MATCHES"
fi

WITHHELD_NAMES=""
WITHHELD_NAMED=0
if [ -n "$WITHHELD_MATCHES" ]; then
  while IFS=$'\t' read -r slug scope path enf rule kind; do
    [ -n "$slug" ] || continue
    printf '%s\n' "$slug" >> "$DEDUPE_FILE"
    if [ "$WITHHELD_NAMED" -lt 10 ]; then
      WITHHELD_NAMES="${WITHHELD_NAMES}${WITHHELD_NAMES:+, }${slug}"
      WITHHELD_NAMED=$((WITHHELD_NAMED + 1))
    fi
  done <<< "$WITHHELD_MATCHES"
fi

# Enforcement-tiered injection depth:
#   enforcement: hard  → the policy's ENTIRE body (everything after the closing
#                        frontmatter `---`) is injected verbatim. A binding rule
#                        must never reach the agent as a 160-char paraphrase of
#                        its first line — the caveats, the exceptions and the
#                        escape hatches all live further down the file.
#   soft / unset       → unchanged: the one-line `## Rule` excerpt, exactly as
#                        before (the default-prose fixture pins this path).
#
# Full text is bounded by a byte budget across the whole injection, consumed in
# reactive-first MATCHES order. Scope precedence (company > repo > personal >
# core) is preserved within each group, so event-specific hard rules claim the
# budget ahead of the SessionStart baseline. Overflow is NEVER silent: a policy
# that does not fit falls back to its summary line and is named in a trailing
# notice, so a shortened set can't be misread as the full text.
# Escape hatches: HQ_POLICY_HARD_FULL_TEXT=0 restores summary-only for hard
# policies; HQ_POLICY_HARD_BUDGET_BYTES resizes the budget.
HARD_FULL="${HQ_POLICY_HARD_FULL_TEXT:-1}"
HARD_BUDGET="${HQ_POLICY_HARD_BUDGET_BYTES:-40960}"

policy_body() {
  # Print everything after the closing frontmatter `---`, leading blank lines
  # trimmed. A file with no frontmatter (or an unreadable one) prints nothing,
  # and the caller falls back to the summary line — fail-open to prior
  # behaviour, never a dropped policy.
  awk '
    /^---[ \t]*$/ && d < 2 { d++; next }
    d >= 2 { if (!started && $0 ~ /^[ \t]*$/) next; started = 1; print }
  ' "$1" 2>/dev/null
}

printf '<policy-reminder>\n'
printf '%s' "$MATCHES" | {
  spent=0
  shortened=""
  while IFS=$'\t' read -r slug scope path enf rule kind; do
    [ -z "$slug" ] && continue
    printf '%s\n' "$slug" >> "$DEDUPE_FILE"
    body=""
    if [ "$HARD_FULL" != "0" ] && [ "$enf" = "hard" ] && [ -n "$path" ] && [ -r "$path" ]; then
      body="$(policy_body "$path")"
    fi
    if [ -n "$body" ]; then
      size="$(printf '%s' "$body" | wc -c | tr -d ' ')"
      if [ $((spent + size)) -le "$HARD_BUDGET" ]; then
        spent=$((spent + size))
        printf '> Policy `%s` (HARD — full text of `%s`):\n' "$slug" "${path#"$HQ_ROOT"/}"
        # Quote every body line into the reminder block, and neutralise any
        # literal <policy-reminder> tag inside a policy body (one exists today)
        # so an injected body cannot close or nest this block.
        printf '%s\n' "$body" \
          | sed -e 's#</policy-reminder>#[/policy-reminder]#g' \
                -e 's#<policy-reminder>#[policy-reminder]#g' \
                -e 's/^/> /' -e 's/^> $/>/'
        continue
      fi
      shortened="${shortened:+$shortened, }$slug"
    fi
    printf '> Policy `%s` applies here: %s\n' "$slug" "$rule"
  done
  if [ -n "$shortened" ]; then
    printf '> Full-text budget of %s bytes reached: these HARD policies were shortened to one-line summaries — %s. Read each in full at its own file before acting on it.\n' \
      "$HARD_BUDGET" "$shortened"
  fi
}
if [ "$WITHHELD" -gt 0 ]; then
  more=""
  if [ "$WITHHELD" -gt "$WITHHELD_NAMED" ]; then
    more=" (+$((WITHHELD - WITHHELD_NAMED)) more)"
  fi
  # Do not start this line with "> Policy `": inject-policy-e2e's slugs()
  # parser intentionally recognises that prefix as an injected policy record.
  printf '> Session policy cap withheld %s policies (cap %s): %s%s. Reactive matches were prioritized over the SessionStart baseline.\n' \
    "$WITHHELD" "$SESSION_POLICY_CAP" "$WITHHELD_NAMES" "$more"
fi
printf '> Read the full rule(s) at `core/policies/{slug}.md` if you need rationale.\n'
printf '</policy-reminder>\n'

exit 0
