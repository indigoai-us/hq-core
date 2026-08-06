#!/usr/bin/env bash
# Regression test for outpost-host/guard.sh.
#
# Verifies the HARD gate both ways using injectable detection inputs:
#   - a fabricated EC2-like env  -> guard PASSES (exit 0)
#   - a fabricated outpost env    -> guard PASSES (exit 0, kind=outpost)
#   - a fabricated non-cloud env  -> guard REFUSES (exit 1, prints NOT_OUTPOST)
#
# Run: bash test-guard.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()   { printf '  ok   - %s\n' "$1"; }
bad()  { printf '  FAIL - %s\n' "$1"; fail=1; }

# Fabricated DMI files
printf 'Amazon EC2'        > "$TMP/sys_vendor.ec2"
printf 'i-0123456789abcdef0'> "$TMP/asset_tag.ec2"
printf 'Innotek GmbH'      > "$TMP/sys_vendor.none"   # e.g. VirtualBox/laptop
printf 'None'              > "$TMP/asset_tag.none"
: > "$TMP/hv.empty"

# systemctl stubs
cat > "$TMP/systemctl.outpost" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "list-unit-files" ]] && { echo "outpost-runner.service enabled disabled"; echo "outpost-sync.service enabled disabled"; }
EOF
cat > "$TMP/systemctl.none" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "list-unit-files" ]] && { echo "sshd.service enabled enabled"; echo "cron.service enabled enabled"; }
EOF
chmod +x "$TMP/systemctl.outpost" "$TMP/systemctl.none"

# Unreachable IMDS base so the network probe fails fast in the negative case.
DEAD_IMDS="http://127.0.0.1:1"

# --- case 1: EC2-like (DMI markers), no outpost units, dead IMDS -> PASS
out="$(OUTPOST_GUARD_SYS_VENDOR_FILE="$TMP/sys_vendor.ec2" \
       OUTPOST_GUARD_ASSET_TAG_FILE="$TMP/asset_tag.ec2" \
       OUTPOST_GUARD_HV_UUID_FILE="$TMP/hv.empty" \
       OUTPOST_GUARD_SYSTEMCTL="$TMP/systemctl.none" \
       OUTPOST_GUARD_IMDS_BASE="$DEAD_IMDS" \
       bash "$GUARD")"; rc=$?
if [[ $rc -eq 0 && "$out" == OK\ kind=ec2* ]]; then ok "EC2 DMI markers -> pass (ec2)"; else bad "EC2 DMI markers should pass; rc=$rc out=[$out]"; fi

# --- case 2: HQ Outpost units present -> PASS (kind=outpost)
out="$(OUTPOST_GUARD_SYS_VENDOR_FILE="$TMP/sys_vendor.none" \
       OUTPOST_GUARD_ASSET_TAG_FILE="$TMP/asset_tag.none" \
       OUTPOST_GUARD_HV_UUID_FILE="$TMP/hv.empty" \
       OUTPOST_GUARD_SYSTEMCTL="$TMP/systemctl.outpost" \
       OUTPOST_GUARD_IMDS_BASE="$DEAD_IMDS" \
       bash "$GUARD")"; rc=$?
if [[ $rc -eq 0 && "$out" == OK\ kind=outpost* ]]; then ok "Outpost units -> pass (outpost)"; else bad "Outpost units should pass; rc=$rc out=[$out]"; fi

# --- case 3: non-cloud (no markers, no units, dead IMDS) -> REFUSE
out="$(OUTPOST_GUARD_SYS_VENDOR_FILE="$TMP/sys_vendor.none" \
       OUTPOST_GUARD_ASSET_TAG_FILE="$TMP/asset_tag.none" \
       OUTPOST_GUARD_HV_UUID_FILE="$TMP/hv.empty" \
       OUTPOST_GUARD_SYSTEMCTL="$TMP/systemctl.none" \
       OUTPOST_GUARD_IMDS_BASE="$DEAD_IMDS" \
       bash "$GUARD")"; rc=$?
if [[ $rc -eq 1 && "$out" == NOT_OUTPOST* ]]; then ok "non-cloud env -> refuse"; else bad "non-cloud env should refuse; rc=$rc out=[$out]"; fi

if [[ $fail -eq 0 ]]; then echo "PASS: all guard cases"; else echo "FAIL: guard test"; fi
exit $fail
