# create-dockerfile

Create optimized Dockerfile for project.

## Arguments

`$ARGUMENTS` = `--repo <path>` (required)

Optional:
- `--type <nodejs|python|go|rust>` - Project type
- `--multi-stage` - Use multi-stage build
- `--target <dev|prod>` - Build target

## Codex Execution

```bash
cd {repo} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {repo} \
  "Create optimized Dockerfile for this {project_type} project. Use multi-stage build, non-root user, minimal final image. Generate .dockerignore too." 2>&1
```

## Process

1. Detect project type and dependencies
2. Choose base image (prefer slim/alpine)
3. Design build stages:
   - Dependencies stage
   - Build stage
   - Production stage
4. Optimize layer caching
5. Add security best practices:
   - Non-root user
   - Minimal final image
   - No secrets in image
6. Generate Dockerfile
7. Generate .dockerignore
8. Present for human approval

## Output

- `Dockerfile`
- `.dockerignore`
- `docker-compose.yml` (if needed)

## Node.js Template

```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# Production stage
FROM node:20-alpine
WORKDIR /app
RUN addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001
COPY --from=builder /app/node_modules ./node_modules
COPY --chown=nodejs:nodejs . .
USER nodejs
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

## Best Practices

- Use specific version tags, not latest
- Order commands for cache efficiency
- COPY specific files, not entire context
- Use .dockerignore for node_modules, .git, etc.
