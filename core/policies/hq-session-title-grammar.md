---
id: hq-session-title-grammar
title: Name the session with one meaningful glyph, company-first
scope: global
trigger: a session whose subject has become clear and whose title is still a slug or host autoname
when: always
on: [SessionStart, UserPromptSubmit]
enforcement: soft
public: true
version: 6
created: 2026-08-26
updated: 2026-09-02
source: user-correction
tags: [session, naming, ergonomics]
---

## Rule

Name the session yourself with `set_session_title` on the first turn — outside the terminal CLI the hook's title never lands, so this call is the only namer. The hook injects a one-time first-turn reminder carrying its company/project hint; act on it before other work, then rename again only if the subject changes.

HQ session titles follow one grammar:

```
{glyph} {COMPANY} · {Product} · {subject}
```

**Exactly one glyph. Never two.** A second glyph beside the first reads as a
badge pair and makes the left edge busier without making it more scannable.

The glyph shows **the most useful thing about the session right now**, chosen by
the ladder below — first tier that applies wins.

### Tier 1 — needs you, or finished

Always wins. These are the rows a person is scanning for.

| | |
|---|---|
| 🙋 | needs you — the session is waiting on an answer or an action |
| 🤝 | handed off — a person or fleet agent owns it now |
| 📤 | handoff ready — the session is closed, resume from the thread |
| ✅ | done — the work shipped |
| 🧊 | parked — deliberately on ice |

**Never use ⛔, 🚫, ⚠️ or any hazard sign for "waiting on the user".** Nothing
is wrong when a session has a question — a hazard glyph reads as an incident
and, used routinely, teaches the eye that alarming glyphs are ordinary.

`/handoff` has two moments and they are different rows in a sidebar: 📝 while
the handoff is being written, 📤 once it is ready. The hook emits 📝, because
that is what the running command tells it; only the assistant knows when the
handoff actually finished, so the assistant sets 📤.

### Tier 2 — long-running by nature

| | |
|---|---|
| 🔁 | recurring loop — scheduled monitors, canaries, smokes |
| 💬 | standing channel — inbox, Slack, an ongoing thread |

### Tier 3 — workflow stage

| | |
|---|---|
| 💭 | exploring — brainstorming, nothing decided |
| 📐 | planning — writing the PRD or spec |
| ⚡ | building — executing, shipping |
| 👀 | in review — PR open, awaiting a human |
| 🧪 | verifying — tests, smokes, diagnosis in flight |
| 📝 | wrapping up — the handoff is being written, not yet ready |

### Tier 4 — craft

Use when the stage would say nothing useful — an idle session, or one whose
stage is simply "building" and whose craft is the more interesting fact. This
tier is open: reach for an apter glyph when one exists.

🎨 design · ⚖️ legal · 💰 money · 📊 data · 🔎 research · 🔒 access ·
🛠️ tooling · ✍️ writing · 📣 growth · 🤖 agents · 📱 mobile ·
🏗️ architecture · 🧭 strategy · 🐛 incident · 🎟️ client · 🎤 music and events

**Never render a placeholder glyph.** If nothing in any tier is true, the title
starts with the company and no glyph at all. A glyph that appears when there is
nothing to say trains the eye to ignore the whole column.

### Company and subject

**`COMPANY`** — always the first text token, upper-case: `HQ`, `ME` (personal),
or the company's slug upper-cased. Long slugs get an explicit short form from
the `aliases:` block in `personal/settings/session-title.yaml` rather than a
mid-word truncation — release code carries no tenant names. Omit the token
entirely when no company resolves; do not substitute a generic one.

**`Product`** — the repo or product the session is working in, in Title Case:
`Work`, `Console`, `Sync`. Optional, and placed before the subject so identity
survives truncation — a sidebar shows roughly 33 characters, so anything that
identifies the session has to arrive early.

Omit it when it says nothing: when the company has only one product, or when the
subject already names it. Drop a leading word the company token already carried —
under company `HQ`, the repo `hq-work` is `Work`, not `HQ Work`.

