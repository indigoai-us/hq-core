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
#   hard → the policy's BINDING body is injected verbatim (everything after the
#          frontmatter up to the first archival heading), under a per-policy
#          cap and a shared byte budget whose overflow is reported, never
#          silent.
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
STDIN_FILE=""
POLICY_TRIGGER_INPUT_FILE_LIMIT=65536

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS="$(cd "$SCRIPT_DIR/../.." && pwd)/core/scripts"
HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

JQ="$(command -v jq || true)"

. "$HELPERS/hook-lib.sh"

# The timeout watchdog and master hook use this exact session-hash convention
# for their per-dispatch journal. Adapter runtimes execute this hook before the
# master hook exports HQ_HOOK_TIMEOUT_JOURNAL_FILE, so derive the same path when
# the environment handoff has not happened yet.
policy_trigger_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\0' "$@" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' "$@" | sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s\0' "$@" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else
    return 1
  fi
}

policy_trigger_journal_file() {
  local journal_file="${HQ_HOOK_TIMEOUT_JOURNAL_FILE:-}" session_hash=""
  if [ -n "$journal_file" ]; then
    printf '%s' "$journal_file"
    return 0
  fi
  [ -n "${SESSION_ID:-}" ] || return 0
  session_hash="$(policy_trigger_sha256 "$SESSION_ID" 2>/dev/null || true)"
  [ -n "$session_hash" ] || return 0
  printf '%s/workspace/.hook-timeout-journal/%s.tsv' "$HQ_ROOT" "$session_hash"
}

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

# These four scalar values are required on every invocation. When jq is
# available (the same prerequisite for policy evaluation below), extract them
# in one process rather than launching jq four times. NUL delimiters keep
# whitespace and embedded newlines intact; command substitution then matches
# hq_json_get's existing trailing-newline behavior. Fall back to the shared
# helper when jq or a complete scalar result is unavailable.
INITIAL_FIELDS=()
if [ -n "$JQ" ]; then
  while IFS= read -r -d '' initial_field; do
    INITIAL_FIELDS+=("$initial_field")
  done < <(
    # shellcheck disable=SC2016 # jq program intentionally uses single quotes.
    printf '%s' "$STDIN_JSON" | "$JQ" -j '
      def scalar($path):
        try (getpath($path) | if . == null or type == "object" or type == "array" then "" else tostring end)
        catch "";
      scalar(["hook_event_name"]) + "\u0000",
      scalar(["session_id"]) + "\u0000",
      scalar(["tool_name"]) + "\u0000",
      scalar(["cwd"]) + "\u0000"
    ' 2>/dev/null
  )
fi
if [ "${#INITIAL_FIELDS[@]}" -eq 4 ]; then
  EVENT="$(printf '%s' "${INITIAL_FIELDS[0]}")"
  SESSION_ID="$(printf '%s' "${INITIAL_FIELDS[1]}")"
  TOOL_NAME="$(printf '%s' "${INITIAL_FIELDS[2]}")"
  CWD="$(printf '%s' "${INITIAL_FIELDS[3]}")"
else
  EVENT="$(extract hook_event_name)"
  SESSION_ID="$(extract session_id)"
  TOOL_NAME="$(extract tool_name)"
  CWD="$(extract cwd)"
fi
[ -z "$EVENT" ] && EVENT="PreToolUse"
[ -z "$CWD" ] && CWD="$HQ_ROOT"

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

# Second ledger for `inject: always` policies (see the frontmatter field of the
# same name). Where the session ledger above fires a slug at most once for the
# WHOLE session, this TURN ledger fires an `always` slug at most once per TURN:
# it is truncated at the start of every UserPromptSubmit (turn boundary), so an
# always-policy re-injects on each new user message, but is still deduped across
# the mid-turn Bash calls of that same turn (no per-command spam). The two
# ledgers are disjoint by policy: a `once` slug is only ever recorded in the
# session ledger, an `always` slug only in the turn ledger.
TURN_FILE="$DEDUPE_DIR/${SESSION_ID:-default}.turn.txt"
if [ "$EVENT" = "UserPromptSubmit" ]; then
  : > "$TURN_FILE" 2>/dev/null || true
fi
touch "$TURN_FILE" 2>/dev/null || true

# Accumulate
# "slug<TAB>scope<TAB>abs_path<TAB>enforcement<TAB>rule<TAB>kind<TAB>inject<TAB>whenstate"
# matches. `kind`, `inject` and `whenstate` are internal metadata (the cap, the
# dedup ledger, and the malformed-trigger notice); the TSV
# contract remains its original five fields and retains its original ordering.
# Default emit still prints only slug+rule as <policy-reminder> prose; tsv mode
# (HQ_POLICY_EMIT=tsv, US-406) prints all five fields per line.
MATCHES=""
# already <slug> [inject]  — has this slug already fired in the ledger that
# governs its cadence? `once` (default) consults the session ledger; `always`
# consults the per-turn ledger.
already() {
  if [ "${2:-once}" = "always" ]; then
    grep -Fxq "$1" "$TURN_FILE" 2>/dev/null
  else
    grep -Fxq "$1" "$DEDUPE_FILE" 2>/dev/null
  fi
}
# The ledgers are newline-separated policy slugs. Keep the normal path at the
# same process cost as before, but compact a ledger once it grows past 64 KiB.
# Compaction removes duplicate slugs without dropping an older policy, so the
# session-level dedupe contract remains intact while a noisy writer cannot make
# every later awk invocation scan an unbounded duplicate set. Both compaction
# and append take the same lock: replacing a ledger inode while another hook
# appends to the old inode would otherwise lose the new slug.
POLICY_LEDGER_COMPACT_THRESHOLD=65536
POLICY_LEDGER_LOCK_WAIT_ATTEMPTS=200
POLICY_LEDGER_LOCK_STALE_SECONDS=30

policy_ledger_lock_is_stale() {
  local lock_dir="$1" mtime="" now="" age=""
  if stat -c '%Y' "$lock_dir" >/dev/null 2>&1; then
    mtime="$(stat -c '%Y' "$lock_dir" 2>/dev/null || true)"
  elif stat -f '%m' "$lock_dir" >/dev/null 2>&1; then
    mtime="$(stat -f '%m' "$lock_dir" 2>/dev/null || true)"
  else
    return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age=$((now - mtime))
  [ "$age" -ge "$POLICY_LEDGER_LOCK_STALE_SECONDS" ]
}

