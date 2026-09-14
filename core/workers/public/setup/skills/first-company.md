---
name: first-company
title: First company
description: Settle whether a new person is joining a company, starting one, or working alone, and then actually do it.
---

# First company

This is the question that shapes every other part of setup. A person who
belongs to a company gets shared channels, shared knowledge, teammates and
company credentials. A person working alone gets a clean personal HQ with none
of that overhead. Getting this wrong is expensive to undo, so settle it
properly, and then do the work rather than describing it.

Ask one question, in plain words, and wait:

> **Are you setting this up for a company, or just for yourself right now?**

## They already belong to a company

Their companies come from the "Owner context" block at the top of their
message (checked with their own sign-in, and refreshed every few minutes, so a
company they just joined shows up shortly after the sync). Never use your own
`hq` membership or company lookups for this: those describe you, the bot. If
the block says the check failed, tell them you could not check right now,
rather than treating them as someone with no company.

If the owner context, or claiming their invitations, shows a membership, they are already in.
There is nothing to create. Tell them which company they joined and who else is
in it, in one line, and move on to the next step. Do not offer to create a
second company on top of the one they just joined; that is a common and
confusing mistake.

## They are starting a company

This is outward-facing. It creates a tenant with its own knowledge, policies
and credentials, and (once teammates are invited) it is visible to other
people. Confirm before creating it, in one sentence that names the company:

> I will create **Northwind** as a company in HQ, with you as its owner. Good?

On an explicit yes, run `/onboard` and create it. You know their name and what
they do from the conversation, so answer what you can yourself instead of
relaying every prompt back to them.

When the company exists, say so in one line and ask whether anyone should be
invited yet. Inviting is also outward-facing: a real person receives a real
message. Confirm each invitation with the name and the email address before it
goes out, and provision teammates with `/new-hire` rather than assembling the
identity, membership and vault grants by hand.

"Not yet" is a good answer. They can add people the day they need to, and
nothing about the company is harder to set up later.

## They are working alone

Do not create a company. A personal HQ is a complete, first-class way to use
HQ, and saying so plainly matters: people assume the solo path is the
degraded one. Tell them their work stays private to this machine and their own
HQ Cloud account, and that a company can be added any time without redoing
anything.

Then move on. Do not return to this question later in setup.

## If they are not sure

Ask what they are trying to do first, not what structure they want. Someone who
describes shared client work needs a company; someone describing their own
reading, writing and research does not. Make the recommendation yourself in one
sentence, with the reason, and let them agree or correct you. Do not present
the trade-off as a list and leave them to solve it.
