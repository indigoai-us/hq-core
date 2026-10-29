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
#      re-verifies, then files the existing `hq feedback bug` summary for any
#      remaining findings.
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

sanitize_check_ids() {
  tr -dc 'A-Za-z0-9._:\n -' | cut -c 1-200 | sort -u
}

# Focused regression-test entry point for the exact production sanitizer.
if [ "${HQ_TEST_CLIENT_HEALTH_SANITIZER:-}" = "1" ]; then
  sanitize_check_ids
  exit $?
fi

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
             "unresolved-company-uid", "manifest-upload-rejected"] as $allowed
          |
          (.results // [])[]
          | select(.family == "sync" and (.status == "FAIL" or .status == "WARN"))
          | . as $row
          | select((($row.checkId // "") | startswith("sync.journal.") | not) or $row.fix.autoFixable != false)
          | select(($row.checkId != "sync.manifest.personal" and $row.checkId != "sync.update.core" and (($row.checkId // "") | startswith("sync.manifest.company.") | not)) or $row.status == "FAIL" or $row.fix.autoFixable != false)
          | select(((($row.checkId // "") as $rid | ["sync.runtime.realtime-lag", "sync.runtime.device-limit", "sync.runtime.conflicts"] | any(.[]; . == $rid)) | not) or $row.status == "FAIL" or ($row.fix | if type == "object" then .autoFixable else null end) != false)
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
              "unresolved-company-uid", "manifest-upload-rejected"
            ]);
            for (const r of rows) {
              if (!r || r.family !== "sync") continue;
              if (r.status !== "FAIL" && r.status !== "WARN") continue;
              if (typeof r.checkId === "string"
                && (r.checkId.startsWith("sync.journal.")
                  || r.checkId === "sync.manifest.personal"
                  || r.checkId === "sync.update.core"
                  || r.checkId.startsWith("sync.manifest.company.")
                  || r.checkId === "sync.runtime.realtime-lag"
                  || r.checkId === "sync.runtime.device-limit"
                  || r.checkId === "sync.runtime.conflicts")
                && r.status !== "FAIL" && r.fix && r.fix.autoFixable === false) continue;
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

    # Extract only completed refresh-sync outcomes from the --fix JSON. A
    # missing or malformed refreshSync array is not evidence that a check was
    # unreached, so callers keep every remaining finding in that case.
    refresh_sync_attempted_ids() {
      local document="$1"
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        printf '%s\n' "$document" | "$HQ_LIB_JQ" -e \
          'type == "object" and (.refreshSync | type == "array") and
           all(.refreshSync[]; (.checkId | type == "string") and
             (.outcome == "pull-succeeded" or .outcome == "pull-timeout" or
              .outcome == "pull-failed:4xx" or .outcome == "pull-failed:5xx" or
              .outcome == "pull-failed:network" or .outcome == "pull-failed:other"))' \
          >/dev/null 2>&1 || return 1
        printf '%s\n' "$document" | "$HQ_LIB_JQ" -r '.refreshSync[].checkId' 2>/dev/null || return 1
        return 0
      fi
      if [ -n "${HQ_LIB_NODE:-}" ]; then
        printf '%s\n' "$document" | "$HQ_LIB_NODE" -e '
          let input = "";
          process.stdin.on("data", chunk => input += chunk).on("end", () => {
            let doc;
            try { doc = JSON.parse(input); } catch { process.exit(1); }
            if (!doc || typeof doc !== "object" || !Array.isArray(doc.refreshSync)) process.exit(1);
            const outcomes = new Set([
              "pull-succeeded", "pull-timeout", "pull-failed:4xx",
              "pull-failed:5xx", "pull-failed:network", "pull-failed:other"
            ]);
            if (!doc.refreshSync.every(item => item && typeof item.checkId === "string" && outcomes.has(item.outcome))) {
              process.exit(1);
            }
            for (const item of doc.refreshSync) process.stdout.write(item.checkId + "\n");
          });' 2>/dev/null || return 1
        return 0
      fi
      return 1
    }

    # "<checkId>\t<class>" for each refresh-sync attempt in the --fix JSON,
    # where class is one fixed word: succeeded, timeout, handed-off,
    # lock-busy, 4xx, 5xx, network or other. Unknown outcomes are dropped.
    # Only the class leaves the machine: no paths, messages or values.
    refresh_sync_outcome_classes() {
      local document="$1"
      [ -n "$document" ] || return 0
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        printf '%s\n' "$document" | "$HQ_LIB_JQ" -r '
          if type == "object" and (.refreshSync | type == "array") then
            .refreshSync[]
            | select((.checkId | type == "string") and (.outcome | type == "string"))
            | select(.checkId | test("^sync\\.journal\\.[A-Za-z0-9._-]{1,160}$"))
            | [.checkId, ({"pull-succeeded":"succeeded","pull-timeout":"timeout",
                "pull-handed-off":"handed-off","pull-failed:lock-busy":"lock-busy",
                "pull-failed:4xx":"4xx","pull-failed:5xx":"5xx",
                "pull-failed:network":"network","pull-failed:other":"other"}[.outcome] // empty)]
            | select(length == 2) | @tsv
          else empty end' 2>/dev/null || true
        return 0
      fi
      if [ -n "${HQ_LIB_NODE:-}" ]; then
        printf '%s\n' "$document" | "$HQ_LIB_NODE" -e '
          let input = "";
          process.stdin.on("data", chunk => input += chunk).on("end", () => {
            let doc;
            try { doc = JSON.parse(input); } catch { return; }
            if (!doc || typeof doc !== "object" || !Array.isArray(doc.refreshSync)) return;
            const classes = {
              "pull-succeeded": "succeeded", "pull-timeout": "timeout",
              "pull-handed-off": "handed-off", "pull-failed:lock-busy": "lock-busy",
              "pull-failed:4xx": "4xx", "pull-failed:5xx": "5xx",
              "pull-failed:network": "network", "pull-failed:other": "other"
            };
            for (const item of doc.refreshSync) {
              if (!item || typeof item.checkId !== "string" || typeof item.outcome !== "string") continue;
              if (!/^sync\.journal\.[A-Za-z0-9._-]{1,160}$/.test(item.checkId)) continue;
              const cls = Object.prototype.hasOwnProperty.call(classes, item.outcome) ? classes[item.outcome] : null;
              if (cls) process.stdout.write(item.checkId + "\t" + cls + "\n");
            }
          });' 2>/dev/null || true
      fi
      return 0
    }

    # Checks the --fix run never reached. One "<checkId>" per line for each
    # sync.journal.*, sync.manifest.company.* or sync.manifest.personal
    # finding that --fix did not attempt in a run that used all
    # MAX_REFRESH_SYNC_PLANS_PER_RUN (10) network slots. hq-cli shares those
    # slots between journal pulls and manifest uploads, so both count. Such a
    # row is waiting for a later run, not failing (feedback 84d7a862).
    # Manifest uploads use the same slots, so a stale manifest past the cap
    # is unreached too (feedback 19d0a45e), but only while it is WARN: the
    # third argument lists the post-fix WARN ids that are auto-fixable, and a
    # manifest that is FAIL, not auto-fixable, or missing from that list
    # still files.
    # "Attempted" is any refresh-sync or refresh-manifest entry in applied,
    # any entry in refreshSync (a pull
    # that left no outcome is in applied only) or any row the fix JSON marks
    # repair-did-not-clear. "not-attempted" alone is not enough: hq-cli also
    # uses it for dirty-tree and pass-limit skips, which can repeat forever.
    # Exit 1 when the document has no refreshSync array.
    HQ_REFRESH_SYNC_CAP=10
    fix_unreached_ids() {
      local document="$1" findings="$2" warn_ids="${3:-}"
      [ -n "$document" ] || return 1
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        printf '%s\n' "$document" | "$HQ_LIB_JQ" -e \
          'type == "object" and (.refreshSync | type == "array")' >/dev/null 2>&1 || return 1
        printf '%s\n' "$findings" | "$HQ_LIB_JQ" -R -r --argjson cap "$HQ_REFRESH_SYNC_CAP" \
          --argjson doc "$document" --arg warn "$warn_ids" '
          def ids(f): [f | select(type == "object") | .checkId | select(type == "string")];
          ($doc.applied | if type == "array" then . else [] end) as $applied
          | ($doc.unresolved | if type == "array" then . else [] end) as $unresolved
          | (ids($doc.refreshSync[])
             + ids($applied[] | select(type == "object"
                 and (.fixClass == "refresh-sync" or .fixClass == "refresh-manifest")))
             + ids($unresolved[] | select(type == "object" and .reason == "repair-did-not-clear"))) as $tried
          | ((ids($doc.refreshSync[]) + ids($applied[] | select(type == "object"
               and (.fixClass == "refresh-sync" or .fixClass == "refresh-manifest")))
             | unique | length) >= $cap) as $capped
          | select($capped)
          | (split(":")[0]) as $id
          | select($id | test("^sync\\.(journal\\.[A-Za-z0-9._-]{1,160}|manifest\\.company\\.[A-Za-z0-9._-]{1,160}|manifest\\.personal)$"))
          | select(($tried | index($id)) == null)
          | select(($id | startswith("sync.manifest.") | not)
              or (($warn | split("\n") | index($id)) != null))
          | $id' 2>/dev/null || return 1
        return 0
      fi
      if [ -n "${HQ_LIB_NODE:-}" ]; then
        printf '%s\n' "$findings" | HQ_FIX_DOC="$document" HQ_WARN_IDS="$warn_ids" "$HQ_LIB_NODE" -e '
          let input = "";
          process.stdin.on("data", chunk => input += chunk).on("end", () => {
            let doc;
            try { doc = JSON.parse(process.env.HQ_FIX_DOC || ""); } catch { process.exit(1); }
            if (!doc || typeof doc !== "object" || !Array.isArray(doc.refreshSync)) process.exit(1);
            const arr = v => Array.isArray(v) ? v : [];
            const ids = list => list
              .filter(i => i && typeof i === "object" && typeof i.checkId === "string")
              .map(i => i.checkId);
            const applied = arr(doc.applied);
            const tried = new Set([
              ...ids(doc.refreshSync),
              ...ids(applied.filter(i => i && (i.fixClass === "refresh-sync" || i.fixClass === "refresh-manifest"))),
              ...ids(arr(doc.unresolved).filter(i => i && i.reason === "repair-did-not-clear"))
            ]);
            const slots = new Set([
              ...ids(doc.refreshSync),
              ...ids(applied.filter(i => i && (i.fixClass === "refresh-sync" || i.fixClass === "refresh-manifest")))
            ]);
            if (slots.size < Number(process.argv[1])) return;
            const warn = new Set((process.env.HQ_WARN_IDS || "").split("\n"));
            for (const line of input.split("\n")) {
              const id = line.split(":")[0];
              if (!/^sync\.(journal\.[A-Za-z0-9._-]{1,160}|manifest\.company\.[A-Za-z0-9._-]{1,160}|manifest\.personal)$/.test(id)) continue;
              if (tried.has(id)) continue;
              if (id.startsWith("sync.manifest.") && !warn.has(id)) continue;
              process.stdout.write(id + "\n");
            }
          });' "$HQ_REFRESH_SYNC_CAP" 2>/dev/null || return 1
        return 0
      fi
      return 1
    }

    # One line naming what --fix applied, so a report shows "not reached"
    # apart from "attempted and still failing" (feedback 19d0a45e). Only
    # sanitised sync check ids (from applied, plus refreshSync entries), a
    # fixed fix-class word and a fixed outcome
    # word leave the machine: refresh-sync uses its pull outcome class, other
    # classes the re-check status. No paths, targets or messages. At most 20
    # entries, deduped; empty when the document is missing or malformed.
    # Only checks still in the report (second argument, one id per line) are
    # named. Checks --fix cleared are counted, not named, so a report never
    # lists a company it would not otherwise mention.
    fix_applied_summary() {
      local document="$1" keep="${2:-}"
      [ -n "$document" ] || return 0
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        printf '%s\n' "$document" | "$HQ_LIB_JQ" -r --arg keep "$keep" '
          def cls: {"pull-succeeded":"succeeded","pull-timeout":"timeout",
            "pull-handed-off":"handed-off","pull-failed:lock-busy":"lock-busy",
            "pull-failed:4xx":"4xx","pull-failed:5xx":"5xx",
            "pull-failed:network":"network","pull-failed:other":"other"}[.] // "unknown";
          select(type == "object" and (.applied | type == "array"))
          | ((.refreshSync | if type == "array" then . else [] end)
             | map(select(type == "object" and (.checkId | type == "string")) | {key: .checkId, value: (.outcome | cls)})
             | from_entries) as $pull
          | [.applied[]
             | select(type == "object" and (.checkId | type == "string")
                 and (.checkId | test("^sync\\.[A-Za-z0-9._-]{1,160}$"))
                 and (.fixClass | type == "string") and (.fixClass | test("^[a-z][a-z-]{0,39}$")))
             | "\(.checkId) \(.fixClass) \(if .fixClass == "refresh-sync"
                 then ($pull[.checkId] // "no-outcome")
                 elif (.postStatus == "PASS" or .postStatus == "WARN" or .postStatus == "FAIL" or .postStatus == "SKIP")
                 then .postStatus else "no-recheck" end)"]
          + [$pull | to_entries[] | select(.key | test("^sync\\.[A-Za-z0-9._-]{1,160}$"))
             | "\(.key) refresh-sync \(.value)"]
          | unique
          | ($keep | split("\n") | map(select(length > 0))) as $k
          | map(select((split(" ")[0]) as $id | $k | index($id))) as $named
          | ([.[] | split(" ")[0]] | unique | map(select(. as $id | $k | index($id) | not)) | length) as $other
          | ($named | length) as $n
          | ([($named[0:20] | join("; "))]
             + (if $n > 20 then ["+\($n - 20) more"] else [] end)
             + (if $other > 0 then ["\($other) other checks"] else [] end)
             | map(select(length > 0)) | join("; "))
          | select(length > 0)' 2>/dev/null || true
        return 0
      fi
      if [ -n "${HQ_LIB_NODE:-}" ]; then
        printf '%s\n' "$document" | HQ_KEEP_IDS="$keep" "$HQ_LIB_NODE" -e '
          let input = "";
          process.stdin.on("data", c => input += c).on("end", () => {
            let doc;
            try { doc = JSON.parse(input); } catch { return; }
            if (!doc || typeof doc !== "object" || !Array.isArray(doc.applied)) return;
            const classes = {
              "pull-succeeded": "succeeded", "pull-timeout": "timeout",
              "pull-handed-off": "handed-off", "pull-failed:lock-busy": "lock-busy",
              "pull-failed:4xx": "4xx", "pull-failed:5xx": "5xx",
              "pull-failed:network": "network", "pull-failed:other": "other"
            };
            const pull = {};
            for (const i of Array.isArray(doc.refreshSync) ? doc.refreshSync : []) {
              if (!i || typeof i !== "object" || typeof i.checkId !== "string") continue;
              pull[i.checkId] = Object.prototype.hasOwnProperty.call(classes, i.outcome) ? classes[i.outcome] : "unknown";
            }
            const out = new Set();
            for (const a of doc.applied) {
              if (!a || typeof a !== "object" || typeof a.checkId !== "string" || typeof a.fixClass !== "string") continue;
              if (!/^sync\.[A-Za-z0-9._-]{1,160}$/.test(a.checkId) || !/^[a-z][a-z-]{0,39}$/.test(a.fixClass)) continue;
              let o;
              if (a.fixClass === "refresh-sync") o = Object.prototype.hasOwnProperty.call(pull, a.checkId) ? pull[a.checkId] : "no-outcome";
              else o = ["PASS", "WARN", "FAIL", "SKIP"].includes(a.postStatus) ? a.postStatus : "no-recheck";
              out.add(a.checkId + " " + a.fixClass + " " + o);
            }
            for (const [id, o] of Object.entries(pull)) {
              if (/^sync\.[A-Za-z0-9._-]{1,160}$/.test(id)) out.add(id + " refresh-sync " + o);
            }
            const keep = new Set((process.env.HQ_KEEP_IDS || "").split("\n").filter(Boolean));
            const list = [...out].sort();
            const named = list.filter(e => keep.has(e.split(" ")[0]));
            const other = new Set(list.map(e => e.split(" ")[0]).filter(id => !keep.has(id))).size;
            const parts = [];
            if (named.length) parts.push(named.slice(0, 20).join("; "));
            if (named.length > 20) parts.push("+" + (named.length - 20) + " more");
            if (other > 0) parts.push(other + " other checks");
            if (parts.length) process.stdout.write(parts.join("; ") + "\n");
          });' 2>/dev/null || true
      fi
      return 0
    }

    # 0 when the installed hq-cli is older than the release that made --fix
    # skip unresolvable companies and refresh up to 10 journals per run
    # (5.345.159). Most stale-journal and manifest reports come from those
    # builds, and only an update fixes them.
    HQ_CLI_FIX_FLOOR="5.345.159"
    cli_older_than_fix_floor() {
      local version="$1"
      case "$version" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) return 1 ;;
      esac
      awk -v a="$version" -v b="$HQ_CLI_FIX_FLOOR" 'BEGIN {
        split(a, x, "."); split(b, y, ".");
        for (i = 1; i <= 3; i++) {
          if ((x[i] + 0) < (y[i] + 0)) exit 0;
          if ((x[i] + 0) > (y[i] + 0)) exit 1;
        }
        exit 1
      }'
    }

    doctor_document() {
      # Newer CLI versions resolve the opt-in hq-flags gate. Older versions
      # reject the private option, so fall back to ordinary JSON output. Both
      # invocations are bounded and raw JSON stays in this process.
      local document rc
      document=$(cd "$HQ_ROOT" 2>/dev/null && bounded 120 hq doctor --json --client-health-report 2>/dev/null)
      rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$document" ]; then
        document=$(cd "$HQ_ROOT" 2>/dev/null && bounded 120 hq doctor --json 2>/dev/null)
        rc=$?
      fi
      # Exit 1 (with no findings) when doctor itself did not run cleanly, so
      # callers can tell "no findings" from "could not check".
      [ "$rc" -eq 0 ] && [ -n "$document" ] || return 1
      printf '%s\n' "$document"
    }

    doctor_degraded() {
      local document
      document=$(doctor_document) || return 1
      printf '%s\n' "$document" | sync_findings
    }

    # stdin: an `hq doctor --json` document. stdout: the checkId of every sync
    # row whose status is exactly WARN and whose fix.autoFixable is true (a
    # row --fix could have repaired had it reached it). Used only to keep a manifest FAIL
    # filing when the run hit the --fix cap; prints nothing on bad input.
    sync_warn_ids() {
      if [ -n "${HQ_LIB_JQ:-}" ]; then
        "$HQ_LIB_JQ" -r '(.results // [])[] | select(type == "object")
          | select(.family == "sync" and .status == "WARN" and (.checkId | type == "string"))
          | select((.fix | type == "object") and .fix.autoFixable == true)
          | .checkId' 2>/dev/null || true
        return 0
      fi
      if [ -n "${HQ_LIB_NODE:-}" ]; then
        "$HQ_LIB_NODE" -e '
          let d = "";
          process.stdin.on("data", c => d += c).on("end", () => {
            let doc;
            try { doc = JSON.parse(d); } catch { return; }
            for (const r of (doc && Array.isArray(doc.results)) ? doc.results : []) {
              if (r && r.family === "sync" && r.status === "WARN" && typeof r.checkId === "string"
                && r.fix && typeof r.fix === "object" && r.fix.autoFixable === true)
                process.stdout.write(r.checkId + "\n");
            }
          });' 2>/dev/null || true
        return 0
      fi
      cat >/dev/null 2>&1 || true
    }

    # The set of check IDs last reported from this install, as one line:
    # "<fingerprint> <epoch of the successful send>". The same set is not
    # filed again until a clean doctor run shows no findings, the set changes,
    # or 14 days pass since that send (feedback 9b4a5016: machines filed the
    # same report every day). The expiry matters because the clean run that
    # clears the record only happens inside remediation, and remediation only
    # runs when a session sees a foreground signal. A user who fixes sync by
    # hand never gets that run, so without an expiry the same set returning
    # later would never be reported again.
    REPORTED_SET="$STATE_DIR/bugs/reported-set"
    REPORTED_SET_TTL_SECONDS=1209600   # 14 days
    # HQ_TEST_FORCE_HEALTH_NOW is a fixture seam only (same shape as
    # HQ_TEST_FORCE_HEALTH_DEADLINE): it moves this run's clock so the 14-day
    # expiry is provable without waiting.
    NOW=$(date +%s)
    case "${HQ_TEST_FORCE_HEALTH_NOW:-}" in
      ""|*[!0-9]*) ;;
      *) NOW="$HQ_TEST_FORCE_HEALTH_NOW" ;;
    esac

    # Corroborate: the foreground signal alone is not enough to act on.
    FINDINGS=$(doctor_degraded)
    DOCTOR_RC=$?
    if [ -z "$FINDINGS" ]; then
      [ "$DOCTOR_RC" -eq 0 ] && rm -f "$REPORTED_SET" 2>/dev/null
      exit 0
    fi

    # Attempt the allowlisted safe repairs, then re-verify. Only findings that
    # SURVIVE the fix pass are report-worthy — a fixed issue files no bug.
    UNREACHED_FILTER_ENABLED=false
    FLAG_READER="$HQ_ROOT/.claude/hooks/client-health-unreached-checks-flag.cjs"
    if [ -f "$FLAG_READER" ] && [ -n "${HQ_LIB_NODE:-}" ]; then
      FLAG_VALUE=$(HQ_CLI_BIN="${HQ_CLI_BIN:-$(command -v hq 2>/dev/null)}" "$HQ_LIB_NODE" "$FLAG_READER" 2>/dev/null) || FLAG_VALUE=false
      [ "$FLAG_VALUE" = true ] && UNREACHED_FILTER_ENABLED=true
    fi
    # The --fix JSON is always captured now: its per-journal refresh outcomes
    # go into the report (feedback cd56a501), and the unreached filter below
    # reads it when its flag is on. Capture to a private state file: on the
    # portable watchdog path, a killed command can leave a grandchild holding
    # stdout open. A command substitution around bounded would then wait for
    # that pipe after the deadline. Reading the completed file keeps the same
    # deadline and output.
    FIX_RESULT_FILE="$STATE_DIR/fix-result.$$"
    ( cd "$HQ_ROOT" 2>/dev/null && umask 077 && bounded 300 hq doctor --fix --yes --json \
        > "$FIX_RESULT_FILE" 2>/dev/null ) || true
    FIX_RESULT=$(cat "$FIX_RESULT_FILE" 2>/dev/null || true)
    rm -f "$FIX_RESULT_FILE" 2>/dev/null || true
    REMAINING_DOC=$(doctor_document)
    REMAINING_RC=$?
    REMAINING=""
    REMAINING_WARN_IDS=""
    if [ "$REMAINING_RC" -eq 0 ]; then
      REMAINING=$(printf '%s\n' "$REMAINING_DOC" | sync_findings)
      REMAINING_WARN_IDS=$(printf '%s\n' "$REMAINING_DOC" | sync_warn_ids)
    fi
    REMAINING_DOC=""
    HQ_CLI_VERSION_SEEN=$(cd "$HQ_ROOT" 2>/dev/null && bounded 15 hq --version 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    # An outdated hq-cli cannot repair these checks itself. Tell the user once
    # at the next session start (feedback cd56a501); only the version leaves
    # this file.
    if [ -n "$REMAINING" ] && cli_older_than_fix_floor "$HQ_CLI_VERSION_SEEN"; then
      PENDING_TMP="$STATE_DIR/cli-outdated.pending.$$"
      if (umask 077; printf '%s\n' "$HQ_CLI_VERSION_SEEN" > "$PENDING_TMP") 2>/dev/null \
          && mv -f "$PENDING_TMP" "$STATE_DIR/cli-outdated.pending" 2>/dev/null; then
        :
      else
        rm -f "$PENDING_TMP" 2>/dev/null
      fi
    fi
    # The repair pass cleared everything: a later recurrence is a new report.
    # Checked before the unreached-journal filter, which hides rows that
    # are still failing.
    if [ "$REMAINING_RC" -eq 0 ] && [ -z "$REMAINING" ]; then
      rm -f "$REPORTED_SET" 2>/dev/null
    fi
    UNREACHED_COMPANY_JOURNAL_COUNT=0
    if [ "$UNREACHED_FILTER_ENABLED" = true ]; then
      if ATTEMPTED_REFRESH_IDS=$(refresh_sync_attempted_ids "$FIX_RESULT"); then
        FILTERED_REMAINING=""
        SEEN_UNREACHED=""
        while IFS= read -r finding; do
          [ -n "$finding" ] || continue
          finding_id="${finding%%:*}"
          finding_slug="${finding_id#sync.journal.}"
          case "$finding_id" in
            sync.journal.*)
              case "$finding_slug" in
                ""|personal|__hq_personal_vault__) ;;
                *)
                  case $'\n'"$ATTEMPTED_REFRESH_IDS"$'\n' in
                    *$'\n'"$finding_id"$'\n'*) ;;
                    *)
                      case $'\n'"$SEEN_UNREACHED"$'\n' in
                        *$'\n'"$finding_id"$'\n'*) ;;
                        *)
                          SEEN_UNREACHED="${SEEN_UNREACHED}${finding_id}"$'\n'
                          UNREACHED_COMPANY_JOURNAL_COUNT=$((UNREACHED_COMPANY_JOURNAL_COUNT + 1))
                          continue
                          ;;
                      esac
                      ;;
                  esac
                  ;;
              esac
              ;;
          esac
          FILTERED_REMAINING="${FILTERED_REMAINING}${finding}"$'\n'
        done <<EOF_FINDINGS
$REMAINING
EOF_FINDINGS
        REMAINING="${FILTERED_REMAINING%$'\n'}"
      fi
    fi
    # Journals and auto-fixable WARN manifests past the --fix refresh cap are not
    # failures yet. This needs no flag: the fix JSON itself says they were not
    # reached. Attempted journals that stayed FAIL or WARN still file.
    if [ -n "$REMAINING" ] && CAPPED_UNREACHED_IDS=$(fix_unreached_ids "$FIX_RESULT" "$REMAINING" "$REMAINING_WARN_IDS") \
        && [ -n "$CAPPED_UNREACHED_IDS" ]; then
      FILTERED_REMAINING=""
      while IFS= read -r finding; do
        [ -n "$finding" ] || continue
        finding_id="${finding%%:*}"
        case $'\n'"$CAPPED_UNREACHED_IDS"$'\n' in
          *$'\n'"$finding_id"$'\n'*)
            case "$finding_id" in
              sync.journal.personal|sync.journal.__hq_personal_vault__|sync.manifest.*) ;;
              *) UNREACHED_COMPANY_JOURNAL_COUNT=$((UNREACHED_COMPANY_JOURNAL_COUNT + 1)) ;;
            esac
            continue
            ;;
        esac
        FILTERED_REMAINING="${FILTERED_REMAINING}${finding}"$'\n'
      done <<EOF_CAPPED
$REMAINING
EOF_CAPPED
      REMAINING="${FILTERED_REMAINING%$'\n'}"
    fi

    if [ "$UNREACHED_COMPANY_JOURNAL_COUNT" -gt 0 ]; then
      printf '%s\tunreached_company_journal_checks=%s\n' "$(date +%s)" \
        "$UNREACHED_COMPANY_JOURNAL_COUNT" >> "$STATE_DIR/repair-pass.log" 2>/dev/null || true
      PENDING_TMP="$STATE_DIR/unreached-count.pending.$$"
      if (umask 077; printf '%s\n' "$UNREACHED_COMPANY_JOURNAL_COUNT" > "$PENDING_TMP") 2>/dev/null \
          && mv -f "$PENDING_TMP" "$STATE_DIR/unreached-count.pending" 2>/dev/null; then
        :
      else
        rm -f "$PENDING_TMP" 2>/dev/null
      fi
    fi
    [ -n "$REMAINING" ] || exit 0
    # An hq-cli below the fix floor cannot clear journal or manifest checks;
    # only an update can. When those are all that is left, the local update
    # notice (cli-outdated.pending) is the whole response: a feedback row
    # would only record user configuration (feedback 84d7a862, 32 of 44
    # linked rows). Any other sync row still files, with likely-cause noted.
    if cli_older_than_fix_floor "$HQ_CLI_VERSION_SEEN" \
        && ! printf '%s\n' "$REMAINING" | grep -vqE '^(sync\.(journal|manifest)\.|$)'; then
      exit 0
    fi

    # Only sanitised IDs leave the machine. Cap both rows and ID length so a
    # large install still produces a small report; raw messages stay local.
    CHECK_IDS=$(printf '%s\n' "$REMAINING" | sanitize_check_ids)
    # Fingerprint the KINDS of failing checks, not each company: per-company
    # rows come and go as --fix rotates through journals, so per-company ids
    # would give a new fingerprint (and a new report) on most days. Personal
    # journals keep their own ids. The result is sorted and deduped, so doctor
    # output order does not matter.
    CHECK_SET=$(printf '%s\n' "$CHECK_IDS" | sed -E \
        -e 's/^sync\.journal\.(personal|__hq_personal_vault__)(:|$)/sync.journal-personal.\1\2/' \
        -e 's/^sync\.journal\.[^:]*/sync.journal.company/' \
        -e 's/^sync\.journal-personal\./sync.journal./' \
        -e 's/^(sync\.manifest\.(company|unresolved))\.[^:]*/\1/' \
      | sort -u | cksum | tr -d ' \t')

    # One bounded attempt per install, not one attempt per company/check.
    # Reserve it BEFORE sending: a timeout may mean the report was accepted
    # but the response was lost. Retrying could duplicate the report.
    BUG_LOCK="$STATE_DIR/bugs/summary.lock"
    ATTEMPT_STAMP="$STATE_DIR/bugs/report-attempt.stamp"
    if [ -f "$BUG_LOCK" ]; then
      LOCK_MTIME=$(stat -c %Y "$BUG_LOCK" 2>/dev/null || stat -f %m "$BUG_LOCK" 2>/dev/null || echo "$NOW")
      [ "$((NOW - LOCK_MTIME))" -gt 3600 ] && rm -f "$BUG_LOCK" 2>/dev/null
    fi
    if ! ( set -C; : > "$BUG_LOCK" ) 2>/dev/null; then
      exit 0
    fi
    # The same set was already reported from this install in the last 14
    # days and has not cleared since: one open report is enough. Read under
    # the lock so a concurrent run's record is seen. Only an exact
    # "<fingerprint> <epoch>" line with an epoch that is not in the future
    # suppresses; anything else is treated as no record, so a corrupt ledger
    # files a report instead of hiding one. A dedup hit exits here without
    # writing, so it never extends the window.
    LEDGER=""
    [ -f "$REPORTED_SET" ] && LEDGER=$(head -c 256 "$REPORTED_SET" 2>/dev/null)
    LEDGER_TS="${LEDGER#* }"
    if [ -n "$CHECK_SET" ] && [ "$LEDGER" = "$CHECK_SET $LEDGER_TS" ]; then
      case "$LEDGER_TS" in
        ""|*[!0-9]*) ;;
        *)
          if [ "${#LEDGER_TS}" -le 12 ] && [ "$LEDGER_TS" -le "$NOW" ] \
              && [ "$((NOW - LEDGER_TS))" -lt "$REPORTED_SET_TTL_SECONDS" ]; then
            rm -f "$BUG_LOCK" 2>/dev/null
            exit 0
          fi
          ;;
      esac
    fi
    if [ -f "$ATTEMPT_STAMP" ]; then
      STAMP_MTIME=$(stat -c %Y "$ATTEMPT_STAMP" 2>/dev/null || stat -f %m "$ATTEMPT_STAMP" 2>/dev/null || echo "$NOW")
      if [ "$((NOW - STAMP_MTIME))" -lt 86400 ]; then
        rm -f "$BUG_LOCK" 2>/dev/null
        exit 0
      fi
    fi
    if ! ( : > "$ATTEMPT_STAMP" ) 2>/dev/null; then
      rm -f "$BUG_LOCK" 2>/dev/null
      exit 0
    fi
    # The removed direct-Sentry CLI route is no longer available. Keep sending
    # the same sanitized summary through the feedback report path below.
    CHECK_COUNT=$(printf '%s\n' "$CHECK_IDS" | wc -l | tr -d ' ')
    # Annotate each journal row with how its --fix pull ended. The fingerprint
    # above is computed from CHECK_IDS alone, so outcomes never change dedup.
    OUTCOME_CLASSES=$(refresh_sync_outcome_classes "$FIX_RESULT")
    CHECK_LIST=$(printf '%s\n' "$CHECK_IDS" | head -50 | while IFS= read -r line; do
      [ -n "$line" ] || continue
      id="${line%%:*}"
      cls=$(printf '%s\n' "$OUTCOME_CLASSES" | awk -F '\t' -v id="$id" '$1 == id { print $2; exit }')
      if [ -n "$cls" ]; then
        printf -- '- %s (--fix pull: %s)\n' "$line" "$cls"
      else
        printf -- '- %s\n' "$line"
      fi
    done)
    FIX_APPLIED_LINE=$(fix_applied_summary "$FIX_RESULT" \
      "$(printf '%s\n' "$CHECK_IDS" | sed 's/:.*//')" | head -n 1 \
      | tr -dc 'A-Za-z0-9._: ;+-' | cut -c 1-4096)
    CLI_NOTE=""
    if cli_older_than_fix_floor "$HQ_CLI_VERSION_SEEN"; then
      CLI_NOTE="hq-cli $HQ_CLI_VERSION_SEEN is older than $HQ_CLI_FIX_FLOOR. Updating hq-cli fixes most of these checks.
