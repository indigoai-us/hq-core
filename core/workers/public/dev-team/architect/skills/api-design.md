# api-design

Design API contracts and interfaces.

## Arguments

`$ARGUMENTS` = `--endpoint <path>` or `--feature <name>` (required)

Optional:
- `--repo <path>` - Target repository
- `--format <openapi|typescript>` - Output format

## Process

1. **Analyze Existing APIs**
   - Read current route structure
   - Identify naming conventions
   - Check authentication patterns

2. **Define Contract**
   - Request/response schemas
   - Error handling patterns
   - Authentication requirements

3. **Generate Interfaces**
   - TypeScript types
   - OpenAPI spec (if requested)
   - Validation schemas

4. **Present for Review**
   - Show proposed contract
   - Highlight breaking changes
   - Get approval

## Output

TypeScript interface:
```typescript
// API Contract: POST /api/auth/login
export interface LoginRequest {
  email: string;
  password: string;
  rememberMe?: boolean;
}

export interface LoginResponse {
  user: {
    id: string;
    email: string;
    name: string;
  };
  token: string;
  expiresAt: string;
}

export interface LoginError {
  code: 'INVALID_CREDENTIALS' | 'ACCOUNT_LOCKED' | 'RATE_LIMITED';
  message: string;
}
```

## Example

```bash
node dist/index.js api-design --feature "user authentication" --repo repos/my-app

# Output:
# === API Design: User Authentication ===
#
# Proposed endpoints:
#
# POST /api/auth/login
#   Request: { email, password, rememberMe? }
#   Response: { user, token, expiresAt }
#   Errors: INVALID_CREDENTIALS, ACCOUNT_LOCKED, RATE_LIMITED
#
# POST /api/auth/logout
#   Request: {} (auth header required)
#   Response: { success: true }
#
# GET /api/auth/me
#   Request: {} (auth header required)
#   Response: { user }
#
# Generated types:
#   src/types/auth.ts
#
# [Approve contract? y/n/modify]
```
