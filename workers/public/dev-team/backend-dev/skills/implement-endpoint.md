# implement-endpoint

Create a new API endpoint based on specification.

## Arguments

`$ARGUMENTS` = `--spec <method path>` (required, e.g., "POST /api/users")

Optional:
- `--repo <path>` - Target repository
- `--types <file>` - TypeScript types file to use

## Process

1. **Parse Specification**
   - Extract HTTP method
   - Extract path and parameters
   - Identify resource and action

2. **Analyze Existing Patterns**
   - Find API routes in repo
   - Match naming conventions
   - Identify auth patterns

3. **Generate Implementation**
   - Route handler
   - Input validation
   - Business logic call
   - Response formatting
   - Error handling

4. **Add Tests**
   - Unit test for handler
   - Integration test if applicable

5. **Present for Approval**
   - Show generated code
   - Get human approval

## Output

New files:
- `src/app/api/{resource}/route.ts` (Next.js) or
- `src/routes/{resource}.ts` (Express)

Test files:
- `src/app/api/{resource}/route.test.ts`

## Example

```bash
node dist/index.js implement-endpoint --spec "POST /api/auth/login" --repo repos/my-app

# Output:
# === Implementing: POST /api/auth/login ===
#
# Pattern detected: Next.js App Router
#
# Will create:
#   src/app/api/auth/login/route.ts
#   src/app/api/auth/login/route.test.ts
#
# Implementation:
#   - Validate email/password input
#   - Call AuthService.login()
#   - Return user + token
#   - Handle errors (400, 401, 500)
#
# [Approve? y/n/modify]
```
