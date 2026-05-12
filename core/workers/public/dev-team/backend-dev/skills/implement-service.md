# implement-service

Create a service/business logic layer.

## Arguments

`$ARGUMENTS` = `--name <ServiceName>` (required)

Optional:
- `--repo <path>` - Target repository
- `--methods <list>` - Comma-separated method names

## Process

1. **Analyze Requirements**
   - Parse service name
   - Infer domain from name
   - Identify dependencies

2. **Check Existing Services**
   - Find service patterns
   - Match conventions
   - Identify shared utilities

3. **Generate Service**
   - Class/module structure
   - Method implementations
   - Dependency injection
   - Type definitions

4. **Add Tests**
   - Unit tests per method
   - Mock dependencies

5. **Present for Approval**

## Output

New files:
- `src/services/{name}.ts`
- `src/services/{name}.test.ts`

## Example

```bash
node dist/index.js implement-service --name "UserService" --methods "create,findById,update,delete"

# Output:
# === Implementing: UserService ===
#
# Methods:
#   - create(data: CreateUserInput): Promise<User>
#   - findById(id: string): Promise<User | null>
#   - update(id: string, data: UpdateUserInput): Promise<User>
#   - delete(id: string): Promise<void>
#
# Dependencies:
#   - Database (Prisma/Drizzle)
#   - EmailService (optional)
#
# [Approve? y/n/modify]
```
