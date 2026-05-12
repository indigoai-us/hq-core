---
description: Submit a bug report or feature request to HQ via hq feedback CLI
allowed-tools: AskUserQuestion, Write, Bash(mktemp:*), Bash(bash:*), Bash(rm:*), Bash(core/scripts/hq-session.sh:*), Bash(hq:*), Bash(pwd:*)
argument-hint: "bug|feature [title]"
visibility: public
---

# /feedback — Submit HQ feedback

Loads the feedback skill from `.claude/skills/feedback/SKILL.md` and runs the assemble-and-submit pipeline.

**Input:** $ARGUMENTS — `bug|feature [title]` — if no type prefix is given (first token is neither `bug` nor `feature`), the entire argument is treated as the title and TYPE defaults to `bug`.

## Steps

1. Load the feedback skill from `.claude/skills/feedback/SKILL.md`
2. Execute the skill pipeline:
   - Parse type and title per Step 1 of SKILL.md (title-only invocations like `/feedback "Login broken"` are handled — entire string becomes TITLE, TYPE defaults to `bug`); use **AskUserQuestion** for title if absent
   - Allocate body path via `mktemp -t hq-feedback-body` (capture the printed literal path — it does NOT persist as a shell variable across separate Bash tool calls)
   - Capture CWD via `pwd` (capture as a literal value)
   - Summarize the current + prior turn into 2–4 bullets (prose — no Bash)
   - Find the last failing tool call in the conversation, or record `none` (prose — no Bash)
   - Assemble four-section body (`## User Message` = `$ARGUMENTS` verbatim / session context / last failing tool / cwd hint) and write it to the captured body path using the Write tool; `## User Message` captures the raw user input separately from the `--title` extraction
   - Resolve company slug via `core/scripts/hq-session.sh get company_slug` (capture as a literal value)
   - Submit via single Bash call: substitute all captured literal values into the command template (`hq feedback "<type>" --title "<title>" --body-file "<body-path>" [--company "<slug>"]; rc=$?; rm -f "<body-path>"; exit $rc`) — shell variables from prior calls do not survive across Bash tool invocations
3. Report the `Submitted: feedback_<uuid>` confirmation line
