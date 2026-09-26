#!/bin/bash
# check-client-health.sh — SessionStart hook (client-sync-health-control-plane US-015)
#
# Local self-healing: detect an outdated or degraded install at session start
# and repair or report it automatically, before support ever needs a dashboard.
#
#   1. Cheap, filesystem-only pre-checks in the foreground (never networked,
#      never blocking): a sync journal shard untouched beyond the stale
#      threshold, or the check-hq-update cache showing a newer hq-core release.
#   2. Only when a pre-check fires AND the cooldown window has been CLAIMED, a
#      fully detached background remediation (`--remediate` mode of this same
#      script) corroborates with `hq doctor --json` (the sync family, US-015
#      hq-cli), runs `hq doctor --fix --yes` for auto-fixable findings,
#      re-verifies, then sends normalized client-health events directly to
#      Sentry when the company flag is on. Flag-off and older CLI installs keep
#      filing the existing `hq feedback bug` summary.
#
# Cautions paid for in blood:
#   - The cooldown window is claimed ATOMICALLY and the stamp is written BEFORE
#     the launch, mirroring check-hq-update.sh. An exclusive `set -C` (O_EXCL)
#     claim plus a re-check of the stamp under that claim is what makes two
#     concurrent SessionStarts produce exactly one remediation; `&` alone
#     proves nothing about the child, and a check-then-act cooldown is not a
#     cooldown.
#   - The cooldown must LATCH. If the state dir or the stamp cannot be written
#     (read-only workspace/, full disk), the hook does nothing at all — a
#     cooldown that silently fails to record would fire remediation on every
#     single session, forever.
#   - Remediation requires corroborating signals: a cheap foreground signal
#     AND a doctor FAIL/WARN before any fix or bug (bridge-health false
#     positives).
#   - NOTHING free-text leaves the machine. Bug reports carry the stable
#     `checkId` (sanitised to [A-Za-z0-9._-]) and a fixed template, never the
#     doctor's `message` or a findings dump: live doctor messages embed
#     ABSOLUTE PATHS, and the PRD's non-goals forbid shipping customer paths,
#     file names, or raw logs off-box.
#   - `timeout(1)` is NOT present on a stock macOS. Bounding degrades
#     timeout → gtimeout → a portable background+watchdog fallback on the SAME
#     deadline, so self-heal still runs there — but is never UNBOUNDED. On the
#     common Mac install an unbounded fallback would let doctor/feedback run
#     forever with no kill switch; a self-healing hook must not be able to make
#     a machine worse.
#   - The hook NEVER blocks or fails a session: trap exit 0, no set -e, body
#     swallows stderr. Honors HQ_DISABLED_HOOKS=check-client-health both via
#     hook-gate and directly here.
#
# Wired in .claude/settings.json SessionStart and gated by hook-gate.sh under
# "check-client-health" (standard and strict profiles).

