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
# Event: taken from `hook_event_name` in the stdin JSON (default PreToolUse).
# Scope (tenant-safe): global core/policies ALWAYS; the active company's and
#   active repo's policies ONLY when the session is in that company/repo.
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

# Accumulate "slug<TAB>rule" matches here; dedup by slug at the end.
MATCHES=""
already() { grep -Fxq "$1" "$DEDUPE_FILE" 2>/dev/null; }
# Bash-native membership: a `printf "$MATCHES" | grep -q` pipe races under
# `set -o pipefail` — grep -q closes the pipe on first hit, printf takes SIGPIPE
# (141), and the pipeline fails the script before any reminder is emitted. The
# tab is the field delimiter, so match on "<slug><TAB>".
pending_has() { case "$MATCHES" in *"$1"$'\t'*) return 0 ;; *) return 1 ;; esac; }

add_match() {
  # add_match <slug> <rule>
  local slug="$1" rule="$2"
  [ -n "$slug" ] || return 0
  already "$slug" && return 0
  pending_has "$slug" && return 0
  MATCHES="${MATCHES}${slug}	${rule}
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
  case "$CWD" in
    *companies/*)
      co="$(printf '%s' "$CWD" | sed -nE 's#.*companies/([^/]+).*#\1#p')"
      [ -n "$co" ] && DIRS+=("$HQ_ROOT/companies/$co/policies") ;;
  esac
  case "$CWD" in
    *repos/public/*|*repos/private/*)
      rscope="$(printf '%s' "$CWD" | sed -nE 's#.*repos/(public|private)/.*#\1#p')"
      rname="$(printf '%s' "$CWD" | sed -nE 's#.*repos/[^/]+/([^/]+).*#\1#p')"
      [ -n "$rscope" ] && [ -n "$rname" ] && DIRS+=("$HQ_ROOT/repos/$rscope/$rname/.claude/policies") ;;
  esac
  DIRS+=("$HQ_ROOT/personal/policies" "$HQ_ROOT/core/policies")

  # Collect in-scope policy files (skip generated/template/readme).
  POLICY_FILES=()
  for dir in "${DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in _digest.md|example-policy.md|README.md) continue ;; esac
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
    while IFS=$'\t' read -r slug rule; do
      add_match "$slug" "$rule"
    done < <(
      # ALREADY (the dedupe ledger) is NEWLINE-separated and, after SessionStart
      # injects every on:[SessionStart] policy, routinely has many lines. It is
      # passed via the environment, NOT `awk -v`: onetrueawk/mawk (the default
      # awk on macOS/BSD) abort with "newline in string" on a `-v` value that
      # contains a literal newline, which silently kills this whole evaluation
      # for the rest of the session. ENVIRON has no such restriction. Keep it on
      # the env — do NOT move it back to `-v ALREADY=`.
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
      function finalize(   onpad,ev_on,ai_on,ss_on,matched,r) {
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
        if (matched) { emitted[id]=1; print id "\t" rule }
      }
      function reset_file(){ d=0; id=""; whenx=""; onx=""; rule=""; rsec=0; rcap=0 }
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
      d==1 && /^on:/   { s=$0; sub(/^on:[ \t]*/,"",s);   gsub(/[][,]/," ",s); onx=s; next }
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
        add_match "$t_slug" "$t_rule"
      fi
    done <<< "$TRIGGERS"
  fi
fi

# ── Emit + record ─────────────────────────────────────────────────────────
[ -n "$MATCHES" ] || exit 0

printf '<policy-reminder>\n'
printf '%s' "$MATCHES" | while IFS=$'\t' read -r slug rule; do
  [ -z "$slug" ] && continue
  printf '> Policy `%s` applies here: %s\n' "$slug" "$rule"
  printf '%s\n' "$slug" >> "$DEDUPE_FILE"
done
printf '> Read the full rule(s) at `core/policies/{slug}.md` if you need rationale.\n'
printf '</policy-reminder>\n'

exit 0
