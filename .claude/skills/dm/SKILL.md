---
name: dm
description: Send a direct message to a teammate — they receive it as an HQ Sync menubar notification. Recipients can be an email, a personUid, or just a NAME (auto-resolved to the right teammate across all your companies), and a comma-separated list opens a group DM. Optionally attach an agent prompt (one-click "Copy prompt" for their agent), a details pane, or schedule it for later. Use when the user wants to DM/message/ping/notify a teammate, hand context to someone's agent, or send themselves a note/reminder. Wraps `hq dm`.
allowed-tools: Bash(hq:*), Read, Glob, Grep
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

- `<recipient>` — one of:
  - a teammate's **email** (e.g. `[EMAIL]`),
  - a **personUid** (`prs_…`),
  - a bare **name** (e.g. `stefan` or `Stefan Walsh`) — resolved to the exact
    email before sending (see **Resolve recipients** below), or
  - a **comma-separated list** of any of the above — this opens a **group DM**
    (every token is resolved independently). Your own email = a note-to-self.
- `<message>` — the notification body (the headline the recipient sees). Required.

Options:

| Option | Effect |
|---|---|
| `--prompt <text>` / `--prompt-file <path>` | Agent-context prompt the recipient can one-click copy into their own agent session. Only when present does the banner show **Copy prompt**. |
| `--details <text>` / `--details-file <path>` | Longer text shown in the recipient's **Open details** window. |
| `--at <iso>` | Schedule delivery at an ISO8601 time (store-and-forward — arrives even if you're offline at that time). |
| `--in <duration>` | Schedule after a relative delay: `30s`, `10m`, `2h`, `1d`. |

## Steps

1. **Resolve intent.** From the user's request, pull the recipient(s), the
   message body, and any agent prompt / details / schedule. If the user said
   "send my agent context" or "so their agent can act," put that in `--prompt`.
   If they want a longer writeup, use `--details`.

2. **Resolve recipients to emails.** `hq dm` only accepts an **email** or a
   **personUid** — it does NOT look up names. So before sending, turn every
   recipient token into one. First split the recipient on commas (a comma means
   a group DM); then resolve **each token independently**:

   - **Fast path — already an email or personUid → use it verbatim.** If the
     token contains `@` (an email) or starts with `prs_` (a personUid), pass it
     through unchanged. Do NOT look it up. This keeps every existing
     email/personUid invocation working exactly as before.

   - **Name → resolve against your local member roster.** Otherwise treat the
     token as a name. Your synced companies each keep a member roster on disk at
     `companies/*/people/*/meta.yaml` — one file per person, carrying `name`,
     `slug`, `email`, and `type` (`internal`/`external`). This is the cheapest
     source: it's local, offline, and already covers **all** the companies you
     belong to (one `companies/<co>/` directory per company). Glob those files
     and match the token **case-insensitively** against each person's full
     `name`, any single word of their `name` (so `jacob` matches `Jacob Posel`),
     or their `slug`. Collect every match as `{name, email, company, role}`.

     - **Exactly one match → resolve to that person's `email`** and continue.
     - **More than one match → STOP and disambiguate.** Never guess. Present the
       candidates (name · company · role · email) as a single decision and let
       the user pick — use the runtime structured picker (`AskUserQuestion` /
       Codex `request_user_input`), one question, plain-text numbered fallback if
       no picker is available (the decision-queue pattern). Use the chosen email.
     - **Zero matches → say so plainly and stop.** Tell the user no teammate
       named "<token>" was found across their companies, and that they can pass
       the exact email or personUid instead (or that the person may not be in a
       company they share / not yet synced to this machine). Do not send a
       guessed recipient.

   After this step you hold a fully-resolved list of emails/personUids — one for
   a 1:1 DM, two or more for a group DM.

3. **Send.** Run a single `hq dm` invocation with the resolved recipient(s).
   For a group DM, join the resolved tokens back into one comma-separated
   recipient string (a group needs at least 2 other people). Examples:

   ```bash
   # Plain DM (email — fast path, unchanged)
   hq dm stefan@example.com "Heads up — prod deploy going out at 3pm"

   # By name — resolved to the teammate's email first, then sent
   hq dm stefan "Heads up — prod deploy going out at 3pm"

   # Group DM — comma-separated recipients (each token resolved independently)
   hq dm "[EMAIL],corey,prs_abc123" "Sync on the launch at 4?"

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

4. **Report.** Print the command's result — `DM sent to <recipient> (eventId …)`
   or `Scheduled DM … for <time>`. When you resolved a name, mention who it
   resolved to (e.g. "sent to Stefan Walsh <[EMAIL]>") so the user can
   confirm it reached the right person. On `Recipient not found or not reachable`,
   tell the user they can only DM someone they share an active company with
   (and to double-check the email / personUid).

## Notes

- Name resolution is **read-only and local** — it only reads
  `companies/*/people/*/meta.yaml` and never mutates anything. If a teammate
  isn't in that roster yet (not synced, or never recorded), pass their exact
  email/personUid; the name lookup is a convenience layer over the same `hq dm`.
- Requires a signed-in HQ session (`/hq-login`). The CLI resolves the caller
  identity from the Cognito token — the DM is always **from** the signed-in user.
- Sending is CLI/session-only by design; the menubar app is **receive-only**.
- Scheduled DMs are promoted to live notifications within ~60s of their time
  on the recipient's next inbox poll.
- Never paste secrets into a DM body/prompt/details — DMs are stored server-side.
