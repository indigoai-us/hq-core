---
name: hq-secrets
description: Use HQ CLI secrets safely through env injection or one-off exec.
allowed-tools: Bash(hq:*), Bash(source:*), Bash(bash:*)
---

# HQ Secrets

Manage secrets stored in AWS SSM Parameter Store via the `hq secrets` CLI. Secrets are scoped to either a **company** (shared, with per-secret ACLs and groups) or the **calling person** (`--personal`, owner-only with no sharing). Access happens through Cognito-authenticated API calls. Company secrets support per-secret ACLs with `read`/`write`/`admin` permissions, granted to individuals or groups; personal secrets have no sharing surface in v1.

See also [`hq-files`](../hq-files/SKILL.md) for managing file-prefix access controls in the HQ vault — same groups model, different ACL domain.

## Schema-driven dev workflow: `hq run`

For repos that commit a `.env.schema` file, `hq run` is the recommended dev-workflow path. It discovers `.env.schema` by walking up from the current working directory to the first ancestor containing a `.git/` directory (or the filesystem root if there is none), fetches all `hq()`-declared secrets in a single API request to the vault, and spawns the command with secrets injected as env vars — no `--only` list needed, and the CLI itself never prints values.

```dotenv
# .env.schema
# Committed to the repo. Read by `hq run`. Authored by anyone with secret-write
# permission; consumed by anyone with secret-read permission per the standard
# per-secret ACL.

# @hqCompany("indigo")

# Non-sensitive defaults — passed straight through to the child process.
# These don't touch the vault.
NODE_ENV=development
LOG_LEVEL=info

# Sensitive: var name == secret name (the common case)
# @required
DATABASE_URL=hq()

# Sensitive: explicit override — fetches from secret INDIGO_NX/DB_URL even
# though the env var the child process sees is DB_URL
# @required
DB_URL=hq("INDIGO_NX/DB_URL")

# Optional: hq run will still succeed if this secret is missing or the dev
# does not have ACL access; the var simply is not set in the child env.
# @optional
SENTRY_DSN=hq()
```

A sibling `.env.local` (gitignored) overrides any schema value, including `hq()`-resolved ones:

```dotenv
# .env.local — DO NOT COMMIT
# Local override that wins over hq() resolution
DATABASE_URL=postgres://localhost:5432/indigo_dev
```

Use `hq run` instead of `hq secrets exec` when your repo has a `.env.schema`. Use `hq secrets exec` for one-off or scripted invocations where a schema file is not appropriate.

| Command | Purpose |
|---------|---------|
| `hq run -- <cmd>` | Run a command with all `.env.schema`-declared secrets injected (recommended for schema-driven repos) |
| `hq run --check` | Resolve and report all secrets without spawning a child process |
| `hq run --company <slug> -- <cmd>` | Override the company slug at runtime |

## Commands

| Command | Purpose |
|---------|---------|
| `hq secrets list` | List all secrets (names + metadata, no values) |
| `hq secrets get <PATH>` | Show secret metadata (value redacted by default) |
| `hq secrets get <PATH> --reveal` | Show metadata AND the decrypted value |
| `hq secrets set <PATH>` | Create/update a secret (interactive prompt, never echoed) |
| `hq secrets set <PATH> --from-stdin` | Create/update from piped input |
| `hq secrets delete <PATH>` | Delete a secret (prompts for confirmation) |
| `hq secrets delete <PATH> --force` | Delete without confirmation |
| `hq secrets exec --only KEY1,KEY2 -- <cmd>` | Run a command with secrets injected as env vars |
| `source <(hq secrets env --only KEY1,KEY2)` | Export secrets into the current shell (refuses to run on a TTY) |
| `hq secrets generate-link <PATH>` | Generate a one-time URL for a human to submit a secret value |
| `hq secrets generate-link <PATH> --expires 2d` | Custom expiry (default 24h, max 7d) |
| `hq secrets cache clear` | Clear the local encrypted secrets cache |
| `hq secrets acl <PATH>` | Show the ACL for a secret: creator, grantees, permissions, open/restricted status |
| `hq secrets share <PATH> --with <email-or-group> --permission <read\|write\|admin>` | Grant access to a person or group |
| `hq secrets unshare <PATH> --from <email-or-group>` | Revoke access from a person or group |
| `hq groups create <groupId> --name "<name>"` | Create a named group |
| `hq groups delete <groupId>` | Delete a group |
| `hq groups add <groupId> <principal>` | Add a member (email or personUid) to a group |
| `hq groups remove <groupId> <principal>` | Remove a member from a group |
| `hq groups list` | List all groups in the company |
| `hq groups members <groupId>` | List members of a group |

