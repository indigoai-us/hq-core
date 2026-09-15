---
id: claude-bg-shell-pressure-reap
title: Idle background Bash tasks are reaped by Claude Code's PSI watcher, not by OOM — poll with Monitor or a detached process
when: run_in_background || ((oom || (low && memory)) && (background || poller || killed || stopped))
on: [PreToolUse, UserPromptSubmit]
enforcement: hard
public: true
version: 1
created: 2026-09-15
updated: 2026-09-15
source: incident-response
learned_from: bg-task-memory-kill-investigation-2026-09-14
---

## Rule

Scope: Claude Code sessions only. The `run_in_background` fact is emitted only for Claude Code's Bash tool; in Codex or Grok, ignore this rule. The PSI mechanism below is the Linux path; on other OSes the same reap listens to the OS memory-pressure signal instead.

1. **Know the killer.** A harness-tracked background Bash task (`run_in_background: true`) that ends as `killed` with the summary *"was stopped because the system is running low on memory"* was killed by the Claude Code CLI itself. The kernel OOM killer, cgroup `memory.max`/`memory.high`, systemd-oomd, and earlyoom are not involved. The CLI's bundled Bun runtime arms a Linux PSI trigger `some 150000 2000000` on `/proc/pressure/memory`: 150 ms of memory stall anywhere on the host within a 2 s window. When it fires, the CLI kills every running background shell in any interactive session where:
   - the user has not interacted for 30 minutes,
   - the main loop is not busy, and
   - no subagent, teammate, or workflow task is running.
   Monitors, print-mode/SDK sessions, and processes the harness does not track (`setsid nohup … & disown`) are exempt.

2. **Do not diagnose it with `free`.** Free and available RAM are never compared. A host with 30+ GB "available" still trips the trigger when page-cache refaults or CPU saturation stretch reclaim. Use `/proc/pressure/memory` (avg10/avg60), `/proc/pressure/cpu`, and `workingset_refault_file` in `/proc/vmstat`. Before blaming the kernel, confirm with `journalctl -k | grep -i oom` and the cgroup's `memory.events`.

3. **HARD: do not re-arm the same background sleep loop after a memory-pressure kill.** It will be reaped again at the next stall burst. Pick a poller that survives:
   - **Preferred:** the Monitor tool, whose tasks never get the pressure-reap listener.
   - A **bounded** detached process that writes a status file, plus a wake path that reads it (Monitor, `ScheduleWakeup`, or a cron job). It must have a hard deadline, a recorded PID, and a stop path, so it cannot outlive its purpose and pile up orphans: `setsid nohup timeout 2h <script> >"$dir/poll.log" 2>&1 & echo $! >"$dir/poll.pid"; disown`. Stop it with `kill "$(cat "$dir/poll.pid")"`, never with a pattern kill.
   - For long unattended polls that must be harness-tracked, set `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` in the user-scope `env` block of `~/.claude/settings.json` or in the session launcher. It applies only to sessions started afterwards. The trade-off: on real exhaustion the kernel OOM killer becomes the backstop. That decision belongs to the operator; do not set it silently.

4. **Never promise a result that depends on a reapable background task.** If the only wake path is a `run_in_background` sleep loop in a session the user will leave idle, the result will not arrive. Use one of the survivable pollers above, or tell the user plainly that no wake path exists.

5. **Reduce the stall, not the symptom.** On a shared host, the durable fix is lowering memory stall. Reclaim abandoned long-lived sessions only after confirming with their owner, and stagger heavy jobs (coverage test runs, embedding, many agent lanes) rather than running them all at once. Never pattern-kill processes to free memory.

## Verification

The constants are compiled into the CLI and can change between releases. Before relying on them, re-check the running binary:

```bash
E=/proc/<claude-pid>/exe   # works even when the install was upgraded and the file deleted
grep -abo 'some 150000 2000000' "$E"
grep -abo 'CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP' "$E"
ls -l /proc/<claude-pid>/fd | grep pressure   # armed watcher holds /proc/pressure/memory
```

These were verified in Claude Code 2.1.215, 2.1.263, and 2.1.271: the 30-minute idle constant is `1800000`, and the reason code `memory_pressure` maps to the kill message.

## Rationale

On 2026-09-14 an operator's idle `until … sleep 120` pollers were killed dozens of times over several hours, each 30–180 s after being re-armed, while `free` showed 34 GB available. There were no kernel OOM events, no memcg limits, and oomd was disabled. The cause was the CLI's PSI reap. Peak rolling-2s memory stall ran just under the trigger, and it crossed during reclaim bursts on a 16-core host at load average 42–52 with about 15.6k file refaults/sec. Re-arming the loop could never work, and blaming RAM sent the diagnosis the wrong way. Detached processes survived the whole time.
