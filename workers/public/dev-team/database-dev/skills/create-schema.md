# create-schema

Design database schema for a feature.

## Arguments

`$ARGUMENTS` = `--entity <name>` or `--feature <description>` (required)

Optional:
- `--repo <path>` - Target repository
- `--orm <prisma|drizzle>` - ORM to use

## Process

1. Analyze existing schema
2. Design new tables/models
3. Define relationships
4. Add indexes for common queries
5. Present for approval

## Output

- Schema definition (Prisma/Drizzle)
- Relationship diagram (Mermaid)
- Migration file

## Example

```bash
node dist/index.js create-schema --entity "Comment" --repo repos/my-app

# Output:
# === Schema Design: Comment ===
#
# model Comment {
#   id        String   @id @default(cuid())
#   content   String
#   authorId  String
#   postId    String
#   author    User     @relation(fields: [authorId], references: [id])
#   post      Post     @relation(fields: [postId], references: [id])
#   createdAt DateTime @default(now())
# }
#
# Indexes: authorId, postId, createdAt
#
# [Approve? y/n/modify]
```
