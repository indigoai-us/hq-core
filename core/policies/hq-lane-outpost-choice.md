---
id: hq-lane-outpost-choice
title: Ask the user which Outpost runs a lane, with Auto and This machine as choices
when: outpost || outposts || placement || ((lane || lanes || runner || runners) && (remote || cloud || machine))
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
tier: 2
version: 1
created: 2026-11-23
public: true
---

## Rule

This is the one place that says how an agent chooses where a lane runs. Skills
and docs that start lanes link here instead of repeating it. It applies to
every engine and to every runner lane (`hq runners`, alias `hq lanes`).

1. **Ask before the first lane that could run on an Outpost.** When the work
   could run on an Outpost (it must outlive the session, the user mentioned an
   Outpost or remote work, or the user has any Outpost), ask one structured
   question (AskUserQuestion or the engine's equivalent) before starting the
   lane. Offer:
   - the user's personal Outposts (`hq outposts list --json`) and the
     Outposts of the lane's own company (`hq outposts list --company
     <company> --json`), by name, with "personal" or the company name next to
     it. Never offer another company's Outposts;
   - "Auto (use whatever has room)";
   - "This machine".

   A company Outpost that is not set up for lanes yet refuses the lane. Leave
   it out of the options, or list it with that note. When there are more
   choices than the question allows, offer Auto, This machine, and as many
   Outposts as fit, and let the user type another Outpost name.

   Do not ask for `--loop` or `--remote-control` lanes: hq-cli runs those only
   on this machine.
2. **If the user already named a placement in the request, use it without
   asking.** "On my Outpost", an Outpost name, "auto", or "locally" all count.
3. **Create the lane with the matching flag:**

   | Choice | Flag |
   |---|---|
   | A named Outpost | `--outpost <id>` (with `--company <lane's company>` for a company Outpost) |
   | Auto | `--placement auto` |
   | This machine | `--placement local` |

   Pass `--placement local` for This machine so the choice is explicit.
   `--outpost` takes the Outpost id from the lists above, not its name.

4. **Remember the answer for this session.** Store it with
   `bash core/scripts/hq-session.sh set lane_placement <value>`, where the
   value is `outpost:<id>`, `auto`, or `local`, and use it for later lanes in
   the same session without asking again. Turn `outpost:<id>` back into
   `--outpost <id>` (not `--placement outpost:<id>`), with the lane's
   `--company` for a company Outpost. Ask again only when the user changes it,
   the lane belongs to another company, or the saved Outpost refuses the lane.
5. **Never pick an Outpost silently.** Do not choose an Outpost, personal or
   company, unless the user chose it, named it, or chose Auto.
6. **When Auto is unavailable, say so.** `--placement auto` (like every
   `--placement` value other than `local`, and `--default-placement`) is
   behind a feature gate and can be refused. If `--placement auto` is refused, tell the user in one line and
   ask again with the named Outposts and "This machine" as the options.
7. **Unattended runs do not ask.** Scheduled jobs, overnight runs, and lanes
   started by another lane have no person to ask. A lane started by another
   lane leaves the placement flag off, so it takes the parent's
   `--default-placement` (or runs on the parent's host when there is none). A
   conductor may pass the user's choice as `--default-placement` on lead lanes
   so their lanes follow it. Scheduled jobs and overnight runs use the
   placement written into the job or run definition, or the `lane_placement`
   session value when the run continues the same session, and otherwise run
   on the machine that starts them. None of them pick a company Outpost on
   their own.

## Rationale

Outposts cost money and company Outposts are shared, so the user decides where lanes run.
