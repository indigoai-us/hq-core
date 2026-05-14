---
name: subagent-fanout-budget
description: Commands that spawn Task subagents must batch, pre-filter deterministically, or require user confirmation past a threshold
enforcement: soft
scope: hq-core
applies_to: claude-code
vendor_public_ok: true
public: true
---

## Rule

Any HQ command (or skill) that spawns Task subagents MUST do at least one of the following when the *expected* subagent count for a typical invocation could exceed **50**:

1. **Batch.** Process N items per subagent invocation (target: 5–20), with a structured output schema so the parent can fan results back in. No 1:1 file→subagent patterns.
2. **Deterministic pre-filter.** Reduce the candidate set with cheap shell/regex passes before any LLM call. Subagents only run on residuals that genuinely need model judgment.
3. **User confirmation past a threshold.** If neither (1) nor (2) can be done, the command must surface the planned subagent count to the user via `AskUserQuestion` (or equivalent) and proceed only on explicit confirmation, repeated every N=50 subagents.

A command's published spec MUST state its expected typical and worst-case subagent count in its frontmatter or top-of-file documentation. If the *observed* count exceeds the *stated* typical by more than 5× across two consecutive real-world runs, the command is in violation and must be rewritten under one of the three constraints above.

## Rationale

Subagent fanout is the steepest cost multiplier in HQ. Every subagent is an independent Opus invocation with its own prompt, thinking budget, and output — and `CLAUDE_CODE_SUBAGENT_MODEL=opus` (which is the right setting for HQ — see `~/.claude/projects/-Users-{user}-Documents-HQ/memory/feedback-no-haiku-subagents.md`) keeps each call at the top tier.

The May 2026 weekly-limit exhaustion was driven primarily by `/promote-hq-core` spawning **429 subagents combined across two runs in one day**, against a spec that promised "3–15 calls." A 24× overshoot on the worst run.

The pattern is structural, not specific to that command:

- **1:1 fanout is rarely necessary.** Most "one model call per item" designs can be batched into "one model call per N items" without quality loss.
- **Cheap filters carry most of the value.** If 80% of items can be classified by regex, only the residual 20% needs LLM judgment.
- **Unbounded fanout breaks the user's mental model of cost.** A run that "feels" small (one slash command) can quietly consume tens of millions of effective tokens.

## Examples

### ✅ Compliant: batch with structured output

```python
# /some-command processes N files in K subagents (K = N/10)
batches = chunk(files, 10)
for batch in parallel(batches, max=10):
    spawn_subagent(prompt=f"For each of these {len(batch)} files, return JSON [{{path, verdict}}, ...]")
```

### ✅ Compliant: deterministic pre-filter

```bash
# /promote-hq-core after US-003/US-004
scripts/promote-hq-core-scan.sh  # deterministic regex; 0 subagents
# Files with non-empty pii_flags get surfaced for user decision — still 0 LLM calls
```

### ❌ Non-compliant: 1:1 fanout, no pre-filter

```python
# /promote-hq-core BEFORE the fix
for file in push_candidates:  # 700+ files
    spawn_subagent(prompt=f"Read {file} and return PASS/EDIT/DROP")
```

### ✅ Compliant: bounded by domain, doc'd

```yaml
# /run-project frontmatter
# subagent_count: { typical: N stories, worst_case: N stories × 3 phases }
```

## Enforcement

**Soft.** Authors should self-enforce when adding new commands. Repeated violations should be raised as follow-up tickets via `mcp__ccd_session__spawn_task` or the relevant company's PRD process.

The fanout audit script (`scripts/fanout-audit.sh`, planned follow-up) can run periodically to surface drift between stated and observed counts.

## See also

- `workspace/reports/fanout-audit-2026-05.md` — most recent audit
- `projects/hq-token-economy/prd.json` US-014 — origin of this policy
- `~/.claude/projects/-Users-{user}-Documents-HQ/memory/feedback-no-haiku-subagents.md` — why "just use Haiku" is the wrong response to high subagent counts
- `.claude/policies/model-context-window.md` — sibling policy on context-window defaults
