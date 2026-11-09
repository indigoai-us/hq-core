#!/usr/bin/env bash
# Shared policy size limits. One place for the two numbers that used to be
# hard-coded separately (feedback_1c36af85).
#
#   HQ_POLICY_INJECT_MAX_DEFAULT  per-policy limit of the policy injector
#       (.claude/hooks/inject-policy-on-trigger.sh, HQ_POLICY_HARD_MAX_BYTES).
#       A hard policy whose binding body is over this shows its `## Rule`
#       section if that fits, otherwise only a one-line summary.
#   HQ_POLICY_WRITE_MAX_DEFAULT   authoring ceiling for the whole binding body
#       (validate-policy-frontmatter.sh and the linter,
#       HQ_POLICY_HARD_RULE_MAX_BYTES). It is NOT what is delivered.
#
# Keep HQ_POLICY_INJECT_MAX_DEFAULT equal to the injector default;
# core/scripts/tests/lint-policy-triggers.test.sh fails if they drift.
HQ_POLICY_INJECT_MAX_DEFAULT=2048
HQ_POLICY_WRITE_MAX_DEFAULT=6144
