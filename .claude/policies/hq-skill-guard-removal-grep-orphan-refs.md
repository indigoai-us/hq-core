---
id: hq-skill-guard-removal-grep-orphan-refs
title: When removing a skill-level guard, grep for orphan cross-references and rewrite them standalone
scope: global
trigger: Editing a skill, command, or policy file to remove a guard/section that may be referenced elsewhere in the same file (or sibling files) by name ("same message as the X guard", "see Y section above")
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

When you remove a skill-level guard, section, or preflight block that is referenced from elsewhere in the file (or related files) by name — e.g. `"same message as the Preflight X guard"`, `"see Plan-Mode section above"`, `"the restriction described in <name>"` — you MUST:

1. After the removal, grep the file (and closely-related files: the skill's `SKILL.md`, the command `.md`, and any linked policy) for the name of the removed section.
2. Rewrite every remaining reference to stand on its own (inline the relevant text, or re-anchor to a still-present section).
3. Never leave a dangling pointer to a section that no longer exists.

Concretely, the sequence is:

```bash
# 1. Remove the section (Edit)
# 2. Grep the same file + neighbors for the removed section's unique phrase
grep -nE 'removed-section-name|same message as .* guard' <file>
# 3. For each hit, Edit to inline the referenced content (or delete the reference)
# 4. Re-grep to confirm zero orphan cross-references remain
```

## Rationale

Observed 2026-04-22 while removing the brainstorm skill's Plan-Mode Preflight guard. A sibling section said "uses the same message as the Preflight guard" — after the guard was deleted the sibling pointer became dangling. The dangling pointer was only caught because the reviewer re-read the file; a purely grep-for-"Preflight" check missed it initially because "Preflight" is overloaded in brainstorm (there is also a distinct Repo-run preflight).

Removing a guard is a two-step operation: delete the definition AND fix every reference. Single-step deletions produce silent documentation rot — future readers either get confused by the dangling name or assume the guard still exists.

The grep step is cheap (1 second) and composes with the sibling rule on overloaded-term grep patterns (`hq-grep-preflight-overloaded-compound-pattern.md`): when the removed section's name is an ambiguous word, use a compound pattern to distinguish which instance you are looking for.
