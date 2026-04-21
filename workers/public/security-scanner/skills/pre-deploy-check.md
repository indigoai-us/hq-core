# Pre-Deploy Security Check

Scan a repository for PII, credentials, and sensitive data before public deployment.

## Usage

```
/run security-scanner pre-deploy-check [repo-path]
```

If no path provided, scans current working directory.

## Scan Patterns

### 1. Credentials & Secrets

```bash
# API Keys (various formats)
grep -r -E "(api[_-]?key|apikey)\s*[:=]\s*['\"]?[a-zA-Z0-9_-]{20,}" --include="*.{ts,js,json,yaml,yml,md,env}"

# AWS Keys
grep -r -E "AKIA[0-9A-Z]{16}" --include="*.{ts,js,json,yaml,yml,env}"

# OpenAI/Anthropic Keys
grep -r -E "(sk-[a-zA-Z0-9]{48}|sk-ant-[a-zA-Z0-9-]{90,})" --include="*.{ts,js,json,yaml,yml,env}"

# Generic Secrets
grep -r -E "(secret|password|token|bearer|auth)\s*[:=]\s*['\"]?[a-zA-Z0-9_/-]{8,}" --include="*.{ts,js,json,yaml,yml,env}"

# Private Keys
grep -r -E "-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----" --include="*"
```

### 2. PII Patterns

```bash
# Email addresses (personal domains)
grep -r -E "[a-zA-Z0-9._%+-]+@(gmail|yahoo|hotmail|outlook|icloud|protonmail)\.(com|net|org)" --include="*.{ts,js,json,yaml,yml,md}"

# Phone numbers
grep -r -E "\b\d{3}[-.]?\d{3}[-.]?\d{4}\b" --include="*.{ts,js,json,yaml,yml,md}"

# SSN patterns
grep -r -E "\b\d{3}-\d{2}-\d{4}\b" --include="*.{ts,js,json,yaml,yml,md}"

# Credit card patterns
grep -r -E "\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b" --include="*.{ts,js,json,yaml,yml,md}"
```

### 3. Hardcoded Paths

```bash
# Home directory paths
grep -r -E "/Users/[a-zA-Z0-9_-]+/" --include="*.{ts,js,json,yaml,yml,md}"
grep -r -E "/home/[a-zA-Z0-9_-]+/" --include="*.{ts,js,json,yaml,yml,md}"
grep -r -E "C:\\\\Users\\\\[a-zA-Z0-9_-]+" --include="*.{ts,js,json,yaml,yml,md}"
```

### 4. Company/Personal Names

```bash
# Check against known personal identifiers (configure in .security-scanner.yaml)
# Default: scan for patterns that look like real names in configs
grep -r -E "(author|name|owner)\s*[:=]\s*['\"]?[A-Z][a-z]+ [A-Z][a-z]+" --include="*.{ts,js,json,yaml,yml}"
```

### 5. Internal URLs/IPs

```bash
# Internal IPs
grep -r -E "\b(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))\.\d+\.\d+\b" --include="*.{ts,js,json,yaml,yml,md}"

# Localhost with ports (may indicate dev configs)
grep -r -E "localhost:\d{4,5}" --include="*.{ts,js,json,yaml,yml,md}"

# Internal domain patterns
grep -r -E "\.(local|internal|corp|lan)\b" --include="*.{ts,js,json,yaml,yml,md}"
```

## Exclusions

Skip these paths:
- `node_modules/`
- `.git/`
- `*.lock`
- `dist/`
- `build/`
- `.next/`

## Configuration

Create `.security-scanner.yaml` in repo root:

```yaml
# Patterns to ignore (false positives)
ignore_patterns:
  - "example@example.com"
  - "test-api-key"
  - "placeholder"

# Additional patterns to scan for
custom_patterns:
  - name: "Company Name"
    pattern: "YourCompanyName"
    severity: high

# Paths to skip
skip_paths:
  - "docs/examples/"
  - "test/fixtures/"

# Known safe files
safe_files:
  - "README.md"  # May contain example patterns
```

## Output Format

```
Security Scan Report
====================
Repository: /path/to/repo
Scanned: 2026-01-25T10:00:00Z
Files scanned: 156
Files skipped: 42

CRITICAL (2)
------------
[CRED] workers/config.ts:15
  Found: api_key = "sk-ant-..."

[CRED] .env.example:3
  Found: OPENAI_KEY=sk-...

HIGH (3)
--------
[PII] commands/setup.md:45
  Found: /Users/{your-name}/Documents/

[PII] package.json:8
  Found: author: "John Smith <john@gmail.com>"

[PATH] knowledge/thread-schema.md:12
  Found: workspace_root: "/Users/{your-name}/hq"

MEDIUM (1)
----------
[NAME] workers/cfo/worker.yaml:2
  Found: "CFO Worker for AcmeCorp"

Summary
-------
Critical: 2 (MUST FIX before deploy)
High: 3 (Should fix)
Medium: 1 (Review recommended)
Low: 0

Run with --fix to see suggested replacements.
```

## Suggested Fixes

When run with `--fix`, suggest replacements:

| Found | Replace With |
|-------|--------------|
| `/Users/{your-name}/` | `/path/to/your/hq/` |
| `john@gmail.com` | `your-email@example.com` |
| `"John Smith"` | `"Your Name"` |
| `AcmeCorp` | `example-company` |
| `sk-ant-...` | `{ANTHROPIC_API_KEY}` |

## Integration

### Git Pre-Push Hook

Add to `.git/hooks/pre-push`:

```bash
#!/bin/bash
# Run security scan before pushing to public remote

remote="$1"
url="$2"

# Only scan for public remotes
if [[ "$url" == *"github.com"* ]] && [[ "$url" != *"private"* ]]; then
  echo "Running security scan for public repo..."
  /run security-scanner pre-deploy-check

  if [ $? -ne 0 ]; then
    echo "Security scan failed. Fix issues before pushing."
    exit 1
  fi
fi
```

### CI/CD Integration

```yaml
# GitHub Actions
- name: Security Scan
  run: |
    claude --print "/run security-scanner pre-deploy-check"
```
