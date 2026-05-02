---
id: anthropic-pricing-verify
title: Verify Anthropic API pricing before hardcoding
scope: global
trigger: any code that hardcodes LLM token pricing
enforcement: soft
applies_to: [anthropic]
public: true
---

## Rule

Always web-search current Anthropic pricing before hardcoding cost constants. Pricing changes frequently — GoClaw had stale rates (haiku $0.80 vs actual $0.25, opus $15 vs actual $5) that inflated cost estimates by 3x. Check platform.claude.com/docs/en/about-claude/pricing.

## Rationale

Discovered Mar 2026 when wiring LLM cost tracking for GoClaw fleet. The hardcoded constants in metrics-routes.ts were from an earlier pricing era. Cost dashboards showed wildly inflated numbers.