# ─── Remediation mode (runs detached in the background, never as a hook) ─────
if [ "${1:-}" = "--remediate" ]; then
  # Best-effort throughout; every failure is silent.
  {
    umask 077
    HQ_ROOT="${2:-$PWD}"
    STATE_DIR="$HQ_ROOT/workspace/.hq-client-health"

    command -v hq >/dev/null 2>&1 || exit 0

    # Defense in depth: the hook mode already refuses an incomplete tree, but
    # --remediate is a public entry point (and could be invoked directly, or
    # inherited by a stale detached child). Only a COMPLETE HQ install — both
    # root markers — is ever a legitimate remediation target; core/core.yaml
    # alone is present in any hooks-only copy such as the `hq doctor
    # --deep-test` sandbox.
    [ -f "$HQ_ROOT/core/core.yaml" ] || exit 0
    [ -f "$HQ_ROOT/companies/manifest.yaml" ] || exit 0

    mkdir -p "$STATE_DIR/bugs" 2>/dev/null || exit 0
    [ -d "$STATE_DIR/bugs" ] || exit 0

    # Bounded execution, portably. `timeout` ships with GNU coreutils and is
    # ABSENT on a stock macOS (where coreutils installs it as `gtimeout`).
    # Without this fallback every bounded call would fail with 127, doctor
    # would report nothing, and self-healing would silently never run on a Mac.
    HQ_TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
    bounded() {
      # bounded <seconds> <command...>
      #
      # HQ_TEST_FORCE_HEALTH_DEADLINE is a fixture seam only (same shape as
      # precompact-thrashing-detector.sh's HQ_TEST_FORCE_* knobs): it shortens
      # the deadline so a hang is provable in seconds. It applies to BOTH
      # bounding paths below, so the timeout(1) path and the portable fallback
      # can never drift to different budgets.
      local secs="${HQ_TEST_FORCE_HEALTH_DEADLINE:-$1}"; shift
      if [ -n "$HQ_TIMEOUT_BIN" ]; then
        "$HQ_TIMEOUT_BIN" "$secs" "$@"
        return $?
      fi

      # Neither timeout nor gtimeout exists. That is the COMMON case on a stock
      # macOS, not an edge case, so running unbounded here would mean most Mac
      # users get an `hq doctor` / `hq feedback` that can run forever behind a
      # wedged call, with no kill switch and stray processes left behind. A
      # self-healing hook must never be able to make a machine worse — so bound
      # it with a portable watchdog on the SAME deadline instead.
      # Explicit stdin preserves --body-file - in the background child.
      "$@" <&0 &
      local cmd_pid=$!
      (
        waited=0
        while [ "$waited" -lt "$secs" ]; do
          # Stop the instant the command is gone. The watchdog must never
          # outlive what it guards, or a later process that reused the pid
          # could be killed by a watchdog that has forgotten its target.
          kill -0 "$cmd_pid" 2>/dev/null || exit 0
          sleep 1
          waited=$((waited + 1))
        done
        # TERM first, then KILL: a shell blocked in a child call defers TERM
        # until that child returns, which for a hang is never.
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 2
        kill -KILL "$cmd_pid" 2>/dev/null
      ) >/dev/null 2>&1 &
      local dog_pid=$!
      wait "$cmd_pid" 2>/dev/null
      local rc=$?
      # The command has been reaped, so retire its watchdog before it can ever
      # fire at a recycled pid — and reap the watchdog too, leaving no zombie.
      kill "$dog_pid" 2>/dev/null
      wait "$dog_pid" 2>/dev/null
      return "$rc"
    }

    # JSON engine order is the shared HQ one (core/scripts/hook-lib.sh): jq
    # first, node fallback, then degrade to "no findings" so the caller keeps
    # its fail-open behaviour. NEVER an interpreter outside that pair — HQ hooks
    # must run on Windows machines that have no working python3 (the Store alias
    # stub resolves on PATH and then fails every call), which is why
    # core/scripts/tests/hooks-no-python.test.sh tripwires any runtime use.
    . "$HQ_ROOT/core/scripts/hook-lib.sh" 2>/dev/null || true

    # stdin: an `hq doctor --json` document. stdout: the bare `checkId` of every
    # FAIL/WARN result in the sync family, or an opt-in `checkId: reasonCode`
    # pair when that result's company enabled the hq-flags gate.
    #
    # The doctor's `message` is deliberately DROPPED here rather than carried
    # and redacted later: it is free-text diagnostics that routinely embeds
    # absolute paths (home dir, HQ root, vault paths), and this value's only
    # consumer ships it off-box in a bug report. The opt-in path adds only a
    # whitelisted reason enum beside the stable id; paths, messages, and targets
    # remain local even if a doctor JSON producer returns unexpected text.
    sync_findings() {
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        "$HQ_LIB_JQ" -r '
          ["core-version-unavailable", "core-update-available", "no-local-tree",
             "never-synced", "invalid-last-sync", "stale-threshold",
             "manifest-unavailable", "manifest-state-unavailable",
             "no-manifest-scopes", "never-uploaded", "invalid-upload-time",
             "unresolved-company-uid"] as $allowed
          |
          (.results // [])[]
          | select(.family == "sync" and (.status == "FAIL" or .status == "WARN"))
          | select(.checkId != "sync.update.core" or .status == "FAIL")
          | . as $row
          | ($row.checkId // "") as $candidate_id
          | (if ($candidate_id | test("^sync\\.[A-Za-z0-9._-]{1,160}$"))
             then $candidate_id else "unknown" end) as $check_id
          | if $row.clientHealthReasonCodesEnabled == true and (($allowed | index($row.reasonCode)) != null)
            then "\($check_id): \($row.reasonCode)"
            else $check_id
            end
        ' 2>/dev/null || true
        return 0
      fi
      if [ -n "${HQ_LIB_NODE:-}" ]; then
        "$HQ_LIB_NODE" -e '
          let d = "";
          process.stdin.on("data", c => d += c).on("end", () => {
            let doc;
            try { doc = JSON.parse(d); } catch (e) { return; }
            const rows = (doc && doc.results) || [];
            const allowed = new Set([
              "core-version-unavailable", "core-update-available", "no-local-tree",
              "never-synced", "invalid-last-sync", "stale-threshold",
              "manifest-unavailable", "manifest-state-unavailable",
              "no-manifest-scopes", "never-uploaded", "invalid-upload-time",
              "unresolved-company-uid"
            ]);
            for (const r of rows) {
              if (!r || r.family !== "sync") continue;
              if (r.status !== "FAIL" && r.status !== "WARN") continue;
              if (r.checkId === "sync.update.core" && r.status === "WARN") continue;
              const id = typeof r.checkId === "string" && /^sync\.[A-Za-z0-9._-]{1,160}$/.test(r.checkId)
                ? r.checkId
                : "unknown";
              const value = r.clientHealthReasonCodesEnabled === true && allowed.has(r.reasonCode)
                ? `${id}: ${r.reasonCode}`
                : id;
              process.stdout.write(value + "\n");
            }
          });' 2>/dev/null || true
        return 0
      fi
      cat >/dev/null 2>&1 || true
    }

    doctor_degraded() {
      # Newer CLI versions resolve the opt-in hq-flags gate. Older versions
      # reject the private option, so fall back to ordinary JSON output. Both
      # invocations are bounded and raw JSON stays in this process.
      local output_file="${1:-}" document rc
      document=$(cd "$HQ_ROOT" 2>/dev/null && bounded 120 hq doctor --json --client-health-report 2>/dev/null)
      rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$document" ]; then
        document=$(cd "$HQ_ROOT" 2>/dev/null && bounded 120 hq doctor --json 2>/dev/null)
        rc=$?
      fi
      [ "$rc" -eq 0 ] || return 0
      if [ -n "$output_file" ]; then
        (umask 077; printf '%s\n' "$document" > "$output_file") 2>/dev/null || true
      fi
      printf '%s\n' "$document" | sync_findings
    }

    # Corroborate: the foreground signal alone is not enough to act on.
    FINDINGS=$(doctor_degraded)
    [ -n "$FINDINGS" ] || exit 0

    # Attempt the allowlisted safe repairs, then re-verify. Only findings that
    # SURVIVE the fix pass are report-worthy — a fixed issue files no bug.
    ( cd "$HQ_ROOT" 2>/dev/null && bounded 300 hq doctor --fix --yes --json >/dev/null 2>&1 )
    FIX_RC=$?
    case "$FIX_RC" in
      124|137|143) FIX_OUTCOME="fix_timed_out" ;;
      0) FIX_OUTCOME="not_auto_fixable" ;;
      *) FIX_OUTCOME="fix_failed" ;;
    esac
    POST_FIX_JSON_FILE=$(mktemp "$STATE_DIR/post-fix.XXXXXX" 2>/dev/null || true)
    REMAINING=$(doctor_degraded "$POST_FIX_JSON_FILE")
    if [ -z "$REMAINING" ]; then
      [ -n "$POST_FIX_JSON_FILE" ] && rm -f "$POST_FIX_JSON_FILE" 2>/dev/null
      exit 0
    fi

    # One bounded attempt per install, not one attempt per company/check.
    # Reserve it BEFORE sending: a timeout may mean either route accepted the
    # report but the response was lost. Retrying could duplicate the report.
    NOW=$(date +%s)
    BUG_LOCK="$STATE_DIR/bugs/summary.lock"
    ATTEMPT_STAMP="$STATE_DIR/bugs/report-attempt.stamp"
    if [ -f "$BUG_LOCK" ]; then
      LOCK_MTIME=$(stat -c %Y "$BUG_LOCK" 2>/dev/null || stat -f %m "$BUG_LOCK" 2>/dev/null || echo "$NOW")
      [ "$((NOW - LOCK_MTIME))" -gt 3600 ] && rm -f "$BUG_LOCK" 2>/dev/null
    fi
    if ! ( set -C; : > "$BUG_LOCK" ) 2>/dev/null; then
      [ -n "$POST_FIX_JSON_FILE" ] && rm -f "$POST_FIX_JSON_FILE" 2>/dev/null
      exit 0
    fi
    if [ -f "$ATTEMPT_STAMP" ]; then
      STAMP_MTIME=$(stat -c %Y "$ATTEMPT_STAMP" 2>/dev/null || stat -f %m "$ATTEMPT_STAMP" 2>/dev/null || echo "$NOW")
      if [ "$((NOW - STAMP_MTIME))" -lt 86400 ]; then
        rm -f "$BUG_LOCK" 2>/dev/null
        [ -n "$POST_FIX_JSON_FILE" ] && rm -f "$POST_FIX_JSON_FILE" 2>/dev/null
        exit 0
      fi
    fi
    if ! ( : > "$ATTEMPT_STAMP" ) 2>/dev/null; then
      rm -f "$BUG_LOCK" 2>/dev/null
      [ -n "$POST_FIX_JSON_FILE" ] && rm -f "$POST_FIX_JSON_FILE" 2>/dev/null
      exit 0
    fi

    # Newer hq-cli sends the normalized event directly to Sentry when every
    # affected company has enabled the default-off flag. Older CLIs, a disabled
    # flag, or a failed send retain the existing feedback report path below.
    if [ -n "$POST_FIX_JSON_FILE" ] && [ -s "$POST_FIX_JSON_FILE" ]; then
      if ( cd "$HQ_ROOT" 2>/dev/null && bounded 60 hq doctor \
          --client-health-sentry \
          --json-input "$POST_FIX_JSON_FILE" \
          --client-health-fix-outcome "$FIX_OUTCOME" >/dev/null 2>&1 ); then
        ( : > "$STATE_DIR/bugs/summary.stamp" ) 2>/dev/null || true
        rm -f "$POST_FIX_JSON_FILE" "$BUG_LOCK" 2>/dev/null
        exit 0
      fi
    fi
    [ -n "$POST_FIX_JSON_FILE" ] && rm -f "$POST_FIX_JSON_FILE" 2>/dev/null

    # Only sanitised IDs leave the machine. Cap both rows and ID length so a
    # large install still produces a small report; raw messages stay local.
    CHECK_IDS=$(printf '%s\n' "$REMAINING" | tr -c 'A-Za-z0-9._:\n -' '_' | cut -c 1-200 | sort -u)
    CHECK_COUNT=$(printf '%s\n' "$CHECK_IDS" | wc -l | tr -d ' ')
    CHECK_LIST=$(printf '%s\n' "$CHECK_IDS" | head -50 | sed 's/^/- /')
    # Automatic reports must opt out explicitly: the feedback CLI otherwise
    # collects and uploads the same log bundle for every report.
    if ( cd "$HQ_ROOT" 2>/dev/null && bounded 60 hq feedback bug \
          --title "Client health: sync checks unresolved after hq doctor --fix" \
          --no-logs --body-file - >/dev/null 2>&1 <<EOF
Automated report from the check-client-health SessionStart hook.

After the safe repair pass, $CHECK_COUNT sync checks still report FAIL or WARN.
Check IDs or opted-in checkId: reasonCode pairs (up to 50 shown):
$CHECK_LIST

Doctor messages and log bundles are not attached. Reproduce locally with
\`hq doctor --json\`. Component versions are attached by the feedback pipeline.
Automatic reporting is limited to one attempt per HQ install every 24 hours.
EOF
    ); then
      ( : > "$STATE_DIR/bugs/summary.stamp" ) 2>/dev/null || true
    fi
    rm -f "$BUG_LOCK" 2>/dev/null
  } 2>/dev/null || true
  exit 0
fi

# ─── Hook mode (SessionStart) ────────────────────────────────────────────────
# Fail silently on ANY error — advisory only, never blocks a session.
trap 'exit 0' EXIT

# Consume stdin (master-hook passes it even if empty)
cat >/dev/null 2>&1 || true

{

# Honor HQ_DISABLED_HOOKS directly, even when invoked outside hook-gate.
case ",${HQ_DISABLED_HOOKS:-}," in
  *,check-client-health,*) exit 0 ;;
esac

HQ_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
STATE_DIR="$HQ_ROOT/workspace/.hq-client-health"
STAMP="$STATE_DIR/remediation.stamp"
LOCK="$STATE_DIR/remediation.lock"
COOLDOWN_SECONDS=21600            # 6h between remediation launches
LOCK_STALE_SECONDS=300            # abandoned claim (killed mid-launch) age-out
STALE_JOURNAL_SECONDS=604800      # 7 days, matching the doctor's sync family
UPDATE_CACHE="$HQ_ROOT/workspace/.hq-update-check/last-check.json"
SYNC_STATE_DIR="${HQ_STATE_DIR:-$HOME/.hq}"

command -v hq >/dev/null 2>&1 || exit 0

# Only a COMPLETE HQ install is a legitimate remediation target. A partial tree
# — a bare checkout, or the `hq doctor --deep-test` sandbox, which copies only
# .claude/.codex/.grok/core — must never have background repair or bug filing
# run against it. Both markers are required: core/core.yaml alone is present in
# any hooks-only copy of the tree.
[ -f "$HQ_ROOT/core/core.yaml" ] || exit 0
[ -f "$HQ_ROOT/companies/manifest.yaml" ] || exit 0

# Display the latest locally stored next step once. The display claim uses a
# lock and a result id, so parallel SessionStarts cannot print it twice.
show_last_result_once() {
  local result_file="$STATE_DIR/last-result.json"
  local lock_file="$STATE_DIR/last-result-show.lock"
  local shown_file="$STATE_DIR/last-result.shown"
  local data result_id check_class step previous temp_file now lock_mtime
  [ -f "$result_file" ] || return 0

  # A killed hook can leave the exclusive display claim behind. This section
  # only reads a small local file and exits quickly, so age out abandoned claims.
  if [ -f "$lock_file" ]; then
    now=$(date +%s)
    lock_mtime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo "$now")
    [ "$((now - lock_mtime))" -gt 300 ] && rm -f "$lock_file" 2>/dev/null
  fi
  ( set -C; : > "$lock_file" ) 2>/dev/null || return 0

  data=""
  if command -v jq >/dev/null 2>&1; then
    data=$(jq -er '
      select(type == "object" and (.result_id | type == "string") and (.check_class | type == "string"))
      | [.result_id, .check_class] | @tsv
    ' "$result_file" 2>/dev/null) || data=""
  elif command -v node >/dev/null 2>&1; then
    data=$(node -e '
      try {
        const fs = require("node:fs");
        const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (value && typeof value.result_id === "string" && typeof value.check_class === "string") {
          process.stdout.write(`${value.result_id}\t${value.check_class}`);
        }
      } catch {}
    ' "$result_file" 2>/dev/null) || data=""
  fi
  result_id="${data%%$'\t'*}"
  check_class="${data#*$'\t'}"
  if ! [[ "$result_id" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    rm -f "$lock_file" 2>/dev/null
    return 0
  fi

  case "$check_class" in
    sync.update.core)
      step="HQ couldn't update itself automatically. Run hq update or /update-hq, then restart this session." ;;
    sync.journal.personal|sync.journal.personal_vault)
      step="HQ hasn't synced your personal files in over 7 days and the automatic fix did not work. Run hq sync and check the result. If it fails, run hq doctor and send the output to support." ;;
    sync.journal.company)
      step="HQ hasn't synced this company's files in over 7 days and the automatic fix did not work. Run hq sync and check the result. If it fails, run hq doctor and send the output to support." ;;
    sync.manifest.personal|sync.manifest.personal_vault)
      step="HQ couldn't read your personal sync list. Run hq doctor --fix. If it still fails, run hq login again." ;;
    sync.manifest.company)
      step="HQ couldn't read a company sync manifest. Run hq doctor --fix. If it still fails, run hq login again." ;;
    other)
      step="HQ still reports a sync health issue after its automatic fix. Run hq doctor and send the output to support." ;;
    *)
      rm -f "$lock_file" 2>/dev/null
      return 0 ;;
  esac

  previous=$(cat "$shown_file" 2>/dev/null || true)
  if [ "$previous" != "$result_id" ]; then
    temp_file="$shown_file.$$"
    if (umask 077; printf '%s\n' "$result_id" > "$temp_file") 2>/dev/null \
        && mv -f "$temp_file" "$shown_file" 2>/dev/null; then
      printf '<hq-client-health-result>\n%s\n</hq-client-health-result>\n' "$step"
    else
      rm -f "$temp_file" 2>/dev/null
    fi
  fi
  rm -f "$lock_file" 2>/dev/null
}
show_last_result_once

# Cheap cooldown fast path. This is an OPTIMISATION, not the guard: the
# authoritative cooldown decision is re-made below under the exclusive claim.
if [ -f "$STAMP" ]; then
  STAMP_MTIME=$(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  [ "$((NOW - STAMP_MTIME))" -lt "$COOLDOWN_SECONDS" ] && exit 0
fi

# Cheap foreground pre-checks (filesystem only — a healthy install exits here
# having read a few mtimes and emitted nothing).
SIGNAL=""

# (a) Stale sync journal: a shard the engine has not touched in the stale
#     window. Only journals that EXIST count — no journals means sync is not
#     in use here, which is not a degradation signal.
NOW=$(date +%s)
for JOURNAL in "$SYNC_STATE_DIR"/sync-journal.*.json; do
  [ -f "$JOURNAL" ] || continue
  J_MTIME=$(stat -c %Y "$JOURNAL" 2>/dev/null || stat -f %m "$JOURNAL" 2>/dev/null || echo "$NOW")
  if [ "$((NOW - J_MTIME))" -gt "$STALE_JOURNAL_SECONDS" ]; then
    SIGNAL="stale-sync-journal"
    break
  fi
done

# (b) Known-newer hq-core release, from the check-hq-update hook's cache.
if [ -z "$SIGNAL" ] && [ -f "$UPDATE_CACHE" ] && [ -f "$HQ_ROOT/core/core.yaml" ]; then
  LATEST=$(grep -oE '"latest":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$UPDATE_CACHE" 2>/dev/null \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/' | head -1)
  LOCAL=$(grep -E '^hqVersion:' "$HQ_ROOT/core/core.yaml" 2>/dev/null | head -1 \
    | sed -E 's/^hqVersion:[[:space:]]*["'"'"']?([0-9]+\.[0-9]+\.[0-9]+)["'"'"']?.*/\1/')
  if [ -n "$LATEST" ] && [ -n "$LOCAL" ] && [ "$LATEST" != "$LOCAL" ]; then
    A=$(printf '%s' "$LATEST" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
    B=$(printf '%s' "$LOCAL" | awk -F. '{ printf("%03d%03d%03d\n", $1, $2, $3) }')
    [ "$A" \> "$B" ] && SIGNAL="core-update-available"
  fi
fi

[ -n "$SIGNAL" ] || exit 0

# ── Claim the cooldown window, THEN launch ───────────────────────────────────
# Order matters and mirrors check-hq-update.sh: claim → re-check → stamp →
# launch. Everything before the claim is advisory; two SessionStarts racing
# here must produce exactly ONE remediation.
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
[ -d "$STATE_DIR" ] || exit 0

# Release a claim abandoned by a session killed mid-launch, so one crash cannot
# mute self-healing forever.
if [ -f "$LOCK" ]; then
  NOW=$(date +%s)
  LOCK_MTIME=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo "$NOW")
  [ "$((NOW - LOCK_MTIME))" -gt "$LOCK_STALE_SECONDS" ] && rm -f "$LOCK" 2>/dev/null
fi

# The exclusive create. `set -C` (noclobber) makes the redirection an
# open(O_CREAT|O_EXCL) issued by the shell ITSELF — no external binary, no
# separate test — so exactly one racer wins and every other one exits here.
# The subshell keeps noclobber (and any redirection failure) local.
( set -C; : > "$LOCK" ) 2>/dev/null || exit 0

# Re-check the cooldown under the claim — the fast path above was read before
# the winner of a race had written its stamp.
if [ -f "$STAMP" ]; then
  STAMP_MTIME=$(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$((NOW - STAMP_MTIME))" -lt "$COOLDOWN_SECONDS" ]; then
    rm -f "$LOCK" 2>/dev/null
    exit 0
  fi
fi

# The stamp is the cooldown. If it cannot be written, the window can never
# close — so refuse to remediate at all rather than remediate on every session
# forever against an unwritable workspace/.
if ! ( : > "$STAMP" ) 2>/dev/null || [ ! -f "$STAMP" ]; then
  rm -f "$LOCK" 2>/dev/null
  exit 0
fi

SELF="$HQ_ROOT/.claude/hooks/check-client-health.sh"
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$SELF" --remediate "$HQ_ROOT" >/dev/null 2>&1 &
else
  nohup bash "$SELF" --remediate "$HQ_ROOT" >/dev/null 2>&1 &
fi
rm -f "$LOCK" 2>/dev/null

cat <<EOF
<hq-client-health>
Detected a possible local health issue ($SIGNAL). Background remediation is
running: hq doctor will corroborate and apply safe fixes (hq doctor --fix).
Unresolved checks go to Sentry when the company flag is on, or to the existing
feedback report path on older installs and while the flag is off.
No action needed in this session.
</hq-client-health>
EOF

} 2>/dev/null || true

exit 0