likely-cause=stale-cli"
    fi
    # Automatic reports must opt out explicitly: the feedback CLI otherwise
    # collects and uploads the same log bundle for every report.
    if ( cd "$HQ_ROOT" 2>/dev/null && bounded 60 hq feedback bug \
          --reporter agent \
          --title "[observation] Client health: sync checks unresolved after hq doctor --fix" \
          --no-logs --body-file - >/dev/null 2>&1 <<EOF
src=client-health impact=inferred
Automated report from the check-client-health SessionStart hook.

After the safe repair pass, $CHECK_COUNT sync checks still report FAIL or WARN.
Check IDs or opted-in checkId: reasonCode pairs (up to 50 shown), with the
--fix pull outcome for sync journals when known:
$CHECK_LIST

--fix applied (check id, fix class, outcome): ${FIX_APPLIED_LINE:-none}
${CLI_NOTE:+
$CLI_NOTE
}
Doctor messages and log bundles are not attached. Reproduce locally with
\`hq doctor --json\`. Component versions are attached by the feedback pipeline.
Automatic reporting is limited to one attempt per HQ install every 24 hours,
and the same set of checks is reported at most once every 14 days until it
clears or changes.
EOF
    ); then
      ( : > "$STATE_DIR/bugs/summary.stamp" ) 2>/dev/null || true
      # Only a filed report suppresses the set, and only a filed report sets
      # the timestamp. A failed send leaves the ledger as it was and may retry
      # after the 24h cooldown, as before. Written via rename so a reader
      # never sees a half-written line.
      LEDGER_TMP="$REPORTED_SET.$$"
      if ( printf '%s %s\n' "$CHECK_SET" "$NOW" > "$LEDGER_TMP" ) 2>/dev/null \
          && mv -f "$LEDGER_TMP" "$REPORTED_SET" 2>/dev/null; then
        :
      else
        rm -f "$LEDGER_TMP" 2>/dev/null
      fi
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

# Surface counts from the last bounded repair in the same SessionStart
# diagnostics stream as the local next step. The remediation itself is detached,
# so the count is delivered on the next human-visible client-health check.
show_unreached_count_once() {
  local pending_file="$STATE_DIR/unreached-count.pending"
  local lock_file="$STATE_DIR/unreached-count-show.lock"
  local count now lock_mtime
  [ -f "$pending_file" ] || return 0
  if [ -f "$lock_file" ]; then
    now=$(date +%s)
    lock_mtime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo "$now")
    [ "$((now - lock_mtime))" -gt 300 ] && rm -f "$lock_file" 2>/dev/null
  fi
  ( set -C; : > "$lock_file" ) 2>/dev/null || return 0
  if [ ! -f "$pending_file" ]; then
    rm -f "$lock_file" 2>/dev/null
    return 0
  fi
  count=$(cat "$pending_file" 2>/dev/null || true)
  case "$count" in
    ""|*[!0-9]*) rm -f "$lock_file" 2>/dev/null; return 0 ;;
  esac
  if [ "$count" = 1 ]; then
    printf '<hq-client-health-result>\n1 company journal check was not reached by the last automatic repair and was left out of its report.\n</hq-client-health-result>\n'
  else
    printf '<hq-client-health-result>\n%s company journal checks were not reached by the last automatic repair and were left out of its report.\n</hq-client-health-result>\n' "$count"
  fi
  rm -f "$pending_file" "$lock_file" 2>/dev/null || true
}
show_unreached_count_once

# Tell the user once that their hq-cli is too old for --fix to repair their
# sync checks (written by remediation; feedback cd56a501).
show_cli_outdated_once() {
  local pending_file="$STATE_DIR/cli-outdated.pending"
  local version
  [ -f "$pending_file" ] || return 0
  version=$(head -c 32 "$pending_file" 2>/dev/null | tr -d '\r\n')
  rm -f "$pending_file" 2>/dev/null || return 0
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 0 ;;
  esac
  case "$version" in
    *[!0-9.]*) return 0 ;;
  esac
  printf '<hq-client-health-result>\nHQ sync checks are still failing after the automatic fix, and hq-cli %s is older than 5.345.159, the release that fixes most of them. Update hq-cli with: npm install -g @indigoai-us/hq-cli@latest (then start a new session).\n</hq-client-health-result>\n' "$version"
}
show_cli_outdated_once

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
      step="HQ couldn't update itself automatically. Run /update-hq to update HQ (hq update only updates packs), then restart this session." ;;
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

# Windows Git Bash/MSYS/Cygwin: setsid() drops the hidden console that the
# desktop host gave this hook, so every native program the detached child runs
# (node, powershell, curl) opens a visible console window. Only use setsid on
# real POSIX hosts; on MSYS a plain background child keeps the hidden console.
hq_setsid_available() {
  # OSTYPE (set by bash itself) avoids forking uname on the hook hot path.
  case "${OSTYPE:-}" in msys*|cygwin*) return 1 ;; esac
  command -v setsid >/dev/null 2>&1
}

SELF="$HQ_ROOT/.claude/hooks/check-client-health.sh"
if hq_setsid_available; then
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
