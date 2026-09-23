#!/usr/bin/env bash
# source-yaml-validate.sh — validate a sources/{channel}/source.yaml.
# Spec: core/knowledge/public/hq-core/source-yaml-spec.md
# Usage: source-yaml-validate.sh <path/to/source.yaml>
# Exit 0 valid; 1 invalid (each violation printed); 2 bad usage / missing file.
set -uo pipefail
f="${1:-}"
[ -n "$f" ] || { echo "usage: source-yaml-validate.sh <source.yaml>" >&2; exit 2; }
[ -f "$f" ] || { echo "source-yaml-validate: no such file $f" >&2; exit 2; }

get() {
  awk -v k="$1" '$0 ~ "^"k":" { sub("^"k":[[:space:]]*", ""); sub("[[:space:]]+#.*$", ""); gsub(/^["\x27]|["\x27]$/, ""); print; exit }' "$f"
}
v=0
bad() { echo "$f: $*"; v=$((v+1)); }
oneof() { case " $3 " in *" $2 "*) ;; *) bad "$1 must be one of: $3 (got '${2:-<missing>}')" ;; esac; }

channel="$(get channel)"; kind="$(get kind)"; arrives="$(get arrives)"; pull="$(get pull_command)"
aud="$(get audience_rule)"; proc="$(get processor)"; run="$(get run)"; sched="$(get schedule)"

[ -n "$channel" ] || bad "channel is required"
folder="$(basename "$(dirname "$f")")"
[ -z "$channel" ] || [ "$channel" = "$folder" ] || bad "channel '$channel' must equal its folder name '$folder'"
oneof kind "$kind" "meeting email slack doc custom"
oneof arrives "$arrives" "drop pull cloud"
[ "$arrives" != pull ] || [ -n "$pull" ] || bad "pull_command is required when arrives: pull"
[ -n "$aud" ] || bad "audience_rule is required (attendees|thread|channel|company|explicit); it is never defaulted"
[ -z "$aud" ] || oneof audience_rule "$aud" "attendees thread channel company explicit"
[ -n "$proc" ] || bad "processor is required (<worker>/<skill>)"
[ -z "$proc" ] || printf '%s' "$proc" | grep -Eq '^[a-z0-9-]+/[a-z0-9-]+$' || bad "processor must look like <worker>/<skill> (got '$proc')"
oneof run "$run" "local cloud"
if [ -z "$sched" ]; then bad "schedule is required (cron or on-close)"
elif [ "$sched" != on-close ] && [ "$(printf '%s' "$sched" | awk '{print NF}')" -ne 5 ]; then bad "schedule must be a 5-field cron or on-close (got '$sched')"; fi

[ "$v" -eq 0 ] && { echo "$f: ok"; exit 0; }
exit 1
