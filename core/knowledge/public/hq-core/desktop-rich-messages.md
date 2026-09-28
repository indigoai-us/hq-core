---
type: reference
domain: [engineering, product]
status: canonical
tags: [desktop-app, hq-desktop, messaging, hq-block, rich-content, agents, setup]
relates_to: [knowledge/public/hq-core/hq-desktop-app.md, workers/public/setup/worker.yaml]
verified_against:
  - repo: hq-desktop-app
    ref: origin/main@c621a6a1
    app_version: 0.10.347
    date: 2026-09-27
---

# Desktop Rich Messages (`hq-block`)

An agent or bot can attach structured content to a message in HQ DMs and
channels. The agent sends data; HQ Desktop renders it with its own
components. Agents never send markup or script. This page is the contract as
implemented by the desktop parser.

## Rules

- Every rich message still carries a plain-text `body`. Old clients,
  notifications and other surfaces show only the body.
- Two carriers, parsed into the same model:
  1. A `richContent` field on the message (server passthrough). Preferred when
     present and valid.
  2. A fenced block with the language `hq-block` inside `body`. This works
     with no server support, so it is what a bot should emit.
- One envelope per message. The client lifts it out of the body and shows the
  remaining prose as the bubble text.
- The envelope is `{"v": 1, "blocks": [ … ]}`. A `v` other than `1` (or the
  string `"1"`) is rejected. Unknown block kinds are dropped. If no block
  parses, the body renders as ordinary Markdown.

## How to emit a block

Write the normal reply, then append the fence as the last thing in the
message:

    Weekly read: signups up, one flow needs attention.

    ```hq-block
    {"v":1,"blocks":[{"kind":"stat","items":[{"label":"Signups","value":"1,204","delta":"+8%","trend":"up"}]}]}
    ```

Emitter guidance:

- Three backticks, `hq-block` on the same line, the JSON on its own line,
  three backticks to close, not indented.
- Never send a message that is only a fence. Some on-box reply cleaners strip a
  fence that wraps the whole message, which leaves literal JSON.
- The desktop also recognises an envelope that arrives unfenced, fenced with
  another label, or pretty-printed, and cuts it from the text. Do not rely on
  this; it exists so a formatting slip does not show raw JSON to a person.
  JSON that is not a valid envelope is left in the text.
- A well-formed envelope whose blocks are all of kinds this app version does
  not know is still cut from the text and renders nothing.

## Block kinds

Field names below are the ones the parser reads
(`packages/ui/src/chat/messaging/richMessageContent.ts`).

| `kind` | Fields | Notes |
|---|---|---|
| `stat` | `items`: `[{label, value, delta?, trend?}]` | `trend`: `up`, `down`, `flat`. Up to 12 items. Items with neither label nor value are dropped. |
| `table` | `columns`: string[], `rows`: string[][], `align?`: (`left`\|`center`\|`right`)[], `caption?` | Up to 12 columns, 100 rows, 500 characters per cell. Missing align entries default to `left`. |
| `chart` | `chartType`: `line`\|`bar`, `series`: `[{name, data: number[]}]`, `categories?`: string[], `caption?` | Up to 8 series, 200 points each. Any `chartType` other than `bar` is drawn as `line`. Non-numeric points are dropped. |
| `markdown` | `text` (alias `body`) | Rendered through the same safe Markdown renderer as message bodies. Up to 4000 characters. |
| `badge` | `label`, `tone?` | `tone`: `neutral`, `success`, `warning`, `danger`, `accent`; unknown becomes `neutral`. |
| `keyValue` | `items`: `[{key, value}]` | Up to 50 rows. |
| `progress` | `value` (number), `label?`, `tone?` | `value` is clamped to 0–100. `tone` uses the badge values. |
| `callout` | `body` (alias `text`), `tone?`, `title?` | `tone`: `info`, `success`, `warning`, `danger`; unknown becomes `info`. `body` goes through the safe Markdown renderer. |
| `decision` | `question`, `options`: `[{id?, label, description?, recommended?}]` or plain strings, `allowOther?`, `questionId?` | Up to 10 options, rendered as buttons. Only the first `recommended: true` is honoured. `allowOther` defaults to true and adds a free-text "Other". Clicking an option sends its `label` as the person's reply; `questionId` is kept for correlation and not shown. |
| `suggestions` | `items`: string[] (or `[{label}]`) | Suggested replies. See below. |
| `setupDone` | `slackAgent?`: boolean | Setup finished. See below. |

