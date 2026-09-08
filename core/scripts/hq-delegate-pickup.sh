#!/usr/bin/env bash
# hq-core: public
# hq-delegate-pickup.sh — close the delegation loop with a receipt or a FAILED
# state (2026-09-07).
#
# Why: the delegate pipeline ended at "sent", which is a send receipt, not a
# delivery receipt. Seven delegations sat at sent/building with no way to tell
# whether the recipient could act. This script adds the two missing states:
#
#   sent --(evidence)--> picked-up      recipient demonstrably has the work
#   sent --(silence past window)--> failed   nobody picked it up; sender is told why
#
# Evidence, checked in order (any one suffices):
#   1. --ack "<text>"            an explicit acknowledgement (DM reply, chat) —
#                                recorded verbatim with a timestamp
#   2. repo branch has a commit by the recipient after sentAt
#      (manifest.repo.path + repo.branch, author email == to.principal)
#   3. --evidence "<free text>"  any other proof the operator observed
#
# Usage:
#   hq-delegate-pickup.sh --manifest <path> --ack "<text>"        # record receipt
#   hq-delegate-pickup.sh --manifest <path> --evidence "<text>"   # record receipt
#   hq-delegate-pickup.sh --manifest <path> --check [--window-hours N]   # probe repo; fail if silent past window (default 72)
#   hq-delegate-pickup.sh --manifest <path> --status               # print state line
#
# Exit 0: picked-up (or already). Exit 5: failed (window elapsed, no evidence).
# Exit 6: still waiting (inside window, no evidence). Exit 2: usage/precondition.
set -uo pipefail
MANIFEST=""; ACK=""; EVIDENCE=""; CHECK=0; STATUS_ONLY=0; WINDOW="${HQ_DELEGATE_PICKUP_WINDOW_HOURS:-72}"
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --ack) ACK="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --window-hours) WINDOW="$2"; shift 2 ;;
    --status) STATUS_ONLY=1; shift ;;
    -h|--help) sed -n 2,28p "$0"; exit 0 ;;
    *) echo "hq-delegate-pickup: unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$MANIFEST" ] && [ -r "$MANIFEST" ] || { echo "usage: --manifest <path> (--ack|--evidence|--check|--status)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "hq-delegate-pickup: jq required" >&2; exit 2; }
NOW="${HQ_DELEGATE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
STATUS="$(jq -r '.status // empty' "$MANIFEST")"
SENT_AT="$(jq -r '.sentAt // empty' "$MANIFEST")"
TO="$(jq -r '.to.principal // empty' "$MANIFEST")"
NAME="$(jq -r '.to.displayName // .to.principal // "the recipient"' "$MANIFEST")"

if [ "$STATUS_ONLY" = 1 ]; then
  jq -r '"\(.delegationId) \(.status)" + (if .pickedUpAt then " picked-up " + .pickedUpAt + " via " + (.pickup.kind // "?") else "" end) + (if .failedAt then " failed " + .failedAt + ": " + (.failure.reason // "") else "" end)' "$MANIFEST"
  exit 0
fi
case "$STATUS" in
  picked-up) echo "hq-delegate-pickup: already picked up ($(jq -r '.pickedUpAt' "$MANIFEST"))"; exit 0 ;;
  failed) echo "hq-delegate-pickup: already failed ($(jq -r '.failure.reason // ""' "$MANIFEST"))"; exit 5 ;;
  sent) ;;
  *) echo "hq-delegate-pickup: manifest status is '$STATUS' — only a 'sent' delegation can be picked up (send it first)" >&2; exit 2 ;;
esac

record_pickup() { # <kind> <detail>
  jq --arg now "$NOW" --arg k "$1" --arg d "$2" \
    '.status = "picked-up" | .pickedUpAt = $now | .pickup = {kind: $k, detail: $d, recordedAt: $now}' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  echo "hq-delegate-pickup: $NAME picked up the delegation ($1) — status advanced to 'picked-up'"
  exit 0
}
[ -n "$ACK" ] && record_pickup ack "$ACK"
[ -n "$EVIDENCE" ] && record_pickup evidence "$EVIDENCE"

[ "$CHECK" = 1 ] || { echo "hq-delegate-pickup: nothing to do (pass --ack, --evidence, --check, or --status)" >&2; exit 2; }

# Evidence 2: a commit by the recipient on the handed-over branch after sentAt.
REPO="$(jq -r '.repo.path // empty' "$MANIFEST")"
BRANCH="$(jq -r '.repo.branch // empty' "$MANIFEST")"
if [ -n "$REPO" ] && [ -d "$REPO" ] && [ -n "$BRANCH" ] && [ -n "$TO" ]; then
  git -C "$REPO" fetch -q origin "$BRANCH" 2>/dev/null || true
  ref="origin/$BRANCH"; git -C "$REPO" show-ref --verify --quiet "refs/remotes/$ref" || ref="$BRANCH"
  c="$(git -C "$REPO" log "$ref" --author="$TO" ${SENT_AT:+--since="$SENT_AT"} --format='%h %ad %s' --date=short -1 2>/dev/null || true)"
  [ -n "$c" ] && record_pickup commit "$c on $BRANCH"
fi

# No evidence. Inside the window: waiting. Past it: FAILED, with the reason.
if [ -n "$SENT_AT" ]; then
  sent_epoch="$(date -u -d "$SENT_AT" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$SENT_AT" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date -u -d "$NOW" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$NOW" +%s 2>/dev/null || date +%s)"
  age_h=$(( (now_epoch - sent_epoch) / 3600 ))
else
  age_h=0
fi
if [ "$age_h" -lt "$WINDOW" ]; then
  echo "hq-delegate-pickup: waiting — no pickup evidence from $NAME yet (${age_h}h of a ${WINDOW}h window)"
  exit 6
fi
reason="no pickup evidence from $NAME within ${WINDOW}h of send (${SENT_AT:-unknown}): no acknowledgement, no commit by $TO on ${BRANCH:-the branch}"
jq --arg now "$NOW" --arg r "$reason" '.status = "failed" | .failedAt = $now | .failure = {reason: $r, recordedAt: $now}' \
  "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
echo "hq-delegate-pickup: FAILED — $reason. Re-send with a direct ask, or hand it to someone else." >&2
exit 5
