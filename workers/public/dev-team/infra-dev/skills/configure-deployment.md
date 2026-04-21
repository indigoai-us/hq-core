# configure-deployment

Configure deployment for application.

## Arguments

`$ARGUMENTS` = `--repo <path>` (required)

Optional:
- `--platform <vercel|railway|fly|aws|gcp>` - Deployment platform
- `--env <staging|production>` - Target environment
- `--preview` - Enable preview deployments

## Codex Execution

```bash
cd {repo} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {repo} \
  "Configure deployment for {platform} ({env} environment). Include config file, env var template, and rollback strategy." 2>&1
```

## Process

1. Analyze project requirements:
   - Runtime (Node, Python, Go, etc.)
   - Environment variables needed
   - External services (DB, cache, etc.)
2. Choose deployment strategy:
   - Blue-green
   - Rolling
   - Canary
3. Configure platform:
   - vercel.json / fly.toml / railway.json
   - Environment variable templates
   - Domain configuration
4. Set up preview deployments (if --preview)
5. Configure rollback strategy
6. Present for human approval

## Output

- Platform configuration file
- Environment variable template
- Deployment documentation

## Vercel Config

```json
{
  "buildCommand": "npm run build",
  "outputDirectory": "dist",
  "framework": null,
  "regions": ["iad1"],
  "env": {
    "DATABASE_URL": "@database-url"
  }
}
```

## Fly.io Config

```toml
app = "my-app"
primary_region = "iad"

[build]
  dockerfile = "Dockerfile"

[http_service]
  internal_port = 3000
  force_https = true
  auto_stop_machines = true
  auto_start_machines = true

[[services.ports]]
  handlers = ["http"]
  port = 80

[[services.ports]]
  handlers = ["tls", "http"]
  port = 443
```

## Human Checkpoints

- Approve deployment configuration
- Approve environment variables
- Approve production deployments (always)
