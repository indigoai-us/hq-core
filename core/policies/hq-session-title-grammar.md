---
id: hq-session-title-grammar
title: Name the session in HQ title grammar once its subject is known
scope: global
trigger: a session whose subject has become clear and whose title is still a slug or host autoname
when: session-title || sessiontitle || rename
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 2
created: 2026-08-26
updated: 2026-08-26
source: user-correction
tags: [session, naming, ergonomics]
---

## Rule

HQ session titles follow one grammar:

```
{icon} {CATEGORY} · {subject} · {phase}
```

- `icon` — one emoji. The domain icon, or a live status flag (`▶️` running,
  `✅` recently completed) when one applies. Never render both.
- `CATEGORY` — a SHOUTCASE token of 2–8 characters: `SEC`, `LEGAL`, `OPS`,
  `FIX`, `DESIGN`, `DOCS`, `TEST`, `DATA`, `PLAN`, `FLEET`, `HQ`, `ME`, or a
  company's first slug token.
- `subject` — what the session is actually about, written for a human. Not a
  directory slug.
- `phase` — the current mode: `Scoping`, `Building`, `Verifying`, `Blocked`,
  `Done`. Optional; drop it rather than guess.

Keep the whole title at or under roughly 56 characters.

`core/scripts/session-title.sh` emits this grammar automatically at session
start, but it can only ever put a directory slug in the `subject` slot — that
is all a folder name contains. Once the session's real subject is clear
(normally after the first substantive turn), set the title yourself with
`set_session_title`, keeping the grammar and replacing the slug with a written
subject. Update it again when the phase changes materially. Do not re-title on
every turn; the sidebar is not a progress bar.

Do not override a title the user set themselves. Claude Code's native autoname
arrives through the same `session_title` input and transcript custom-title line
as a `/rename`; it is not evidence of a human override. When provenance is
unavailable, classify ownership by title grammar: an HQ-grammar match remains
automated, while non-matching free-form prose is a manual title.

## Rationale

The hook's automatic titles are accurate and useless: `hq-company-resolution-routing · chat`
tells a reader nothing that the folder name did not. Titles are read in the
desktop sidebar, the `/resume` picker and the terminal tab, where the whole
value is recognising a session at a glance.

The grammar is also the ownership signal. `.claude/hooks/session-title.sh`
decides whether a title is HQ's or a human rename, and a title set via
`set_session_title` is by design absent from both of HQ's ledgers. Ownership is
therefore tested by grammar match (`hq_title_grammar`): a SHOUTCASE category
token before a middot is HQ's; free-form prose ("AGI book translations") is the
user's, and HQ backs off permanently. Titling outside the grammar makes HQ
mistake its own work for a manual rename and stop titling that session. Version
2 records the host-autoname case: ledger absence and the shared title input
cannot establish human provenance, so grammar is the durable ownership
discriminator.
