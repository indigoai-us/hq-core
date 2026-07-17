---
name: dm
description: Send HQ Sync direct messages, prompts, details, or scheduled notes to teammates.
allowed-tools: Bash(hq:*), Read, Glob, Grep
---

# /dm — Send an HQ direct message

Send a person-to-person notification through HQ. The recipient gets it as a
macOS notification in their HQ Desktop App; if you attach agent context they
get a one-click **Copy prompt** action, and if you attach details they get an
**Open details** window. You can DM yourself (note-to-self / reminders).

This is the **send** side — receiving is handled by the HQ Desktop App.
You can only DM someone you share an active company with.

## Usage

```
hq dm <recipient> <message> [options]
```

- `<recipient>` — one of:
  - a teammate's **email** (e.g. `stefan@example.com`),
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

2. **Resolve & confirm recipient emails — never send blind.** `hq dm` only
   accepts an **email** or a **personUid** — it does NOT look up names. So before
   sending, turn every recipient token into a **confirmed** email. First split
   the recipient on commas (a comma means a group DM); then resolve **each token
   independently**:

   - **Fast path — already an email or personUid → use it verbatim.** If the
     token contains `@` (an email) or starts with `prs_` (a personUid), pass it
     through unchanged. Do NOT look it up. This keeps every existing
     email/personUid invocation working exactly as before.

   - **Name → resolve with `hq people resolve` (confirm before sending).**
     Otherwise treat the token as a name and resolve it through the built-in
     people lookup (hq-cli ≥ 5.47.16) instead of sending to an unconfirmed
     recipient:

     ```bash
     hq people resolve "<token>" --json            # active company
     hq people resolve "<token>" --json --company <slug>   # when scoping explicitly
     ```

     This is **single-company and tenancy-safe**: it reads the active company's
     member roster (`companies/<co>/people/*/meta.yaml`) and never looks across
     company boundaries — HQ tenancy rules forbid cross-company member lookups.
     The active company is the sole non-archived company in
     `companies/manifest.yaml`; pass `--company <slug>` to scope explicitly. Read
     the JSON `status` field:

     - **`status: "found"` → use the returned `email`.** Resolution is confirmed;
       continue. (`hq people resolve "<token>"` without `--json` prints the bare
       email if you just want the address.)
     - **`status: "ambiguous"` → STOP and disambiguate.** Never guess. The result
       carries a `matches[]` array (the same set `hq people search "<token>"`
       returns); present those candidates (name · email · role) as a single
       decision and let the user pick — use the runtime structured picker
       (`AskUserQuestion` / Codex `request_user_input`), one question, plain-text
       numbered fallback if no picker is available (the decision-queue pattern).
       Use the chosen person's email.
     - **`status: "no_email"` → STOP.** The person was found but has no email on
       record. Tell the user plainly and ask for the exact email/personUid; do
       not send.
     - **`status: "not_found"` → STOP.** Say plainly that no teammate named
       "<token>" was found in the company, and that they can pass the exact email
       or personUid instead (or the person may not be in this company / not yet
       synced to this machine). Do not send a guessed recipient.
     - **"Multiple companies" error (no `--company` given) → ask which company,**
       then re-run `hq people resolve "<token>" --company <slug>`. Stay
       single-company; never fan the lookup across every company.

   After this step you hold a fully-resolved list of **confirmed**
   emails/personUids — one for a 1:1 DM, two or more for a group DM.

3. **Humanize, then send.** Before sending, run the channel-aware humanize pass
   on the message body (and any `--prompt` / `--details` text) per
   `core/knowledge/public/hq-core/humanize-before-send.md` — channel `dm`,
   default intensity `light`: strip the obvious AI tells but keep the message
   terse and conversational. Never rewrite recipients, scheduling flags, or
   anything that is not prose. Then run a single `hq dm` invocation with the
   resolved recipient(s). For a group DM, join the resolved tokens back into one
   comma-separated recipient string (a group needs at least 2 other people).
   Examples:

   ```bash
   # Plain DM (email — fast path, unchanged)
   hq dm stefan@example.com "Heads up — prod deploy going out at 3pm"

   # By name — confirmed to the teammate's email via `hq people resolve` first, then sent
   hq dm stefan "Heads up — prod deploy going out at 3pm"

   # Group DM — comma-separated recipients (each token resolved independently)
   hq dm "stefan@example.com,corey,prs_abc123" "Sync on the launch at 4?"

   # With agent context (recipient gets a Copy-prompt action)
   hq dm stefan@example.com "Can your agent take this over?" \
     --prompt "You are Stefan's agent. Pick up the acme-web deploy: merge #178, run the deploy script, verify routes."

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
   resolved to (e.g. "sent to Stefan Walsh <stefan@example.com>") so the user can
   confirm it reached the right person. On `Recipient not found or not reachable`,
   tell the user they can only DM someone they share an active company with
   (and to double-check the email / personUid).

## Notes

- Name resolution is **read-only, local, and single-company** — `hq people
  resolve` only reads the active company's `companies/<co>/people/*/meta.yaml`
  roster, never mutates anything, and never looks across companies (tenancy-safe
  by construction). If a teammate isn't in that roster yet (not synced, or never
  recorded), pass their exact email/personUid; the name lookup is a confirm layer
  over the same `hq dm`. Use `hq people search "<token>"` to browse candidates,
  and `--company <slug>` to scope when you belong to more than one company.
- Requires a signed-in HQ session (`/hq-login`). The CLI resolves the caller
  identity from the Cognito token — the DM is always **from** the signed-in user.
- Sending is CLI/session-only by design; the HQ Desktop App is **receive-only**.
- Scheduled DMs are promoted to live notifications within ~60s of their time
  on the recipient's next inbox poll.
- Never paste secrets into a DM body/prompt/details — DMs are stored server-side.

## See also

- `/hq-share` — share a vault path in your message
- `/signals` — see action items and commitments
