# Outpost scheduled jobs — registry schema

Declarative job definitions for recurring headless Claude/Codex runs on a
user's **Outpost**. Product command: `/schedule` (`/job` is a deprecated
alias). Registry YAML rides hq-sync; an on-box reconciler materializes
systemd user timers. Readiness and run telemetry live in **hq-pro**, not in
the YAML.

## Disambiguation: not fleet Agent Scheduled Jobs

| | **Outpost scheduled jobs** (this spec) | **Fleet Agent Scheduled Jobs** |
|---|---|---|
| Who | End-user personal/company jobs | Hosted agents and local bots |
| Where | User Outpost (systemd user timers) | hq-pro-agents job records on EventBridge Scheduler; agents-v2 boxes also run HqFleet-native cron on the box clock |
| Registry | `personal/jobs/*.yaml`, `companies/{co}/jobs/*.yaml` | hq-pro-agents job records (`/v1/agents/{uid}/jobs`); HqFleet cron store on the box |
| Product surface | `/schedule` | `hq bot jobs <name>` (local bots), `hq agents jobs list\|pause\|cancel` (hosted agents) |

Do **not** unify these systems in v1. Paths stay `…/jobs/` for Outpost jobs.
Fleet scheduling is described in
[agents-and-bots.md](agents-and-bots.md#scheduled-jobs): `hq bot jobs` and
`hq agents jobs` both manage hq-pro EventBridge jobs, and
`hq-agents-v2-import-jobs` (hq-agents-v2) migrates an agent's EventBridge
jobs onto HqFleet cron and pauses the originals (verified against
hq-cli@dfe49a48, hq-pro-agents@f6275ec7, hq-agents-v2@5ec6d18 on 2026-09-27).

## Registry locations

| Path | Scope |
|---|---|
| `personal/jobs/*.yaml` | Owner's personal jobs (one file per job, or one job per file) |
| `companies/{co}/jobs/*.yaml` | Company-scoped jobs; any member may create/edit (vault/sync ACLs gate access). v1 runs only on the **creator's** Outpost (`owner` match). |

Each YAML file defines **exactly one** job. Filename is advisory; `id` is
authoritative.

## Job schema (v1)

```yaml
id: daily-sentry-triage          # required — kebab-case slug, unique across scanned registry
name: Daily Sentry triage        # required — human label
schedule: "0 9 * * 1-5"          # required — canonical 5-field cron (see Schedule)
timezone: America/New_York       # optional — IANA tz; omitted means the host's local timezone
runtime: claude                  # required — claude | codex
exec:                            # required — exactly one of prompt | skill
  prompt: "Triage new Sentry issues and DM a summary."
  # OR:
  # skill: my-skill-ref
  # args:
  #   window: 24h
cwd: companies/indigo/projects/foo   # optional — HQ-root-relative working directory
timeout_seconds: 900             # required — integer 60..14400
notify: profile                  # required — dm | none | profile
enabled: true                    # required — boolean
owner: user@example.com          # required — owner email or personUid
created_at: "2026-08-23T18:00:00Z"  # required — ISO-8601 UTC
requirements:                    # optional but recommended — fixed vocabulary
  runtime: claude                # claude | codex (should match top-level runtime)
  secrets:                       # vault key NAMES only — never values
    - SENTRY_API_TOKEN
  company: indigo                # optional company slug
  cwd: companies/indigo/projects/foo  # optional; may mirror top-level cwd
  tools:                         # optional tool/MCP hints for probe UX
    - hq-secrets
```

### Required fields

`id`, `name`, `schedule`, `runtime`, `exec`, `timeout_seconds`,
`notify`, `enabled`, `owner`, `created_at`.

### Field notes

- **`id`**: `[a-z][a-z0-9-]{1,62}` — unique within a validate pass over the
  registry set. Duplicate `id` across files is an error.
- **`timezone`**: optional IANA zone. The reconciler appends a declared zone to
  `OnCalendar=`; if omitted, systemd uses the host's local timezone. Unsafe
  characters are rejected before a unit is written.
- **`runtime`**: `claude` or `codex` only. Unknown values (e.g. `gemini`) fail
  validation.
- **`exec`**: object with either `prompt` (non-empty string) **or** `skill`
  (non-empty string) plus optional `args` (mapping). Both `prompt` and `skill`
  together is invalid. `args` values must be scalars or lists of scalars —
  no nested secret blobs. Optional `surface`: `headless` | `remote`
  (overrides profile `execution_surface`; see Alert profile). `remote` is
  Claude-only — Codex always runs headless.
- **`timeout_seconds`**: integer in **[60, 14400]** (15 minutes default
  recommendation is product guidance; bounds are hard).
- **`notify`**:
  - `dm` — always DM the owner via `hq dm`
  - `none` — no completion/failure notification
  - `profile` — use `personal/settings/schedule-alerts.yaml` (v1 delivery
    still implements **dm only**; see Alert profile)
- **`requirements`**: fixed vocabulary keys only:
  `runtime`, `secrets`, `company`, `cwd`, `tools`. Any other key is rejected.
  - `secrets[]`: vault key **names** (e.g. `SENTRY_API_TOKEN`). Inline
    credential-shaped strings are rejected (validator + `secret-patterns`).
  - `runtime` inside requirements should match top-level `runtime` when both
    are set (mismatch is an error).

### Secrets policy

Never put secret **values** in job YAML, unit files, or examples. Examples
list **names only**. The runner injects only `requirements.secrets[]` via
`hq secrets exec` (confirmed allowlist). Validator rejects secret-shaped
content in `requirements.secrets` entries and in `exec` prompt/skill/args.

## Schedule semantics

- **Canonical storage is cron** (five fields: minute hour dom month dow).
- Natural-language schedules are resolved by `/schedule` at creation time and
  **never stored raw** in YAML.
- Optional sixth seconds field is **not** accepted in v1.
- Timezone is the job's IANA zone; wall-clock confirmation in `/schedule`
  echoes local time for that zone.

## Readiness / status — NOT YAML source of truth

Do **not** treat readiness, last probe, last run, or failure class as mutable
fields on synced job YAML.

| Concern | Source of truth |
|---|---|
| Job definition (schedule, exec, requirements, …) | Registry YAML |
| `readiness` (`pending_probe` \| `ready` \| `blocked` \| `unknown`) | hq-pro jobs status table (US-009) |
| `last_probe_at`, `last_run_at`, `last_exit`, `failure_class`, `next_actions[]` | hq-pro jobs status table |

YAML **may omit** readiness entirely. If a local/informational `readiness`
key appears (e.g. leftover draft), validators **ignore** it — it is not
authoritative and the Outpost must **never rewrite** job YAML to publish
status. `/schedule list` and reconcile read hq-pro; if the API is down, list
shows registry fields and marks status stale/unknown.

Initial list UX after create: job appears as **`pending_probe`** until an
Outpost probe ingests status (still API-backed, not a YAML write).

## Alert profile schema

Path: `personal/settings/schedule-alerts.yaml`

```yaml
channel: dm                    # dm | slack | email | outpost-session
destination:                   # channel-specific; names/ids only — no tokens
  # dm: (implicit owner)
  # slack: { workspace: my-ws, channel: "#alerts" }
  # email: { to: user@example.com }
  # outpost-session: { mode: remediation-brief }
execution_surface: headless    # headless | remote (Claude only; default headless)
updated_at: "2026-08-23T18:00:00Z"
```

- **v1 delivery implements `dm` only** (via `hq dm` to the job owner).
- Setting `slack` / `email` / `outpost-session` is **stored** but `/schedule`
  warns unimplemented and delivery falls back to dm; runners log
  `channel_unimplemented`.
- **`execution_surface`**:
  - `headless` (default) — `claude -p` / `codex exec`; no Desktop remote.
  - `remote` — Claude runs as `claude --remote-control schedule/<job-id>` in a
    dedicated tmux session with the job prompt auto-started. When the job
    finishes the session is torn down and appears under Claude Desktop
    **Archived** remotes (named `schedule/<job-id>`). Codex ignores `remote`
    and stays headless.
  - Per-job `exec.surface` overrides this profile field when set.
- First mutating `/schedule` prompts once and writes this profile (default
  `dm` + `execution_surface: headless`, or `remote` when the user opts in for
  observability). Alerts never go only to the original create chat thread.

## Sync conflict policy

Applies to `personal/jobs/*.yaml` and `companies/*/jobs/*.yaml`:

1. The Outpost **does not author status into job YAML**. Status is API-only,
   so readiness cannot thrash via sync conflicts on YAML.
2. For registry YAML conflicts on files the box **did not author**, Outpost
   sync uses **keep-local** (prefer the box's already-synced copy / last
   good local) rather than clobbering with a partial remote merge that could
   drop jobs mid-reconcile. Authoring happens on the laptop/`/schedule`
   side; the box is a consumer.
3. Status conflicts cannot occur on YAML because status is not stored there.
4. Derived systemd units under `~/.config/systemd/user/` are disposable and
   never synced.

## Validator

`core/scripts/jobs-validate.sh` exits non-zero with per-field errors for:

- missing required field
- invalid cron
- unknown `runtime`
- `timeout_seconds` outside 60–14400
- duplicate `id` across inputs
- unknown `requirements` keys
- inline credential-shaped values in `requirements.secrets` or `exec`

Usage:

```bash
bash core/scripts/jobs-validate.sh path/to/job.yaml
bash core/scripts/jobs-validate.sh personal/jobs companies/indigo/jobs
```

Fixtures: `core/scripts/tests/fixtures/jobs/` · suite:
`core/scripts/tests/jobs-validate.test.sh`.

## Probe (US-008)

`core/scripts/hq-job-probe.sh` runs **on the Outpost** against a job's
requirements checklist and POSTs telemetry to hq-pro. It never rewrites job
YAML for readiness.

### Checks

| Check | Pass when |
|---|---|
| Runtime CLI auth | `claude`: non-empty `~/.claude/.credentials.json` + `claude` on PATH; `codex`: non-empty `~/.codex/auth.json` + `codex` on PATH |
| Secrets | each `requirements.secrets[]` name appears in `hq secrets list` (`--company` when set, else `--personal`) — **names only**, never values |
| cwd | optional path exists (HQ-root-relative or absolute) |
| company | when set, `companies/{co}/` exists on the box HQ tree |

### Ingest

- **Endpoint:** `POST {HQ_PRO_API_URL}/outpost/internal/jobs-status`
- **Auth:** `x-outpost-instance-token` header (same trust model as
  disk-status / relay-status). Identity from `OUTPOST_USER_ID` +
  `OUTPOST_INSTANCE_TOKEN` (env), else `/etc/outpost/codex-identity.env`, else
  `USER_ID=` / `INSTANCE_TOKEN=` lines in `/usr/local/bin/outpost-runner.sh`.
- **Body:** `userId`, `jobId`, `kind=probe`, `readiness` (`ready`\|`blocked`),
  `probed_at`, `event_id`, `next_actions[]`, optional `checks`, optional
  `outpostId`.
- **API base env:** `HQ_PRO_API_URL` → `HQ_API_URL` → `HQ_VAULT_API_URL` →
  `https://hqapi.hq.computer`.

### StatusIngestError

On unreachable API / 5xx / retryable ingest error: bounded backoff retries,
write forensics under `~/.hq/jobs/probes/{id}/last-attempt.json`, leave prior
API readiness unchanged, surface next_action
`status ingest failed — retry probe`, and **never** report `ready` solely
because ingest failed. Laptop-side CLI/secrets must never fake Outpost
readiness — jobs stay `pending_probe` until an on-box probe succeeds.

Fixtures / suite: `core/scripts/tests/fixtures/jobs-probe/`,
`core/scripts/tests/hq-job-probe.test.sh`.

## Reconcile + runner (US-004)

`core/scripts/outpost-jobs-reconcile.sh` materializes disposable systemd **user**
units from the synced registry. `core/scripts/hq-job-run.sh` is the oneshot
executor each timer starts.

### Units

- Paths: `~/.config/systemd/user/hq-job-{id}.service` + `.timer`
- Timer: `OnCalendar=` (from 5-field cron, with an optional IANA zone suffix),
  `Persistent=true`, `RandomizedDelaySec` (default 60)
- Service: `ExecStart=…/hq-job-run.sh --hq-root … --job-id {id}`
- Disabled / deleted / non-`ready` jobs: units removed and timers stopped
- Idempotent: second reconcile with no registry/status change is a noop
- Company jobs: only when `owner` matches this Outpost's identity (creator box)

### Readiness gate

Timers arm **only** when box-local status cache (or live GET when
`HQ_ACCESS_TOKEN` is available) reports `readiness=ready`. Cache is written by
`hq-job-probe.sh` on successful ingest under `~/.hq/jobs/status-cache/{id}.json`.
Post-sync reconcile probes jobs that lack ready status, then re-reads cache.

### Runner

- Global flock `~/.hq/jobs/run.lock` (serialized-only; US-001)
- Timeout from `timeout_seconds` (default 600)
- Secrets only via `hq secrets [--company|--personal] exec --only …` (allowlist
  = `requirements.secrets[]`) or cached CLI auth — never unit-file secrets
- Claude: `claude -p … --output-format text --permission-mode bypassPermissions`
- Codex: `codex exec -s workspace-write --skip-git-repo-check` (box 0.147;
  **not** `--ask-for-approval never`)
- Missing CLI auth → log clear skip reason, exit 0 (do not fail the unit)
- Approval-mode preflight: before launch, resolve the Claude permission mode the
  run would get (bypass disabled by `permissions.disableBypassPermissionsMode`
  falls back to `defaultMode`). Only `bypassPermissions` and `dontAsk` launch;
  any other mode (`plan`, `default`, `acceptEdits`, `auto`, or an unrecognized
  value) is refused. `auto` is refused because its classifier can fall back to
  asking. A `dontAsk` run logs `permission_note=dontAsk` (tools that are not
  pre-approved are denied, so the run can finish with nothing done). Refused:
  mark the run blocked (`blocked=permission_mode`) and notify the owner. The
  interactive `defaultMode` is not changed.
- Company bind: when `requirements.company` is set, bind it to a pre-minted
  session id (`hq-session.sh --session-id <id> set company_slug <slug>`) and
  launch the agent under that id; a failed bind blocks the run and notifies.
- Logs: `~/.hq/jobs/logs/{id}/`
- Compute-meter marker (JSONL): `~/.hq/jobs/meters/runs.jsonl` schema
  `hq.outpost.job-run/v1` (`kind=scheduled-job-run`, job_id, runtime,
  started_at, ended_at, exit_status, duration_seconds)

### Sync hook

`outpost-jobs-reconcile.sh --ensure-hook` installs
`personal/hooks/Stop/90-outpost-jobs-reconcile.sh` so `hq-sync-runner` runs
reconcile after each sync cycle. On-demand: run the script directly.
Provisioning (US-005) enables linger + ensures the hook on every box.

The reconciler also runs from `outpost-jobs-reconcile.service`, a system unit
with `User=ec2-user` and no login session. When `XDG_RUNTIME_DIR` is unset it
uses `/run/user/<uid>` (and `$XDG_RUNTIME_DIR/bus` for
`DBUS_SESSION_BUS_ADDRESS`) so `systemctl --user` reaches the lingering user
manager; if that directory is missing it logs the `loginctl enable-linger`
remedy. A pass with `errors>0` exits 1, and the Stop hook logs a warning to
stderr and `after-sync.log` instead of discarding the failure.

Fixtures / suites: `core/scripts/tests/hq-job-run.test.sh`,
`core/scripts/tests/outpost-jobs-reconcile.test.sh`.

## Remediation alerts (US-006)

After each run, `hq-job-run.sh` classifies the outcome, attempts bounded
self-remediation, writes run telemetry (including `failure_class`) to hq-pro,
then notifies via `hq-job-notify.sh`. Alerts never go to the original
`/schedule` create session/thread.

### Failure classes

| Class | Meaning | Self-remediate (v1) |
|---|---|---|
| `auth` | Runtime CLI logged out / unauthorized | Cognito/`hq auth refresh` only — **never** device re-login loop |
| `secrets` | Missing/denied vault secret | Always-human (`hq secrets share`) |
| `timeout` | Exit 124 / timeout markers | No auto-retry |
| `agent_error` | Agent/runtime non-zero without infra/auth signals | No auto-retry |
| `infra` | Transport / disk / transient API | Cognito refresh + one `hq sync pull` + **single** immediate retry |

### Scripts

- `core/scripts/hq-job-remediate.sh` — allowlist above; stdout JSON
  `{attempted, actions[], retry_recommended, always_human, next_action}`
- `core/scripts/hq-job-notify.sh` — dm delivery + 24h collapse

### Notify / profile

- Honors job `notify`: `dm` | `none` | `profile` (default profile)
- Profile: `personal/settings/schedule-alerts.yaml`
- **v1 delivers `dm` only** via `hq dm` to job `owner`
- `slack` / `email` / `outpost-session` → still dm + log `channel_unimplemented`
- Success/failure DM body: job name, ok/failed/blocked/recovered, classification,
  one-line summary, duration, log path; auth/secrets include a concrete next action
- Escalation: first failure DM immediate; consecutive failures collapse to **one
  DM / 24h / job**; recovery after failures sends a recovered DM
- Notify delivery failure is logged under `~/.hq/jobs/alerts/{id}/` and **never**
  fails the job run

### Run status ingest

- **Endpoint:** `POST {HQ_PRO_API_URL}/outpost/internal/jobs-status`
- **Body:** `userId`, `jobId`, `kind=run`, `run_at`, `event_id`/`run_id`,
  `last_exit`, `failure_class` (`auth|secrets|timeout|agent_error|infra` or
  `null` on success), `next_actions[]`
- Same box identity as probe (`x-outpost-instance-token`)
- Ingest failure is logged and does not fail the run

### Trust model (review 7A)

Runner injects **only** `requirements.secrets[]` via `hq secrets exec --only`.
No v1 static prompt scan for other secret names.

Fixtures / suites: `core/scripts/tests/hq-job-notify.test.sh`,
`core/scripts/tests/hq-job-remediate.test.sh`,
`core/scripts/tests/hq-job-alerts.test.sh` (run+notify+collapse).

## Related

- Probe: `hq-job-probe.sh` (Probe section) — writes hq-pro status, not YAML
- Reconcile / run: this section (US-004) — arms timers only when
  status.readiness=`ready`
- Remediation alerts: US-006 section above
- Fleet contrast: `companies/indigo/knowledge/architecture/agent-scheduled-jobs.md`

## Company Outpost jobs (US-005)

Company jobs use the accepted revision registry and company-machine API. They do
not consume a person's local job files or cached login. The legacy entry points
accept `--company-machine <config>`; required-machine mode refuses the legacy path.
Personal OnCalendar rendering matches the pre-US-005 renderer. A wildcard minute
renders as `00` (`* 9 * * *` is once at 09:00). Company jobs expand wildcard
minutes in `core/scripts/lib/company-jobs.mjs`.

Provisioning extends the existing company infrastructure adapter. Its runtime
release receipt includes `jobs.coreVersion` (a released `vX.Y.Z` core tag) and
`jobs.providerVersion` (a pinned Claude CLI version). The adapter resolves the
company slug from its company entity, installs public core through `hq rescue`,
and writes `/etc/hq/company-jobs.json` with the exact company, machine, outpost,
attempt, and IMDSv2 instance binding. The configuration contains paths and the
provider secret name, never secret values. Missing release capabilities block
provisioning before the host is advertised as ready.

The released installer creates the dedicated `hq-jobs` account with a nologin
shell and no extra groups, and refuses an existing account whose shell, primary
group, or extra groups differ. Lingering is disabled for that account. One
root system timer reconciles every job. Node must support built-in SQLite
(22.13 or newer). Root owns released code at `/opt/hq-company-jobs`, the
machine credentials at `/etc/hq/company-machine.json` (mode 600), the ledger
and reports at `/var/lib/hq-job-runner/state`, and the system units under
`/etc/systemd/system`. The job account owns its home and company project
workspace only. Installation checks, as `hq-jobs`, that the credentials file
and the ledger are unreadable, and exercises root/company/project admission as
that account. It also refuses to install unless every path root executes or
reads code from is root-owned and not group- or world-writable, including
every parent directory: the HQ root, `core`, `core/scripts`, `core/scripts/lib`,
the cloud module, and the resolved `node` binary. An `ec2-user`-owned
`core/scripts/lib` is refused. The root runner fetches the API provider key
(`ANTHROPIC_API_KEY` for the provisioned Claude runtime) and any other name on
the accepted revision through the company secret broker. The live broker
accepts `secretName` and `companyUid` only. The runner puts those values in
the job process environment and drops to `hq-jobs` at exec. The job account
never receives the credentials path. Denial produces a blocked receipt before
any provider execution.

### Box Claude sign-in (no provider secret)

When the configuration has no `providerSecret` and the provider is `claude`,
the box uses a Claude sign-in instead of a broker key. The installer creates a
second nologin account, `hq-claude-auth`, whose home `/var/lib/hq-claude-auth`
is mode 700, and refuses to finish if `hq-jobs` can reach it. The root
`hq-company-signin.service` runs `claude auth login --claudeai` as that account
under a pty. It posts the URL to `POST /outpost/company/signin`
(`login-url`) with the company machine principal, polls `login-code` for the
code a company owner or admin submits, types it, and reports `login-complete`.
It also restarts the login on `regenerate-pending`. Codes must match
`^[A-Za-z0-9][A-Za-z0-9#_.~-]{7,511}$` before they are typed.

While it waits for a person, the watcher polls every 5 seconds. After 5
minutes with no activity it polls every 30 seconds. Activity is a new link, a
code, a regenerate, or `hot: true` on the `login-code` reply, which the server
sends while an owner or admin has read the sign-in status in the last 2
minutes or a code or regenerate is waiting. When `hot` is true and the posted
link is older than 10 minutes (the window the server reports as
`loginUrlExpiresAt`), the watcher restarts the login so the person gets a
working link. With no one on the card, an old link is kept and the login is
not restarted. A server that sends no `hot` field never triggers that
restart. A typed code that neither signs in nor makes the CLI print a new link
within 2 minutes restarts the login. Either way the box posts a new link
after a code it took, and the server records that as `lastCodeRejectedAt`.
The watcher logs `login_url_expired_restart` and `login_code_timeout` to its
journal, with no URL or code.

For each run the root runner reads only `accessToken` and `expiresAt` from the
sign-in file (regular file, owned by `hq-claude-auth`, mode 600). If the token
would expire before the run deadline plus five minutes, it runs one minimal
`claude -p` as `hq-claude-auth` so the CLI refreshes its own file, then
re-reads. It then passes the token as `CLAUDE_CODE_OAUTH_TOKEN` through
`LoadCredential` to the claude session unit only. The precondition script never
receives it, and job code never sees the refresh token. A missing or still-short
token blocks the run before any job code runs (`provider_not_signed_in`,
`provider_token_expiring`). Residual risk: job code in the session can read the
access token for its remaining lifetime, and so can another `hq-jobs` process
running at the same time. The global run lock admits one company job at a time,
which keeps other jobs' code off the box while a session holds the token; a
stale-lock reclaim is the only overlap window.

Company jobs share the `hq-jobs` account, so one job could read another's
`/proc/<pid>/environ`. A per-job `DynamicUser` or static user is not used.
Provider CLI auth is checked as `hq-jobs`, and the company project workspace
is mode 700 owned by that account; an ephemeral uid would have neither.
Instead, one global run lock in the ledger admits a single company job at a
time. The lock stamps `since` at acquisition. A later job reclaims it when
`since` is older than `HQ_COMPANY_JOBS_LOCK_TTL_SECONDS` (default 21600, which
is past the 14400-second job cap plus token and receipt time). A holder that
never releases cannot wedge the box. Losing the lock is a `run_lock_lost`
receipt and a nonzero exit, not a swallowed failure.

Each run gets its own home under the job account's `runs/` directory. Provider
transcripts go there. The runner deletes that directory after the receipt is
written, so a later job cannot read the previous transcript.

The default-off `OUTPOST_COMPANY_JOBS_INSTALL_ENABLED` toolset gate adds a normal
released-core refresh and installer invocation for existing configured company
hosts. With the gate absent or false, the existing manifest and digest are
unchanged. Initial company provisioning invokes the installer directly. A release
must publish the core installer and compatible CLI before updating the runtime
capability receipt. This implementation does not publish that receipt or release.

The reconciler calls `POST /outpost/company/jobs` with `action: reconcile`. One
system timer (`hq-company-jobs.timer`, 60 seconds) reconciles every job; there
is not a separate poll per job. Invalid jobs are reported and skipped, and the
rest still install. A rejected job sets `errors` on the reconcile result to a
nonzero count and prints that count. The reconcile process itself still exits 0. The reconciler checks accepted content digests and exact
target bindings, and installs root-owned system timers in the accepted
schedule's timezone. A twice-daily hour list produces two timers. Disable or
deletion removes only this runner's units. Each timer starts an independently
supervised root service, which drops to `hq-jobs` for the job process.
systemd's start limit covers a bounded machine-token refresh (15 seconds) and
the HTTP call (15 seconds) for reconcile, the delivery call, and each secret,
then the job, then 30 seconds to write the receipt. The reconciliation timer
cannot truncate a longer job. A token refresh that does not return is rejected
with `machine_token_timeout` instead of running past that limit. Dispatch requests re-read the current accepted revision and
obtain server-authoritative occurrence/run identifiers through `scheduled`,
`dispatch`, or `recover`. Historical scheduled recovery records are not replayed.
Downtime schedules coalesce into the latest occurrence; receipts report coalescing.

Accepted `context.companyJob` carries `timeoutSeconds` (1–14400, default 600) and
`secrets` (unique uppercase environment names, at most 50). Context is covered by
the accepted content digest. Machine/authentication/runtime environment names
cannot be overridden. Secrets and API headers remain in memory; short-lived
machine token cache files use the private `/run/hq-company-jobs/tokens` runtime
filesystem. Secret values are redacted from captured runner output.

SQLite claims are transactional and durable. Scheduled claims are keyed by company,
job and scheduled occurrence; manual requests use their unique run ID. Terminal
receipts continue to suppress duplicates after expiry or process restart. Claims
expire after the execution deadline plus a safety margin. Reclaim checks the
process's boot/start identity rather than just its PID and refuses overlap with
a still-running owner. Acquisition tokens fence stale owners. A lost supervisor
after execution admission yields a complete `uncertain` receipt instead of
repeating potentially completed effects. This is conservative at-most-once effect
admission, not a claim of exactly-once external effects.
Execution admission remains durable if a recovery supervisor also crashes.

Each run's commands go in a root-owned transient scope
(`systemd-run --scope`, `KillMode=control-group`) when `systemd-run` is
available. The runner ends that scope with `systemctl kill` and `systemctl stop`
on exit and at the deadline, so the cgroup stops exactly that job's processes.
The runner does not record process IDs and does not poll the process table.
After the direct child is reaped it does not signal a PID. Where the scope
cannot be created, the deadline still signals the still-living direct child's
process group and nothing else. The runner then drains pipes briefly, so a
grandchild holding stdout cannot postpone the receipt.
Receipts and output include company, job, accepted revision, content digest, run ID,
scheduled time, actual start/end, machine principal, instance, outpost, attempt,
outcome and output location, plus available registration/edit/request provenance.
Failed, denied, timed-out and uncertain worker outcomes return a nonzero status.
Session replies are parsed from stdout; separately captured stderr diagnostics
are redacted and logged without corrupting the reply envelope.
Receipts are local JSON and SQLite records under `/var/lib/hq-job-runner/state`;
US-004 currently exposes no completion-report endpoint. Notification behavior in
the human job runner remains unchanged.
