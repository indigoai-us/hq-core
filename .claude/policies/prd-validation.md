---
id: prd-validation
title: PRD validation — verify source files at draft, validate JSON post-write
scope: global
trigger: "/plan, /prd, /run-project, /execute-task, PRD drafting, AC writing"
enforcement: soft
created: 2026-04-28
supersedes: prd-json-validation-post-task, prd-verify-source-files
public: true
---

## Rule

Two validation gates protect PRD integrity at different lifecycle points: source-file verification during drafting, and JSON-parse validation after sub-agent writes.

### A. Source-file verification (during PRD drafting)

When a PRD story references concrete product strings (button labels, URLs, route paths, success copy, env var names, API field names), open the actual source file and quote the live value before writing the acceptance criteria.

- Do NOT infer from plan-mode notes, prior conversation, or pattern-match from sibling projects.
- If the detail is ambiguous in the source, pause and ask the user rather than invent a plausible value.
- Applies in both `/plan` interview and finalization phases, and to any AC that a worker would later treat as a literal contract.

### B. JSON-parse validation (after sub-agent writes)

After any sub-agent writes to `prd.json` (setting `passes`, adding `notes`, updating `files`), validate the JSON is parseable before proceeding to the next story:

```bash
python3 -c "import json; json.load(open('prd.json'))"
```

If validation fails, fix the JSON (typically a missing closing `}` on the last-modified story object) before continuing.

## Rationale

**Source verification:** Reading `provision-step.tsx:205` revealed the real CTA is `Download HQ Installer` — no workspace URL exists. A fabricated AC would have surfaced downstream as a swarm worker trying to implement a non-existent route, wasting a full story cycle. Reading the source file takes seconds; unwinding an invented spec takes hours.

**JSON-parse validation:** A corrupted PRD caused `jq` parse errors that crashed the orchestrator mid-completion-flow (after ROAD-008 but before the ROAD-004 retry and completion summary). Required manual PRD fix and orchestrator resume.