acquire_policy_ledger_lock() {
  local ledger="$1" lock_dir="${1}.lock" stale_dir="" attempt=0
  while [ "$attempt" -lt "$POLICY_LEDGER_LOCK_WAIT_ATTEMPTS" ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      if printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null; then
        return 0
      fi
      rm -f "$lock_dir/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    fi

    # A fresh directory may not have its pid file yet. Preserve it through the
    # grace period and retry. Once a lock is older than the bounded critical
    # section, rename it away before reclaiming it so a new owner cannot be
    # deleted after the stale check.
    if policy_ledger_lock_is_stale "$lock_dir"; then
      stale_dir="${lock_dir}.stale.$$.$attempt"
      if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
        rm -f "$stale_dir/pid" 2>/dev/null || true
        rmdir "$stale_dir" 2>/dev/null || true
        attempt=$((attempt + 1))
        continue
      fi
    fi
    sleep 0.01
    attempt=$((attempt + 1))
  done
  return 1
}

release_policy_ledger_lock() {
  local ledger="$1" lock_dir="${1}.lock" owner=""
  owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  [ "$owner" = "$$" ] || return 0
  rm -f "$lock_dir/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

# record_slug <slug> <inject>  — record a fired slug in the ledger that governs
# its cadence, so it is not re-emitted before that ledger next resets.
record_slug() {
  local ledger
  if [ "${2:-once}" = "always" ]; then
    ledger="$TURN_FILE"
  else
    ledger="$DEDUPE_FILE"
  fi
  if ! acquire_policy_ledger_lock "$ledger"; then
    printf 'inject-policy-on-trigger: could not lock policy ledger %s; slug was not recorded.\n' "$ledger" >&2
    return 0
  fi
  if ! printf '%s\n' "$1" >> "$ledger" 2>/dev/null; then
    printf 'inject-policy-on-trigger: could not append slug to policy ledger %s.\n' "$ledger" >&2
  fi
  release_policy_ledger_lock "$ledger"
}

policy_file_bytes() {
  local bytes=""
  bytes="$(wc -c < "$1" 2>/dev/null || true)"
  bytes="${bytes//[!0-9]/}"
  printf '%s' "${bytes:-0}"
}

policy_bytes_bucket() {
  local bytes="$1"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  if [ "$bytes" -lt 16384 ]; then
    printf '<16K'
  elif [ "$bytes" -lt 65536 ]; then
    printf '16-64K'
  elif [ "$bytes" -lt 131072 ]; then
    printf '64-128K'
  else
    printf '>128K'
  fi
}

compact_policy_ledger() {
  local ledger="$1" bytes="$2" temporary=""
  case "$bytes" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$bytes" -gt "$POLICY_LEDGER_COMPACT_THRESHOLD" ] || return 0
  [ -f "$ledger" ] || return 0
  acquire_policy_ledger_lock "$ledger" || return 0
  temporary="$(mktemp "${ledger}.compact.XXXXXX" 2>/dev/null || true)"
  if [ -z "$temporary" ]; then
    release_policy_ledger_lock "$ledger"
    return 0
  fi
  if awk '!seen[$0]++' "$ledger" > "$temporary" 2>/dev/null; then
    mv -f "$temporary" "$ledger" 2>/dev/null || rm -f "$temporary" 2>/dev/null || true
  else
    rm -f "$temporary" 2>/dev/null || true
  fi
  release_policy_ledger_lock "$ledger"
}

# c015 already gives the hook-timeout journal a per-session metadata file.
# Append the current policy-input sizes there so a subsequent timeout warning
# carries the context that was observed by this hook. The master hook resets
# this metadata file at the start of each event, so the append remains bounded
# to the current dispatch and does not become a second unbounded ledger.
record_policy_trigger_sizes() {
  local journal_file metadata_file journal_dir temporary
  journal_file="$(policy_trigger_journal_file)"
  [ -n "$journal_file" ] || return 0
  metadata_file="${journal_file}.meta"
  journal_dir="${journal_file%/*}"
  mkdir -p "$journal_dir" 2>/dev/null || return 0
  if [ ! -f "$metadata_file" ]; then
    temporary="$(mktemp "${metadata_file}.XXXXXX" 2>/dev/null || true)"
    if [ -n "$temporary" ]; then
      if printf 'bash_env_set=unset\ntiming_precision=ms\n' > "$temporary" 2>/dev/null; then
        mv -f "$temporary" "$metadata_file" 2>/dev/null || rm -f "$temporary" 2>/dev/null || true
      else
        rm -f "$temporary" 2>/dev/null || true
      fi
    fi
  fi
  [ -f "$metadata_file" ] || return 0
  printf 'policy_trigger_script=inject-policy-on-trigger.sh\npolicy_trigger_event=%s\nledger_bytes_bucket=%s\nfacts_bytes_bucket=%s\n' \
    "$EVENT" "$LEDGER_BYTES_BUCKET" "$FACTS_BYTES_BUCKET" >> "$metadata_file" 2>/dev/null || true
}

FACTS_FILE=""
INTENT_FACTS_FILE=""
FACT_PAIR_FILE=""
FACTS_TMP_DIR=""
POLICY_ARG_INLINE_LIMIT=65536

cleanup_policy_fact_files() {
  [ -z "$STDIN_FILE" ] || rm -f "$STDIN_FILE" 2>/dev/null || true
  [ -z "$FACTS_FILE" ] || rm -f "$FACTS_FILE" 2>/dev/null || true
  [ -z "$INTENT_FACTS_FILE" ] || rm -f "$INTENT_FACTS_FILE" 2>/dev/null || true
  [ -z "$FACT_PAIR_FILE" ] || rm -f "$FACT_PAIR_FILE" 2>/dev/null || true
}

trap cleanup_policy_fact_files EXIT

prepare_policy_trigger_input() {
  local temporary=""
  [ "${#STDIN_JSON}" -gt "$POLICY_TRIGGER_INPUT_FILE_LIMIT" ] || return 0
  [ -n "$STDIN_FILE" ] && return 0
  [ -n "$FACTS_TMP_DIR" ] || FACTS_TMP_DIR="$HQ_ROOT/workspace/orchestrator/hook-state"
  mkdir -p "$FACTS_TMP_DIR" 2>/dev/null || return 0
  temporary="$(mktemp "$FACTS_TMP_DIR/.policy-trigger-input.XXXXXX" 2>/dev/null || true)"
  [ -n "$temporary" ] || return 0
  if printf '%s' "$STDIN_JSON" > "$temporary" 2>/dev/null; then
    STDIN_FILE="$temporary"
  else
    rm -f "$temporary" 2>/dev/null || true
  fi
}

run_derive_trigger_facts() {
  local event="$1" with_intent="${2:-0}"
  if [ -n "$STDIN_FILE" ]; then
    if [ "$with_intent" = "1" ]; then
      bash "$HELPERS/derive-trigger-facts.sh" "$event" --with-assistant-intent < "$STDIN_FILE" 2>/dev/null || true
    else
      bash "$HELPERS/derive-trigger-facts.sh" "$event" < "$STDIN_FILE" 2>/dev/null || true
    fi
  elif [ "$with_intent" = "1" ]; then
    printf '%s' "$STDIN_JSON" | bash "$HELPERS/derive-trigger-facts.sh" "$event" --with-assistant-intent 2>/dev/null || true
  else
    printf '%s' "$STDIN_JSON" | bash "$HELPERS/derive-trigger-facts.sh" "$event" 2>/dev/null || true
  fi
}

spill_policy_facts() {
  local value="$1" label="$2" temporary=""
  [ "${#value}" -gt "$POLICY_ARG_INLINE_LIMIT" ] || return 0
  [ -n "$FACTS_TMP_DIR" ] || return 0
  [ -d "$FACTS_TMP_DIR" ] || mkdir -p "$FACTS_TMP_DIR" 2>/dev/null || return 0
  temporary="$(mktemp "$FACTS_TMP_DIR/.policy-trigger-$label.XXXXXX" 2>/dev/null || true)"
  [ -n "$temporary" ] || return 0
  if printf '%s\n' "$value" > "$temporary"; then
    case "$label" in
      facts) FACTS_FILE="$temporary" ;;
      intent-facts) INTENT_FACTS_FILE="$temporary" ;;
    esac
  else
    rm -f "$temporary" 2>/dev/null || true
  fi
}
# Bash-native membership: a `printf "$MATCHES" | grep -q` pipe races under
# `set -o pipefail` — grep -q closes the pipe on first hit, printf takes SIGPIPE
# (141), and the pipeline fails the script before any reminder is emitted. The
# tab is the field delimiter, so match on "<slug><TAB>".
pending_has() { case "$MATCHES" in *"$1"$'\t'*) return 0 ;; *) return 1 ;; esac; }

