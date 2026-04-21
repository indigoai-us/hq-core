# Dev Workflows

Standard worker sequences for common task types.

## Available Workflows

### new-api-endpoint
For creating new API endpoints.
```
architect → database-dev → backend-dev → qa-tester
```

### new-ui-feature
For pure frontend features.
```
architect → frontend-dev → motion-designer → qa-tester
```

### full-stack-feature
For features touching both frontend and backend.
```
architect → database-dev → backend-dev → frontend-dev → qa-tester
```

### bug-fix
For fixing reported bugs.
```
qa-tester (reproduce) → backend-dev/frontend-dev → qa-tester (verify)
```

### refactor
For code refactoring.
```
architect (plan) → backend-dev/frontend-dev → code-reviewer → qa-tester
```

### infrastructure
For CI/CD and deployment changes.
```
architect → infra-dev → qa-tester
```

## Workflow Selection

Task executor analyzes issue and selects appropriate workflow based on:
- Issue labels/tags
- Files likely to be modified
- PRD worker_hints field
- Similar past issues
