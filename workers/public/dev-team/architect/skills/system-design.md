# system-design

Design system architecture for a feature or component.

## Arguments

`$ARGUMENTS` = `--feature <description>` (required)

Optional:
- `--repo <path>` - Target repository
- `--scope <small|medium|large>` - Scope of design

## Process

1. **Analyze Existing Architecture**
   - Read project structure
   - Identify patterns in use
   - Map dependencies

2. **Understand Requirements**
   - Parse feature description
   - Identify components affected
   - List integration points

3. **Design Options**
   - Generate 2-3 approaches
   - Evaluate trade-offs
   - Consider future extensibility

4. **Present for Approval**
   - Show options with pros/cons
   - Recommend preferred approach
   - Wait for human decision

5. **Document Decision**
   - Create ADR (Architecture Decision Record)
   - Define interfaces
   - Outline implementation steps

## Output

Architecture decision record:
```markdown
# ADR: {Feature Name}

## Status
Proposed

## Context
{Why this decision is needed}

## Options Considered
1. Option A: {Description}
   - Pro: ...
   - Con: ...

2. Option B: {Description}
   - Pro: ...
   - Con: ...

## Decision
{Chosen approach and why}

## Consequences
- {Impact 1}
- {Impact 2}

## Implementation Guide
{Steps for other workers}
```

## Example

```bash
node dist/index.js system-design --feature "user authentication with OAuth" --repo repos/my-app

# Output:
# === System Design: User Authentication with OAuth ===
#
# Existing patterns:
#   - Next.js App Router
#   - Prisma ORM
#   - No current auth system
#
# Options:
#
# 1. NextAuth.js (Recommended)
#    Pro: Battle-tested, supports many providers
#    Con: Opinionated, some flexibility limits
#
# 2. Custom OAuth implementation
#    Pro: Full control
#    Con: More work, security risks
#
# 3. Clerk/Auth0 (managed service)
#    Pro: Zero maintenance
#    Con: Vendor lock-in, cost
#
# [Select approach: 1/2/3]
```
