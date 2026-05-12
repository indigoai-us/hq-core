---
id: hq-aws
title: AWS platform rules (consolidated)
scope: global
trigger: when working with AWS services (Cognito, Lambda, S3, ECR/ECS, CloudFront, Route53)
enforcement: hard
version: 1
created: 2026-04-29
updated: 2026-04-29
applies_to: [aws]
public: true
tags: [vendor:aws, consolidated]
source: consolidation-merge
---

## Rule

Consolidated AWS platform guardrails covering identity (Cognito, IAM), compute (Lambda), CLI invocation patterns, storage/secrets (Secrets Manager, S3 leak hygiene), and networking (Route53, CloudFront). Group rules by service family below.

## Identity & auth (Cognito, IAM)

### Never tunnel federated provider access_tokens through Cognito Hosted UI
[from cognito-hosted-ui-federated-scope-passthrough.md]

NEVER: Try to expand Cognito Hosted UI scopes to pass a federated provider's `access_token` (e.g. Google, Facebook, GitHub) through to the client.

Cognito mints its own tokens and absorbs the provider's `access_token` by design — the Hosted UI's callback returns only Cognito-issued `id_token` / `access_token` / `refresh_token`, never the upstream federated token. There is no supported scope string that changes this behavior; the `IdentityProvider` construct does not proxy provider scopes to the client.

If you need a Google / GitHub / Facebook API access_token, run a **separate side-channel OAuth flow** from the app server — a distinct `/api/{provider}/authorize` + `/api/{provider}/callback` pair that handles its own PKCE, stores the token server-side (short-lived HTTPOnly cookie or KMS-encrypted row), and never touches Cognito.

Cognito Lambda triggers (PreTokenGeneration) can *read* the federated provider's tokens server-side and stash them in DynamoDB, but this adds a stateful hop, puts refresh responsibility on HQ, and still doesn't expose the token to the browser. The architecturally correct pattern: use Cognito for identity-only (`openid email profile`), and stand up a parallel OAuth flow for resource access. The two flows share the same user via the email claim but have independent token lifecycles.

### After CLI provisioning, run /membership/me self-check against the same vault URL the CLI used
[from hq-cmd-designate-team-cognito-visibility-self-check.md]

ALWAYS, after CLI-based cloud provisioning that depends on Cognito identity, run a `/membership/me` (or equivalent identity-introspection) self-check against the **same vault URL the CLI just wrote to**. Successful provisioning at the CLI layer does NOT guarantee console visibility — the CLI can authenticate against a different Cognito user pool than the console.

Required structure:

