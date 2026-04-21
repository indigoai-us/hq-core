# e2e-testing

Write, run, and debug E2E tests for backend features using Playwright API testing and cloud infrastructure.

## Arguments

`$ARGUMENTS` = `<action>` (required)

Actions:
- `write --target <endpoint|service|flow>` - Write E2E test for a feature
- `run [--filter <pattern>]` - Run E2E tests locally or in CI
- `debug --test <test-name>` - Debug a failing test
- `fix --test <test-name>` - Fix a failing test

Optional:
- `--repo <path>` - Target repository
- `--template <api-endpoints|nextjs-webapp>` - Use specific template
- `--browserbase` - Force Browserbase cloud execution (for UI integration tests)

## Knowledge References

- **Templates:** knowledge/testing/templates/
  - `api-endpoints.md` - For REST API testing (primary for backend)
  - `nextjs-webapp.md` - For full-stack integration tests
  - `cli-browser-oauth.md` - For CLI tools with browser auth
  - `README.md` - When to use each template
- **Infrastructure:** knowledge/testing/e2e-cloud.md
- **Browserbase:** knowledge/testing/browserbase-integration.md
- **Vercel:** knowledge/testing/vercel-preview-deployments.md

## Process

### write

1. Identify feature type:
   - API endpoint → use api-endpoints.md template
   - Full user flow → use nextjs-webapp.md template
2. Read existing tests for patterns (`tests/e2e/api/`)
3. Generate test file following template structure
4. Include: happy path, error cases, auth, validation
5. Run locally to verify: `npm run test:local`

### run

1. Check environment:
   - Local: `npm run test:local`
   - Browserbase: `npm run test:browserbase` (for UI tests)
   - CI: Triggered on push via GitHub Actions
2. Parse results from `test-results/test-results.json`
3. Report pass/fail summary

### debug

1. Run with verbose output: `npm run test:local -- --grep <test> --debug`
2. Check API responses in test results
3. Review request/response logs
4. Identify root cause and suggest fix

### fix

1. Read failing test and error message
2. Check endpoint/service for issues
3. Fix code or update test
4. Re-run to verify fix
5. Commit with clear message

## Output

### write
- New test file: `tests/e2e/api/{endpoint}.spec.ts`
- Test fixtures if needed: `tests/e2e/fixtures/{fixture}.ts`

### run
- Pass/fail summary
- Link to CI results (if available)
- Response details for failures

### debug
- Root cause analysis
- API request/response diff
- Suggested fix

### fix
- Fixed code or test
- Verification that tests pass

## API Testing Patterns

```typescript
// Basic endpoint test
test('GET /api/users returns user list', async ({ request }) => {
  const response = await request.get('/api/users');
  expect(response.ok()).toBeTruthy();
  expect(response.status()).toBe(200);

  const data = await response.json();
  expect(data.users).toBeInstanceOf(Array);
});

// Authenticated request
test('POST /api/protected requires auth', async ({ request }) => {
  const response = await request.post('/api/protected', {
    headers: { 'Authorization': `Bearer ${token}` },
    data: { field: 'value' }
  });
  expect(response.ok()).toBeTruthy();
});

// Error handling
test('POST /api/users validates input', async ({ request }) => {
  const response = await request.post('/api/users', {
    data: { invalid: 'data' }
  });
  expect(response.status()).toBe(400);
  const error = await response.json();
  expect(error.message).toContain('validation');
});
```

## Best Practices

- Test real HTTP requests, not mocked handlers
- Verify response status AND body structure
- Test auth flows with valid and invalid tokens
- Test rate limiting and error responses
- Use fixtures for test data setup/teardown

## CI Integration

Tests run automatically via GitHub Actions:
- On push to any non-main branch
- On pull request
- Results posted as PR comment
- API response logs available in artifacts
