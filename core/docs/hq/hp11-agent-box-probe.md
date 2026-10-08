# HP-11 hosted agent box probe (lead-carried)

Do not run this procedure from the worker lane. The lead runs it on one hosted box after the normal HQ Core update path makes the candidate available. Run all commands as `ec2-user`; do not run `hq-agent-session.sh` as root.

```bash
sudo -u ec2-user -H bash -lc '
set -euo pipefail
cd /home/ec2-user/hq
mkdir -p /tmp/hp11-agent-probe
bash core/scripts/bench-hook-corpus.sh run --runtime hq-agent \
  --out /tmp/hp11-agent-probe/before.json
hq core update
bash core/scripts/bench-hook-corpus.sh run --runtime hq-agent \
  --out /tmp/hp11-agent-probe/after.json
bash core/scripts/bench-hook-corpus.sh compare \
  /tmp/hp11-agent-probe/before.json /tmp/hp11-agent-probe/after.json
jq -e ".runtime == \"hq-agent\" and ([.items[] | select(.event == \"PostToolUse\") | .supported == false] | all)" \
  /tmp/hp11-agent-probe/after.json
find /home/ec2-user/hq-agent -user root -print \
  > /tmp/hp11-agent-probe/root-owned.txt
test ! -s /tmp/hp11-agent-probe/root-owned.txt
printf "root-owned paths: %s\\n" "$(wc -l < /tmp/hp11-agent-probe/root-owned.txt)"
'
```

Expected output: each run writes a JSON report with `runtime: "hq-agent"`; SessionStart and UserPromptSubmit rows have `status: "completed"`, and PostToolUse rows have `status: "unsupported"` with the entrypoint limitation. The compare command reports no routing or HARD-policy regressions. The `jq` command exits 0 and prints `true`; the ownership audit prints `root-owned paths: 0`. If the session rows time out, the ownership audit finds any path, or compare reports regressions, stop and attach both reports to the lead review. Record the box identity, before/after core commits, completed event counts, and ownership audit result in the envelope.