`genui` is reserved and always dropped. Arbitrary agent-authored HTML or
components are not supported.

Limits that apply to every envelope: at most 20 blocks; labels are capped at
200 characters; control characters are stripped from every string.

## Host-placed blocks: `suggestions` and `setupDone`

These two kinds draw nothing inside the message bubble. The app places them
itself, and they add nothing to the plain-text fallback. A message whose body
is only one of these blocks shows no empty bubble.

In the current app (0.10.347) the host acts on them only in the **Setup bot's
DM** (the local bot named `setup`). Other bots can send them, but they will
not render.

### `suggestions`

```hq-block
{"v":1,"blocks":[{"kind":"suggestions","items":["For a company","Just for me"]}]}
```

- Two to four short replies. The parser keeps at most 4, drops blanks and
  case-insensitive duplicates, collapses whitespace, and caps each at 80
  characters.
- They appear as buttons under the bot's newest message. A click sends that
  text as the person's reply.
- The app always adds a final "Something else" button that focuses the message
  box, so the bot should not add its own "Other" item.
- Buttons disappear once the person replies, and a newer bot message without
  suggestions clears them.

### `setupDone`

```hq-block
{"v":1,"blocks":[{"kind":"setupDone"}]}
```

```hq-block
{"v":1,"blocks":[{"kind":"setupDone","slackAgent":true}]}
```

- Marks setup as finished. The app shows a finish card under the last message
  (open HQ in a coding tool, the HQ console, and optionally a Slack bot).
- `slackAgent: true` adds the offer to put the bot in Slack. Clicking it sends
  the bot a message asking it to walk the person through that. The setup
  worker sets it only for someone who started their own company.
- Only the first `setupDone` from the bot counts. The card goes away when the
  person writes again, and dismissing it is remembered per bot.
- The setup worker (`core/workers/public/setup/worker.yaml`) sends it once, in
  the closing message, and never with `suggestions`.

## Separate contracts

- **`systemEvent` v1** is server-authored, not agent-authored. Known types:
  `run_started`, `run_progress`, `run_complete`, `pr_opened`, `deploy`,
  `file_added`, `work_session`, `work_session_blocked`,
  `work_session_task_status`, `work_session_finished`, `member_added`,
  `lifecycle_card`. Unknown types are dropped. `lifecycle_card` kinds:
  `create_company`, `activate_cloud`, `upgrade_plan`, `create_agent`,
  `status`, `companies_summary`, `tab_row`. Clients cannot create these
  cards through message send.
- **`[hq-setup] step=` / `card=` marker lines** belong to the scripted
  `/setup --guided` run. The parser is still in the app source, but the shipped
  host no longer starts that run, and the Setup bot's DM does not strip these
  lines. Bots should not print them.

## Security model

- Values are bound as escaped text or numeric SVG attributes. There is no raw
  HTML path for `stat`, `table`, `chart`, `badge`, `keyValue`, `progress` or
  `decision` data.
- `markdown` text and `callout` bodies use the existing CSP-safe renderer: no
  raw HTML, `http(s)` and `mailto` links only, images shown as alt text.
- Tones are closed enums mapped to the app's own CSS classes; an agent cannot
  pass a colour or style.
- Charts are inline SVG drawn by the app; there is no external chart library.

## Sources

hq-desktop-app `origin/main@c621a6a1`:

- `docs/rich-agent-messages.md`
- `packages/ui/src/chat/messaging/richMessageContent.ts` (parser, caps, `HOST_PLACED_BLOCK_KINDS`)
- `packages/ui/src/chat/messaging/RichMessageContent.svelte`, `ChannelConversation.svelte` (`handleDecision`, "Something else")
- `packages/ui/src/chat/messaging/channelMessageModels.ts` (`systemEvent`)
- `packages/ui/src/chat/setup-bot.ts` (`setupFinaleDue`, `setupSuggestionsDue`, `setupFinaleOffersSlack`)
- `packages/ui/src/shell/DesktopApp.svelte` (setup-bot-only wiring)
- `packages/ui/src/chat/setup-run.ts`, `setup-agent.svelte.ts` (legacy markers)

HQ core: `core/workers/public/setup/worker.yaml` (emitter rules for the Setup bot).
