# run-tests

Run test suite and report results.

## Arguments

`$ARGUMENTS` = `--suite <name>` or `--file <path>` (optional)

Optional:
- `--repo <path>` - Target repository
- `--type <unit|e2e|all>` - Test type
- `--watch` - Watch mode

## Process

1. Detect test framework (Jest, Vitest, Playwright)
2. Run specified tests
3. Capture results
4. Format report
5. Surface failures with context

## Output

Test report:
```
✅ 42 passed
❌ 2 failed
⏭️ 3 skipped

Failed tests:
1. src/api/auth.test.ts:42 - login should return token
   Error: Expected 200, got 401

2. src/components/Button.test.tsx:18 - renders correctly
   Error: Snapshot mismatch
```
