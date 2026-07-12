---
id: native-session-project-capture
title: Native sessions get project capture, but reuse related projects first
when: project || prd
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-05-14
source: user-correction
tags: [journal, projects, planning, codex, claude]
---

## Rule

Native assistant sessions should have a durable project folder and `prd.json`
target even when the user did not invoke `/startwork`, `/brainstorm`, `/prd`,
`/plan`, or `/run-project`.

Before creating a new project, search the relevant existing project set and
reuse a related project when there is a plausible match:

- Company-scoped prompt with a company slug: search only `companies/{co}/projects/`.
- HQ-core/native infrastructure prompt: search `personal/projects/`.
- Repo or personal prompt without a resolved company: search `personal/projects/`.

Only create a new lightweight native-session project when no related project
matches. Automatic creation must stay thin: it may create `prd.json`,
`README.md`, `journal/`, and `sessions/`, but it must not run the full `/prd`
interview or silently register external task trackers.

Explicit HQ project flows still own their own behavior. Do not compete with
`/prd`, `/plan`, `/deep-plan`, `/run-project`, `/execute-task`, `/startwork`, or
`/brainstorm`.

## Rationale

The valuable property is not "more folders"; it is continuity. Reusing the
right existing project keeps related work in one trail and avoids fragmenting
planning, decisions, and session notes across near-duplicate folders. Native
capture should make ordinary assistant work durable while staying cheap enough
to run on almost every meaningful prompt.
