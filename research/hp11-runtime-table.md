# HP-11 runtime before/after table

These captures replay the 16 HP-5 corpus inputs (11 prompts and 5 commands), plus the SessionStart row, on one Linux EC2 box. They compare `2d27e2903cb370c9ce0f85e5444c4af8a82b6a42` with `1de583f28e6a5bf8518c120a8e861dc6f3eadbf3`. They are single-box cross-commit results, not the owner-machine benchmark number. Claude and Codex captures are recorded in `research/hp11-runtime-{baseline,candidate}-{claude,codex}.json`. Grok is explicitly unsupported by this benchmark; the prior zero-output captures were invalidated. The hq-agent direct-fixture timeout captures are marked invalid and are not latency baselines.

| Runtime | Baseline total seconds / bytes / policy lines | Candidate total seconds / bytes / policy lines | Run status |
|---|---:|---:|---|
| Claude | 70.47 / 58,870 / 55 | 148.25 / 58,865 / 55 | 17/17 events completed on both commits |
| Codex | 129.42 / 60,153 / 0 | 161.50 / 60,143 / 0 | 17/17 events completed on both commits |
| Grok | Unsupported | Unsupported | Benchmark rejects `--runtime grok`: the adapter produced no benchmark-visible output in the prior capture |
| hq-agent | No valid capture | No valid capture | Prior direct-fixture runs timed out; the required production dispatcher path was unavailable on this host. Five PostToolUse commands are unsupported. |

The candidate was slower for Claude and Codex in this run; no latency improvement is claimed. The host load limits the interpretation. The Claude capture emitted 55 policy lines; the HP-5 notes claim zero policy lines for the same bare worktree setup, so this discrepancy is retained for lead review. The capture JSON contains 17 rows because it includes SessionStart in addition to the 16 corpus inputs.

The hq-agent diagnosis used `bash -x` on a direct fixture run with `HQ_AGENT_SESSION_SKIP_PROVIDER=1`; it is diagnostic only and did not use the required production dispatcher. One 40-second trace completed in 32.089 seconds, with 15.635 seconds in hooks and 14.873 seconds in the skill catalog; company resolution succeeded and the provider was skipped. This explains why a 30-second direct-fixture cap can expire after bootstrap work, but does not establish production-path behavior. `/usr/local/bin/hq-agent-dispatch` and `/home/ec2-user/hq-agent` are absent on this host, so the required production capture could not be performed. No change was made to `hq-agent-session.sh`.

## HP-6 through HP-9 and HP-13 verification matrix

“Fail / unverified” means the runtime-specific observable was not established by this run. The corpus creates a fresh synthetic session for each item, so it cannot establish same-session cache behavior. Existing fix-story tests exercise Claude hook scripts directly; they do not provide per-runtime proof by themselves.

| Story observable | Claude | Codex | Grok | hq-agent |
|---|---|---|---|---|
| HP-6: one SessionStart local-context block and one Bash PostToolUse policy reminder | Fail / unverified — `bash core/scripts/bench-hook-corpus.sh run --runtime claude`; bare worktree has no duplicate local settings registration | Fail / unverified — same command with `--runtime codex`; output is present but duplicate-block count is not independently asserted | Unsupported — benchmark rejects Grok because adapter output is not observable | Unverified — prior direct-fixture session calls timed out; PostToolUse is unsupported |
| HP-7: unchanged policy stamp skips migration; changed policy triggers it | Fail / unverified — corpus SessionStart row does not isolate the stamp check | Fail / unverified — corpus SessionStart row does not isolate the stamp check | Unsupported — no benchmark capture | Unverified — production-path capture unavailable; migration observable not isolated |
| HP-8: second prompt in the same session skips successful check, retries after warning/failure | Fail / unverified — fresh session per corpus event; run `bash core/scripts/tests/ensure-hq-cli-hook.test.sh` for the Claude guard | Fail / unverified — adapter corpus changes session id per item; no same-session pair | Unsupported — no benchmark capture | Unverified — production-path capture unavailable; corpus uses a new conversation key for each item |
| HP-9: conductor core and Slack/X routing hints | Fail / unverified — p3/p4 hints were present on both commits, so the baseline was not missing them; this run does not assert the conductor-core contract | Fail / unverified — p3/p4 hints were present on both commits, so this run does not establish an HP-9 improvement | Unsupported — no benchmark capture | Unverified — production-path capture unavailable; command events unsupported |
| HP-13: five startwork follow-up asks route correctly | Fail / unverified — the HP-5 corpus has no five follow-up asks | Fail / unverified — same missing corpus inputs | Unsupported — no benchmark capture | Unverified — corpus inputs are absent; production-path capture unavailable |

The matrix is intentionally conservative: it records the runnable capture command and does not promote a runtime to pass based only on successful process exit.
