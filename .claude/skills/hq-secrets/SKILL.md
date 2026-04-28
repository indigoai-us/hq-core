---
name: hq-secrets
description: Use hq CLI secrets commands safely — inject via exec, never handle raw values, generate links for human-supplied credentials.
allowed-tools: Bash(hq:*), Bash(source:*), Bash(bash:*)
---

# HQ Secrets

Manage secrets stored in AWS SSM Parameter Store via the `hq secrets` CLI. Secrets are scoped per company and accessed through Cognito-authenticated API calls. Secrets now support per-secret ACLs with `read`/`write`/`admin` permissions; access can be granted to individuals or groups.

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

All commands accept `--company <slug>` to target a specific company. If omitted, the CLI resolves your company from your membership.

Secret names must match `^[A-Z][A-Z0-9_]*(/[A-Z][A-Z0-9_]+)*$`. Each `/`-separated segment follows the original naming rule. Examples: `MY_API_KEY`, `STRIPE_SECRET`, `PROD/DB_PASSWORD`, `BACKEND/SERVICE/TOKEN`.

## Safe Pattern: `exec`

`hq secrets exec` is the primary way to use secrets. It fetches values server-side, injects them as environment variables into the child process, and never writes values to its own stdout or stderr.

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

6. **Use `generate-link` for human-supplied credentials.** When a workflow needs a secret that the agent should not see (vendor API keys, personal tokens, third-party credentials), generate a one-time submission link and give it to the human:

   ```bash
   hq secrets generate-link VENDOR_API_KEY --expires 1h
   ```

   The human opens the URL, enters the value, and it goes straight to SSM without the agent ever seeing it.

7. **Use `list` to discover available secrets.** Before running `exec`, check what secrets exist for the company.

8. **Check ACL before attempting mutation.** Run `hq secrets acl <PATH>` before calling `share` or `unshare` to confirm you hold `admin` permission. Attempting to mutate an ACL without admin returns a 403 — avoid unnecessary round-trips.

9. **Prefer groups over per-person grants for teams.** Sharing a secret with a group rather than each person individually keeps the ACL table small, makes revocation atomic (remove from group, not from every secret), and produces a clearer audit trail.

10. **Do not widen ACLs without explicit human approval.** Granting `--permission admin` or setting the `open` flag are privilege escalations. Always confirm with the human before making these changes.

## Honest Guardrail Framing

The `exec` command makes the safe path the easy path: secrets are injected as env vars into a child process, and the CLI itself never prints values. The `get` command redacts values by default.

However, these are prompt-level guidelines, not technical enforcement. If the child process run via `exec` is designed to print its environment variables (e.g. `env`, `printenv`), those values will appear in subprocess output that the agent can see. The CLI cannot prevent this — it relies on you, the agent, not running such commands and not capturing subprocess output for the purpose of extracting secrets.

The design makes accidental exposure unlikely. Intentional circumvention is possible but violates the contract.

## Common Workflows

### Deploy with secrets

```bash
hq secrets exec --only DATABASE_URL,REDIS_URL -- npm run deploy
```

### Run tests against a staging API

```bash
hq secrets exec --only STAGING_API_KEY -- npm test
```

### Ask a teammate to provide a credential

```bash
hq secrets generate-link STRIPE_SECRET_KEY --expires 4h
# Share the printed URL with the teammate
```

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
