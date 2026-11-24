---
id: hq-suggest-outpost-uses
title: When a user starts using an Outpost, suggest jobs from their recent work and connect only the apps those jobs need
when: outpost || outposts
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
tier: 2
version: 1
created: 2026-11-20
public: true
---

## Rule

When a user creates an Outpost (personal or company), or starts using one that
has no jobs yet, suggest what it could do for them. This applies to every
engine (Claude, Codex, Grok or another). Do it once per Outpost per session,
after the create or sign-in finishes, never in the middle of it.

1. **Look at recent work, briefly.** Read at most 5 recent items for the
   active company: `workspace/threads/handoff.json`, the newest thread files
   in `workspace/threads/` (their `conversation_summary` and `next_steps`
   fields only). Read nothing else. Stop after 5 files or 30 seconds, whichever comes first. Never scan
   all of `workspace/`, never read transcripts, and skip any item that belongs
   to another company.
2. **Find recurring work.** Look for work the user repeats: catching up on
   meetings, reading team chat, reviewing pull requests, triaging errors or
   tickets, writing a status update.
3. **Propose 1 to 3 jobs.** Each proposal names the schedule, what the job
   produces, where the result goes, and the apps it needs. A company Outpost
   cannot send HQ DMs or email yet, so its jobs write their result into the
   company folder or post through a usable company app.
4. **Check the apps first.** Run `bash core/scripts/usable-integrations.sh
   show --company <company>` (or `hq integrations list --usable --company
   <company>`). An app on that list is ready. For a company Outpost job, the
   app also has to be shared with the company's members, because the job runs
   as the Outpost, not as the user.
5. **Ask one question at a time** with the structured picker (AskUserQuestion
   or the engine's equivalent): first which job to set up, then, only if that
   job needs an app that is not usable, whether to connect it. Connect it
   through the `/hq-integrations` flow. Suggest only the apps a chosen job
   needs. Do not offer a list of every app.
6. **Do the setup yourself after a yes.** Register the job (`hq outposts jobs
   register` on a company Outpost, `/schedule` on a personal one), run it once
   with `run-now`, and report the result. Check the run with `hq outposts jobs
   runs`. A failed `run-now` is reported to the user as a failure, with the
   reason, never as done. Follow
   `hq-never-ask-user-to-run-commands`: the user clicks or answers; they do not
   type commands. Sign-in links and app consent screens are the only steps the
   user does.
7. **Stop after a no.** If the user declines a job or an app, do not offer it
   again in this session, and do not repeat the whole suggestion when they use
   the Outpost again.

When recent work shows nothing useful, offer this generic menu. Check what
each item needs before offering it, and name the missing step. None of these
has been tested end to end on a company Outpost yet:

| Job | What it needs |
|---|---|
| Daily brief from the day's meetings | File sync on, and meeting notes in `companies/<company>/sources/meetings/`. Not yet tested end to end on a company Outpost |
| Daily brief that also covers team chat | The above, plus Slack (or the team's chat app) usable and shared with the company. Not yet tested end to end on a company Outpost |
| Morning summary of open pull requests and failing checks | GitHub usable and shared with the company. Not yet tested end to end on a company Outpost |
| Weekly digest of new and changed files in the company vault | File sync on. Not yet tested end to end on a company Outpost |

Keep company isolation: use only the active company's sessions, files, apps and
Outpost. Never propose a job that reads another company's data.

## Rationale

Recent work shows what a user repeats, a bounded look keeps it fast and in one company, and details are in `core/knowledge/public/hq-core/company-outposts.md`.
