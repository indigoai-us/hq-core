---
id: prd-validation
title: PRD validation — verify source files at draft, validate JSON post-write
scope: global
trigger: "/plan, /prd, /run-project, /execute-task, PRD drafting, AC writing"
enforcement: hard
created: 2026-04-28
supersedes: prd-json-validation-post-task, prd-verify-source-files
public: true
tags: [design, infrastructure]
---

## Rule

Two PRD gates. (A) During drafting: when an AC references a concrete product string (label, URL, route, env var, API field), open the source file and quote the live value. Never infer from plan-mode notes or sibling projects; ask if ambiguous. (B) After any sub-agent write to prd.json: run `python3 -c "import json; json.load(open('prd.json'))"` and fix before next story.

## Rationale

**Source verification:** Reading `provision-step.tsx:205` revealed the real CTA is `Download HQ Installer` — no workspace URL exists. A fabricated AC would have surfaced downstream as a swarm worker trying to implement a non-existent route, wasting a full story cycle. Reading the source file takes seconds; unwinding an invented spec takes hours.

**JSON-parse validation:** A corrupted PRD caused `jq` parse errors that crashed the orchestrator mid-completion-flow (after ROAD-008 but before the ROAD-004 retry and completion summary). Required manual PRD fix and orchestrator resume.
