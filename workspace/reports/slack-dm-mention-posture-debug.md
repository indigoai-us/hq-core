# DEBUG REPORT — Slack direct messages can be misclassified as unaddressed

**Date:** 2026-08-22
**Company:** none resolved (repository-scoped work order)
**Scope lock:** Slack addressing metadata, agent-session prompt assembly, and focused reply-contract tests
**Investigation depth:** 1 hypothesis tested

## Root Cause

**Status:** CONFIRMED

Slack ingress correctly classifies `channel_type=im`, but the session envelope reduces the origin to `channel=slack` and a literal-mention boolean. Prompt assembly then passed only `directMention` to `session_append_mention_posture`, whose false branch assumed every non-mention came from a followed conversation and instructed the agent to stay silent. The stable conversation key still distinguishes Slack DM channel IDs (`#slack:D…`) from channel threads (`#slack:C…`), but the posture helper did not use it.

## Evidence

| Evidence | Supports | Refutes |
|---|---|---|
| `hq-agent-session.sh` extracts `channel`, `convKey`, `sender.verified`, and `directMention`, but passes only the last value to the posture helper. | Hypothesis 1 | — |
| The helper's `false` branch hardcodes “you follow this conversation” and “stay silent,” with no channel check. | Hypothesis 1 | — |
| Slack ingress emits `channel=slack` for both channel threads and DMs; the generated `convKey` retains the Slack channel ID, whose `D` prefix identifies the DM path. | Hypothesis 1 | A `channel=dm` explanation |
| Existing tests cover direct mentions, non-mentions, and absent mention metadata, but not verified DMs. | Hypothesis 1 | Existing-regression-coverage explanation |

## Pattern Classification

**Primary:** TYPE MISMATCH — “not literally mentioned” was treated as equivalent to “not addressed.”

## What Was Ruled Out

- **No DM signal at the session boundary:** ruled out because the stable Slack conversation key retains the `D`-prefixed DM channel ID.
- **Direct-mention regression:** ruled out because the existing true branch is explicit and independently covered.

## Recommended Fix

**Minimal change:** Pass channel, conversation key, and sender-verification context to the posture helper. Keep the direct-mention branch unchanged; treat a verified Slack `D` conversation as addressed before applying the followed-conversation non-mention branch.
**Files to touch:** `core/scripts/lib/session-reply-contract.sh`, `core/scripts/hq-agent-session.sh`, and `core/scripts/tests/hq-agent-session-reply-contract.test.sh`.
**Risk of fix:** LOW — only the generated posture for verified DMs changes; direct mentions, unmentioned Slack channel turns, unverified messages, and absent metadata retain their existing behavior.
**Regression test:** Assert distinct prompt output for a verified DM without a literal mention, an unmentioned followed Slack turn, and a direct mention, plus entrypoint wiring for channel and verification metadata.
