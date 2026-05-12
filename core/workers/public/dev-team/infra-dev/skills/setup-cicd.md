# setup-cicd

Set up CI/CD pipeline for repository.

## Arguments

`$ARGUMENTS` = `--repo <path>` (required)

Optional:
- `--platform <github|gitlab|bitbucket>` - CI platform (default: github)
- `--type <nodejs|python|go|rust>` - Project type
- `--include-deploy` - Include deployment stage

## Codex Execution

```bash
cd {repo} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {repo} \
  "Set up CI/CD pipeline for this {project_type} project on {platform}. Include build, lint, test, security scan stages. Follow existing workflow patterns if present." 2>&1
```

## Process

1. Detect project type from package.json/requirements.txt/go.mod/Cargo.toml
2. Analyze existing workflow files (if any)
3. Design pipeline stages:
   - Build
   - Lint
   - Test
   - Security scan
   - Deploy (if --include-deploy)
4. Generate workflow file(s)
5. Add branch protection rules (suggest)
6. Present for human approval

## Output

- `.github/workflows/ci.yml` (or equivalent)
- Branch protection recommendations
- Required secrets list

## GitHub Actions Template

```yaml
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm run build
      - run: npm run lint
      - run: npm test
```

## Human Checkpoints

- Approve workflow before commit
- Approve any deployment configurations
- Review secrets requirements
