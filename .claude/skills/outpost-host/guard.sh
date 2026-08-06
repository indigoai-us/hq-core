#!/usr/bin/env bash
# outpost-host environment guard.
#
# This skill provisions a public web server (nginx) on the machine it runs on.
# That only makes sense on an HQ Outpost or a plain EC2 instance — a disposable,
# already-public cloud VM. Running it on an operator's laptop or any
# non-outpost/non-EC2 host would install system packages, open ports, and expose
# local apps from a machine that was never meant to be a server. So this guard is
# a HARD gate: the skill must call it FIRST and refuse to continue on failure.
#
# Exit 0  -> environment is an HQ Outpost or EC2 instance; safe to proceed.
# Exit 1  -> not an outpost/EC2 host; the skill must stop and tell the user.
#
# Detection is layered, cheapest + strongest first, and works offline (DMI/systemd)
# so it does not depend on IMDS being reachable.
#
# Detection inputs are injectable via env vars (defaults = the real host sources)
# so the guard can be exercised from both an outpost and a non-outpost in tests.

set -uo pipefail

SYS_VENDOR_FILE="${OUTPOST_GUARD_SYS_VENDOR_FILE:-/sys/devices/virtual/dmi/id/sys_vendor}"
ASSET_TAG_FILE="${OUTPOST_GUARD_ASSET_TAG_FILE:-/sys/devices/virtual/dmi/id/board_asset_tag}"
HV_UUID_FILE="${OUTPOST_GUARD_HV_UUID_FILE:-/sys/hypervisor/uuid}"
IMDS_BASE="${OUTPOST_GUARD_IMDS_BASE:-http://169.254.169.254}"
# Command used to enumerate systemd units; override with a stub in tests.
SYSTEMCTL_CMD="${OUTPOST_GUARD_SYSTEMCTL:-systemctl}"

REASONS=()
KIND=""

mark() { [[ -z "$KIND" ]] && KIND="$1"; REASONS+=("$2"); }

# 1) HQ Outpost systemd units — the strongest "this is an HQ Outpost" signal.
if command -v "$SYSTEMCTL_CMD" >/dev/null 2>&1; then
  if "$SYSTEMCTL_CMD" list-unit-files 2>/dev/null | grep -qE '^outpost-[a-z-]+\.(service|timer)'; then
    mark "outpost" "HQ Outpost systemd units present (outpost-*.service)"
  fi
fi

# 2) DMI board/vendor markers — offline EC2 proof, no network needed.
sys_vendor="$(cat "$SYS_VENDOR_FILE" 2>/dev/null || true)"
asset_tag="$(cat "$ASSET_TAG_FILE" 2>/dev/null || true)"
if [[ "$sys_vendor" == "Amazon EC2" ]]; then
  mark "ec2" "DMI sys_vendor = 'Amazon EC2'"
fi
if [[ "$asset_tag" =~ ^i-[0-9a-f]+$ ]]; then
  mark "ec2" "DMI board_asset_tag is an EC2 instance id ($asset_tag)"
fi

# 3) Xen hypervisor UUID (older instance families).
hv_uuid="$(cat "$HV_UUID_FILE" 2>/dev/null || true)"
if [[ "$hv_uuid" == ec2* ]]; then
  mark "ec2" "Xen hypervisor uuid starts with 'ec2'"
fi

# 4) IMDSv2 — live confirmation, last resort (may be blocked/hop-limited).
if [[ -z "$KIND" ]]; then
  token="$(curl -s -m 2 -X PUT "${IMDS_BASE}/latest/api/token" \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    iid="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" \
      "${IMDS_BASE}/latest/meta-data/instance-id" 2>/dev/null || true)"
    if [[ "$iid" =~ ^i-[0-9a-f]+$ ]]; then
      mark "ec2" "IMDSv2 reachable, instance-id $iid"
    fi
  fi
fi

if [[ -n "$KIND" ]]; then
  echo "OK kind=$KIND"
  for r in "${REASONS[@]}"; do echo "  - $r"; done
  exit 0
fi

cat <<'MSG'
NOT_OUTPOST
This machine is not an HQ Outpost or an EC2 instance.

/outpost-host can only run on an HQ Outpost or a plain EC2 instance — a cloud VM
that is already disposable and internet-facing. It installs and configures a web
server (nginx) and exposes apps publicly, which would be unsafe and pointless on
a laptop or any non-cloud host.

What to do instead:
  - To share a generated artifact or result, use /deploy.
  - To share a vault file, use /hq-share.
  - To host an app, run this skill from your HQ Outpost (the cloud VM HQ runs on).
MSG
exit 1
