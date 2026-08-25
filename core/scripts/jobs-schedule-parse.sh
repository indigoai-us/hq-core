#!/usr/bin/env bash
# hq-core: public
# jobs-schedule-parse.sh — resolve natural-language (or raw cron) schedules for /schedule.
#
# Usage:
#   core/scripts/jobs-schedule-parse.sh [--tz IANA] [--json] "<schedule text>"
#
# Prints one JSON object on stdout:
#   {"ok":true,"cron":"0 9 * * 1-5","timezone":"America/Los_Angeles",
#    "human":"Every weekday at 9:00 AM (America/Los_Angeles)","source":"nl"|"cron"}
#   {"ok":false,"error":"..."}
#
# Cron is always the canonical 5-field form. NL is never echoed back as storage.
# Timezone defaults to the host IANA zone (macOS /etc/localtime, $TZ, or UTC).
#
# Requires: node. Optional: jq (not required for parse).

set -euo pipefail

TZ_OVERRIDE=""

usage() {
  echo "usage: jobs-schedule-parse.sh [--tz IANA] \"<nl or cron schedule>\"" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tz)
      [ "$#" -ge 2 ] || usage
      TZ_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      # JSON is the only output mode; flag kept for callers/docs symmetry
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "jobs-schedule-parse: unknown flag: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 1 ] || usage
SCHEDULE="$*"
SCHEDULE="$(printf '%s' "$SCHEDULE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$SCHEDULE" ] || {
  printf '%s\n' '{"ok":false,"error":"empty schedule"}'
  exit 1
}

export JOBS_SCHEDULE_PARSE_INPUT="$SCHEDULE"
export JOBS_SCHEDULE_PARSE_TZ="${TZ_OVERRIDE}"

node <<'JS'
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const inp = (process.env.JOBS_SCHEDULE_PARSE_INPUT || "").trim();
const tzOverride = (process.env.JOBS_SCHEDULE_PARSE_TZ || "").trim();

function fail(msg, code = 1) {
  process.stdout.write(JSON.stringify({ ok: false, error: msg }));
  process.stdout.write("\n");
  process.exit(code);
}

