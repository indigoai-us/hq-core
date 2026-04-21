---
description: Enforce test-driven development with RED→GREEN→REFACTOR cycle and coverage validation
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [task-description]
visibility: public
pack: dev
---

# /tdd - Test-Driven Development Workflow

Develop a feature using strict test-driven development: write failing tests first, implement minimal code, refactor, and verify coverage.

**Task description:** $ARGUMENTS

## TDD Cycle (MANDATORY)

```
RED → GREEN → REFACTOR → REPEAT
```

1. **RED**: Write a failing test FIRST (verify test fails before implementation)
2. **GREEN**: Write minimal code to pass the test (no over-engineering)
3. **REFACTOR**: Improve code quality while keeping tests green
4. **REPEAT**: Continue until feature is complete and coverage meets requirements

---

## Process

### Step 1: Framework Detection & Setup

Auto-detect the test framework and package manager from the project:

**Package managers** (check in priority order):
- `bun.lockb` → `bun test`
- `pnpm-lock.yaml` → `pnpm test`
- `yarn.lock` → `yarn test`
- `package-lock.json` → `npm test`
- `Cargo.lock` → `cargo test`
- `go.mod` → `go test ./...`

**Test frameworks** (infer from project files):
- `package.json` with `jest` → Jest (Node/TypeScript)
- `package.json` with `vitest` → Vitest (Vite-based)
- `pyproject.toml` or `requirements.txt` → pytest (Python)
- `go.mod` → Go's `testing` package
- `Cargo.toml` → Rust's built-in test framework

**If no framework detected:** Ask the user which test framework and runner to use. Do not proceed without a confirmed test runner.

**Store the detected runner** as `{TEST_CMD}` (e.g., `bun test`, `pnpm test`, `pytest`) and use it for all subsequent test commands in this workflow.

**Report detected framework and package manager to the user before proceeding.**

### Step 2: Define Interfaces (Scaffold)

Create the function/class definition with empty implementation:

- Write TypeScript interfaces (or equivalent) for inputs and outputs
- Define the function signature with placeholder implementation
- Include JSDoc comments describing behavior

Example (TypeScript):
```typescript
/**
 * Validates an email address format.
 * @param email - The email string to validate
 * @returns true if email is valid, false otherwise
 * @throws Error if email is null/undefined
 */
export function validateEmail(email: string): boolean {
  throw new Error('Not implemented');
}
```

### Step 3: Write Failing Tests (RED Phase)

Write comprehensive test suite BEFORE implementation:

**Test types to include:**
- Happy path (valid input → expected output)
- Edge cases (empty, null, undefined, boundary values, max length)
- Error conditions (invalid formats, type errors)
- Integration tests (API endpoints, database operations if applicable)

**Requirements:**
- Tests must FAIL before implementation
- Each test should be independent (no shared state)
- Use meaningful assertion messages
- Run tests and **VERIFY RED status** (all fail as expected)

**Example test structure (Jest/Vitest):**
```typescript
describe('validateEmail', () => {
  describe('happy path', () => {
    it('accepts valid email addresses', () => {
      expect(validateEmail('user@example.com')).toBe(true);
      expect(validateEmail('test.name+tag@domain.co.uk')).toBe(true);
    });
  });

  describe('edge cases', () => {
    it('rejects empty string', () => {
      expect(validateEmail('')).toBe(false);
    });

    it('rejects email without @', () => {
      expect(validateEmail('invalidemail.com')).toBe(false);
    });

    it('rejects email without domain', () => {
      expect(validateEmail('user@')).toBe(false);
    });

    it('rejects email with spaces', () => {
      expect(validateEmail('user @example.com')).toBe(false);
    });

    it('handles special characters', () => {
      expect(validateEmail('user+tag@example.com')).toBe(true);
      expect(validateEmail('user.name@sub.domain.com')).toBe(true);
    });
  });

  describe('error conditions', () => {
    it('throws error if email is null', () => {
      expect(() => validateEmail(null as any)).toThrow();
    });

    it('throws error if email is undefined', () => {
      expect(() => validateEmail(undefined as any)).toThrow();
    });

    it('rejects excessively long email', () => {
      const longEmail = 'a'.repeat(255) + '@example.com';
      expect(validateEmail(longEmail)).toBe(false);
    });
  });
});
```

