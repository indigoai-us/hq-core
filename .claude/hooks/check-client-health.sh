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
#      re-verifies, and files ONE deduplicated bug per unresolved check id per
#      24h window via `hq feedback bug` (diagnostics attach component versions
#      server-side).
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
      "$@" &
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
    # FAIL/WARN result in the sync family, one per line.
    #
    # The doctor's `message` is deliberately DROPPED here rather than carried
    # and redacted later: it is free-text diagnostics that routinely embeds
    # absolute paths (home dir, HQ root, vault paths), and this value's only
    # consumer ships it off-box in a bug report. Emitting the stable check id
    # alone removes the leak surface entirely — and makes the record format
    # single-token, so no message can ever inject an extra record either.
    sync_findings() {
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        "$HQ_LIB_JQ" -r '
          (.results // [])[]
          | select(.family == "sync" and (.status == "FAIL" or .status == "WARN"))
          | (.checkId // "unknown")
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
            for (const r of rows) {
              if (!r || r.family !== "sync") continue;
              if (r.status !== "FAIL" && r.status !== "WARN") continue;
              process.stdout.write(String(r.checkId || "unknown") + "\n");
            }
          });' 2>/dev/null || true
        return 0
      fi
      cat >/dev/null 2>&1 || true
    }

    doctor_degraded() {
      # Emit the checkId of every FAIL/WARN result in the sync family of
      # `hq doctor --json`. Bounded where possible so a hung doctor cannot
      # leave a stray process behind.
      ( cd "$HQ_ROOT" 2>/dev/null && bounded 120 hq doctor --json 2>/dev/null ) \
        | sync_findings
    }

    # Corroborate: the foreground signal alone is not enough to act on.
    FINDINGS=$(doctor_degraded)
    [ -n "$FINDINGS" ] || exit 0

    # Attempt the allowlisted safe repairs, then re-verify. Only findings that
    # SURVIVE the fix pass are report-worthy — a fixed issue files no bug.
    ( cd "$HQ_ROOT" 2>/dev/null && bounded 300 hq doctor --fix --yes >/dev/null 2>&1 )
    REMAINING=$(doctor_degraded)
    [ -n "$REMAINING" ] || exit 0

    # File one deduplicated bug per unresolved check id per 24h window.
    NOW=$(date +%s)
    printf '%s\n' "$REMAINING" | while read -r CHECK_ID; do
      [ -n "$CHECK_ID" ] || continue
      # Sanitised id: this is the ONLY variable that reaches the report, so it
      # is constrained to a path-free, shell-inert character set.
      SAFE_ID=$(printf '%s' "$CHECK_ID" | tr -c 'A-Za-z0-9._-' '_')
      BUG_STAMP="$STATE_DIR/bugs/$SAFE_ID.stamp"
      BUG_LOCK="$STATE_DIR/bugs/$SAFE_ID.lock"

      # Release a lock abandoned by a killed remediation, so one crash cannot
      # mute a check id forever.
      if [ -f "$BUG_LOCK" ]; then
        LOCK_MTIME=$(stat -c %Y "$BUG_LOCK" 2>/dev/null || stat -f %m "$BUG_LOCK" 2>/dev/null || echo "$NOW")
        [ "$((NOW - LOCK_MTIME))" -gt 3600 ] && rm -f "$BUG_LOCK" 2>/dev/null
      fi

      # Claim this check id atomically BEFORE reading the dedupe stamp. Two
      # overlapping remediations would otherwise both see "no stamp" and both
      # file the same bug. `set -C` makes this an open(O_CREAT|O_EXCL) by the
      # shell itself — the same exclusive create the cooldown claim uses.
      ( set -C; : > "$BUG_LOCK" ) 2>/dev/null || continue

      if [ -f "$BUG_STAMP" ]; then
        STAMP_MTIME=$(stat -c %Y "$BUG_STAMP" 2>/dev/null || stat -f %m "$BUG_STAMP" 2>/dev/null || echo 0)
        if [ "$((NOW - STAMP_MTIME))" -lt 86400 ]; then
          rm -f "$BUG_LOCK" 2>/dev/null
          continue
        fi
      fi

      # Stamp only after the submission lands — a failed filing retries next
      # window instead of being recorded as done.
      #
      # The body is a FIXED template plus the sanitised check id. No doctor
      # message, no findings dump, no paths: support correlates by check id and
      # the component versions the feedback pipeline attaches server-side.
      if ( cd "$HQ_ROOT" 2>/dev/null && bounded 60 hq feedback bug \
            --title "Client health: $SAFE_ID unresolved after hq doctor --fix" \
            --body-file - >/dev/null 2>&1 <<EOF
Automated report from the check-client-health SessionStart hook (US-015).

The local doctor reported a sync-family check that \`hq doctor --fix --yes\`
could not repair:

- check: \`$SAFE_ID\`
- status: FAIL or WARN, still present after the safe repair pass

Only the stable check id is reported. Doctor messages and the raw findings
dump are deliberately withheld: they embed local absolute paths, which this
project does not send off-box. Reproduce locally with \`hq doctor --json\`.

Component versions are attached automatically by the feedback pipeline.
EOF
      ); then
        ( : > "$BUG_STAMP" ) 2>/dev/null || true
      fi
      rm -f "$BUG_LOCK" 2>/dev/null
    done
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
running: hq doctor will corroborate, apply safe fixes (hq doctor --fix), and
file a deduplicated bug via hq feedback if the issue is not auto-fixable.
No action needed in this session.
</hq-client-health>
EOF

} 2>/dev/null || true

exit 0
