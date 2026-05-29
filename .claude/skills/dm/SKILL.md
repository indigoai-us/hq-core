---
name: dm
description: Send a direct message to a teammate — they receive it as an HQ Sync menubar notification. Optionally attach an agent prompt (one-click "Copy prompt" for their agent), a details pane, or schedule it for later. Use when the user wants to DM/message/ping/notify a teammate, hand context to someone's agent, or send themselves a note/reminder. Wraps `hq dm`.
allowed-tools: Bash(hq:*)
---

# /dm — Send an HQ direct message

Send a person-to-person notification through HQ. The recipient gets it as a
macOS notification in their HQ Sync menubar; if you attach agent context they
get a one-click **Copy prompt** action, and if you attach details they get an
**Open details** window. You can DM yourself (note-to-self / reminders).

This is the **send** side — receiving is handled by the HQ Sync menubar app.
You can only DM someone you share an active company with.

## Usage

```
hq dm <recipient> <message> [options]
```

- `<recipient>` — a teammate's **email** (e.g. `stefan@example.com`) or **personUid** (`prs_…`). Your own email = a note-to-self.
- `<message>` — the notification body (the headline the recipient sees). Required.

Options:

| Option | Effect |
|---|---|
| `--prompt <text>` / `--prompt-file <path>` | Agent-context prompt the recipient can one-click copy into their own agent session. Only when present does the banner show **Copy prompt**. |
| `--details <text>` / `--details-file <path>` | Longer text shown in the recipient's **Open details** window. |
| `--at <iso>` | Schedule delivery at an ISO8601 time (store-and-forward — arrives even if you're offline at that time). |
| `--in <duration>` | Schedule after a relative delay: `30s`, `10m`, `2h`, `1d`. |

## Steps

1. **Resolve intent.** From the user's request, pull the recipient (email or
   personUid), the message body, and any agent prompt / details / schedule.
   If the user said "send my agent context" or "so their agent can act," put
   that in `--prompt`. If they want a longer writeup, use `--details`.

2. **Send.** Run a single `hq dm` invocation. Examples:

   ```bash
   # Plain DM
   hq dm stefan@example.com "Heads up — prod deploy going out at 3pm"

   # With agent context (recipient gets a Copy-prompt action)
   hq dm stefan@example.com "Can your agent take this over?" \
     --prompt "You are Stefan's agent. Pick up the hq-pro deploy: merge #178, run pnpm deploy:prod, verify routes."

   # With a details pane
   hq dm stefan@example.com "Review notes attached" --details-file /tmp/notes.md

   # Scheduled
   hq dm me@example.com "Stand-up in 10" --in 10m
   hq dm corey@example.com "EOD wrap-up reminder" --at 2026-05-29T17:00:00Z
   ```

   For multi-line or special-character prompts/details, prefer `--prompt-file` /
   `--details-file` (write the text to a mktemp file first) over inline quoting.

3. **Report.** Print the command's result — `DM sent to <recipient> (eventId …)`
   or `Scheduled DM … for <time>`. On `Recipient not found or not reachable`,
   tell the user they can only DM someone they share an active company with
   (and to double-check the email / personUid).

## Notes

- Requires a signed-in HQ session (`/hq-login`). The CLI resolves the caller
  identity from the Cognito token — the DM is always **from** the signed-in user.
- Sending is CLI/session-only by design; the menubar app is **receive-only**.
- Scheduled DMs are promoted to live notifications within ~60s of their time
  on the recipient's next inbox poll.
- Never paste secrets into a DM body/prompt/details — DMs are stored server-side.
