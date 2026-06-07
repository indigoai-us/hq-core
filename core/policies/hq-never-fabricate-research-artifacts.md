---
id: hq-never-fabricate-research-artifacts
title: Never fabricate research artifacts a command did not actually gather
scope: global
trigger: a command produces a research/discovery artifact (brainstorm.md, codebase-scan.md, repo-analysis.md, etc.)
when: /brainstorm || /discover || /deep-plan
on: [UserPromptSubmit]
enforcement: soft
tier: 1
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: user-correction
learned_from: "/brainstorm research-persistence work: initial draft proposed /brainstorm write `codebase-scan.md` and `repo-analysis.md` to satisfy /plan's downstream expectations, but /brainstorm never runs those scanner agents. Writing fake artifacts would have silently misled /plan into skipping its real scanner phase on fabricated data."
---

## Rule

NEVER write a research/discovery artifact on behalf of a command that did not actually execute the underlying work. The producer map must match reality — each artifact's producing command must be the command that actually gathered the data.

Operational checklist before any command writes a research file:

1. **Verify the producer runs the scan.** If `/brainstorm` is about to write `codebase-scan.md`, confirm `/brainstorm` actually spawns a scanner agent. If it does not, do NOT create the file — even with placeholder content, even "for the downstream consumer's benefit."
2. **Emit a typed `null` instead of fake data.** If a downstream consumer expects an artifact the producer cannot honestly generate, have the producer write a frontmatter flag indicating absence (e.g. `codebase_scan: none`) rather than an empty or fabricated file. The consumer then runs its own scan.
3. **Document the producer map.** Each research-persistence contract must have a comment or table enumerating `{artifact_path} → {producing_command}`. If a command is listed as producer, that command's skill file must actually write the artifact with real data.

Consumers must also check: if an expected artifact is missing or flagged absent, run the scan locally. Never assume presence means real.

## Rationale

Fake artifacts are worse than missing artifacts. A missing file triggers the downstream scanner agent to run and produce real data; an empty or fabricated file silently disables that scanner, leaving the consumer to operate on nothing or — worse — on plausibly-shaped fake content. The bug is invisible at runtime because the file exists, passes frontmatter checks, and contains valid markdown. Integrity of research-persistence contracts rests entirely on each producer being honest about what it actually gathered.
