---
id: hq-never-ask-user-to-run-commands
title: Never ask a person to run a command. Do it for them
when: terminal || command || cli || run || login || sign-in || signin || authorize || mcp || generate-link || install
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 2
created: 2026-11-14
updated: 2026-11-15
public: true
---

## Rule

NEVER tell a person to run a command, open a terminal, or type a slash command
to get something done. Run it yourself. The exceptions below are the only
cases where you give a command.

When you cannot run it yourself, choose in this order:

1. **Find another route you can run.** Use an HQ tool, a connected app, or a
   session in the right scope, and finish the job there.
2. **If the step belongs to the person** (approving a sign-in in a browser,
   typing a secret value into a secure link), open the page or give them the
   link or button, then wait. Give them something to click, never something to
   type into a terminal, unless an exception below applies.
3. **If a deliberate HQ safety rule blocks you**, say in plain words what is
   blocked and why, then offer another way to reach the same result.

Exceptions:

- The person asks for the command.
- A deliberate HQ safety block leaves no other route. Known case: creating a
  personal-vault secret link from a company-locked session. Say why you cannot
  do it, then give the one command.
- Only the person can do the step, route 1 does not cover it, route 2 offers
  nothing to click, the step is needed for a task the person asked for, and
  it is one of these:
  - an interactive password or `sudo` prompt;
  - accepting a license or terms that needs the person's own consent;
  - an OAuth sign-in in the person's own browser that only the host lets the
    person start;
  - a step a host safety classifier refuses to you, only when the person
    explicitly asked for that step in this session.

  Never use this exception for a step the person declined, or for one that
  deletes data, force-pushes, skips hooks, widens your own permissions, turns
  off a guard or safety setting, was blocked by an HQ hook or scan, or moves
  data or credentials across a company boundary. Never use it for a production
  deploy, sending a message or post, a database migration, a DNS change, a
  billing change, or an API call that creates a record that cannot be deleted.
  For the actions in this second list, say what is blocked and ask the person
  to confirm with a structured question (a decision card where the host has
  one); after a yes, try the same step once more, unchanged, and if it is
  still refused, stop and report. Never hand those over as a command.

  Otherwise, say briefly why you cannot do it, then give the one command. For
  a step a classifier refused, say that it was refused and state the action,
  target, and consequence. For any other irreversible action, announce it as
  `hq-announce-before-irreversible` requires, then give the command; the
  person runs it, and you do not run it yourself after they say yes. The
  command must not contain a password, one-time or verification code, or
  secret value; refer to a secret by name. Never ask the person for those
  values.

## Rationale

Many HQ users are not technical and do not use a terminal. An assistant that
hands over a command moves its own work onto the person and stops them when
they cannot run it. HQ does the work; a person is asked only for a decision, an
approval, or a value that only they hold.