1. Capture the vault URL the CLI used (read from `<hq-root>/.hq/config.json` or the just-emitted CLI JSON — see `hq-slash-command-config-fallback-trust-order`).
2. Issue an authenticated GET to `<vault_url>/membership/me` using the same access token the CLI used (or via the CLI's own identity helper).
3. Confirm the response shape matches what the console reads (member row present, entity id matches the just-provisioned `cmp_<ULID>`).
4. If the self-check fails, treat the run as a partial success — provisioned but not visible — and exit with the dedicated partial-success exit code.

Same endpoint the console calls ⇒ deterministic visibility check. Pool mismatch (CLI vs console) is the dominant root cause when CLI-side provisioning succeeds but console shows nothing.

### hq-deploy API 401 AUTH_FAILED — Cognito pool mismatch, use direct S3 workaround
[from hq-deploy-cognito-pool-mismatch.md]

WHEN: `POST https://api.{your-domain}.com/api/deploys` with a valid Bearer JWT (from `hq auth login`) returns `401 AUTH_FAILED` — the cause is a Cognito pool mismatch:

- `hq auth login` issues tokens for the **canonical HQ Identity pool** per `auth-strategy.md`
- The hq-deploy production CloudFormation template (`src/infra/cloudformation/template.yaml`) may default to a **different pool**

The deploy skill calls these "the shared HQ Identity pool" but they may NOT be the same pool in production. Compare the pool ID in `~/.hq/cognito-tokens.json` (`iss` claim of the access token) to the pool ID baked into the deploy stack's `template.yaml` — a mismatch is the root cause.

**Workaround (requires explicit user authorization):** bypass the API and deploy directly:
1. Upload build artifacts: `COPYFILE_DISABLE=1 tar -czf - {dir} | aws s3 cp - s3://hq-deploy-{company}-assets/{slug}/bundle.tgz`
2. Invalidate CloudFront: `aws cloudfront create-invalidation --distribution-id {DISTRIBUTION_ID} --paths "/{slug}/*"` (Distribution aliases: `{your-domain}.com`, `*.{your-domain}.com`)
3. The DynamoDB table `hq-deploy-{company}` APP# rows (keyed `ORG#{slug}`) with `passwordHash` and `subdomain` are preserved across direct-S3 pushes. Only DEPLOY# audit history rows are skipped.

**Long-term fix:** update `src/infra/cloudformation/template.yaml` to use the canonical HQ Identity pool (matching `hq auth login`). The 401 looks identical to an expired-token error because both SDK and server-side logs report "invalid token" rather than "wrong pool."

### hq-sync 401 on `prs_*` — first remediation is `/hq-logout && /hq-login`
[from hq-sync-personal-prs-401-stale-cognito-after-pool-cutover.md]

`hq-sync-runner` routes entities through two distinct STS endpoints based on entity-id prefix:

- `cmp_*` (company entities) → `POST /sts/vend`
- `prs_*` (personal entities) → `POST /sts/vend-self`

When you see a 401 Unauthorized on `GET /entity/prs_*` (or on the `/sts/vend-self` call that precedes it), the **first remediation is to refresh the local Cognito tokens**, not to assume a code defect:

```
/hq-logout && /hq-login
# then re-run /hq-sync (or AppBar HQ Sync)
```

Only after a fresh token still produces 401 should you investigate as a code or routing bug. The HQ-prod Cognito user pool cutover replaced the old `hq-dev` pool with `hq-prod` for personal-mode authentication. Tokens issued by the old pool against the old `/sts/vend-self` endpoint silently fail validation against the new pool — the symptom is a generic 401, not "token expired" or "invalid pool", so the failure looks like an authorization bug rather than a stale-credential bug. A fresh `/hq-login` round-trip vends a token from the new pool and resolves the 401 immediately.

### Auto mode does not authorize bypassing production-AWS-read denials
[from hq-auto-mode-no-bypass-prod-aws-denial.md]

Auto mode is NOT a license to defeat production-classified denials. When the harness blocks a read against a production resource (Cognito user pool, DynamoDB table, Lambda function, S3 bucket, Secrets Manager secret, etc.):

1. **Do NOT** fan out to sibling stage / tenant / region resources hoping one slips through the gate. That is working around the *intent* of the rule — the gate exists to force a human pause on production blast radius, not to be enumerated past.
2. **Do NOT** rename the resource argument and retry (e.g. swapping `prod-foo` for `staging-foo` to read "the same data").
3. **Do NOT** silently downgrade the operation (e.g. switching from `Scan` to `Query` only because `Scan` was denied).

**Correct response:**

1. Pause.
2. Surface the block to the user via `AskUserQuestion` (or wait for the human, if interactive).
3. Pivot to a **safer probe** that does not touch the production resource — examples:
   - `vercel env ls production` to identify which stage backs a web app (no AWS read at all).
   - Reading a checked-in fixture or the staging equivalent **only after the user explicitly redirects to staging**.
   - Asking the user for the specific value you need.
4. Only retry the production read after explicit human authorization in the same session.

This rule fires whether the harness denial is a shell-allowlist miss, an MCP server "production" classification, a settings.deny rule, or a hook block. Production-data denials encode an **escalation requirement**, not a routing puzzle. The pattern this prevents — "denied on prod-X → try sibling-X → try different-region-X → eventually find one that returns" — is indistinguishable from credential-bruteforcing behavior in audit logs.

## Compute (Lambda)

### Never mix shorthand and JSON in `aws lambda --environment`
[from aws-lambda-env-full-json-envelope.md]

NEVER mix AWS CLI shorthand and JSON forms in `aws lambda update-function-configuration --environment`. The CLI rejects `Variables=<json-blob>` with `ParamValidationError` because shorthand expects `Variables=k=v,k2=v2` and JSON expects `{"Variables": {...}}` — the two grammars cannot be combined.

ALWAYS build a full JSON envelope before calling:

```bash
ENV_PAYLOAD=$(jq -n --argjson v "$NEW_ENV" '{Variables: $v}')
aws lambda update-function-configuration \
  --function-name "$FN_NAME" \
  --region "$REGION" \
  --environment "$ENV_PAYLOAD" \
  --output json
```

The `jq -n --argjson v "$NEW_ENV"` form is safe because `$NEW_ENV` is already a JSON object (typically produced by `aws lambda get-function-configuration --query Environment.Variables --output json` plus a jq merge). One-line jq wrap that produces `{"Variables": {...}}` and passes the entire thing as full JSON — no mixing, no ambiguity.

### Never run a headless browser in a Vercel Lambda
[from no-headless-browser-in-vercel-lambda.md]

NEVER run Playwright, Puppeteer, or Chromium in a Vercel Lambda. Use ingest-only endpoints that accept pre-captured payloads from client-side callers (extensions, local scripts).

The 250 MB unzipped Lambda cap makes shipping a headless browser architecturally impossible. Attempts to slim the binary or chunk dependencies do not close the gap; the architecture has to move the browser-execution side off Lambda entirely.

## AWS CLI invocation discipline

### Use `command aws` (not the rtk wrapper) when piping AWS CLI JSON output into a parser
[from hq-aws-cli-use-command-not-rtk-wrapper-for-json.md]

ALWAYS invoke the real AWS CLI (`command aws ...` or the absolute path to the `aws` binary) — not the `rtk` wrapper — when the output is being piped into a structured parser such as `jq`, `python -c "import json"`, `node -e`, `yq`, or any tool that requires valid JSON.

The rtk wrapper compresses arrays in its stdout for token-budget reasons and rewrites large list payloads as placeholder strings like `[{...}] (12)`. That rewrite produces human-readable output but invalid JSON — every downstream parser that expects the real CLI shape will blow up with a syntax error or, worse, silently parse the truncation string as data. Use the wrapper freely for interactive human-read queries, but bypass it whenever the next pipe stage is a program.

Recommended pattern:

```bash
command aws ecs describe-services --cluster "$CLUSTER" --services "$SVC" --output json \
  | jq '.services[0].deployments'
```

If you are unsure whether a given shell has `aws` aliased or shadowed, use `\aws ...` or the explicit path (`/opt/homebrew/bin/aws` / `/usr/local/bin/aws`) to skip the alias layer entirely. Interactive: `aws`. Programmatic: `command aws`.

### Use `--output json` + `jq` for CloudWatch log stream names
[from hq-aws-logs-stream-json-output.md]

ALWAYS: Use `--output json` piped through `jq` when reading CloudWatch Logs stream names:

```bash
STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LG" \
  --order-by LastEventTime --descending --max-items 1 \
  --output json | jq -r '.logStreams[0].logStreamName')

aws logs get-log-events --log-group-name "$LG" --log-stream-name "$STREAM" --output json
```

NEVER: Use `--output text` for stream-name reads. Lambda stream names embed `[$LATEST]`, brackets, and `$` — shell-sensitive characters that get split across whitespace-separated text columns or expanded by the shell before `get-log-events` sees them. The downstream call fails with `ResourceNotFoundException` on a name that plainly exists. `--output json | jq -r` preserves the literal string byte-for-byte and quotes it safely for the next command.

General principle: for any AWS CLI read whose values can contain brackets, dollar signs, colons, or unicode, default to `--output json` + `jq`. Reserve `--output text` for ASCII-only fields (ARNs, simple IDs).

## Storage & secrets (Secrets Manager, S3/account-id leak hygiene)

### Never dump raw Secrets Manager `SecretString` to stdout — inspect by keys only
[from hq-secrets-manager-never-dump-secretstring.md]

NEVER dump raw Secrets Manager `SecretString` contents to stdout, even truncated — no `head -c 200`, no `cut -c 1-200`, no `awk '{print substr($0, 1, 200)}'`. Truncation is not a redaction strategy: a JSON blob may pack several `KEY=value` pairs into the first 200 characters, and even one leaked value breaks the "secrets never touch terminal scrollback, tmux buffers, or session transcripts" invariant.

When you need to inspect a secret, dump only its **key shape**:

```bash
aws secretsmanager get-secret-value --secret-id "$ID" --query SecretString --output text \
  | jq -r 'keys[]' | sort
# or
aws secretsmanager get-secret-value --secret-id "$ID" --query SecretString --output text \
  | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin).keys())))'
```

If a specific value is required (e.g. to diff against a deployed env var), pipe it directly into the next tool without a visible stdout hop — use process substitution, a here-string, or a temp file that's `chmod 600` and deleted in the same command chain. The `rtk` wrapper redacts some values but not all; relying on its auto-redaction for interactive inspection has failed in practice. Dumping keys-only preserves every legitimate inspection use case (is the schema right? is the new key present?) while eliminating the category of accidental leaks.

### Add real AWS account IDs to leak-scan denylist under a numeric pattern
[from hq-leak-scan-denylist-aws-account-numeric-pattern.md]

The leak-scan denylist MUST include a numeric pattern that catches real 12-digit AWS account IDs in addition to the named slugs:

1. Add a top-level `aws_account_ids:` (or equivalent) key whose entries enumerate every real AWS account ID associated with any HQ company.
2. Cross-reference the list against `companies/manifest.yaml` `aws_profile` and `aws_account_id` fields once per quarter; whenever a new company onboards or a new account is provisioned, append immediately.
3. The leak-scan rule that consumes this list MUST match exact 12-digit numeric tokens, not substrings — to avoid false positives on order numbers, timestamps, etc. Use a word-boundary anchor (e.g. `\b\d{12}\b` matched against the explicit allowlist, not against any 12-digit number).

A name-only denylist is insufficient: account IDs leak as bare integers in CloudFormation outputs, IAM ARNs, DynamoDB stream ARNs, S3 bucket names that embed the account, etc. The company slug is often stripped or renamed in error messages and resource names, but the numeric ID survives. Resource ARNs are the most common form an account ID takes in policy/skill body text, so the omission is silent and high-impact: a single CloudFormation example or IAM role ARN in a `public: true` policy publishes the account permanently to anyone who clones `hq-core`. Numeric coverage and slug coverage compose — both are needed; neither alone is safe.

## Networking (Route53, CloudFront)

### Query Route53 TXT records with `dig`, not `aws` CLI piped to JSON parsers
[from hq-aws-cli-json-pipe-route53-use-dig.md]

ALWAYS: Use `dig +short TXT <name>` to read Route53 TXT records (and other RRsets) when you need to parse values programmatically — especially for shared multi-value TXT like `_vercel.{apex}`.

NEVER: Rely on `aws route53 list-resource-record-sets` piped to `jq` / `python -c json.load` for these reads. The aws CLI's auto-pager and output formatter emit a yaml-short schema summary (not JSON) when stdout is a pipe and the result is large, *regardless* of `--output json` flags. Parsers then silently receive garbage.

Acceptable reads with aws CLI:
- Direct `--output json` to a file or tty (no pipe), then parse the file
- `--no-cli-pager --output json` explicitly set AND small result set

For writes (`change-resource-record-sets`), aws CLI remains canonical — the pipe-format bug only affects reads. Dig is also faster (no API round-trip to Route53's control plane — queries the public DNS endpoint that clients actually hit), which is what you usually want to confirm anyway: "has DNS propagated?" not "what does the Route53 config say?"

