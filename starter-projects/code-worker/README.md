# Code Worker Setup

Set up a Ralph loop for autonomous code implementation on your projects.

## What You'll Build

- **Code Worker**: Implements features from PRDs autonomously
- **Back Pressure System**: Verification (tests, types, build) before commits
- **Ralph Loop**: Orchestrated implementation with fresh context per task

## How It Works

The Ralph methodology uses a simple loop:
1. Pick a task from PRD (where `passes: false`)
2. Implement it in a fresh context
3. Run back pressure (typecheck, build, tests)
4. If passing, commit and mark complete
5. Repeat until all tasks pass

## Quick Start

1. Run `/setup` and select "Code Worker"
2. Follow the PRD tasks in order:
   - Configure repository connection
   - Create first PRD with features
   - Run first Ralph loop

## Files Created

```
workers/code/{project}/
├── worker.yaml      # Worker configuration

projects/{project}/
├── prd.json         # Feature tracking
└── README.md        # Project documentation

workspace/checkpoints/
└── {feature-id}.json # Task completion records
```

## Writing Good PRDs

Each feature should be:
- **Atomic**: One thing, not multiple
- **Verifiable**: Clear acceptance criteria
- **Scoped**: Files to modify listed upfront

Example feature:
```json
{
  "id": "F1",
  "title": "Add user authentication",
  "description": "Implement JWT-based auth with login/logout endpoints",
  "acceptance_criteria": [
    "POST /login returns JWT token",
    "POST /logout invalidates token",
    "Protected routes return 401 without valid token"
  ],
  "files": ["src/auth.ts", "src/routes/auth.ts"],
  "passes": false
}
```

## Back Pressure Commands

Customize in worker.yaml based on your stack:

**TypeScript/Node:**
```yaml
verification:
  post_execute:
    - check: typecheck
      command: npm run typecheck
      must_pass: true
    - check: build
      command: npm run build
      must_pass: true
```

**Python:**
```yaml
verification:
  post_execute:
    - check: typecheck
      command: mypy .
      must_pass: true
    - check: test
      command: pytest
      must_pass: true
```

## Next Steps After Setup

- Run `/ralph-loop` to implement features automatically
- Use `/checkpoint` to save progress mid-task
- Add more features to prd.json as you go
