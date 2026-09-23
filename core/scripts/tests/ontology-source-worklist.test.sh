#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; w="$here/../ontology-source-worklist.sh"
fail=0; pass=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 — want '$3' got '$2'"; fail=$((fail+1)); fi; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/core/scripts" "$t/companies/acme/sources/meetings"
cp "$here"/../{knowledge-prefs.sh,ontology-candidate.sh,source-yaml-validate.sh,ontology-source-worklist.sh} "$t/core/scripts/"
M="$t/companies/acme/sources/meetings"
printf 'channel: meetings\nkind: meeting\narrives: cloud\naudience_rule: attendees\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' > "$M/source.yaml"
printf -- '---\nid: m1\nattendees: [a@x.com, B@x.com]\n---\nbody\n' > "$M/m1.md"
printf -- '---\nid: m2\n---\nbody\n' > "$M/m2.md"
printf -- '---\nid: m3\n---\nbody\n' > "$M/m3.md"
cat > "$t/hq" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"acl sources/meetings/m2.md"*) echo '{"direct":[{"granteeType":"person","granteeId":"prs_01ABC","permission":"read"},{"granteeType":"email","granteeId":"c@x.com","permission":"read"}]}' ;;
  *) echo '{"direct":[]}' ;;
esac
STUB
chmod +x "$t/hq"; export HQ_ROOT="$t" HQ_BIN="$t/hq"
out="$(bash "$w" --company acme --channel meetings)"
check "three items listed" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 3
check "frontmatter attendees used" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m1.md")) | .audience | join(",")')" "a@x.com,B@x.com"
check "same key as writer" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m1.md")) | .audience_key')" "$(bash "$t/core/scripts/ontology-candidate.sh" key 'a@x.com,b@x.com')"
check "acl attendees used, uid case kept" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m2.md")) | .audience | sort | join(",")')" "c@x.com,prs_01ABC"
check "no audience is a skip, not company" "$(printf '%s\n' "$out" | jq -r 'select(.file|endswith("m3.md")) | .skip')" "no-audience"
bash "$w" --company acme --channel meetings --mark-done "$M/m1.md"
check "mark-done removes from worklist" "$(bash "$w" --company acme --channel meetings | grep -c m1.md)" 0
sed -i.bak 's/run: local/run: cloud/' "$M/source.yaml"
bash "$w" --company acme --channel meetings >/dev/null 2>&1; check "run: cloud refuses locally" "$?" 4
bash "$w" --company acme --channel meetings --force >/dev/null 2>&1; check "--force overrides" "$?" 0
sed -i.bak '/audience_rule/d' "$M/source.yaml"
bash "$w" --company acme --channel meetings --force >/dev/null 2>&1; check "invalid source.yaml exits 2" "$?" 2
echo "ontology-source-worklist: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
