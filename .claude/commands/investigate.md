---
description: Iron Law debugging — root cause investigation before any fixes, scope lock, structured DEBUG REPORT
allowed-tools: Read, Grep, Glob, Write, Bash(git:*), Bash(qmd:*), AskUserQuestion
argument-hint: [company] <bug description or symptom>
visibility: public
---

# /investigate - Iron Law Debugging

Root cause investigation before any fixes. Never touch code until the cause is known.

**Input:** $ARGUMENTS

**Iron Law:** NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST.

## Steps

1. Load the investigate skill from `.claude/skills/investigate/SKILL.md`
2. Resolve company context (manifest lookup, cwd inference — same pattern as `/brainstorm`)
3. Execute the 6-step investigation: scope lock → symptom capture → evidence gathering → pattern classification → hypothesis testing → DEBUG REPORT
4. Save report to `workspace/reports/{slug}-debug.md`
5. If root cause confirmed: present fix gate (apply / manual / more investigation)
6. After confirmed fix applied and verified: suggest `/learn` to capture the pattern