function detectTz() {
  if (tzOverride) return tzOverride;
  const envTz = (process.env.TZ || "").trim();
  if (envTz && envTz.includes("/")) return envTz;
  try {
    const link = fs.realpathSync("/etc/localtime");
    const parts = link.split(path.sep).filter(Boolean);
    const i = parts.indexOf("zoneinfo");
    if (i >= 0) {
      const cand = parts.slice(i + 1).join("/");
      if (cand) return cand;
    }
  } catch (_) {
    /* ignore */
  }
  try {
    const out = execFileSync(
      "timedatectl",
      ["show", "-p", "Timezone", "--value"],
      { encoding: "utf8", timeout: 2000, stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
    if (out && out.includes("/")) return out;
  } catch (_) {
    /* ignore */
  }
  return "UTC";
}

function validateIana(tz) {
  const wellFormed = /^(UTC|[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)+)$/;
  if (!wellFormed.test(tz)) return false;
  try {
    Intl.DateTimeFormat(undefined, { timeZone: tz });
    return true;
  } catch (_) {
    // Intl may lack tzdata on some hosts — accept well-formed names
    return wellFormed.test(tz);
  }
}

const CRON_RE = /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/;

const DOW_NAMES = {
  sun: 0,
  sunday: 0,
  mon: 1,
  monday: 1,
  tue: 2,
  tues: 2,
  tuesday: 2,
  wed: 3,
  wednesday: 3,
  thu: 4,
  thur: 4,
  thurs: 4,
  thursday: 4,
  fri: 5,
  friday: 5,
  sat: 6,
  saturday: 6,
};

const DOW_LABEL = {
  "0": "Sunday",
  "1": "Monday",
  "2": "Tuesday",
  "3": "Wednesday",
  "4": "Thursday",
  "5": "Friday",
  "6": "Saturday",
  "1-5": "weekday",
  "*": "day",
};

function parseClock(fragment) {
  const s = fragment.trim().toLowerCase().replace(/ /g, "");
  const m = /^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/.exec(s);
  if (!m) return null;
  let hour = parseInt(m[1], 10);
  const minute = parseInt(m[2] || "0", 10);
  const ampm = m[3];
  if (minute > 59) return null;
  if (ampm) {
    if (hour < 1 || hour > 12) return null;
    if (ampm === "am") hour = hour === 12 ? 0 : hour;
    else hour = hour === 12 ? 12 : hour + 12;
  } else if (hour > 23) {
    return null;
  }
  return [hour, minute];
}

function fmtClock(hour, minute) {
  const suffix = hour < 12 ? "AM" : "PM";
  let h12 = hour % 12;
  if (h12 === 0) h12 = 12;
  return `${h12}:${String(minute).padStart(2, "0")} ${suffix}`;
}

function humanizeCron(cron, tz) {
  const parts = cron.split(/\s+/);
  if (parts.length !== 5) return `Cron \`${cron}\` (${tz})`;
  const [minute, hour, dom, month, dow] = parts;
  if (
    /^\d+$/.test(minute) &&
    /^\d+$/.test(hour) &&
    dom === "*" &&
    month === "*" &&
    (dow === "*" || dow === "1-5")
  ) {
    const clock = fmtClock(parseInt(hour, 10), parseInt(minute, 10));
    if (dow === "1-5") return `Every weekday at ${clock} (${tz})`;
    return `Every day at ${clock} (${tz})`;
  }
  if (
    /^\d+$/.test(minute) &&
    /^\d+$/.test(hour) &&
    dom === "*" &&
    month === "*" &&
    /^\d+$/.test(dow)
  ) {
    const day = DOW_LABEL[dow] || `day ${dow}`;
    return `Every ${day} at ${fmtClock(parseInt(hour, 10), parseInt(minute, 10))} (${tz})`;
  }
  if (minute.startsWith("*/") && hour === "*" && dom === "*" && month === "*" && dow === "*") {
    return `Every ${minute.slice(2)} minutes (${tz})`;
  }
  if (minute === "0" && hour.startsWith("*/") && dom === "*" && month === "*" && dow === "*") {
    return `Every ${hour.slice(2)} hours (${tz})`;
  }
  if (minute === "0" && hour === "*" && dom === "*" && month === "*" && dow === "*") {
    return `Every hour on the hour (${tz})`;
  }
  return `Cron \`${cron}\` (${tz})`;
}

function parseNl(text) {
  const s = text.trim();
  const low = s.toLowerCase();
  let m = /^every\s+(\d+)\s+minutes?$/.exec(low);
  if (m) {
    const n = parseInt(m[1], 10);
    if (n < 1 || n > 59) return [null, "minute interval must be 1..59"];
    return [`*/${n} * * * *`, `Every ${n} minutes`];
  }
  if (low === "every hour" || low === "hourly") {
    return ["0 * * * *", "Every hour on the hour"];
  }
  m = /^every\s+(\d+)\s+hours?$/.exec(low);
  if (m) {
    const n = parseInt(m[1], 10);
    if (n < 1 || n > 23) return [null, "hour interval must be 1..23"];
    return [`0 */${n} * * *`, `Every ${n} hours`];
  }
  m = /^(?:every\s+)?(weekday|weekdays|day|daily)\s+(?:at\s+)?(.+)$/.exec(low);
  if (m) {
    const kind = m[1];
    const clock = parseClock(m[2]);
    if (!clock) return [null, `could not parse time: ${m[2]}`];
    const [hour, minute] = clock;
    if (kind === "weekday" || kind === "weekdays") {
      return [`${minute} ${hour} * * 1-5`, `Every weekday at ${fmtClock(hour, minute)}`];
    }
    return [`${minute} ${hour} * * *`, `Every day at ${fmtClock(hour, minute)}`];
  }
  m =
    /^(?:every\s+)?(sun(?:day)?|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?)s?\s+(?:at\s+)?(.+)$/.exec(
      low
    );
  if (m) {
    const dow = DOW_NAMES[m[1]];
    const clock = parseClock(m[2]);
    if (!clock) return [null, `could not parse time: ${m[2]}`];
    const [hour, minute] = clock;
    return [
      `${minute} ${hour} * * ${dow}`,
      `Every ${DOW_LABEL[String(dow)]} at ${fmtClock(hour, minute)}`,
    ];
  }
  m = /^at\s+(.+?)\s+every\s+(weekday|weekdays|day|daily)$/.exec(low);
  if (m) {
    const clock = parseClock(m[1]);
    if (!clock) return [null, `could not parse time: ${m[1]}`];
    const [hour, minute] = clock;
    const kind = m[2];
    if (kind === "weekday" || kind === "weekdays") {
      return [`${minute} ${hour} * * 1-5`, `Every weekday at ${fmtClock(hour, minute)}`];
    }
    return [`${minute} ${hour} * * *`, `Every day at ${fmtClock(hour, minute)}`];
  }
  return [
    null,
    "unrecognized schedule — try 'every weekday at 9am', " +
      "'every day at 14:30', 'every monday at 9am', a 5-field cron, " +
      "or 'every 15 minutes'",
  ];
}

const tz = detectTz();
if (!validateIana(tz)) fail(`invalid IANA timezone: ${tz}`);

if (CRON_RE.test(inp) && !/[A-Za-z]/.test(inp)) {
  const cron = inp;
  const human = humanizeCron(cron, tz);
  process.stdout.write(
    JSON.stringify({ ok: true, cron, timezone: tz, human, source: "cron" })
  );
  process.stdout.write("\n");
  process.exit(0);
}

const named = /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(mon-fri|monday-friday)$/i.exec(inp);
if (named) {
  const cron = `${named[1]} ${named[2]} ${named[3]} ${named[4]} 1-5`;
  const human = humanizeCron(cron, tz);
  process.stdout.write(
    JSON.stringify({ ok: true, cron, timezone: tz, human, source: "cron" })
  );
  process.stdout.write("\n");
  process.exit(0);
}

const [cron, humanOrErr] = parseNl(inp);
if (cron == null) fail(humanOrErr);

const human = `${humanOrErr} (${tz})`;
process.stdout.write(
  JSON.stringify({ ok: true, cron, timezone: tz, human, source: "nl" })
);
process.stdout.write("\n");
JS
