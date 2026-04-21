# Dev Team Worker System

Multi-worker system for software development with intelligent task routing, sub-agent spawning, and learning loops.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PROJECT MANAGER                          │
│  • Owns PRD lifecycle                                       │
│  • Selects next issue from project                          │
│  • Spawns Task Executor per issue                           │
│  • Aggregates learnings → knowledge base                    │
└─────────────────────┬───────────────────────────────────────┘
                      │ spawns per issue
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    TASK EXECUTOR                            │
│  • Analyzes issue requirements                              │
│  • Determines worker sequence                               │
│  • Spawns workers as Task subagents                         │
│  • Validates completion, retries on failure                 │
│  • Reports learnings back to Project Manager                │
└─────────────────────┬───────────────────────────────────────┘
                      │ spawns per phase
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  SPECIALIZED WORKERS                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│  │ Architect│ │ Backend  │ │ Frontend │ │    QA    │       │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│  │ Database │ │  Infra   │ │  Motion  │ │Code Review│      │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │
└─────────────────────────────────────────────────────────────┘
```

## Workers

| Worker | Purpose | Key Skills |
|--------|---------|------------|
| **project-manager** | PRD lifecycle, issue selection | next-issue, create-prd, update-learnings |
| **task-executor** | Route to workers, validate | execute, analyze-issue, validate-completion |
| **architect** | System design, planning | system-design, api-design, refactor-plan |
| **backend-dev** | API, business logic | implement-endpoint, implement-service |
| **database-dev** | Schema, migrations | create-schema, create-migration, optimize-query |
| **qa-tester** | Testing, automation | run-tests, write-test, create-demo-account |
| **frontend-dev** | React/Next components | create-component, create-page, add-form |
| **motion-designer** | Animations, polish | add-animation, generate-image (via gnb) |
| **infra-dev** | CI/CD, deployment | setup-cicd, create-dockerfile, add-monitoring |
| **code-reviewer** | PR review, merge | review-pr, merge-to-staging, merge-to-production |
| **knowledge-curator** | Learnings, docs | process-learnings, update-patterns |

## Usage

### Start a Project
```bash
# Create PRD
/run project-manager create-prd --name "my-feature"

# Get next issue
/run project-manager next-issue --project "my-feature"
```

### Execute a Task
```bash
# Execute specific issue
/run task-executor execute --issue "US-001" --project "my-feature"
```

### Individual Workers
```bash
# Design system
/run architect system-design --spec "User authentication system"

# Create API endpoint
/run backend-dev implement-endpoint --name "login" --repo ~/repos/my-app

# Review PR
/run code-reviewer review-pr --pr 123 --repo ~/repos/my-app
```

## Task Format

**PRD** (project level):
```json
{
  "project": "feature-x",
  "epics": [{
    "id": "E1",
    "title": "User Authentication",
    "stories": [{
      "id": "US-001",
      "title": "Login flow",
      "acceptance_criteria": [...],
      "priority": 1,
      "passes": false,
      "worker_hints": ["architect", "backend-dev", "frontend-dev", "qa-tester"]
    }]
  }]
}
```

**Beads**: Stories → beads epics, acceptance criteria → child beads (via `bd` CLI)

## Human-in-the-Loop

Every phase surfaces decisions:
- Approve worker sequence before execution
- Inject context at any phase
- Approve changes before commit
- Confirm production deployments
- On ambiguity: escalate, never auto-decide

## Learning Loop

```
Task Executor completes issue
        ↓
Extract learnings (what worked, what failed, patterns)
        ↓
knowledge-curator routes to:
  - projects/{name}/learnings/
  - knowledge/public/dev-team/patterns/
  - workers/{worker}/knowledge/
```

## Directory Structure

```
workers/public/dev-team/
├── README.md
├── project-manager/
├── task-executor/
├── architect/
├── backend-dev/
├── database-dev/
├── qa-tester/
├── frontend-dev/
├── motion-designer/
├── infra-dev/
├── code-reviewer/
└── knowledge-curator/

knowledge/public/dev-team/
├── patterns/
├── workflows/
└── troubleshooting/
```

## Building Workers

```bash
cd workers/public/dev-team/<worker>
npm install
npm run build
npm run typecheck
```

## Integrated Tools

- **beads** (`bd` CLI) - Task tracking
- **gnb** (gemini-nano-banana) - Image generation
- **Playwright** - Browser automation for QA
- **GitHub CLI** (`gh`) - PR/issue management
- **skills.sh** - Reusable development skills
