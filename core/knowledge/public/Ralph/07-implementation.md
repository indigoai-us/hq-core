---
type: guide
domain: [engineering]
status: canonical
tags: [ralph, implementation, setup, prerequisites, getting-started]
relates_to: []
---

# Practical Implementation

## Prerequisites

Before implementing Ralph, you need:

1. **AI Coding Tool**
   - Claude Code (Anthropic)
   - Cursor
   - Other CLI-based AI tools

2. **Project Setup**
   - Version control (git)
   - Test framework
   - Linter
   - Type checking (if applicable)

3. **Specification Files**
   - PRD in JSON format
   - agents.md configuration
   - Progress tracking file

## Basic Ralph Script

### Minimal Implementation

```bash
#!/bin/bash
# ralph.sh - Basic Ralph loop

ITERATIONS=${1:-10}  # Default 10 iterations

for i in $(seq 1 $ITERATIONS); do
    echo "=== Ralph Loop Iteration $i ==="

    claude --print "Read plans/prd.json and find the first feature where passes is false.

    Implement ONLY that feature.

    Then run these commands in order:
    1. npm test
    2. npm run lint
    3. npm run typecheck
    4. npm run build

    If ALL pass:
    1. Commit the changes with a descriptive message
    2. Update plans/prd.json to set passes: true for this feature
    3. Append progress to progress.txt

    If ANY fail:
    1. Fix the issues
    2. Try again

    Exit when done with this ONE feature."

    echo "Completed iteration $i"
    sleep 2
done

echo "Ralph loop complete!"
```

### Running It

```bash
chmod +x ralph.sh
./ralph.sh 20  # Run 20 iterations
```

## File Structure

```
project/
├── ralph.sh              # The loop script
├── agents.md             # Agent configuration
├── plans/
│   └── prd.json          # Product requirements
├── progress.txt          # Progress log
├── src/                  # Source code
├── tests/                # Test files
├── package.json          # Dependencies
└── tsconfig.json         # TypeScript config
```

## Sample PRD Template

```json
{
  "project": "my-project",
  "updated": "2026-01-13",
  "features": [
    {
      "id": "init-001",
      "title": "Project Setup",
      "description": "Initialize project with basic structure",
      "acceptance_criteria": [
        "package.json exists with correct dependencies",
        "TypeScript configured with strict mode",
        "Jest configured for testing",
        "ESLint configured with recommended rules"
      ],
      "passes": true
    },
    {
      "id": "feat-001",
      "title": "User Authentication",
      "description": "Implement login functionality",
      "acceptance_criteria": [
        "Login form with email and password",
        "Form validation for required fields",
        "API call to /auth/login endpoint",
        "Error handling for failed login",
        "Redirect to dashboard on success"
      ],
      "passes": false
    }
  ]
}
```

## Sample agents.md Template

```markdown
# Project: My Project

## Tech Stack
- TypeScript 5.x
- React 18.x
- Jest for testing
- ESLint for linting

## Commands
| Command | Purpose |
|---------|---------|
| `npm run dev` | Start dev server |
| `npm run build` | Production build |
| `npm test` | Run all tests |
| `npm run lint` | Run linter |
| `npm run typecheck` | Type check |

## Task Protocol

### When implementing a feature:
1. Read the feature spec from plans/prd.json
2. Implement the minimum code to satisfy acceptance criteria
3. Write tests for the new functionality
4. Run verification: `npm test && npm run lint && npm run typecheck`
5. If verification passes, commit and update PRD
6. Log progress to progress.txt

### Commit message format:
```
feat(scope): short description

- Bullet point details

Implements: feature-id
```

### Never:
- Modify multiple features in one iteration
- Skip running tests
- Use `any` type
- Leave console.logs in production code

## Project Structure
- src/components/ - React components
- src/hooks/ - Custom hooks
- src/services/ - API services
- src/types/ - TypeScript types
- tests/ - Test files
```

## Advanced: Visual Feedback Loop

For frontend applications, add browser automation:

### MCP Configuration

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["@anthropic/mcp-server-chrome-devtools"],
      "env": {
        "CHROME_DEBUG_URL": "http://localhost:9222"
      }
    }
  }
}
```

### Chrome Launch Script

```bash
#!/bin/bash
# start-chrome-debug.sh
google-chrome --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-debug
```

### Updated Ralph Script with Visual

```bash
#!/bin/bash
# ralph-visual.sh - Ralph with visual feedback

# Start Chrome in debug mode (background)
./start-chrome-debug.sh &
CHROME_PID=$!

# Wait for Chrome to start
sleep 3

for i in $(seq 1 $ITERATIONS); do
    claude --print "Read plans/prd.json, find first incomplete feature.

    Implement the feature, then:
    1. Run npm test, lint, typecheck
    2. Use Chrome DevTools MCP to take screenshots
    3. Verify the UI looks correct
    4. If all checks pass, commit
    5. Update PRD and progress.txt"
done

# Cleanup
kill $CHROME_PID
```

## Running Overnight

### With tmux

```bash
# Start a tmux session
tmux new-session -d -s ralph

# Run Ralph in the session
tmux send-keys -t ralph './ralph.sh 100' Enter

# Detach and go to sleep
# Next morning:
tmux attach-session -t ralph
```

### With nohup

```bash
nohup ./ralph.sh 100 > ralph.log 2>&1 &
echo $! > ralph.pid

# Check progress
tail -f ralph.log

# Stop if needed
kill $(cat ralph.pid)
```

## Monitoring Progress

### Simple Progress Check

```bash
# See current status
cat progress.txt | tail -20

# Count completed features
grep -c '"passes": true' plans/prd.json
```

### Progress Dashboard Script

```bash
#!/bin/bash
# status.sh

echo "=== Ralph Status ==="
echo ""
echo "Completed features:"
grep -c '"passes": true' plans/prd.json

echo ""
echo "Remaining features:"
grep -c '"passes": false' plans/prd.json

echo ""
echo "Recent progress:"
tail -10 progress.txt

echo ""
echo "Git log:"
git log --oneline -5
```

## Troubleshooting

### Loop Gets Stuck
- Check if tests are flaky
- Verify acceptance criteria is achievable
- Look at progress.txt for error patterns

### Context Window Exhaustion
- Make features smaller
- Clear conversation between iterations
- Use `--print` flag for fresh context

### Slow Iterations
- Optimize test suite
- Use faster type checker settings
- Consider language choice (TypeScript > Rust)

### Quality Issues
- Add more specific acceptance criteria
- Strengthen back pressure (more tests)
- Add code review step for critical features
