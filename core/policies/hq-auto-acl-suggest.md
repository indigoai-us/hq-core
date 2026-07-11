---
id: hq-auto-acl-suggest
title: Suggest least-privilege sharing after artifact creation or task completion
when: share || send || present || deploy || artifact || report || complete || checkpoint || handoff || /deploy || /hq-share || /hq-files || /run-project || /execute-task || /checkpoint || /handoff
on: [UserPromptSubmit, AssistantIntent, PostToolUse]
enforcement: soft
public: true
version: 1
created: 2026-06-19
updated: 2026-06-19
---

## Rule

When a shareable artifact is produced or work completes, surface ONE least-privilege, same-company share suggestion at a time via the structured picker; never auto-grant, never cross company, and never share secrets, settings, raw transcripts, or signals.

Use a suggestion-first model:

- Detect deployable artifacts, vault deliverables, checkpoints, handoffs, and explicit share intent.
- Prefer exact same-company recipients and `read` permission.
- Surface one suggestion at a time so the human can approve, edit recipients, dismiss, or opt out.
- Execute confirmed sharing only with existing primitives such as `hq files share ... --with ... --permission read` or deploy access-policy/access-mode changes.

Guardrails:

- Never widen access automatically in this phase.
- Never suggest sharing `companies/{co}/settings/**`, raw `signals/**`, raw meeting source files, secrets, credentials, or capability links.
- If company or recipient resolution is weak, surface an editable suggestion or stay quiet.
- Respect global, company, and project opt-out settings before surfacing a suggestion.

Opt-out remains available at the global, company, project, and per-artifact level. When a user says not to suggest again for the current artifact, suppress repeats for that fingerprint.

## Rationale

Suggestion-first keeps the default safer than manual sharing while still reducing follow-up work after an artifact is created or a project finishes.

Least-privilege defaults matter here:

1. Read-only sharing is the narrowest useful default for deliverables and deployed artifacts.
2. Same-company resolution avoids accidental spillover when context is incomplete.
3. One decision at a time keeps sharing choices aligned with `decision-queue-one-at-a-time.md`.
4. Existing surfaces already know how to apply ACLs and deploy access changes, so this rule should guide those surfaces instead of creating a parallel path.

This policy complements `auto-deploy-on-create.md` by covering the share decision after an artifact exists, and it stays compatible with `hq-share-session-urls-are-capabilities.md` by refusing to persist capability links.

## Examples

- A report written to `companies/{co}/data/reports/q2-summary.md` should trigger one vault-share suggestion with `read` permission and same-company recipients only.
- A project deliverable written to `companies/{co}/projects/{project}/deliverables/demo.html` should trigger one suggestion, not a batch of multiple share questions.
- A completed deploy that returns an app id should suggest tightening access with the deploy access-policy surface rather than auto-opening access.
- A raw file under `companies/{co}/settings/`, `companies/{co}/signals/`, or `companies/{co}/sources/meetings/` should never produce a share suggestion.