**Run tests and verify RED:**
```bash
{TEST_CMD}        # Use the detected test runner from Step 1
# Expected: ALL tests FAIL (red output)
# If ANY test passes, you haven't written the test correctly — fix it before proceeding
```

### Step 4: Implement Minimal Code (GREEN Phase)

Write **only the minimum code needed** to pass the tests:

- No premature optimization
- No extra features beyond test requirements
- Focus on making tests pass
- Keep code simple and readable

**Example minimal implementation:**
```typescript
export function validateEmail(email: string): boolean {
  if (email === null || email === undefined) {
    throw new Error('Email cannot be null or undefined');
  }

  if (email.length === 0 || email.length > 254) {
    return false;
  }

  // Basic email regex pattern
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return emailRegex.test(email);
}
```

**Run tests and verify GREEN:**
```bash
{TEST_CMD}        # Use the detected test runner from Step 1
# Expected: ALL tests PASS (green output)
```

### Step 5: Refactor (IMPROVE Phase)

Improve code quality while keeping tests green:

- Extract constants and magic strings
- Improve variable/function names
- Remove duplication
- Optimize performance (if needed)
- Add comments for complex logic

**Requirements:**
- Run tests after each refactoring step
- Verify all tests still PASS
- Refactoring should not add new functionality

**Example refactored implementation:**
```typescript
const EMAIL_MAX_LENGTH = 254;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Validates an email address format following RFC 5321 basic rules.
 * @param email - The email string to validate
 * @returns true if email matches expected format, false otherwise
 * @throws Error if email is null or undefined
 */
export function validateEmail(email: string): boolean {
  if (email == null) {
    throw new Error('Email cannot be null or undefined');
  }

  if (email.length === 0 || email.length > EMAIL_MAX_LENGTH) {
    return false;
  }

  return EMAIL_PATTERN.test(email);
}
```

**Run tests after EACH refactoring step:**
```bash
{TEST_CMD}        # Use the detected test runner from Step 1
# Expected: ALL tests still PASS (green output)
# Refactor one concern at a time. Stop when code is clean and readable.
```

### Step 6: Verify Coverage

Check code coverage and add tests for any uncovered paths:

**Coverage requirements by code type:**

| Code Type | Minimum Coverage |
|-----------|------------------|
| Standard application code | 80% |
| Financial calculations | 100% |
| Authentication/authorization | 100% |
| Security-critical code | 100% |
| Encryption/decryption | 100% |

**Run coverage check:**
```bash
# Jest
npm test -- --coverage

# Vitest
npx vitest run --coverage

# pytest
pytest --cov=. --cov-report=term-missing

# Go
go test -cover ./...

# Rust
cargo tarpaulin --out Html
```

**Acceptance criteria:**
- Lines covered: ≥ target percentage
- Branches covered: ≥ target percentage
- Functions covered: ≥ target percentage
- Any uncovered lines documented with rationale (if intentional)

**If coverage is below target:**
1. Identify uncovered code paths
2. Write additional tests for those paths
3. Run tests again (verify GREEN)
4. Re-check coverage

---

## Worked Example: Email Validator (Complete Walkthrough)

### RED Phase Output

```
$ npm test

FAIL  src/email-validator.test.ts
  validateEmail
    happy path
      ✕ accepts valid email addresses (0ms)
      ✕ accepts variation formats (1ms)
    edge cases
      ✕ rejects empty string (0ms)
      ✕ rejects email without @ (1ms)
      ✕ rejects email without domain (0ms)
      ✕ rejects email with spaces (0ms)
      ✕ handles special characters (1ms)
    error conditions
      ✕ throws error if email is null (0ms)
      ✕ throws error if email is undefined (0ms)
      ✕ rejects excessively long email (0ms)

Tests:       0 passed, 10 failed, 10 total
```

