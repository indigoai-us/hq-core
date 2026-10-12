---
name: capacity
description: "Show usage, limits and reset times for every signed-in AI account (Claude, Codex, Grok) as a card in chat, or a table in a terminal."
allowed-tools: "Bash(hq capacity:*), mcp__visualize__read_me, mcp__visualize__show_widget"
---

# /capacity

Use this when the user says `/capacity` or asks to see AI account usage.

Show usage, limits, and reset times for every signed-in AI account (Claude, Codex, Grok). The card comes from `hq capacity`. This skill never reads credentials, Keychain items, or provider APIs.

## Step 1: Ask hq for the card

```bash
hq capacity --widget
```

Keep stdout as the fragment. Note the exit code. Do not pass `--json` with `--widget` (that is a usage error).

Stop with one step, `hq capacity enable`, when either of these is true:

- `hq` is not on PATH.
- The command exits 0 and the fragment says capacity is not enabled or collection is off.

Do not render a usage card and do not write the attention sentences in that case. If the widget tool from Step 2 is available and the fragment is that short not-enabled message, pass the fragment through unchanged and then stop. Otherwise print `hq capacity enable` and stop.

When `--widget` is an unknown option, or `capacity` is an unknown command, this hq-cli is too old. Say once that `npm i -g @indigoai-us/hq-cli@latest` adds the card. If `hq capacity` itself runs, show its table (Step 3) and stop. If `capacity` is unknown, stop after the install line. Do not invent a table.

Exit 0 with an HTML fragment means the ledger rendered. Go to Step 2 when `mcp__visualize__show_widget` is available. Otherwise go to Step 3.

## Step 2: Render the card

1. Call `mcp__visualize__read_me` once, silently, before the widget. Do not print its result.
2. Call `mcp__visualize__show_widget` with `widget_code` set to the fragment exactly as `hq capacity --widget` printed it, and `title` set to `ai_account_capacity`.
3. Do not edit the fragment. Do not recompute or retype any number in it.
4. After the card, write at most 3 short plain sentences. Name only what needs attention: a used-up limit, the account with the most headroom, and the next reset that matters. Use the card's own labels. Do not restate a percent, a count, or a clock time. If nothing needs attention, write nothing after the card.

The card's Refresh button sends `/capacity`, which runs this skill again.

## Step 3: Terminal table

Use this when `mcp__visualize__show_widget` is not available (terminal Claude Code, Codex, Cursor), or when Step 1 found that `--widget` is unknown and `hq capacity` still runs:

```bash
hq capacity
```

Show that table as printed. Do not paste the HTML fragment in its place. Do not recompute its numbers.

## Adding an account

To add another signed-in account, point the user to `hq capacity login`. Do not log in from this skill.

## Rules

- The only command is `hq capacity`. No credential files, no Keychain, no provider HTTP APIs.
- `hq` missing, or capacity not enabled: `hq capacity enable`, then stop.
- Refresh re-runs `/capacity`.
- Do not change the fragment.
