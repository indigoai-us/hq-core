# Dev Team Knowledge Base

Shared knowledge for the dev-team worker system.

## Structure

```
dev-team/
├── patterns/          # Reusable code patterns discovered during execution
├── workflows/         # Standard worker sequences for common task types
└── troubleshooting/   # Common issues and fixes
```

## Patterns

Patterns are extracted from successful task completions:

- Backend patterns: API design, error handling, auth flows
- Frontend patterns: Component structure, state management
- Database patterns: Schema design, query optimization
- Testing patterns: E2E strategies, mocking approaches

## Workflows

Standard worker sequences:

- **new-api-endpoint**: architect → database-dev → backend-dev → qa-tester
- **new-ui-feature**: architect → frontend-dev → motion-designer → qa-tester
- **full-stack-feature**: architect → database-dev → backend-dev → frontend-dev → qa-tester
- **bug-fix**: qa-tester (reproduce) → backend-dev/frontend-dev → qa-tester (verify)

## Troubleshooting

Common issues encountered during development:

- Build failures and resolutions
- Test flakiness patterns
- Integration issues between workers

&nbsp;