**`subject`** — what the session is actually about, written for a human. Not a
directory slug.

Keep the whole title at or under roughly 56 characters.

`core/scripts/session-title.sh` emits a tier 2 or tier 3 glyph, the company, the
product (when the session cwd sits inside `repos/`) and a slug automatically
(when the setting allows), deriving the stage from the active slash command. It
never emits 🙋 — it cannot know that — and never a craft glyph, since its only
subject is a directory slug and any keyword match against that slug would be
redundant with the slug by construction. Both are the model's job. Once the
session's real subject is clear (normally after the first substantive turn),
set the title yourself with `set_session_title`, keeping the grammar and
replacing the slug with a written subject. Update it when the tier changes. Do
not re-title on every turn; the sidebar is not a progress bar.

Do not override a title the user set themselves.

### The hook does not run everywhere

`hookSpecificOutput.sessionTitle` is honoured by the terminal CLI. The Claude
Code desktop app ignores it: it names sessions itself from the first prompt and
tracks them under `local_<uuid>` ids distinct from the `session_id` hooks are
given, so sessions created there carry no HQ title state at all. Wherever the
hook's seed title is absent, `set_session_title` is not an improvement on the
hook — it is the entire feature. Honour the user's setting first either way.

### Honour the user's setting

Session auto-naming is a user setting. Before renaming a session, resolve it:

```bash
bash core/scripts/session-title-config.sh
```

It prints `enabled=` and `mode=`, resolving env → `personal/settings/session-title.yaml`
→ `core/settings/session-title.yaml` → built-in defaults.

- `enabled=false` — do not set a session title at all. The hook has already
  stood down; do not work around it with `set_session_title`.
- `mode=auto` — the hook's mechanical title is the whole feature. Do not
  rename, and do not "improve" a slug into a written subject.
- `mode=full` — the default. Replace the slug with a written subject as
  described above.

A user who has turned this off or down has said they do not want their sidebar
rewritten. An assistant that renames anyway is the single most annoying way
this feature can fail, because the user has to undo it by hand every session.

## Rationale

One glyph, chosen well, beats two glyphs chosen mechanically. v3 of this policy
allowed an optional second glyph for craft; in practice the pair read as visual
weight rather than as two separate facts, and the left edge stopped being a
column. The information that the second glyph carried is not lost — it moved
into tier 4, where it is rendered *instead of* a stage glyph whenever it is the
more interesting fact about the session.

The ladder is ordered by what a person is actually scanning for. "Does this
need me" and "is this finished" are the two questions that make someone open
the sidebar at all, so they outrank everything. Session kind comes next because
a recurring monitor is something you want to skip past, not read. Stage and
craft are detail, and compete for the remaining space.

⛔ is banned by name. It was used for "waiting on the user", which is not a
failure state — a session with a question is working correctly. Routinely
spending a hazard glyph on a normal condition is how a warning stops meaning
anything, and it makes an ordinary sidebar look like an incident board.

The no-placeholder rule survives from v2, where a `🟦` fallback stood in for
anything unclassified. An empty slot renders as nothing.

Company leads the text because it is the top-level filter, and because sidebar
groups are user-curated and frequently absent — the title cannot rely on them.

The grammar is also the ownership signal. `.claude/hooks/session-title.sh`
decides whether a title is HQ's or a human rename, and a title set via
`set_session_title` is by design absent from both of HQ's ledgers. Ownership is
tested by grammar match (`hq_title_grammar`): a SHOUTCASE company token before
a middot is HQ's, while free-form prose ("AGI book translations") is the user's,
and HQ backs off permanently. Titling outside the grammar makes HQ mistake its
own work for a manual rename and stop titling that session.

This policy is injected as a per-session baseline (`on: [SessionStart]`,
`when: always`). Its earlier trigger tokens — `session-title`, `rename` — do not
occur in ordinary prompts, so the reminder effectively never reached the model
and titles fell back to the host autoname.