All commands accept `--company <slug>` to target a specific company; if omitted, the CLI resolves your company from your membership. Pass `--personal` instead to operate on your **personal vault** — secrets scoped to your `prs_*` person entity, owner-only, no sharing. `--personal` and `--company` are mutually exclusive. Sharing-related subcommands (`share`, `unshare`, `acl`, `generate-link`) reject when `--personal` is set.

Secret names must match `^[A-Z][A-Z0-9_]*(/[A-Z][A-Z0-9_]+)*$`. Each `/`-separated segment follows the original naming rule. Examples: `MY_API_KEY`, `STRIPE_SECRET`, `PROD/DB_PASSWORD`, `BACKEND/SERVICE/TOKEN`.

## Safe Patterns: `hq run` and `hq secrets exec`

**For repos with a committed `.env.schema`**, `hq run` is the recommended path. It auto-discovers the schema by walking up from the current directory to the repo root, batch-fetches all `hq()`-declared secrets in one call, and spawns the command with them injected as env vars. No `--only` list to maintain; the schema is the source of truth.

```bash
hq run -- npm run dev
hq run -- npm test
hq run --company indigo -- node script.js
```

**For one-off or scripted invocations** without a schema file, use `hq secrets exec`:

`hq secrets exec` fetches values server-side, injects them as environment variables into the child process, and never writes values to its own stdout or stderr.

```bash
hq secrets exec --only DATABASE_URL,API_KEY -- npm run migrate
hq secrets exec --only AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY -- aws s3 ls
hq secrets exec --only OPENAI_API_KEY -- node script.js
```

The `--only` flag is required — there is no "inject all" mode. Name exactly the secrets the child process needs.

Results are cached locally (encrypted, 5-minute TTL) so repeated `exec` calls within a short window don't re-fetch from the API.

## Sourcing into a shell: `env`

