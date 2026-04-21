# e2e-testing

Write, run, and debug E2E tests for frontend features using Playwright and cloud infrastructure.

## Arguments

`$ARGUMENTS` = `<action>` (required)

Actions:
- `write --target <page|component|flow>` - Write E2E test for a feature
- `run [--filter <pattern>]` - Run E2E tests locally or in CI
- `debug --test <test-name>` - Debug a failing test
- `fix --test <test-name>` - Fix a failing test

Optional:
- `--repo <path>` - Target repository
- `--template <nextjs-webapp|cli-browser-oauth>` - Use specific template
- `--browserbase` - Force Browserbase cloud execution

## Knowledge References

- **Templates:** knowledge/testing/templates/
  - `nextjs-webapp.md` - For Next.js/React apps
  - `cli-browser-oauth.md` - For CLI with browser flows
  - `api-endpoints.md` - For API testing
  - `README.md` - When to use each template
- **Infrastructure:** knowledge/testing/e2e-cloud.md
- **Browserbase:** knowledge/testing/browserbase-integration.md
- **Vercel:** knowledge/testing/vercel-preview-deployments.md

## Process

### write

1. Identify feature type and select appropriate template
2. Read existing tests for patterns (`tests/e2e/`)
3. Generate test file following template structure
4. Add data-testid attributes to components if needed
5. Run locally to verify: `npm run test:local`

### run

1. Check environment:
   - Local: `npm run test:local`
   - Browserbase: `npm run test:browserbase`
   - CI: Triggered on push via GitHub Actions
2. Parse results from `test-results/test-results.json`
3. Report pass/fail summary

### debug

1. Run with Playwright Inspector: `npm run test:debug -- --grep <test>`
2. Check screenshots in `test-results/`
3. Review Browserbase session recording if applicable
4. Identify root cause and suggest fix

### fix

1. Read failing test and error message
2. Check component/page for issues
3. Fix code or update test
4. Re-run to verify fix
5. Commit with clear message

## Output

### write
- New test file: `tests/e2e/{feature}.spec.ts`
- Updated playwright.config.ts (if needed)

### run
- Pass/fail summary
- Link to CI results (if available)
- Screenshots for failures

### debug
- Root cause analysis
- Suggested fix
- Session recording URL (Browserbase)

### fix
- Fixed code or test
- Verification that tests pass

## Best Practices

- Write tests that mirror real user behavior
- Use data-testid for stable selectors
- Test both happy paths and error states
- Don't rely on arbitrary timeouts
- Keep tests independent (no shared state)

## CI Integration

Tests run automatically via GitHub Actions:
- On push to any non-main branch
- On pull request
- Results posted as PR comment
- Artifacts (screenshots, traces) uploaded on failure