add_match() {
  # add_match <slug> <scope> <abs_path> <enforcement> <rule> [reactive|baseline] [once|always] [ok|malformed] [specificity]
  # Back-compat: add_match <slug> <rule> → scope=core path= enf=unset
  local slug="$1" scope rule path enf kind injv ws spec
  if [ "$#" -ge 5 ]; then
    scope="$2"; path="$3"; enf="$4"; rule="$5"
    kind="${6:-reactive}"
    injv="${7:-once}"
    ws="${8:-ok}"
    spec="${9:-0}"
  else
    scope="core"; path=""; enf="unset"; rule="${2:-}"; kind="reactive"; injv="once"; ws="ok"; spec=0
  fi
  case "$spec" in ''|*[!0-9]*) spec=0 ;; esac
  [ -n "$slug" ] || return 0
  [ "$injv" = "always" ] || injv="once"
  already "$slug" "$injv" && return 0
  pending_has "$slug" && return 0
  [ -n "$enf" ] || enf="unset"
  [ "$kind" = "baseline" ] || kind="reactive"
  [ "$ws" = "malformed" ] || ws="ok"
  # Tabs inside rule would break the field layout — collapse them.
  rule="${rule//$'\t'/ }"
  MATCHES="${MATCHES}${slug}	${scope}	${path}	${enf}	${rule}	${kind}	${injv}	${ws}	${spec}
"
}

