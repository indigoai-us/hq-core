# validate-completion

Run back pressure checks on completed work.

## Arguments

`$ARGUMENTS` = `--repo <path>` (required)

Optional:
- `--checks <list>` - Comma-separated checks to run (default: all)
- `--strict` - Fail on warnings

## Process

1. **Run Type Check**
   ```bash
   npm run typecheck
   ```
   - Must pass with zero errors
   - Warnings logged but don't fail

2. **Run Linter**
   ```bash
   npm run lint
   ```
   - Must pass with zero errors
   - Auto-fix if possible

3. **Run Tests**
   ```bash
   npm test
   ```
   - All tests must pass
   - New code should have coverage

4. **Run Build** (if applicable)
   ```bash
   npm run build
   ```
   - Build must succeed
   - No runtime errors

5. **E2E Manifest Check** ({company-2}-site only)
   Skip if repo is not `repos/private/{company-2}-site`.
   ```bash
   npm run check-coverage
   ```
   - All app routes must have test coverage in manifest
   - Exit code 1 = uncovered pages exist
   ```bash
   npm run generate-manifest && git diff --quiet tests/e2e/manifest.json
   ```
   - If diff is non-empty, manifest is stale
   - Fail with: "Run `npm run generate-manifest` and commit the updated manifest"

6. **Report Results**
   - Show pass/fail for each check
   - Surface errors clearly
   - Suggest fixes if possible

## Checks

| Check | Command | Required |
|-------|---------|----------|
| typecheck | npm run typecheck | Yes |
| lint | npm run lint | Yes |
| test | npm test | Yes (if tests exist) |
| build | npm run build | No (optional) |
| e2e-manifest | npm run check-coverage + generate-manifest drift | Yes ({company-2}-site only) |

## Output

Validation report:
```
Validation Results:
  ✅ typecheck: passed (0 errors)
  ✅ lint: passed (0 errors, 2 warnings)
  ✅ test: passed (45 tests, 100% passing)
  ⏭️ build: skipped
  ✅ e2e-manifest: passed (32 pages covered, manifest fresh)

Overall: PASS
```

Or on failure:
```
Validation Results:
  ✅ typecheck: passed
  ❌ lint: failed (3 errors)
     - src/api/auth.ts:42 - Unexpected any
     - src/api/auth.ts:58 - Missing return type
     - src/api/auth.ts:72 - Unused variable 'temp'
  ⏭️ test: skipped (lint failed)

Overall: FAIL
Suggestion: Fix lint errors, then re-run
```

## Example

```bash
node dist/index.js validate-completion --repo repos/private/my-app

# Output:
# Running validation checks...
#
# [1/3] typecheck...
#   ✅ passed (0 errors)
#
# [2/3] lint...
#   ✅ passed (0 errors, 2 warnings)
#   Warnings:
#     - src/api/auth.ts:42 - Consider using explicit type
#     - src/api/auth.ts:58 - Prefer const over let
#
# [3/3] test...
#   ✅ passed (45 tests)
#
# Overall: PASS
# Ready to commit.
```
