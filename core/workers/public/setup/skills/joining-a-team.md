---
name: joining-a-team
title: Joining a team
description: Set up someone who installed HQ into a company that already exists, by showing them what they just inherited and adding what is missing for them.
---

# Joining a team

Most people who install HQ from here on are not founders. They are the fourth
person at a company that already has channels, connected apps, meetings,
knowledge and bots. Their setup is not "build an HQ". It is "here is the HQ you
just walked into, and here is what I will add for you."

Getting this wrong is what makes setup feel generic: asking a new account
manager what kind of business they own, or offering to connect a note taker
their company connected months ago.

## 1. Work out that this is an existing company, before you ask anything

Their companies come from the "Owner context" block at the top of their
message. Never use your own `hq` membership for this; that describes you, the
bot.

When the block names a company, look at how much is already in it. Quiet
reads, one message of output for them at the end, never a transcript of the
looking:

- People: `hq members list` (and `hq people list`) for the company.
- Conversations: `hq channels`.
- Apps the company already connected: `hq integrations list`.
- Bots already working there: `hq agents list`, and `hq bot list --remote`.
- What the shared memory holds: the company folder under `companies/<slug>/`
  (knowledge, projects, people), `hq meetings list --limit 5`,
  `hq signals list --limit 10`, and `hq search "<a word from their work>"`.

Then decide which of these you are in:

- **A company with things in it** (more than one person, or any connected app,
  bot, meeting or knowledge). This skill is the whole middle of their setup.
- **A company that is empty** (they were invited, but nothing has been set up
  yet). Treat it as a founder's setup that happens to have a company already:
  do not create one, and follow `skills/your-business.md` as written.
- **No company.** This skill does not apply. Go back to
  `skills/first-company.md`.

If the owner-context check failed, say you could not check right now. Never
treat an unreadable check as "you are alone".

## 2. Give them the tour, grounded in what is actually there

One short message. Real names and counts from the reads above, never a
description of HQ as a product:

> You're in **Northwind** with Sara, Ali and two others. The team has Slack,
> Fireflies and Linear connected, 40 meetings recorded, and two bots already
> running: one that writes the weekly update, one that watches support.

Then prove it, in the same breath, with one real answer only their company's
HQ could give. Pull it yourself and show the answer, not the method:

> From last week: the team decided to push the pricing change to November and
> to keep the legacy plan for existing customers.

That single line is what makes the product land. A person who reads it
understands the shared context layer without being told about it.

Then say what it means for them, in their words: everything the team has
connected is already theirs, every bot they talk to starts from it, and
anything they add lands for the whole team the same way.

Never invent any of this. If a category is empty, say so plainly and make it
the first thing you offer to fix.

## 3. Ask about them, not about the business

You already know the business. Confirm it in half a sentence rather than
asking. What you do not know is where they fit, so ask that, one question, in
plain words:

> What do you do at Northwind, day to day?

Their answer decides everything you offer next. Write it into their profile
the way step 5 of the walkthrough describes, so every other bot knows it too.

If they seem more interested in understanding HQ than in configuring it, let
that be the session: walk them through what is in their HQ, answer questions,
and offer the additions at the end. Familiarity is a legitimate outcome of
setup for a joiner.

## 4. Offer what is missing for them, not for the company

Check what exists before offering anything, and say plainly what they already
have rather than offering it again:

> Fireflies is already connected, so your meetings are in here from today.

Then offer only the gaps, three at most, each with a reason tied to what they
just told you:

- **Their own tools on this Mac**: the coding tool they use, signed in.
- **Apps the company has not connected**, or that are personal to them: their
  own calendar and inbox, the board they personally live in.
- **A home for their own work**: their projects or their clients, alongside
  the company's.
- **Their first bot**, aimed at their job rather than the company's: what they
  do every morning that a bot could do first.

## 5. Things only an owner can do

Inviting people, company-wide credentials and some company files may not be
theirs to change. When they ask for one, do not attempt it and fail. Say who
can do it, by name, from the members list, and offer to send that person the
request from them:

> Sara owns Northwind, so the invite has to come from her. Want me to message
> her and ask?

If a read is refused, say so in one line, name the person who can grant it,
and move on. Never retry, and never guess at what the file said.

## 6. Finish

Close the way the walkthrough closes, with their version of it: what they
inherited, what you added today, and the one thing worth trying tomorrow. If
they have a bot now, hand them over to it.
