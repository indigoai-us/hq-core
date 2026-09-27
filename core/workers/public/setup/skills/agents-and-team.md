---
name: agents-and-team
description: Walk someone through putting an agent in Slack, connecting an outside agent, inviting a teammate, and sharing a connected app or a key with them. What you can do yourself, what only they can click, and how to check it worked.
---

# Agents and the team

Use this whenever someone wants one of these, during setup or after it:

- an agent in Slack for their team
- another agent (not one of HQ's own) connected to their company
- a teammate invited
- a connected app, or a key, shared with a teammate

The rules from your instructions still hold: one question per message, plain
words, and you run the commands yourself. Everything below that goes out to
another person or costs money is confirmed first, in one short line, before
you run it.

## Check these first, every time

Run `hq whoami` and `hq companies list`, and read the "Owner context" block.

1. **A company, not their personal HQ.** All four flows are company-level. If
   they have no company yet, say so and offer to create one first.
2. **Their role.** Creating agents, connecting Slack and inviting anyone but a
   plain member need an owner or admin. If they are a member, say that plainly
   and offer to draft a short note to their company's owner instead.
3. **Their plan, when the flow depends on it.** Check it as
   `skills/pricing.md` says; never guess it. Inviting people, sharing a
   connected app and sharing a key are included in every plan (within
   Starter's limits of 5 people, 1 connected app and 10 keys). Hosted agents,
   Slack agents included, are not part of Starter: they need HQ Workforce
   ($500 a month for the company), and then each agent is $100 a month on
   top. If HQ refuses something or quotes a price, pass that answer on.

Never ask anyone to paste a token, a code, a password or a key into this chat.
Tokens go into the HQ console, codes go into the other agent, keys go through
`hq secrets generate-link`.

## An agent in Slack

The current way is a cloud agent created in HQ that gets its own Slack app in
the company's workspace. Three moments need the person: approving the monthly
price, signing the agent in to its model, and the Slack side (connecting the
workspace once, then installing the app).

1. Ask what they want the agent to do and what to call it. Suggest a name and
   a job drawn from their business.
2. Run `hq agents provision "<name>" --company <slug> --model <model>` without
   `--yes` and tell them the price it quotes. Only after they say yes, run it
   again with `--yes`. If it exits with code 3, HQ needs payment first
   (on Starter that means upgrading to HQ Workforce): pass on what it says and
   the checkout link it prints, and say an owner has to complete it.
3. Follow it with `hq agents status <name> --company <slug> --json`. When it
   shows a model sign-in link and code (or run `hq agents login-code`), give
   both to them and wait for "done".
4. **Connecting the Slack workspace, once per company.** If the status shows
   `FACTORY_ROOT_MISSING`, the company's Slack is not connected yet. Send them
   to `https://hq.computer/companies/<slug>/agents` (the page is called Bots).
   There they open api.slack.com/apps, generate the App Configuration Token
   pair, and paste both tokens into the console, not into this chat. Only an
   owner or admin can do this; there is no command for it.
5. **Installing the app.** When the status shows a `slack-install` action,
   give them the install link. Someone in their Slack workspace clicks
   Install. If their workspace needs admin approval for new apps, say a Slack
   admin has to approve it and that you will pick up once they have.
6. If a `slack-app-token` action appears, send them to the app's Basic
   Information page in Slack to create an app-level token with
   `connections:write`, and to paste it on the agent's row on the Bots page.
7. When the status shows the agent is ready, have them invite it to a Slack
   channel and @mention it there. Check from your side with
   `hq agents message <name> "hello" --company <slug>`.

When something goes wrong:

- The Slack tokens are rejected or expired: generate a fresh pair at
  api.slack.com/apps and paste it again. The pair belongs to the Slack user
  who made it.
- The workspace does not allow creating apps: the company can reuse an
  existing Slack bot token instead (`--slack-bot-token`, or
  `--slack-tokens-stdin` so it never appears on screen). Ask whether they
  have one before suggesting it.
- The agent ignores someone's DM: that person's Slack account is not linked to
  HQ yet. They open the link the agent sent them and sign in.
- `hq agents retry` does not clear a step that is waiting on a person. Say
  which person action is still open instead.

## Another agent, connected from the console

Agents HQ does not host (grokbot, OpenClaw, Hermes, Muse, or anything that can
use MCP) connect as an "External bot". Creating one happens only in the
console; you guide, they click.

1. Ask which agent it is and where it runs.
2. Send them to `https://hq.computer/companies/<slug>/agents`, then Add bot,
   a name, **External bot**, the agent's framework, and **Create and get
   code**. The code works once and expires in 15 minutes. It goes into the
   other agent, never into this chat.
3. On the machine where that agent runs, the console's prompt does the rest,
   or by hand: `pnpm add -g @indigoai-us/hq-cli`, then
   `hq agent enroll <CODE> --company <slug>`, `hq agent kit install`, and
   registering `hq agent mcp` as an MCP server in that agent.
4. `hq agent probe` on that machine passing, or the Enrolled badge in the
   console, means it worked. If the code expired, `hq agents rotate <uid>`
   makes a new one.

Tell them what it gets: the company's files, messages, search, and the keys
shared with it, the same context their own agents have.

If they only mean their own Claude, ChatGPT, Codex or Grok (the chat apps, not
a bot), that is simpler: Integrations, then **Connect an agent** in the
console, and they sign in in the browser.

## Inviting a teammate

Every invite runs through HQ's new-hire flow. Read
`.claude/skills/new-hire/SKILL.md` in the HQ folder before the first invite and
follow its steps: check `hq members list` first, set the role, invite, then
the access that person needs (groups, shared apps and keys) and the
acceptance follow-through. It is your playbook, not something to show them:
ask its questions in plain words, one at a time, skip what setup has not
created yet (groups, an onboarding packet), and never name the skill or its
command. If that file is not in this HQ, the steps below are enough.

1. Ask for one email and whether they should be a member or an admin
   (member is the default; admins can only invite members). If they already
   said who, do not ask again.
2. Confirm in one line that an invitation email will go to that address, and
   wait for yes.
3. Send the invite the way the new-hire flow says
   (`hq members invite <email> --company <slug> --role member`).
4. Tell them what happens next: the teammate opens the email, signs in with
   Google or Microsoft, and gets the company in their own HQ, so their Claude
   Code or Codex knows the business from their first session. Say what they
   will see that matters to this person (the client homes, and any app you
   have shared with them; a connected app stays private to the person who
   connected it until it is shared). Always add: "Tell them to check their
   spam folder if the email doesn't show up in a few minutes."
5. Check with `hq members list` (pending until they accept). If they never
   got it, `--resend` sends it again.

Then offer, once, to share a connected app or a key with the new teammate.

## Sharing a connected app

Connected apps are private to whoever connected them until they are shared.
Sharing one is included in every plan.

1. `hq integrations list`, then confirm which app and with whom.
2. `hq integrations share <app> --with <email> --permission read` (or
   `--with everyone` for the whole company).
3. Check with `hq integrations access <app>`.

## Sharing a key

Refer to keys by name only; never print a value.

1. Confirm which key and with whom.
2. `hq secrets share <PATH> --with <email> --permission read`. For the whole
   company the target is `@all`. Personal keys cannot be shared.
3. Check with `hq secrets acl <PATH>`.
4. A key that is not stored yet: `hq secrets generate-link <PATH>` gives them
   a link to paste it into, so it never passes through this chat.

Say what sharing means in their terms: the teammate's agents can use the key
through HQ without anyone sending it over Slack or email.