# ── (A) Frontmatter when:/on: evaluation ──────────────────────────────────
if [ -n "$JQ" ] && [ -f "$HELPERS/eval-trigger.sh" ] && [ -f "$HELPERS/derive-trigger-facts.sh" ]; then
  # Bash 3.2's command-substitution reader consumes a pipe one byte at a time
  # for this helper. Large tool commands therefore spend the entire adapter
  # deadline moving an already-buffered JSON string through a pipe. Hand the
  # helper a regular file once the payload crosses the inline threshold.
  FACTS_TMP_DIR="$HQ_ROOT/workspace/orchestrator/hook-state"
  prepare_policy_trigger_input
  # AssistantIntent channel: AI-message-only facts, available where there is a
  # transcript look-back (PreToolUse + UserPromptSubmit). Policies with
  # `on: [AssistantIntent]` are evaluated against THIS set, not the event facts.
  INTENT_FACTS=""; INTENT_MODE=0
  if [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "UserPromptSubmit" ]; then
    INTENT_MODE=1
    # Derive both fact channels from one payload parse and one helper launch.
    # The two records are deliberately newline-delimited: fact sets are
    # space-separated tokens, and the helper normalizes all text-derived
    # newlines before returning. Read the records from a file rather than using
    # `${pair#*newline}`; Bash's shortest-prefix matcher becomes quadratic on a
    # 200 KB first line and can consume the entire adapter deadline.
    mkdir -p "$FACTS_TMP_DIR" 2>/dev/null || true
    FACT_PAIR_FILE="$(mktemp "$FACTS_TMP_DIR/.policy-trigger-pair.XXXXXX" 2>/dev/null || true)"
    if [ -n "$FACT_PAIR_FILE" ]; then
      run_derive_trigger_facts "$EVENT" 1 > "$FACT_PAIR_FILE"
      FACTS=""
      INTENT_FACTS=""
      pair_lines=0
      while IFS= read -r pair_line; do
        if [ "$pair_lines" -eq 0 ]; then
          FACTS="$pair_line"
          pair_lines=1
        else
          INTENT_FACTS="$pair_line"
          pair_lines=2
          break
        fi
      done < "$FACT_PAIR_FILE"
      if [ "$pair_lines" -lt 2 ]; then
        INTENT_FACTS="$(run_derive_trigger_facts AssistantIntent)"
      fi
    else
      FACTS="$(run_derive_trigger_facts "$EVENT")"
      INTENT_FACTS="$(run_derive_trigger_facts AssistantIntent)"
    fi
  else
    FACTS="$(run_derive_trigger_facts "$EVENT")"
  fi

  # Keep large fact sets out of awk -v. Derived facts are ASCII tokens, so the
  # Bash lengths are byte lengths here and avoid adding wc subprocesses to the
  # fact derivation hot path. The ledger byte counts replace the two old cat
  # reads that previously materialized the whole ledgers in shell variables.
  spill_policy_facts "$FACTS" facts
  spill_policy_facts "$INTENT_FACTS" intent-facts
  FACTS_INLINE="$FACTS"
  INTENT_FACTS_INLINE="$INTENT_FACTS"
  [ -z "$FACTS_FILE" ] || FACTS_INLINE=""
  [ -z "$INTENT_FACTS_FILE" ] || INTENT_FACTS_INLINE=""
  FACTS_BYTES=$((${#FACTS} + ${#INTENT_FACTS}))
  DEDUPE_BYTES="$(policy_file_bytes "$DEDUPE_FILE")"
  TURN_BYTES="$(policy_file_bytes "$TURN_FILE")"
  LEDGER_BYTES=$((DEDUPE_BYTES + TURN_BYTES))
  LEDGER_BYTES_BUCKET="$(policy_bytes_bucket "$LEDGER_BYTES")"
  FACTS_BYTES_BUCKET="$(policy_bytes_bucket "$FACTS_BYTES")"
  record_policy_trigger_sizes
  compact_policy_ledger "$DEDUPE_FILE" "$DEDUPE_BYTES"
  compact_policy_ledger "$TURN_FILE" "$TURN_BYTES"

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
      # `${f##*/}`, NOT `$(basename "$f")`. The command substitution forked a
      # process per candidate file: on a 3,419-policy install that was 3,419
      # forks on EVERY Bash tool call and EVERY prompt, and it dominated the
      # hook's wall time (18.4s in the loop vs 176ms to actually read and parse
      # the same files). Bash suffix removal is the exact equivalent for every
      # path a glob can produce, at zero processes. Regression test:
      # core/scripts/tests/inject-policy-no-per-file-fork.test.sh.
      case "${f##*/}" in
        example-policy.md|README.md) continue ;;
        *" "*) continue ;;              # any space => sync conflict/drift copy
        *.sync-conflict-*.md) continue ;;  # Syncthing-style conflict copy
        *.conflict-*) continue ;;          # HQ Sync conflict twin (<slug>.md.conflict-<ts>-<id>.md)
      esac
      POLICY_FILES+=("$f")
    done
  done

  # Parsed policy frontmatter is stable across hook fires far more often than
  # the event facts or session ledger. Cache that parsed representation in the
  # established per-machine hook-state directory, never beside policies. The
  # cache key is the ordered scope list and the invalidation fingerprint is a
  # SHA-256 digest of each selected regular file's pathname, inode, size,
  # nanosecond mtime, and nanosecond ctime. ctime is the important field: an
  # ordinary user can restore mtime after a content edit, but cannot restore
  # the kernel-maintained ctime. This catches content-only same-size edits,
  # additions, removals, replacement, and precedence-order changes without
  # trusting directory mtimes, which do not change for an in-place child-file
  # edit on many filesystems.
  #
  # SHA-256 and GNU stat are intentionally cache prerequisites on the fast
  # path: on a host without either we take the existing uncached path rather
  # than accept a weaker stale signal. GNU stat accepts every policy path in
  # one process, so metadata validation is thousands of stat syscalls but not
  # thousands of shell forks. -L is required because the scanner's -f test and
  # awk both follow a policy symlink: fingerprint the target, not the link, so
  # a target edit changes ctime and a retarget changes the reported inode.
  # macOS falls back to a content-hash fingerprint; it keeps correctness where
  # BSD stat lacks nanosecond ctime formatting.
  POLICY_HASH_MODE=""
  if command -v sha256sum >/dev/null 2>&1; then
    POLICY_HASH_MODE="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    POLICY_HASH_MODE="shasum"
  fi
  POLICY_FINGERPRINT_MODE=""
  if stat -Lc '%n\t%i\t%s\t%y\t%z' "$SCRIPT_DIR" >/dev/null 2>&1; then
    POLICY_FINGERPRINT_MODE="metadata"
  elif [ -n "$POLICY_HASH_MODE" ]; then
    POLICY_FINGERPRINT_MODE="content"
  fi
  policy_hash() {
    case "$POLICY_HASH_MODE" in
      sha256sum) sha256sum "$@" 2>/dev/null ;;
      shasum) shasum -a 256 "$@" 2>/dev/null ;;
      *) return 1 ;;
    esac
  }
  policy_fingerprint() {
    local manifest digest
    case "$POLICY_FINGERPRINT_MODE" in
      metadata)
        # Stream the stat manifest straight into SHA-256. Holding the roughly
        # half-megabyte manifest in a command-substitution variable doubled the
        # warm-path fingerprint cost on a 3,476-policy corpus; pipefail keeps a
        # partial stat failure fail-open just as the old assignment did.
        digest="$(stat -Lc '%n\t%i\t%s\t%y\t%z' "$@" 2>/dev/null | policy_hash)" || return 1
        printf '%s\n' "${digest%% *}"
        return 0
        ;;
      content)
        manifest="$(policy_hash "$@")" || return 1
        ;;
      *) return 1 ;;
    esac
    digest="$(printf '%s\n' "$manifest" | policy_hash)" || return 1
    printf '%s\n' "${digest%% *}"
  }
  policy_cache_state_dir() {
    # A few standalone hook fixtures provide only hq_json_get. Keep those
    # lightweight callers fail-open while using hook-lib's standard location
    # whenever the full helper is available.
    if declare -F hq_hook_state_dir >/dev/null 2>&1; then
      hq_hook_state_dir "$HQ_ROOT"
    else
      local state_dir="$HQ_ROOT/workspace/orchestrator/hook-state"
      mkdir -p "$state_dir" 2>/dev/null || true
      printf '%s\n' "$state_dir"
    fi
  }

  # The cached records use ASCII FS (0x1c), outside valid policy frontmatter
  # syntax. The writer refuses to publish a cache if it sees this separator in
  # a record, retaining the uncached path instead of risking a lossy decode.
  CACHE_SEP=$'\034'
  CACHE_RECORDS=0
  CACHE_WRITE=0
  CACHE_TMP=""
  CACHE_STATUS=""
  CACHE_FILE=""
  EVAL_INPUTS=("${POLICY_FILES[@]}")
  if [ "${#POLICY_FILES[@]}" -gt 0 ] && [ -n "$POLICY_HASH_MODE" ] && [ -n "$POLICY_FINGERPRINT_MODE" ]; then
    POLICY_FINGERPRINT="$(policy_fingerprint "${POLICY_FILES[@]}" 2>/dev/null || true)"
    if [ -n "$POLICY_FINGERPRINT" ]; then
      scope_hash="$(printf '%s\n' "${DIRS[@]}" | policy_hash 2>/dev/null || true)"
      scope_key="${scope_hash%% *}"
      CACHE_DIR="$(policy_cache_state_dir)/policy-trigger-cache"
      if [ -n "$scope_key" ] && mkdir -p "$CACHE_DIR" 2>/dev/null; then
        CACHE_FILE="$CACHE_DIR/${scope_key}.cache"
        CACHE_HEADER="hq-policy-cache-v1${CACHE_SEP}${POLICY_FINGERPRINT}"
        cache_header=""
        if [ -r "$CACHE_FILE" ]; then
          IFS= read -r cache_header < "$CACHE_FILE" || true
        fi
        if [ "$cache_header" = "$CACHE_HEADER" ]; then
          CACHE_RECORDS=1
          EVAL_INPUTS=("$CACHE_FILE")
        else
          # mktemp creates a unique, private inode. The completed file below is
          # renamed over CACHE_FILE atomically, so a concurrent reader sees the
          # old complete cache or this complete one, never a partial write.
          CACHE_TMP="$(mktemp "$CACHE_DIR/.${scope_key}.tmp.XXXXXX" 2>/dev/null || true)"
          if [ -n "$CACHE_TMP" ] && printf '%s\n' "$CACHE_HEADER" > "$CACHE_TMP"; then
            CACHE_STATUS="${CACHE_TMP}.status"
            CACHE_WRITE=1
          else
            CACHE_TMP=""
          fi
        fi
      fi
    fi
  fi

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
  # The parsed-record cache still evaluates every policy for a new event. A
  # second small cache remembers that evaluation for the current session's
  # exact facts and ledger state. It has 64 fixed slots per scope, selected by
  # the first byte of the session digest modulo 64, rather than creating an unbounded
  # file per session. The full session digest remains in the header, so a slot
  # collision is a cache miss and reevaluation, never a cross-session hit.
  # Writers publish with rename; a concurrent reader sees a complete old entry
  # or a complete replacement, and never needs an unsafe deletion sweep.
  EVAL_CACHE_HIT=0
  EVAL_CACHE_WRITE=0
  EVAL_CACHE_TMP=""
  EVAL_CACHE_STATUS=""
  EVAL_CACHE_FILE=""
  EVAL_CACHE_DIR=""
  if [ -n "$CACHE_FILE" ] && [ "$CACHE_WRITE" != "1" ]; then
    eval_session_hash="$(printf '%s' "${SESSION_ID:-default}" | policy_hash 2>/dev/null || true)"
    eval_session_key="${eval_session_hash%% *}"
    eval_input_hash="$(
      {
        printf '%s\034%s\034%s\034' "$EVENT" "$INTENT_MODE" "$FACTS" "$INTENT_FACTS"
        cat "$DEDUPE_FILE" 2>/dev/null || true
        printf '\034'
        cat "$TURN_FILE" 2>/dev/null || true
        printf '\n'
      } | policy_hash 2>/dev/null || true
    )"
    eval_input_key="${eval_input_hash%% *}"
    if [ -n "$eval_session_key" ] && [ -n "$eval_input_key" ]; then
      # Evaluation entries contain grammar verdicts, unlike the parsed-policy
      # cache above. A parser change can therefore make an otherwise matching
      # v2 entry wrong. Keep parsed records at v1, but namespace evaluation
      # results by parser revision so a previous permissive verdict is never
      # replayed after a stricter grammar ships.
      EVAL_CACHE_DIR="$CACHE_DIR/eval-v3"
      if mkdir -p "$EVAL_CACHE_DIR" 2>/dev/null; then
        eval_slot="$(printf '%02x' "$((16#${eval_session_key:0:2} % 64))")"
        EVAL_CACHE_FILE="$EVAL_CACHE_DIR/${scope_key}.${eval_slot}.eval"
        EVAL_CACHE_HEADER="hq-policy-eval-v3${CACHE_SEP}${POLICY_FINGERPRINT}${CACHE_SEP}${eval_session_key}${CACHE_SEP}${eval_input_key}"
        eval_cache_header=""
        if [ -r "$EVAL_CACHE_FILE" ]; then
          IFS= read -r eval_cache_header < "$EVAL_CACHE_FILE" || true
        fi
        if [ "$eval_cache_header" = "$EVAL_CACHE_HEADER" ]; then
          EVAL_CACHE_HIT=1
        else
          EVAL_CACHE_TMP="$(mktemp "$EVAL_CACHE_DIR/.${scope_key}.${eval_slot}.eval.tmp.XXXXXX" 2>/dev/null || true)"
          if [ -n "$EVAL_CACHE_TMP" ] && printf '%s\n' "$EVAL_CACHE_HEADER" > "$EVAL_CACHE_TMP"; then
            EVAL_CACHE_STATUS="${EVAL_CACHE_TMP}.status"
            EVAL_CACHE_WRITE=1
          else
            EVAL_CACHE_TMP=""
          fi
        fi
      fi
    fi
  fi
  if [ "${#POLICY_FILES[@]}" -gt 0 ]; then
    policy_evaluator() {
      # The ledgers are read from files with getline. This preserves the
      # newline-safe behavior that motivated the old ENVIRON handoff and also
      # avoids the Linux MAX_ARG_STRLEN limit when a long session has many
      # dedupe entries. Large fact sets are spilled to the same hook-state
      # directory and read through the same file-backed path.
      # Emit: slug<TAB>scope<TAB>abs_path<TAB>enforcement<TAB>rule<TAB>kind.
      # `kind` is consumed only inside this hook before prose emission; the
      # public HQ_POLICY_EMIT=tsv path continues to print five fields below.
      awk -v EVENT="$EVENT" -v INTENT_MODE="$INTENT_MODE" \
          -v EVFACTS="$FACTS_INLINE" -v AIFACTS="$INTENT_FACTS_INLINE" \
          -v EVFACTS_FILE="$FACTS_FILE" -v AIFACTS_FILE="$INTENT_FACTS_FILE" \
          -v ALREADY_FILE="$DEDUPE_FILE" -v ALREADY_TURN_FILE="$TURN_FILE" \
          -v CACHE_RECORDS="$CACHE_RECORDS" -v CACHE_WRITE="$CACHE_WRITE" \
          -v CACHE_TMP="$CACHE_TMP" -v CACHE_STATUS="$CACHE_STATUS" \
          -v CSEP="$CACHE_SEP" '
      # Keep this hot-path parser structurally identical to eval-trigger.sh.
      # In particular, an opening paren needs a closing paren: accepting it
      # here while --check rejects it makes authoring and runtime disagree.
      function skipsp() { while (substr(E, pos, 1) ~ /[ \t]/) pos++ }
      function pOr(  v) {
        v=pAnd(); skipsp()
        while (valid && substr(E,pos,2)=="||") { pos+=2; rhs=pAnd(); v=(v || rhs); skipsp() }
        return v
      }
      function pAnd(  v) {
        v=pNot(); skipsp()
        while (valid && substr(E,pos,2)=="&&") { pos+=2; rhs=pNot(); v=(v && rhs); skipsp() }
        return v
      }
      function pNot(  c) { skipsp(); c=substr(E,pos,1); if(c=="!"){pos++; return (pNot()?0:1)} return pAtom() }
      function pAtom(  v,c) {
        skipsp(); c=substr(E,pos,1)
        if(c=="(") {
          pos++; v=pOr(); skipsp()
          if(substr(E,pos,1)!=")") { valid=0; return 0 }
          pos++; return v
        }
        if(c=="0" || c=="1") { pos++; return (c=="1") ? 1 : 0 }
        valid=0; return 0
      }
      # evalexpr(expr, which) -> 0 TRUE | 1 FALSE | 2 fail-open. which: "ev"|"ai".
      function evalexpr(expr, which,   e,s,out,tok,present,v) {
        e=expr; gsub(/[ \t]/,"",e); if(e=="") return 2            # empty -> fail open
        s=expr; out=""
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH)
          present = (which=="ev") ? (tok in evh) : (tok in aih)
          out = out substr(s,1,RSTART-1) (present?"1":"0")
          s = substr(s,RSTART+RLENGTH)
        }
        out = out s
        if (out ~ /[^01&|!() \t]/) return 2                       # unsafe -> malformed
        E=out; pos=1; valid=1
        v=pOr()
        # Trailing garbage is malformed, NOT a shorter true expression. The
        # recursive-descent parser stops at the first token it cannot continue
        # from, so `merge || pull request` used to evaluate as `merge || pull`
        # and silently discard every term after the bare space. Requiring the
        # parse to consume the whole expression turns that into a detected
        # malformation the authoring validator and the linter both name.
        skipsp()
        if (!valid || pos <= length(E)) return 2
        return (v ? 0 : 1)
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
      function cOr(   v,w) { v=cAnd(); cskipsp(); while(substr(C,cpos,2)=="||"){cpos+=2; w=cAnd(); if(v==1||w==1)v=1; else if(v==0&&w==0)v=0; else v=2; cskipsp()} return v }
      function cAnd(  v,w) { v=cNot(); cskipsp(); while(substr(C,cpos,2)=="&&"){cpos+=2; w=cNot(); if(v==0||w==0)v=0; else if(v==1&&w==1)v=1; else v=2; cskipsp()} return v }
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
      function finalize(   onpad,ev_on,ai_on,ss_on,matched,r,sc,en,kind,ij,degraded,ws,cache_rule) {
        if (whenx=="") return
        if (id=="") id=base(fname)
        if (onx=="") onx="PreToolUse"                              # default when on: omitted
        # On a cache miss, write the parsed record while this same pass has the
        # policy file open. A malformed cache record is never published: the
        # parent only renames the temp file when END writes an "ok" status.
        if (CACHE_WRITE) {
          cache_rule=rule
          gsub(/\t/," ",cache_rule)
          if (index(id,CSEP) || index(fname,CSEP) || index(whenx,CSEP) || index(onx,CSEP) || index(enf,CSEP) || index(injx,CSEP) || index(statx,CSEP) || index(cache_rule,CSEP)) cache_unsafe=1
          else print id CSEP scopeof(fname) CSEP fname CSEP whenx CSEP onx CSEP enf CSEP injx CSEP statx CSEP cache_rule CSEP "." >> CACHE_TMP
        }
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
        # `inject: always` (default `once`) picks which ledger governs dedup:
        # the per-turn ledger (re-injects each user turn) vs the per-session
        # ledger (fires at most once for the whole session).
        ij = (injx=="always" ? "always" : "once")
        if (ij=="always") { if (id in turnalready) return }        # per-turn dedup ledger
        else { if (id in already) return }                         # per-session dedup ledger
        if (id in emitted) return                                  # de-dup within this run
        if (statx=="retired") return                               # retired policies never inject (policy-retire.sh)
        matched=0; degraded=0; spec=0
        if (ev_on || ss_on) { r=evalexpr(whenx,"ev"); if(r==0) { matched=1; spec=specificity(whenx,"ev") } else if(r==2) degraded=1 }
        if (!matched && ai_on && INTENT_MODE) { r=evalexpr(whenx,"ai"); if(r==0) { matched=1; spec=specificity(whenx,"ai") } else if(r==2) degraded=1 }
        # An expression the grammar cannot parse used to MATCH — a blanket
        # fail-open that made every malformed policy fire on every event and
        # crowd the cap with alphabetical noise, burying the policies that
        # genuinely matched. The promise worth keeping is narrower: a typo must
        # never SUPPRESS A HARD RULE. So a malformed `when:` on an
        # enforcement: hard policy degrades to the once-per-session baseline
        # (deprioritized behind real reactive matches, deduped by the session
        # ledger) instead of re-firing forever, and a malformed soft/unset
        # policy does not inject at all. Both are reported by
        # core/scripts/lint-policy-triggers.sh and blocked at authoring time by
        # validate-policy-frontmatter.sh.
        if (!matched && degraded && enf=="hard") { matched=1 }
        if (matched) {
          emitted[id]=1
          sc=scopeof(fname)
          en=(enf=="" ? "unset" : enf)
          ws=(degraded ? "malformed" : "ok")
          # Policies whose current event is explicitly listed are reactive even
          # if they also carry SessionStart. Conditional SessionStart-only
          # policies are reactive as well: they matched facts from this event.
          # Only the unconditional SessionStart backfill is baseline.
          kind=((degraded || (ss_on && !ev_on && !(ai_on && INTENT_MODE) && unconditional(whenx))) ? "baseline" : "reactive")
          gsub(/\t/," ",rule)
          print id "\t" sc "\t" fname "\t" en "\t" rule "\t" kind "\t" ij "\t" ws "\t" spec
        }
      }
      function reset_file(){ d=0; id=""; whenx=""; onx=""; enf=""; injx=""; statx=""; rule=""; rsec=0; rcap=0 }
      # specificity(expr, which): how many distinct identifiers in the `when:`
      # expression are present in the fact set. A policy keyed on
      # `deploy && vercel && indigo` outranks one keyed on `deploy` alone when
      # both match — it is more specific to this event. Used only for ordering.
      function specificity(expr, which,   s,tok,n,seen) {
        s=expr; n=0; delete seen
        while (match(s, "[A-Za-z0-9_./][A-Za-z0-9_./-]*")) {
          tok=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
          if (tok=="always" || tok=="never") continue
          if (!(tok in seen)) { seen[tok]=1; if ((which=="ev") ? (tok in evh) : (tok in aih)) n++ }
        }
        return n
      }
      BEGIN {
        if (EVFACTS_FILE != "") {
          while ((getline factline < EVFACTS_FILE) > 0) {
            n=split(factline,fa,/[ ,]+/)
            for(i=1;i<=n;i++) if(fa[i]!="") evh[fa[i]]=1
          }
          close(EVFACTS_FILE)
        } else {
          n=split(EVFACTS,fa,/[ ,]+/)
          for(i=1;i<=n;i++) if(fa[i]!="") evh[fa[i]]=1
        }
        if (AIFACTS_FILE != "") {
          while ((getline intentline < AIFACTS_FILE) > 0) {
            n=split(intentline,ga,/[ ,]+/)
            for(i=1;i<=n;i++) if(ga[i]!="") aih[ga[i]]=1
          }
          close(AIFACTS_FILE)
        } else {
          n=split(AIFACTS,ga,/[ ,]+/)
          for(i=1;i<=n;i++) if(ga[i]!="") aih[ga[i]]=1
        }
        while ((getline ledgerline < ALREADY_FILE) > 0) if(ledgerline!="") already[ledgerline]=1
        close(ALREADY_FILE)
        while ((getline turnline < ALREADY_TURN_FILE) > 0) if(turnline!="") turnalready[turnline]=1
        close(ALREADY_TURN_FILE)
        reset_file()
      }
      # Cache files have one validated header followed by parsed records. The
      # cache is an optimization only; final matching still runs for current
      # event facts and current session dedupe ledgers.
      CACHE_RECORDS {
        if (FNR==1) next
        n=split($0,cr,CSEP)
        if (n < 10) next
        id=cr[1]; fname=cr[3]; whenx=cr[4]; onx=cr[5]; enf=cr[6]
        injx=cr[7]; statx=cr[8]; rule=cr[9]
        finalize()
        next
      }
      FNR==1 { if (seen) finalize(); reset_file(); seen=1 }
      { fname=FILENAME }
      /^---[ \t]*$/ { if (d<2) { d++; next } }
      d==1 && /^id:/   { s=$0; sub(/^id:[ \t]*/,"",s);   gsub(/^["'"'"']|["'"'"']$/,"",s); id=s; next }
      d==1 && /^status:/ { s=$0; sub(/^status:[ \t]*/,"",s); gsub(/[ \t"]/,"",s); statx=s; next }
      d==1 && /^when:/ { s=$0; sub(/^when:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s); gsub(/^["'"'"']|["'"'"']$/,"",s); whenx=s; next }
      d==1 && /^on:/   { s=$0; sub(/^on:[ \t]*/,"",s);   gsub(/[][, ]/," ",s); onx=s; next }
      d==1 && /^enforcement:/ {
        s=$0; sub(/^enforcement:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s)
        gsub(/^["'"'"']|["'"'"']$/,"",s); enf=s; next
      }
      d==1 && /^inject:/ {
        s=$0; sub(/^inject:[ \t]*/,"",s); sub(/[ \t]+#.*/,"",s)
        gsub(/^["'"'"']|["'"'"']$/,"",s); injx=s; next
      }
      d>=2 && /^## Rule[ \t]*$/ { rsec=1; next }
      d>=2 && rsec && /^## / { rsec=0 }
      d>=2 && rsec && !rcap && NF { line=$0; gsub(/\*\*/,"",line); if(length(line)>160) line=substr(line,1,157)"..."; rule=line; rcap=1 }
      END {
        if (!CACHE_RECORDS && seen) finalize()
        if (CACHE_WRITE) print (cache_unsafe ? "unsafe" : "ok") > CACHE_STATUS
      }
      ' "${EVAL_INPUTS[@]}" | {
        # Byte-oriented awk can cut through a multibyte code point. Some iconv
        # implementations still return nonzero after -c repairs the output.
        iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true
      }
    }
    POLICY_EVALUATION_OK=1
    if [ "$EVAL_CACHE_HIT" = "1" ]; then
      eval_cache_first_line=1
      while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
        if [ "$eval_cache_first_line" = "1" ]; then
          eval_cache_first_line=0
          continue
        fi
        add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind" "$injv" "$ws" "$spec"
      done < "$EVAL_CACHE_FILE"
    elif [ "$EVAL_CACHE_WRITE" = "1" ]; then
      EVAL_RESULTS_TMP="${EVAL_CACHE_TMP}.results"
      POLICY_EVALUATION_OK=0
      if policy_evaluator > "$EVAL_RESULTS_TMP"; then
        POLICY_EVALUATION_OK=1
        if cat "$EVAL_RESULTS_TMP" >> "$EVAL_CACHE_TMP" \
          && printf 'ok\n' > "$EVAL_CACHE_STATUS"; then
          :
        else
          POLICY_EVALUATION_OK=0
        fi
      fi
      while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
        add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind" "$injv" "$ws" "$spec"
      done < "$EVAL_RESULTS_TMP"
      rm -f "$EVAL_RESULTS_TMP" 2>/dev/null || true
    else
      while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
        add_match "$slug" "$scope" "$path" "$enf" "$rule" "$kind" "$injv" "$ws" "$spec"
      done < <(policy_evaluator)
    fi
    # The evaluator has completed before the process substitution returns. A
    # failed/unrepresentable cache write is discarded; policy output already
    # came from the original uncached evaluator in that case.
    if [ "$CACHE_WRITE" = "1" ]; then
      cache_status=""
      [ -r "$CACHE_STATUS" ] && IFS= read -r cache_status < "$CACHE_STATUS" || true
      if [ "$cache_status" = "ok" ] && [ "$POLICY_EVALUATION_OK" = "1" ]; then
        mv -f "$CACHE_TMP" "$CACHE_FILE" 2>/dev/null || true
      else
        rm -f "$CACHE_TMP" 2>/dev/null || true
      fi
      rm -f "$CACHE_STATUS" 2>/dev/null || true
    fi
    if [ "$EVAL_CACHE_WRITE" = "1" ]; then
      eval_cache_status=""
      [ -r "$EVAL_CACHE_STATUS" ] && IFS= read -r eval_cache_status < "$EVAL_CACHE_STATUS" || true
      if [ "$eval_cache_status" = "ok" ] && [ "$POLICY_EVALUATION_OK" = "1" ]; then
        mv -f "$EVAL_CACHE_TMP" "$EVAL_CACHE_FILE" 2>/dev/null || true
      else
        rm -f "$EVAL_CACHE_TMP" 2>/dev/null || true
      fi
      rm -f "$EVAL_CACHE_STATUS" 2>/dev/null || true
    fi
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
  printf '%s' "$MATCHES" | while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
    [ -z "$slug" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$scope" "$path" "$enf" "$rule"
    record_slug "$slug" "$injv"
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
#
# Within each group, `enforcement: hard` policies are stable-partitioned ahead
# of soft/unset ones (2026-09-07). Before this, the 16-slot cap cut in glob
# order, so a hard rule about production credentials could lose its slot to a
# soft style note that happened to sort earlier in the same directory. Scope
# order (company > repo > personal > core) is still preserved inside each
# enforcement tier.
ORDERED_MATCHES=""
GROUP=""
for match_kind in reactive baseline; do
  for match_tier in hard other; do
    while IFS= read -r match; do
      [ -n "$match" ] || continue
      case "$match" in
        *$'\t'"$match_kind"$'\t'*) ;;
        *) continue ;;
      esac
      IFS=$'\t' read -r _m_slug _m_scope _m_path _m_enf _m_rest <<< "$match"
      if [ "$match_tier" = "hard" ]; then
        [ "$_m_enf" = "hard" ] || continue
      else
        [ "$_m_enf" != "hard" ] || continue
      fi
      GROUP="${GROUP}${match}
"
    done <<< "$MATCHES"
    # Within a (kind, tier) group, more specific triggers first (field 9,
    # numeric, descending); `sort -s` keeps scope order for ties. Rows without
    # the field sort as 0.
    if [ -n "$GROUP" ]; then
      ORDERED_MATCHES="${ORDERED_MATCHES}$(printf '%s' "$GROUP" | sort -t "$(printf '\t')" -k9,9nr -s)
"
    fi
    GROUP=""
  done
done
MATCHES="$ORDERED_MATCHES"

# Truncation is NEVER silent. In addition to naming withheld policies below,
# record them now: the SessionStart baseline is a one-time introduction, so a
# policy that lost the cap was considered and dropped, not deferred to the next
# event where it could crowd out new reactive work again.
# INDEX MODE (2026-09-07, default): there is no count cap. Every matching
# policy is listed as a one-line index entry (id, tier, scope, summary), and
# only reactive HARD matches carry full text, inside HARD_BUDGET. The whole
# emission is bounded by OUTPUT_CEILING below, so nothing is withheld by rank:
# at ~120 bytes a line, 50+ policies fit under the host ceiling, and the agent
# pulls any rule's full text on demand (`qmd get <slug>` or the file).
# Setting HQ_SESSION_POLICY_CAP to a positive number restores the legacy
# count cap (used by the box-preflight bounds tests).
SESSION_POLICY_CAP="${HQ_SESSION_POLICY_CAP:-0}"
MATCH_COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
WITHHELD=0
WITHHELD_MATCHES=""
if [ "$SESSION_POLICY_CAP" -gt 0 ] && [ "$MATCH_COUNT" -gt "$SESSION_POLICY_CAP" ]; then
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
  while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
    [ -n "$slug" ] || continue
    record_slug "$slug" "$injv"
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
# Host ceiling (2026-09-07): Claude Code persists any hook stdout above ~10,000
# bytes to a file and shows the model a ~2 KB preview — everything past it is
# lost for that turn. 3,341 such truncated outputs were found on one install,
# most of them this hook. The full-text budget therefore lives well under that
# ceiling, and the WHOLE emission is capped by OUTPUT_CEILING below, with a
# non-silent fallback to summaries when the cap would otherwise be exceeded.
HARD_BUDGET="${HQ_POLICY_HARD_BUDGET_BYTES:-5120}"
# Per-policy ceiling. Without it a single long hard policy can swallow most of
# the shared budget and push every other hard rule down to its summary line.
HARD_MAX="${HQ_POLICY_HARD_MAX_BYTES:-2048}"
# Absolute ceiling on this hook's stdout. Must stay below the host's ~10,000
# byte persist threshold with margin; core/scripts/tests/inject-policy-output-ceiling.test.sh
# fails if either default is raised past it.
OUTPUT_CEILING="${HQ_POLICY_OUTPUT_CEILING_BYTES:-8000}"
# A configured ceiling is an absolute stdout bound, not a request we may round
# up to a more convenient value. Refuse a malformed value explicitly instead
# of falling through to an arithmetic comparison (and a silent hook failure).
case "$OUTPUT_CEILING" in
  ''|*[!0-9]*)
    printf 'inject-policy-on-trigger: HQ_POLICY_OUTPUT_CEILING_BYTES must be a non-negative integer; emitted no stdout.\n' >&2
    exit 0
    ;;
esac
# Everything from the first archival heading on is history and justification,
# not the binding rule: it is what the agent must NOT be made to re-read on
# every injection. `## Rule`, `## Scope`, `## Enforcement` and friends stay.
# Set HQ_POLICY_BODY_STOP='' to inject whole files again.
# Matched against a lowercased line, so keep the pattern lowercase.
BODY_STOP="${HQ_POLICY_BODY_STOP-^#+[[:space:]]*(rationale|rationale and context|background|change history|changelog|history|examples?|references?|related|see also|sources?|provenance|evidence)[[:space:]]*$}"

policy_body() {
  # Print the binding part of the policy: everything after the closing
  # frontmatter `---`, leading blank lines trimmed, stopping at the first
  # archival heading. A file with no frontmatter (or an unreadable one) prints
  # nothing, and the caller falls back to the summary line — fail-open to prior
  # behaviour, never a dropped policy.
  awk -v stop="$BODY_STOP" '
    /^---[ \t]*$/ && d < 2 { d++; next }
    d >= 2 {
      if (!started && $0 ~ /^[ \t]*$/) next
      if (stop != "" && tolower($0) ~ stop) exit
      started = 1; print
    }
  ' "$1" 2>/dev/null | awk '
    # trim trailing blank lines left behind by the cut
    { L[NR]=$0 }
    END { last=0; for(i=1;i<=NR;i++) if (L[i] ~ /[^ \t]/) last=i
          for(i=1;i<=last;i++) print L[i] }
  '
}

# Record every emitted slug in its ledger exactly once, BEFORE emission: the
# emission below may run twice (full text, then summary-only fallback) and
# must not double-record.
printf '%s' "$MATCHES" | while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
  [ -z "$slug" ] && continue
  record_slug "$slug" "$injv"
done

emit_reminder() {
printf '<policy-reminder>\n'
printf '%s' "$MATCHES" | {
  spent=0
  shortened=""
  oversize=""
  malformed=""
  while IFS=$'\t' read -r slug scope path enf rule kind injv ws spec; do
    [ -z "$slug" ] && continue
    [ "$ws" = "malformed" ] && malformed="${malformed:+$malformed, }$slug"
    body=""
    # HARD rules carry full text while the budget lasts. MATCHES is already
    # ordered reactive-before-baseline and by specificity, so rules that
    # matched THIS event claim the budget first; a baseline hard rule that
    # loses the budget is still an index line, one read away.
    if [ "$HARD_FULL" != "0" ] && [ "$enf" = "hard" ] && [ -n "$path" ] && [ -r "$path" ]; then
      body="$(policy_body "$path")"
    fi
    if [ -n "$body" ]; then
      size="$(printf '%s' "$body" | wc -c | tr -d ' ')"
      if [ "$size" -gt "$HARD_MAX" ]; then
        # One policy must not crowd out every other hard rule in the budget.
        oversize="${oversize:+$oversize, }$slug"
        body=""
      elif [ $((spent + size)) -le "$HARD_BUDGET" ]; then
        spent=$((spent + size))
        printf '> Policy `%s` (HARD — binding rule from `%s`):\n' "$slug" "${path#"$HQ_ROOT"/}"
        # Quote every body line into the reminder block, and neutralise any
        # literal <policy-reminder> tag inside a policy body (one exists today)
        # so an injected body cannot close or nest this block.
        printf '%s\n' "$body" \
          | sed -e 's#</policy-reminder>#[/policy-reminder]#g' \
                -e 's#<policy-reminder>#[policy-reminder]#g' \
                -e 's/^/> /' -e 's/^> $/>/'
        continue
      fi
      [ -n "$body" ] && shortened="${shortened:+$shortened, }$slug"
    fi
    if [ "$enf" = "hard" ]; then
      printf '> Policy `%s` applies here: %s  [HARD · %s]\n' "$slug" "$rule" "$scope"
    else
      printf '> Policy `%s` applies here: %s\n' "$slug" "$rule"
    fi
  done
  if [ -n "$shortened" ]; then
    printf '> Full-text budget of %s bytes reached: these HARD policies were shortened to one-line summaries — %s. Read each in full at its own file before acting on it.\n' \
      "$HARD_BUDGET" "$shortened"
  fi
  if [ -n "$oversize" ]; then
    printf '> Over the %s-byte per-policy limit, so shortened to one-line summaries — %s. Read each in full at its own file before acting on it, and consider trimming the rule.\n' \
      "$HARD_MAX" "$oversize"
  fi
  if [ -n "$malformed" ]; then
    printf '> Malformed `when:` trigger (does not parse, so it cannot be matched against this event) — %s. These are surfaced as a once-per-session fallback, not because they matched. Repair with: bash core/scripts/lint-policy-triggers.sh\n' \
      "$malformed"
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
printf '> This is an index. Before acting in an area a HARD rule covers, read that rule in full: `qmd get <slug>` or the policy file (companies/<co>/policies, personal/policies, core/policies). One-line entries are summaries, not the rule.\n'
printf '</policy-reminder>\n'
}

# The smallest useful delivery keeps the valid reminder wrapper and tells the
# model that policies matched, while directing it to the source files. Its
# measured size (including the final newline printed below) is the floor for a
# structured reminder. A lower configured ceiling emits no stdout and gets an
# explicit stderr explanation rather than a partial tag or an oversized blob.
compact_reminder() {
  printf '<policy-reminder>\n> Policies matched; read policy files.\n</policy-reminder>'
}

OUT="$(emit_reminder)"
# Measure precisely what the final `printf '%s\n'` below will write; command
# substitution strips emit_reminder's final newline.
OUT_BYTES="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
if [ "$OUT_BYTES" -gt "$OUTPUT_CEILING" ] && [ "$HARD_FULL" != "0" ]; then
  # Too big for the host to deliver: fall back to one-line summaries for
  # every policy, and say so. A shortened set the model can read beats a full
  # set it never sees.
  OUT="$(HARD_FULL=0 emit_reminder)"
  OUT="${OUT%</policy-reminder>*}> Output ceiling of ${OUTPUT_CEILING} bytes would have been exceeded (${OUT_BYTES} bytes with full text): every HARD policy above is shortened to its summary line. Read each in full at its own file before acting on it.
</policy-reminder>"
  OUT_BYTES="$(printf '%s\n' "$OUT" | wc -c | tr -d ' ')"
fi
if [ "$OUT_BYTES" -gt "$OUTPUT_CEILING" ]; then
  # Still over even as summaries: drop trailing policy lines until it fits,
  # naming how many were cut. Rebuild and measure the complete final candidate
  # on every pass, including its notice and printf's newline, so a 9 -> 10
  # cut-count transition cannot cross the ceiling after the last measurement.
  cut=0
  while :; do
    if [ "$cut" -gt 0 ]; then
      candidate="${OUT%</policy-reminder>*}> Output ceiling of ${OUTPUT_CEILING} bytes: ${cut} lower-ranked policy line(s) cut from this reminder. They stay in the ledger as fired; see the policy files.
</policy-reminder>"
    else
      candidate="$OUT"
    fi
    candidate_bytes="$(printf '%s\n' "$candidate" | wc -c | tr -d ' ')"
    if [ "$candidate_bytes" -le "$OUTPUT_CEILING" ]; then
      OUT="$candidate"
      OUT_BYTES="$candidate_bytes"
      break
    fi
    last_line="$(printf '%s\n' "$OUT" | grep -n '^> Policy `' | tail -1 | cut -d: -f1 || true)"
    if [ -z "$last_line" ]; then
      # Policy lines cannot make room for an oversized withheld/malformed
      # notice. Preserve the more informative existing fallback whenever it
      # fits; only then shrink again to the compact form, and measure both.
      if [ "$cut" -gt 0 ]; then
        last_resort="<policy-reminder>
> Output ceiling of ${OUTPUT_CEILING} bytes: ${cut} lower-ranked policy line(s) cut from this reminder. Remaining reminder text was omitted to keep this event deliverable; see the policy files.
</policy-reminder>"
      else
        last_resort="<policy-reminder>
> Output ceiling of ${OUTPUT_CEILING} bytes: remaining reminder text was omitted to keep this event deliverable; see the policy files.
</policy-reminder>"
      fi
      last_resort_bytes="$(printf '%s\n' "$last_resort" | wc -c | tr -d ' ')"
      if [ "$last_resort_bytes" -le "$OUTPUT_CEILING" ]; then
        OUT="$last_resort"
        OUT_BYTES="$last_resort_bytes"
      else
        # The compact reminder is deliberately measured too: a ceiling below
        # its useful 76-byte floor must not leak a fixed-size fallback.
        compact_out="$(compact_reminder)"
        compact_bytes="$(printf '%s\n' "$compact_out" | wc -c | tr -d ' ')"
        if [ "$compact_bytes" -le "$OUTPUT_CEILING" ]; then
          OUT="$compact_out"
          OUT_BYTES="$compact_bytes"
        else
          OUT=""
          OUT_BYTES=0
          NO_STDOUT_REASON="HQ_POLICY_OUTPUT_CEILING_BYTES=${OUTPUT_CEILING} is below the ${compact_bytes}-byte minimum reminder"
        fi
      fi
      break
    fi
    OUT="$(printf '%s\n' "$OUT" | sed "${last_line}d")"
    cut=$((cut + 1))
  done
fi
# Emission stats (2026-09-07): one line per event so a live smoke or benchmark
# can prove, per session and per runtime, that every reminder stayed under the
# host ceiling. OUT_BYTES is the final `printf '%s\n'` byte count. Cheap append;
# failure is ignored.
{ STATS_DIR="$HQ_ROOT/workspace/orchestrator/policy-emit-stats"; mkdir -p "$STATS_DIR" 2>/dev/null \
  && printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$OUT_BYTES" "$MATCH_COUNT" >> "$STATS_DIR/${SESSION_ID:-unknown}.txt"; } 2>/dev/null || true
if [ -n "${NO_STDOUT_REASON:-}" ]; then
  printf 'inject-policy-on-trigger: %s; emitted no stdout.\n' "$NO_STDOUT_REASON" >&2
else
  printf '%s\n' "$OUT"
fi

exit 0