### GREEN Phase Output (After Implementation)

```
$ npm test

PASS  src/email-validator.test.ts
  validateEmail
    happy path
      ✓ accepts valid email addresses (2ms)
      ✓ accepts variation formats (1ms)
    edge cases
      ✓ rejects empty string (0ms)
      ✓ rejects email without @ (0ms)
      ✓ rejects email without domain (1ms)
      ✓ rejects email with spaces (0ms)
      ✓ handles special characters (1ms)
    error conditions
      ✓ throws error if email is null (0ms)
      ✓ throws error if email is undefined (0ms)
      ✓ rejects excessively long email (0ms)

Tests:       10 passed, 10 total (18ms)
```

### Coverage Report (After Implementation & Refactoring)

```
$ npm test -- --coverage

------------|----------|----------|----------|----------|-------------|
File        | % Stmts  | % Branch | % Funcs  | % Lines   | Uncovered   |
------------|----------|----------|----------|----------|-------------|
All files   |   100    |   100    |   100    |   100     |             |
 email-...ts |   100    |   100    |   100    |   100     |             |
------------|----------|----------|----------|----------|-------------|
```

---

## Anti-Patterns to Avoid

- **Testing implementation details**: Test behavior, not internal state
- **Shared test state**: Each test must be independent (no `beforeAll` side effects)
- **Insufficient assertions**: Verify specific outputs, not just "no error"
- **Untested error paths**: Include tests for error conditions, not just happy path
- **No mocking of external dependencies**: Mock API calls, database, file system, etc.
- **Skipped tests**: Never commit `xit()` or `.skip` — fix the test or remove it

---

## Tips for Success

1. **Write tests first, always** — This forces you to think about the interface before implementation
2. **Fail fast** — The RED phase should show clear test failures before coding
3. **Minimal code** — The simplest code that passes tests is usually the best code
4. **Refactor fearlessly** — Tests are your safety net; they prevent regressions
5. **Coverage is a tool, not a goal** — 80% coverage is a checkpoint, not a target
6. **Test the interface, not the implementation** — Users care about behavior, not how you achieve it

---

## Framework-Specific Commands

### Jest (Node.js/TypeScript)
```bash
# Run all tests
npm test

# Run tests in watch mode
npm test -- --watch

# Run coverage
npm test -- --coverage

# Run specific test file
npm test email-validator.test.ts
```

### Vitest (Vite/TypeScript)
```bash
# Run all tests
npx vitest run

# Run tests in watch mode
npx vitest

# Run coverage
npx vitest run --coverage

# Run specific test file
npx vitest email-validator.test.ts
```

### pytest (Python)
```bash
# Run all tests
pytest

# Run tests in watch mode
pytest --lf (runs last-failed)

# Run coverage
pytest --cov=. --cov-report=term-missing

# Run specific test file
pytest tests/test_email_validator.py
```

### go test (Go)
```bash
# Run all tests
go test ./...

# Run with verbose output
go test -v ./...

# Run coverage
go test -cover ./...

# Run specific test
go test -run TestValidateEmail ./...
```

### cargo test (Rust)
```bash
# Run all tests
cargo test

# Run tests in release mode
cargo test --release

# Run with coverage (requires tarpaulin)
cargo tarpaulin --out Html

# Run specific test
cargo test validate_email
```

---

## Success Checklist

After completing the TDD workflow, verify:

- [ ] Framework detected correctly
- [ ] Tests written BEFORE implementation (RED phase confirmed)
- [ ] All tests PASS (GREEN phase confirmed)
- [ ] Code refactored for clarity and quality
- [ ] Coverage meets requirements (80%+ standard, 100% for critical paths)
- [ ] Test suite includes: happy path, edge cases, error conditions
- [ ] No shared state between tests
- [ ] Meaningful assertion messages
- [ ] Code committed with comprehensive test suite
