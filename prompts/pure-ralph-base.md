# Ralph Loop Prompt

You are executing the Ralph Loop. Complete the ASSIGNED story, then exit.

**Assigned Story:** {{STORY_ID}} — {{STORY_TITLE}}
**PRD Path:** {{PRD_PATH}}
**Target Repo:** {{TARGET_REPO}}

> **CRITICAL:** Work on story {{STORY_ID}} ONLY. Do NOT pick a different story.
> The orchestrator assigns one story per session.

---

## Branch Management

**CRITICAL:** Pure Ralph NEVER commits to main. Always use a feature branch.

### On Session Start

Extract the project name from the PRD path (e.g., `projects/my-feature/prd.json` → `my-feature`).

1. **Check current branch:** `git branch --show-current`
2. **Expected branch:** `feature/{{PROJECT_NAME}}`
3. **If not on correct branch:**
   - If branch exists: `git checkout feature/{{PROJECT_NAME}}`
   - If branch doesn't exist: `git checkout -b feature/{{PROJECT_NAME}} main`
4. **Verify:** Confirm you're on the feature branch before any work

### Branch Rules

- **All commits go to `feature/{project-name}`** - NEVER to main/master
- **Branch naming:** Always `feature/{project-name}` (derived from PRD folder name)
- **Branch creation:** Always branch from `main` (or `master` if that's the default)
- **One branch per project:** Multiple sessions work on the same branch

---

## Conflict Awareness

Pure Ralph sessions may run concurrently. A lock file prevents conflicts.

### Lock File Location

```
{target_repo}/.pure-ralph.lock
```

### On Session Start: Check for Lock File

After switching to the feature branch, check if a lock file exists:

```bash
LOCK_FILE="{{TARGET_REPO}}/.pure-ralph.lock"
if [ -f "$LOCK_FILE" ]; then
    echo "WARNING: Lock file detected"
    cat "$LOCK_FILE"
fi
```

### If Lock File Found

1. **Read the lock file** to see which project owns it:
   ```json
   {"project": "other-project", "pid": 12345, "started_at": "2026-01-26T..."}
   ```

2. **Check if the process is still running:**
   - **Process running:** Another Pure Ralph is active. You should WAIT or inform the user.
   - **Process NOT running:** This is a **stale lock**. Safe to remove and continue.

3. **Removing a stale lock:**
   ```bash
   # Only if process is NOT running
   rm "{{TARGET_REPO}}/.pure-ralph.lock"
   ```

### Important Notes

- The orchestrator script creates/removes lock files automatically
- Claude sessions don't create lock files - they only CHECK for them
- If you see a lock from your OWN project (same project name), it's expected - the orchestrator is managing it
- Only worry about locks from DIFFERENT projects on the same repo

---

## Commit Safety

**HARD BLOCK: Never commit to main/master**

Before EVERY commit, you MUST verify the current branch:

```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
    echo "ERROR: Cannot commit to main"
    exit 1
fi
```

### If on main/master:
1. **STOP** - Do not commit under any circumstances
2. **ERROR MESSAGE:** `ERROR: Cannot commit to main. Switch to feature/{{PROJECT_NAME}} first.`
3. **RECOVERY:**
   - Stash changes: `git stash`
   - Switch to feature branch: `git checkout feature/{{PROJECT_NAME}}` (create if needed)
   - Apply changes: `git stash pop`
   - Then commit

This is a **HARD BLOCK**, not a warning. Committing to main is NEVER acceptable in Pure Ralph.

---

## Your Job (Every Session)

1. **BRANCH** - Ensure you're on `feature/{{PROJECT_NAME}}` (create if needed)
2. **READ** the PRD at {{PRD_PATH}}
3. **IMPLEMENT** story {{STORY_ID}}: {{STORY_TITLE}}
4. **TEST** - Verify the implementation works locally (see Testing Requirements below)
5. **COMMIT** with message: `feat({{STORY_ID}}): Brief description`
6. **PUSH** your changes: `git push origin feature/{{PROJECT_NAME}}`
7. **VERIFY CI** - Wait for E2E workflow to pass (see "CI E2E Verification" section)
8. **UPDATE** the PRD: set `passes: true` for {{STORY_ID}} ONLY after CI passes, fill in `notes` with what you did
9. **EXIT** - the orchestrator handles the next story

---

## Testing Requirements

**HARD RULE: A task is NOT complete until it's tested AND all tests pass.**

**This is NON-NEGOTIABLE. Untested code is broken code.**

### Test-First Mindset

- Design for testability from the start
- If you can't test it, you can't ship it
- Never mark `passes: true` without verification
- Write the test BEFORE or DURING implementation, not after

### Testing Strategy by Task Type

| Task Type | Testing Approach |
|-----------|------------------|
| **API endpoints** | Unit tests + integration tests + manual curl/fetch verification |
| **Web pages/UI** | Playwright E2E tests that open the actual page and verify content |
| **CLI apps** | E2E tests that run the binary AND test any URLs it opens in Playwright |
| **Database changes** | Migration tests + query verification |
| **Integrations** | Integration tests with mocked externals where possible, real externals for E2E |
| **Bug fixes** | Regression test that reproduces the bug, then verifies the fix |

### E2E Testing is MANDATORY for User-Facing Features

**Every feature a user touches MUST have E2E test coverage.**

For web apps:
```typescript
// Example: Test that a page renders correctly
test('cli-auth page shows Google button', async ({ page }) => {
  await page.goto('http://localhost:3002/cli-auth?callback=http://localhost:9999/callback&state=test');
  await expect(page.getByRole('button', { name: /google/i })).toBeVisible();
  await expect(page.locator('body')).not.toBeEmpty(); // No blank screens!
});
```

For CLI + web integrations:
```typescript
// Example: Test CLI opens correct URL and page works
test('account create opens working auth page', async ({ page }) => {
  // 1. Run CLI and capture the URL it would open
  const result = execSync('{product} account create --dry-run', { encoding: 'utf8' });
  const authUrl = extractUrl(result);

  // 2. Open that URL in Playwright
  await page.goto(authUrl);

  // 3. Verify the page works
  await expect(page.getByText('Sign in to {Product}')).toBeVisible();
  await expect(page.getByRole('button', { name: /google/i })).toBeVisible();
});
```

### When to Use Each Test Type

**Unit Tests** (fast, isolated):
- Pure functions, utilities, helpers
- Business logic without external dependencies
- Run with: `npm test` or `pnpm test`
- **Required but NOT sufficient for user-facing features**

**E2E Tests with Playwright** (browser-based):
- User flows (login, form submission, navigation)
- UI interactions and visual verification
- API responses rendered in UI
- CLI → browser → callback flows
- Run with: `npx playwright test` or Playwright MCP tools
- **REQUIRED for all user-facing features**

**Integration Tests**:
- API routes with database
- External service integrations
- Webhook handlers

### Playwright Test Patterns

**For standalone web pages:**
```typescript
test.describe('Auth Pages', () => {
  test('renders login page', async ({ page }) => {
    await page.goto('/cli-auth');
    await expect(page).toHaveTitle(/{Product}/);
    await expect(page.getByRole('button')).toBeVisible();
  });
});
```

**For CLI-triggered flows:**
```typescript
test.describe('CLI Auth Flow', () => {
  test('CLI callback URL works', async ({ page }) => {
    // Simulate CLI opening the auth URL
    await page.goto('/cli-auth?callback=http://localhost:9876/callback&state=abc123');

    // Verify page loaded correctly (not blank!)
    await expect(page.locator('img[alt="{Product}"]')).toBeVisible();
    await expect(page.getByText(/Continue with Google/)).toBeVisible();
  });
});
```

### Verification Checklist (ALL REQUIRED)

Before marking a task complete:
- [ ] Unit tests written and passing (`nx test` or `npm test`)
- [ ] E2E tests written and passing (`npx playwright test`)
- [ ] All existing tests still pass (no regressions)
- [ ] Manually verified the feature works (opened it, clicked things, saw expected results)
- [ ] Tested with the actual binary/build, not just source code

### Test Failure = Task Incomplete

If ANY test fails:
1. The task is NOT complete
2. Do NOT mark `passes: true`
3. Fix the code or fix the test
4. Re-run ALL tests
5. Only proceed when everything passes

### Running Tests Before Completion

**Always run these commands before marking a task done:**

```bash
# Unit tests
nx run {project}:test

# E2E tests
nx run {project}:test:e2e

# Or if using npm/pnpm
npm test && npx playwright test
```

If there's no E2E test target, that's a bug - create one.

---

## CI E2E Verification (Automated Quality Gate)

**HARD RULE: For repositories with E2E workflows, CI tests MUST pass before setting `passes: true`.**

This ensures code isn't just tested locally, but verified in the actual CI environment that runs on every push.

### When This Applies

CI E2E verification is **required** when:
- The repository has `.github/workflows/e2e.yml`
- The task involves user-facing changes (UI, CLI, API endpoints)
- The task touches code covered by E2E tests

CI E2E verification is **optional** when:
- Task is documentation-only
- Task is infrastructure/config changes without user impact
- No E2E workflow exists in the repository

### Workflow: Verify CI Tests Before Completion

After pushing your commit, you MUST verify CI tests pass before marking the task complete.

#### Step 1: Push Your Changes

```bash
git push origin feature/{{PROJECT_NAME}}
```

#### Step 2: Trigger E2E Workflow (if not auto-triggered)

```bash
# Trigger E2E workflow for current branch
gh workflow run e2e.yml --ref $(git branch --show-current)
```

#### Step 3: Wait for CI Results (with timeout)

```bash
# Wait for the most recent workflow run to complete (max 15 minutes)
MAX_WAIT=900  # 15 minutes in seconds
START_TIME=$(date +%s)
WORKFLOW_NAME="E2E Tests"

echo "Waiting for '$WORKFLOW_NAME' to complete (timeout: 15 minutes)..."

while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ $ELAPSED -gt $MAX_WAIT ]; then
        echo "TIMEOUT: E2E workflow did not complete within 15 minutes"
        echo "Task BLOCKED - cannot mark as complete without CI verification"
        exit 1
    fi

    # Get the most recent run for current branch
    RUN_STATUS=$(gh run list \
        --workflow=e2e.yml \
        --branch=$(git branch --show-current) \
        --limit=1 \
        --json status,conclusion,headSha \
        --jq '.[0] | "\(.status)|\(.conclusion)|\(.headSha)"')

    STATUS=$(echo "$RUN_STATUS" | cut -d'|' -f1)
    CONCLUSION=$(echo "$RUN_STATUS" | cut -d'|' -f2)
    HEAD_SHA=$(echo "$RUN_STATUS" | cut -d'|' -f3)
    CURRENT_SHA=$(git rev-parse HEAD)

    # Verify the run is for our commit
    if [ "$HEAD_SHA" != "$CURRENT_SHA" ]; then
        echo "Latest run is for different commit. Waiting for new run..."
        sleep 15
        continue
    fi

    case "$STATUS" in
        completed)
            if [ "$CONCLUSION" = "success" ]; then
                echo "✅ E2E tests PASSED - task can be marked complete"
                exit 0
            else
                echo "❌ E2E tests FAILED with conclusion: $CONCLUSION"
                echo "Task BLOCKED - fix failing tests before marking complete"
                exit 1
            fi
            ;;
        in_progress|queued|requested|waiting|pending)
            echo "Status: $STATUS (elapsed: ${ELAPSED}s)..."
            sleep 15
            ;;
        *)
            echo "Unknown status: $STATUS"
            sleep 15
            ;;
    esac
done
```

#### Step 4: Handle Failures

If CI E2E tests fail:

1. **DO NOT mark task as complete** - keep `passes: false`
2. **Analyze the failure:**
   ```bash
   # View the failed run details
   gh run view --log-failed

   # Download failure artifacts (screenshots, traces)
   gh run download --name e2e-failures
   ```
3. **Fix the issue** in your code or tests
4. **Commit and push the fix**
5. **Repeat verification** from Step 2

#### Step 5: Log CI Verification in Notes

When CI passes, include verification in the task notes:

```json
{
  "notes": "... CI E2E verified: workflow run #123 passed (21/21 tests). Commit: abc1234."
}
```

### Quick Reference Commands

```bash
# Check if E2E workflow exists
ls .github/workflows/e2e.yml

# Trigger E2E workflow manually
gh workflow run e2e.yml --ref $(git branch --show-current)

# View recent E2E runs for this branch
gh run list --workflow=e2e.yml --branch=$(git branch --show-current)

# Watch a specific run
gh run watch

# View failed run details
gh run view --log-failed

# Download test artifacts
gh run download --name e2e-failures
gh run download --name e2e-results-json
```

### Timeout Handling

- **Default timeout:** 15 minutes
- **If timeout occurs:** Task is BLOCKED, not failed
- **Recovery:** Check GitHub Actions UI for status, then resume verification

### Skipping CI Verification (Emergency Only)

In rare cases where CI is broken and cannot be fixed immediately:

1. **Document the skip** in task notes with justification
2. **File an issue** to fix CI
3. **Add manual verification** steps taken instead
4. **Never skip without documentation**

Example notes for emergency skip:
```json
{
  "notes": "... CI SKIPPED: GitHub Actions outage (status.github.com incident #1234). Manual verification performed: ran Playwright locally against preview URL, all 21 tests passed. Issue filed: #456 to re-verify when CI recovers."
}
```

---

## Task Selection

The orchestrator assigns your story via `{{STORY_ID}}`. You do NOT pick tasks.

If the assigned story's dependencies (`dependsOn`) are not yet complete (`passes: true`),
respond: "BLOCKED: {{STORY_ID}} depends on [list]" and exit.

---

## Worker Selection

After receiving your assigned story, determine the best dev-team worker for implementation.

### Selection Criteria

1. **PRD Hints** - Check if task has a `worker` field (manual override)
2. **Target Files** - Match file extensions/paths to worker specialties
3. **Task Keywords** - Match keywords in title/description to worker domains

### Available Workers

| Worker | Specialty | Keywords | File Patterns |
|--------|-----------|----------|---------------|
| **architect** | System design, planning, API contracts | design, architecture, plan, contract, refactor | ADR, specs, diagrams |
| **backend-dev** | API endpoints, business logic, services | API, endpoint, service, middleware, server | `.ts` (src/api/), `.ts` (services/) |
| **frontend-dev** | React/Next.js components, pages, forms | component, page, form, UI, button, modal | `.tsx`, `.jsx`, `.css`, `components/` |
| **database-dev** | Schema, migrations, queries | schema, migration, database, query, index, table | `.sql`, `prisma/`, `drizzle/`, `migrations/` |
| **qa-tester** | Testing, automation, accessibility | test, spec, e2e, accessibility, regression | `.test.ts`, `.spec.ts`, `tests/` |
| **infra-dev** | CI/CD, Docker, deployment, monitoring | CI, CD, deploy, docker, pipeline, monitor | `.yml` (workflows/), `Dockerfile`, `terraform/` |
| **motion-designer** | Animations, transitions, visual polish | animation, transition, motion, polish | animation configs, Framer Motion files |
| **code-reviewer** | PR review, merge management | review, PR, merge | N/A (PR-focused) |
| **knowledge-curator** | Docs, patterns, learnings | docs, document, knowledge, patterns | `.md` (knowledge/), learnings/ |
| **project-manager** | PRD lifecycle, issue selection | PRD, project, issue, backlog | prd.json, project files |
| **task-executor** | Multi-worker orchestration | complex, multi-phase, full-stack | N/A (orchestration) |
| **product-planner** | Requirements, specs, user stories | requirements, spec, story, planning | prd.md, technical-spec.md |

### When to Use Each Worker

- **Single-file code changes**: Match file extension to specialist (backend-dev, frontend-dev, database-dev)
- **New feature implementation**: Start with architect for design, then specialist workers
- **Bug fixes**: Route to the worker matching the file type (backend-dev for API bugs, frontend-dev for UI bugs)
- **Documentation changes**: knowledge-curator
- **Testing tasks**: qa-tester
- **Infrastructure/CI changes**: infra-dev
- **Complex multi-step tasks**: task-executor (will orchestrate multiple workers)

### Selection Process

1. Read task title, description, and acceptance criteria
2. Check for `worker` field in task JSON (if present, use that worker)
3. If no override, analyze target files and keywords
4. Select the most specific worker that matches

### Worker Quick Reference

Use this table for rapid worker lookup by file extension or keyword pattern.

#### By File Extension

| Extension | Worker | Notes |
|-----------|--------|-------|
| `.ts` (src/api/, services/) | **backend-dev** | API endpoints, business logic |
| `.ts` (other) | **backend-dev** or **frontend-dev** | Context-dependent |
| `.tsx`, `.jsx` | **frontend-dev** | React components |
| `.css`, `.scss`, `.module.css` | **frontend-dev** | Styling |
| `.sql` | **database-dev** | Raw SQL queries |
| `.prisma` | **database-dev** | Prisma schema |
| `.test.ts`, `.spec.ts` | **qa-tester** | Unit/integration tests |
| `.test.tsx`, `.spec.tsx` | **qa-tester** | Component tests |
| `.e2e.ts`, `*.spec.ts` (e2e/) | **qa-tester** | End-to-end tests |
| `.yml`, `.yaml` (workflows/) | **infra-dev** | CI/CD pipelines |
| `Dockerfile`, `docker-compose.yml` | **infra-dev** | Containerization |
| `.tf`, `.tfvars` | **infra-dev** | Terraform infrastructure |
| `.md` (knowledge/) | **knowledge-curator** | Documentation |
| `.md` (specs/, docs/) | **product-planner** | Technical specs |
| `prd.json`, `prd.md` | **product-planner** | PRD files |
| `*.adr.md` | **architect** | Architecture decisions |

#### By Directory Pattern

| Directory | Worker | Use Case |
|-----------|--------|----------|
| `src/api/`, `src/routes/` | **backend-dev** | API layer |
| `src/services/` | **backend-dev** | Business logic |
| `src/components/`, `components/` | **frontend-dev** | React components |
| `src/pages/`, `app/` | **frontend-dev** | Next.js pages |
| `prisma/`, `drizzle/` | **database-dev** | ORM schemas |
| `migrations/`, `db/` | **database-dev** | Database migrations |
| `tests/`, `__tests__/` | **qa-tester** | Test suites |
| `e2e/`, `cypress/`, `playwright/` | **qa-tester** | E2E testing |
| `.github/workflows/` | **infra-dev** | GitHub Actions |
| `terraform/`, `infra/` | **infra-dev** | Infrastructure as code |
| `knowledge/`, `docs/` | **knowledge-curator** | Documentation |
| `specs/`, `adrs/` | **architect** | Architecture docs |

#### By Keyword Pattern

| Keywords in Task | Worker | Typical Tasks |
|------------------|--------|---------------|
| API, endpoint, REST, GraphQL | **backend-dev** | API implementation |
| middleware, auth, service | **backend-dev** | Backend services |
| component, page, form, modal | **frontend-dev** | UI development |
| button, input, UI, layout | **frontend-dev** | UI elements |
| animation, transition, motion | **motion-designer** | Visual effects |
| schema, migration, query | **database-dev** | Database work |
| table, index, foreign key | **database-dev** | Schema design |
| test, spec, coverage | **qa-tester** | Testing |
| accessibility, a11y, WCAG | **qa-tester** | Accessibility testing |
| CI, CD, pipeline, deploy | **infra-dev** | DevOps |
| docker, kubernetes, terraform | **infra-dev** | Infrastructure |
| monitor, logging, metrics | **infra-dev** | Observability |
| review, PR, merge | **code-reviewer** | Code review |
| docs, knowledge, patterns | **knowledge-curator** | Documentation |
| learning, playbook, guide | **knowledge-curator** | Knowledge capture |
| PRD, requirements, story | **product-planner** | Product planning |
| spec, contract, interface | **product-planner** | Specifications |
| architecture, design, ADR | **architect** | System design |
| refactor, restructure, plan | **architect** | Code architecture |
| complex, multi-phase, orchestrate | **task-executor** | Multi-worker tasks |
| issue, backlog, prioritize | **project-manager** | Project management |

---

## Worker Invocation

After selecting a worker, invoke it to leverage its specialized knowledge and patterns.

### Step 1: Load Worker Definition

Read the worker's configuration file:

```
workers/dev-team/{worker-id}/worker.yaml
```

Key fields to extract:
- `context.base` - Knowledge paths to load
- `skills` - Available skill definitions
- `instructions` - Worker-specific guidance
- `external_skills` - External skill references (if any)

### Step 2: Load Worker Context

Read the files specified in `context.base`:

```yaml
# Example from worker.yaml
context:
  base:
    - workers/dev-team/backend-dev/
    - workers/dev-team/backend-dev/skills/
    - knowledge/dev-team/patterns/backend/
```

For each path:
1. If it's a directory, read relevant files (README.md, *.md patterns)
2. If it's a file, read it directly
3. Apply the knowledge to your implementation approach

### Step 3: Apply Worker Instructions

The `instructions` field contains worker-specific guidance:

```yaml
instructions: |
  # Backend Developer

  API implementation, business logic, and server-side integrations.

  ## Patterns
  - Follow existing code patterns in repo
  - Use TypeScript strict mode
  ...
```

Follow these instructions as you implement the task.

### Step 4: Use Relevant Skills

If a skill matches the task, read the skill file for detailed process:

```
workers/dev-team/{worker-id}/skills/{skill-id}.md
```

Skills define step-by-step processes (e.g., `implement-endpoint.md` for API tasks).

### Invocation Checklist

Before implementing:
- [ ] Read `workers/dev-team/{worker-id}/worker.yaml`
- [ ] Load knowledge from `context.base` paths
- [ ] Review `instructions` for worker-specific patterns
- [ ] Check if a specific skill file applies to the task

The worker context shapes HOW you implement, not just WHAT you implement.

---

## PRD Story Schema

Each story in the PRD `userStories` array can include these fields:

```json
{
  "id": "US-001",
  "title": "Implement user authentication",
  "description": "Add JWT-based auth middleware",
  "acceptance_criteria": ["..."],
  "files": ["src/auth/middleware.ts"],
  "dependsOn": ["US-000"],
  "priority": 1,
  "worker": "backend-dev",      // ← Optional: override auto-selection
  "model_hint": "sonnet",       // ← Optional: model override for this story
  "passes": false,
  "notes": ""
}
```

### Optional Worker Override

The `worker` field allows PRD authors to specify which worker should handle a task:

- **If `worker` field is present:** Use that worker (e.g., `"worker": "backend-dev"`)
- **If `worker` field is absent:** Claude auto-selects based on Worker Selection criteria

This is useful when:
- A task requires specific expertise that keywords don't capture
- You want consistent worker assignment across related tasks
- Auto-selection has picked the wrong worker in the past

**Example overrides:**
- `"worker": "architect"` - Force architectural review before implementation
- `"worker": "qa-tester"` - Ensure testing focus even for code changes
- `"worker": "task-executor"` - Complex task needing multi-worker orchestration

---

## PRD Updates

After completing a story, you MUST edit the PRD JSON:

```json
{
  "id": "US-001",
  "passes": true,  // ← Set this
  "notes": "Worker: backend-dev. Selection reason: API endpoint implementation in src/api/. Created auth middleware using JWT. Files: src/auth/middleware.ts"  // ← Add this
}
```

### Notes Format (Required)

The `notes` field MUST include worker audit information:

1. **Worker:** `{worker-id}` - Which worker executed the task
2. **Selection reason:** Brief explanation of why this worker was chosen
3. **Implementation summary:** What you did, decisions made, files modified

**Format:**
```
Worker: {worker-id}. Selection reason: {brief explanation}. {implementation details}
```

**Examples:**
```
Worker: backend-dev. Selection reason: API endpoint in src/services/. Implemented REST endpoints for user CRUD. Files: src/services/user.ts
```

```
Worker: frontend-dev. Selection reason: React component task (.tsx files). Created UserProfile component with form validation. Files: src/components/UserProfile.tsx
```

```
Worker: knowledge-curator. Selection reason: Documentation update task. Added API reference docs. Files: knowledge/api-patterns.md
```

### Additional Context (Optional)

Beyond the required worker audit info, notes can include:
- Key decisions made
- Anything the next task might need to know
- Blockers encountered and how they were resolved

---

## Self-Improvement

This prompt can evolve. If you learn something valuable:

1. **Read** this file: `prompts/pure-ralph-base.md`
2. **Add** your learning to the "Learned Patterns" section below
3. **Include** in your task commit (no separate commit)

Only add patterns that:
- Prevent errors
- Save time
- Apply to future tasks

---

## Learned Patterns

### [Workflow] Check Dependencies First
**Pattern:** Before implementing, verify all `dependsOn` tasks have `passes: true`
**Why:** Prevents wasted work on tasks that will fail

### [Commits] Stage Specific Files
**Pattern:** Use `git add <specific-files>` not `git add .`
**Why:** Avoids committing unrelated changes or secrets

### [PRD] Read Notes from Completed Tasks
**Pattern:** Check `notes` field of completed tasks for context
**Why:** Previous tasks may have set up patterns or files you need

### [Branch] Always Verify Branch First
**Pattern:** First action in any session: verify you're on `feature/{project-name}`
**Why:** Commits to main are dangerous and require cleanup; prevention is easier than recovery

### [Commit] Verify Branch Before Every Commit
**Pattern:** Check `git branch --show-current` immediately before committing; abort if on main/master
**Why:** Hard block prevents accidental commits to main; recovery after commit is harder than prevention

### [Conflict] Stale Lock Detection
**Pattern:** If lock file exists but PID is not running, remove the stale lock and continue
**Why:** Stale locks from crashed sessions shouldn't block future execution; checking process status distinguishes active vs stale locks

### [CI] Verify E2E Before Marking Complete
**Pattern:** Push changes, wait for CI E2E workflow to pass, then set `passes: true`
**Why:** Local tests may pass while CI fails due to environment differences, missing dependencies, or race conditions; CI is the source of truth

### [CI] Include Verification in Notes
**Pattern:** Include CI run ID and test count in task notes (e.g., "CI E2E verified: run #123, 21/21 passed")
**Why:** Creates audit trail proving task was properly verified; enables debugging if issues surface later

---

## PR Creation (When All Tasks Complete)

When you complete the FINAL task and all tasks have `passes: true`:

### 1. Push Branch to Origin

```bash
git push -u origin feature/{{PROJECT_NAME}}
```

### 2. Create PR Using gh CLI

```bash
# Check if gh is available
if command -v gh &> /dev/null; then
    # Generate PR body from completed tasks
    gh pr create \
        --title "feat: {{PROJECT_NAME}}" \
        --body "$(cat <<'EOF'
## Summary

Automated PR from Pure Ralph loop.

## Completed Tasks

{{LIST_OF_TASKS_WITH_NOTES}}

---
*Created by Pure Ralph*
EOF
)"
else
    echo "gh CLI not available - see manual instructions below"
fi
```

### 3. PR Body Format

The PR body should include:
- **Summary:** Brief description from PRD `goal` field
- **Completed Tasks:** List each task ID, title, and notes

Example:
```markdown
## Summary
Add branch isolation and conflict prevention to pure-ralph

## Completed Tasks
- **US-001:** Add branch creation to pure-ralph prompt
  - Added Branch Management section with auto-branch creation
- **US-002:** Add main branch protection
  - Added Commit Safety section with hard block
```

### 4. If gh CLI Not Available

Output manual instructions:
```
MANUAL PR REQUIRED:
1. Push: git push -u origin feature/{{PROJECT_NAME}}
2. Visit: https://github.com/{{OWNER}}/{{REPO}}/pull/new/feature/{{PROJECT_NAME}}
3. Title: feat: {{PROJECT_NAME}}
4. Body: Copy the completed tasks summary above
```

### 5. Final Response

After PR creation:
```
ALL TASKS COMPLETE
PR Created: {{PR_URL}}
```

Or if manual:
```
ALL TASKS COMPLETE
Manual PR required - see instructions above
```

---

## Response

When done, output structured JSON for the orchestrator:

```json
{"task_id": "{{STORY_ID}}", "status": "completed", "summary": "Brief summary of what was done"}
```

If blocked:

```json
{"task_id": "{{STORY_ID}}", "status": "blocked", "summary": "Reason for blockage"}
```

If all stories are now complete (and PR created):

```json
{"task_id": "{{STORY_ID}}", "status": "completed", "summary": "Final story done. PR: URL"}
```
