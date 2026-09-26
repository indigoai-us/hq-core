---
id: hq-monitor-for-long-running-waits
title: Use hq monitor for long waits and event delivery
when: sleep || poll || watch || wait-for || monitor || run_in_background || ((loop || while || until) && (sleep || poll || wait))
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 1
created: 2026-09-25
updated: 2026-09-25
source: approved-design
---

## Rule

- Use `hq monitor` for repeated events or waits that may pass 30 minutes. Add `--persistent` to those long watches. For one notification, use a single-shot background command that exits when its condition is true.
- In Claude Code, use `hq monitor start ... --persistent` instead of re-arming the 30-minute Monitor tool.
- Keep watch output actionable: use `grep --line-buffered`, add `|| true` to poll loops, wait at least 30 seconds between remote API calls, match every terminal state, and print only lines that need action. Silence is not success.
- Prompt caching only works within an hour. A turn that starts more than an hour after the previous one re-reads the whole conversation at full price. During a long watch, check in at least every 55 minutes; a short check-in reads the conversation from cache at the lower price and resets the hour. `hq monitor` sends a check-in every 55 minutes by default; use `--checkin` to change the interval or `--checkin off` to disable it. Keep check-in turns short: confirm the watch is armed, act only if something changed, then stop.
- Claude sessions and lanes are woken by events. Interactive Codex sessions receive events at their next tool call or user message; interactive Grok sessions receive them at their next tool call.
