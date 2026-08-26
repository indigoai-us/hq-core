# Outpost scheduled jobs — registry schema

Declarative job definitions for recurring headless Claude/Codex runs on a
user's **Outpost**. Product command: `/schedule` (`/job` is a deprecated
alias). Registry YAML rides hq-sync; an on-box reconciler materializes
systemd user timers. Readiness and run telemetry live in **hq-pro**, not in
the YAML.

## Disambiguation: not fleet Agent Scheduled Jobs

| | **Outpost scheduled jobs** (this spec) | **Fleet Agent Scheduled Jobs** |
|---|---|---|
| Who | End-user personal/company jobs | HQ/Indigo fleet deep agents |
| Where | User Outpost (systemd user timers) | EventBridge Scheduler + IoT/vault |
| Registry | `personal/jobs/*.yaml`, `companies/{co}/jobs/*.yaml` | Fleet agent manifests / EventBridge |
| Product surface | `/schedule` | Company-agent / ops tooling |

Do **not** unify these systems in v1. Paths stay `…/jobs/` for Outpost jobs;
fleet docs remain under agent-scheduled-jobs architecture.

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
timezone: America/New_York       # required — IANA tz; reconciler renders OnCalendar with this tz
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

`id`, `name`, `schedule`, `timezone`, `runtime`, `exec`, `timeout_seconds`,
`notify`, `enabled`, `owner`, `created_at`.

### Field notes

- **`id`**: `[a-z][a-z0-9-]{1,62}` — unique within a validate pass over the
  registry set. Duplicate `id` across files is an error.
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
- Timer: `Timezone=` (job IANA tz), `OnCalendar=` (from 5-field cron),
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
- Logs: `~/.hq/jobs/logs/{id}/`
- Compute-meter marker (JSONL): `~/.hq/jobs/meters/runs.jsonl` schema
  `hq.outpost.job-run/v1` (`kind=scheduled-job-run`, job_id, runtime,
  started_at, ended_at, exit_status, duration_seconds)

### Sync hook

`outpost-jobs-reconcile.sh --ensure-hook` installs
`personal/hooks/Stop/90-outpost-jobs-reconcile.sh` so `hq-sync-runner` runs
reconcile after each sync cycle. On-demand: run the script directly.
Provisioning (US-005) enables linger + ensures the hook on every box.

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
