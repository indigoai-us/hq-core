# Audit Report — PR #153

**Run:** 2026-08-04T17:52:58Z
**Branch:** audit/promote-auto-main-3456ae5
**Findings hash:** 247d9661fe3becccde79c6da00efae52e855d4893fceab6ba0908db197ec1d71

## Findings (manual review required)

All 4 findings are in `core/scripts/tests/refresh-vault-access.test.sh`.
Matched pattern: pii/email ([EMAIL]) on lines 27, 38, 39, 44.

These appear to be RFC 2606 reserved addresses used as test stub data.
Recommend adding this file to `.claude/audit/suppressions.yaml` with
`scanners: [pii]` and appropriate rationale.
