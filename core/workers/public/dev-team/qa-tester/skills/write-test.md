# write-test

Write a new test for a feature or function.

## Arguments

`$ARGUMENTS` = `--target <file|function>` (required)

Optional:
- `--repo <path>` - Target repository
- `--type <unit|integration|e2e>` - Test type

## Process

1. Analyze target code
2. Identify test cases
3. Generate test file
4. Add to test suite
5. Verify tests pass

## Output

New test file with:
- Setup/teardown
- Happy path tests
- Edge cases
- Error handling tests
