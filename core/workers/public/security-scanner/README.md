# Security Scanner Worker

Pre-deployment security scanner for public repositories. Detects PII, credentials, and sensitive data before pushing to public repos.

## Skills

| Skill | Description |
|-------|-------------|
| `pre-deploy-check` | Full scan of repo for sensitive data |
| `scan-file` | Scan a specific file |
| `generate-report` | Generate detailed security report |

## Usage

```bash
# Scan current repo before deployment
/run security-scanner pre-deploy-check

# Scan specific path
/run security-scanner pre-deploy-check repos/public/my-project

# Scan with fix suggestions
/run security-scanner pre-deploy-check --fix
```

## What It Detects

### Credentials & Secrets
- API keys (OpenAI, Anthropic, AWS, etc.)
- Private keys (RSA, SSH)
- Tokens and bearer auth
- Passwords in configs

### PII (Personally Identifiable Information)
- Personal email addresses
- Phone numbers
- Hardcoded user paths (`/Users/{your-name}/`)
- Real names in author fields

### Company-Specific Data
- Internal company names
- Internal URLs/IPs
- Project codenames

## Configuration

Create `.security-scanner.yaml` in your repo:

```yaml
ignore_patterns:
  - "example@example.com"
  - "test-api-key"

custom_patterns:
  - name: "Company Name"
    pattern: "MyCompanyInc"
    severity: high

skip_paths:
  - "docs/examples/"
  - "test/fixtures/"
```

## Git Hook Integration

Add to `.git/hooks/pre-push` to automatically scan before pushing to public repos.

## Best Practices

1. **Run before every public push** - Make it part of your workflow
2. **Configure ignore patterns** - Reduce false positives
3. **Use placeholders** - `{your-name}`, `{api-key}`, `/path/to/your/hq/`
4. **Separate configs** - Keep real credentials in `.env` files (gitignored)