When secrets must persist in the current shell (e.g. an interactive debugging session, or a tool that spawns its own sub-commands and won't inherit from a single `exec`), use `hq secrets env`:

```bash
source <(hq secrets env --only DATABASE_URL,API_KEY)
```

The command writes `export KEY='value'` lines to stdout with POSIX-safe single-quote escaping. All status messages go to stderr, so nothing pollutes the sourced output.

**TTY guard**: when stdout is a terminal, `hq secrets env` prints `export KEY='[REDACTED]'` instead of the real values (and a warning to stderr). Values are only emitted when stdout is a pipe or process substitution — i.e. when someone is actually sourcing them. Running `hq secrets env --only STRIPE_KEY` directly will never expose the value on screen.

**Agent guidance**: prefer `exec` over `env` whenever possible. `env` mutates the caller's shell environment, which is easy to leave around in later commands (history files, subprocess logs). Only use `env` when the workload genuinely cannot be expressed as a single `exec` invocation.

## Permissions and ACL

Each secret has an ACL controlling who can read, write, or administer it.

- **`read`**: can fetch the secret value (`get --reveal`, `exec`, `env`).
- **`write`**: can update the value (`set`).
- **`admin`**: full `read` + `write` access, plus can `share` / `unshare` the secret.

The **creator** of a secret is implicitly its admin. This grant cannot be revoked.

By default, a newly created secret has a **restricted** ACL — only the creator has access. An **open** ACL flag grants `read` to everyone in the company without needing an explicit per-person grant; `open` is a flag on the ACL, not a permission level.

**Groups as grantees**: `--with` and `--from` accept either an email address or a group id (see `## Groups` below). A group grant extends the permission to every current member; adding or removing members from the group automatically adjusts who has access without touching the secret's ACL.

Inspect an ACL with `hq secrets acl <PATH>`. Group-based entries appear as `group:<groupId>` in the grantee column.

```bash
# Show who has access
hq secrets acl PROD/DB_PASSWORD

# Grant read access to a teammate
hq secrets share PROD/DB_PASSWORD --with alice@example.com --permission read

# Revoke access
hq secrets unshare PROD/DB_PASSWORD --from alice@example.com
```

You must have `admin` permission on the secret to call `share` or `unshare`.

## Personal vault (`--personal`)

`--personal` swaps the scope from a company (`cmp_*`) to the caller's canonical person entity (`prs_*`). Use it for credentials that aren't tied to any company — your own GitHub PAT, a personal OpenAI key, a shared-with-you-only vendor token. Secrets stored under `--personal` are visible only to you; there is no sharing, no ACL surface, no groups.

```bash
# Store a personal secret (interactive prompt)
hq secrets --personal set MY_GITHUB_PAT

# Or from stdin
echo "$VALUE" | hq secrets --personal set MY_GITHUB_PAT --from-stdin

# List your personal secrets
hq secrets --personal list

# Inject into a command
hq secrets --personal exec --only MY_GITHUB_PAT -- gh auth refresh

# Reveal (be deliberate; same redact-by-default rules as company scope)
hq secrets --personal get MY_GITHUB_PAT --reveal

# Delete
hq secrets --personal delete MY_GITHUB_PAT
```

Subcommands disabled under `--personal`:

| Subcommand | Behaviour |
|------------|-----------|
| `share` | Errors: "share is not supported with --personal." |
| `unshare` | Errors: "unshare is not supported with --personal." |
| `acl` | Errors: "acl is not supported with --personal." |
| `generate-link` | Errors: "generate-link is not supported with --personal." |

If a teammate needs access to a secret, store it in a company scope and `share` it. `--personal` is for credentials that are genuinely yours alone.

`hq run` resolves a company from your `.env.schema`'s `@hqCompany(...)` annotation; it does NOT currently support personal scope. If a workload needs personal secrets, use `hq secrets --personal exec --only KEY -- <cmd>` instead of `hq run`.

## Groups

A group is a named collection of people in a company. Grants made to a group apply to all members without modifying the secret's ACL directly.

Subcommands:

| Command | Purpose |
|---------|---------|
| `hq groups create <groupId> --name "<name>" [--description "<desc>"]` | Create a group |
| `hq groups delete <groupId>` | Delete a group and all its memberships |
| `hq groups add <groupId> <principal>` | Add a member (email or personUid) |
| `hq groups remove <groupId> <principal>` | Remove a member |
| `hq groups list` | List all groups in the company |
| `hq groups members <groupId>` | List members of a group |

Example — create a team group and share a secret with it:

```bash
hq groups create grp_backend-team --name "Backend team"
hq groups add grp_backend-team alice@example.com
hq groups add grp_backend-team bob@example.com
hq secrets share PROD/DB_PASSWORD --with grp_backend-team --permission read
```

To onboard a new hire, add them to the group — they inherit all group-level secret grants automatically.

## Rules for Agent Workflows

1. **Use `exec` to inject secrets into commands.** Do not use `get --reveal` to read a value and then pass it manually. Let `exec` handle the injection.

2. **Never capture `exec` output to extract secrets.** Do not wrap `hq secrets exec` in command substitution (`$(...)` or backticks), pipe its output to another tool, or attempt to parse the child process's stdout/stderr for secret values. Run `exec` as a terminal command and let the child process use the env vars directly.

3. **Do not run commands that print environment variables inside `exec`.** Commands like `env`, `printenv`, `echo $SECRET`, `node -e "console.log(process.env.X)"`, or `set` would expose secret values in the agent's visible output. Only run the actual workload command.

4. **`get` redacts by default.** Use `hq secrets get <PATH>` freely to check metadata (last modified, version). The value is shown as `[REDACTED]` unless you pass `--reveal`.

5. **Do not use `get --reveal` in agent workflows** unless the human has explicitly asked you to display a secret value. This is an escape hatch for human-in-the-loop steps, not for agent automation.

6. **Use `generate-link` for human-supplied credentials.** `hq run` does NOT replace `hq secrets generate-link` — they serve different purposes. When a workflow needs a secret that the agent should not see (vendor API keys, personal tokens, third-party credentials), generate a one-time submission link and give it to the human:

   ```bash
   hq secrets generate-link VENDOR_API_KEY --expires 1h
   ```

   The human opens the URL, enters the value, and it goes straight to SSM without the agent ever seeing it. **Surface that URL only as a Markdown inline link** — `[Submit VENDOR_API_KEY — expires in 1h ›](https://hq.{co}.com/secrets-input/<token>)` — never as bare visible text, and never with the token in the visible label. It is a single-use capability; the same render + persistence rules as share-session URLs apply (`core/policies/hq-secure-link-render-as-markdown.md` and `core/policies/hq-share-session-urls-are-capabilities.md`).

7. **Use `list` to discover available secrets.** Before running `exec`, check what secrets exist for the company.

8. **Check ACL before attempting mutation.** Run `hq secrets acl <PATH>` before calling `share` or `unshare` to confirm you hold `admin` permission. Attempting to mutate an ACL without admin returns a 403 — avoid unnecessary round-trips.

9. **Prefer groups over per-person grants for teams.** Sharing a secret with a group rather than each person individually keeps the ACL table small, makes revocation atomic (remove from group, not from every secret), and produces a clearer audit trail.

10. **Do not widen ACLs without explicit human approval.** Granting `--permission admin` or setting the `open` flag are privilege escalations. Always confirm with the human before making these changes.

11. **Never delegate capability-link minting + rendering to a subagent.** `hq secrets generate-link` (and any `share-session` / capability URL) MUST be run and rendered in the **parent turn that talks to the human** — one Markdown inline link, per `core/policies/hq-secure-link-render-as-markdown.md`. A Task subagent does NOT receive the SessionStart-injected policies (from `inject-policy-on-trigger.sh`), so it has no knowledge of the markdown-render / persistence rules and will dump bare token URLs. If a workflow step needs a credential, return control to the parent and mint there — do not generate the link inside a subagent. (Backstop: the `enforce-capability-link-render` Stop hook blocks a parent turn that emits a bare capability URL, but it cannot see inside a subagent — prevention is this rule.)

## Honest Guardrail Framing

The `hq run` and `hq secrets exec` commands both make the safe path the easy path: secrets are injected as env vars into a child process, and the CLI itself never prints values. The `get` command redacts values by default.

However, these are prompt-level guidelines, not technical enforcement. If the child process run via `hq run` or `hq secrets exec` is designed to print its environment variables (e.g. `env`, `printenv`), those values will appear in subprocess output that the agent can see. The CLI cannot prevent this — it relies on you, the agent, not running such commands and not capturing subprocess output for the purpose of extracting secrets.

The design makes accidental exposure unlikely. Intentional circumvention is possible but violates the contract.

## Common Workflows

### Deploy with secrets

For repos with a `.env.schema` (recommended):
```bash
hq run -- npm run deploy
```

For one-off or schema-less invocations:
```bash
hq secrets exec --only DATABASE_URL,REDIS_URL -- npm run deploy
```

### Run tests against a staging API

For repos with a `.env.schema` (recommended):
```bash
hq run -- npm test
```

For one-off or schema-less invocations:
```bash
hq secrets exec --only STAGING_API_KEY -- npm test
```

### Ask a teammate to provide a credential

```bash
hq secrets generate-link STRIPE_SECRET_KEY --expires 4h
```

Surface the resulting URL **only as a Markdown inline link** —
`[Submit STRIPE_SECRET_KEY — expires in 4h ›](https://hq.{co}.com/secrets-input/<token>)` —
never as bare visible text, label free of the token. Single-use capability;
governed by `core/policies/hq-secure-link-render-as-markdown.md`.
Mint + render this in the parent turn — never inside a subagent (guardrail 11).

### Check what secrets exist

```bash
hq secrets list --company myco
```

### Store a secret from a script

```bash
echo "$VALUE" | hq secrets set NEW_SECRET --from-stdin
```

### Clear stale cache

```bash
hq secrets cache clear
```

### Share a secret with a teammate

```bash
hq secrets share PROD/DB_PASSWORD --with alice@example.com --permission read
```

### Check who has access to a secret

```bash
hq secrets acl PROD/DB_PASSWORD
```

### Create a team group and share a secret with it

```bash
hq groups create grp_backend-team --name "Backend team"
hq groups add grp_backend-team alice@example.com
hq secrets share PROD/DB_PASSWORD --with grp_backend-team --permission read
```

### Revoke access

```bash
hq secrets unshare PROD/DB_PASSWORD --from alice@example.com
```

### Store a credential that's yours alone (personal vault)

```bash
hq secrets --personal set MY_GITHUB_PAT
hq secrets --personal exec --only MY_GITHUB_PAT -- gh auth refresh
```
