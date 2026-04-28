---
name: designate-team
description: Mark an HQ company directory as cloud-backed, run company sync, and write an audit row for HQ Pro team designation.
allowed-tools: Read, Bash(bash:*), Bash(yq:*), Bash(awk:*), Bash(grep:*), Bash(wc:*), Bash(tr:*), Bash(mkdir:*), Bash(mktemp:*), Bash(mv:*), Bash(printf:*), Bash(date:*), Bash(jq:*), Bash(hq:*)
argument-hint: "<company-slug>"
---

# Designate Team

Codex bridge for `/designate-team`.

## Source Of Truth

Read `.claude/commands/designate-team.md` first. That slash command owns the
validation rules, idempotent YAML update behavior, sync invocation, and audit
row format.

## Codex Adaptation

Execute the command workflow inline from the HQ root with the requested
`<company-slug>`.

Required behavior:

- Refuse `personal`.
- Validate the slug is a key under `companies:` in `companies/manifest.yaml` (the manifest is wrapped under a top-level `companies:` key for hq-sync menubar compatibility).
- Refuse manifest entries with `status: archived`.
- Validate `companies/{slug}/` exists locally.
- Create `companies/{slug}/company.yaml` if missing.
- Set `cloud: true` idempotently, with exactly one `cloud:` key afterward.
- Prefer `yq`; use the awk fallback from the command when `yq` is unavailable.
- Run `hq sync push "companies/{slug}" --hq-root "$PWD" --company "{slug}" --message "designate-team:{slug}" --on-conflict keep` when the installed `hq` supports `sync push`.
- Fall back to legacy `hq sync --companies` only when `sync push` is not present.
- If `hq` is missing, tell the user the exact `hq sync push ...` command to run.
- On successful sync, parse the `cmp_*` ULID + `hq-vault-cmp-*` bucket name out of `hq sync push` output and idempotently upsert them into `.companies.{slug}.cloud_uid` + `.companies.{slug}.bucket_name` in `companies/manifest.yaml` (yq required; awk fallback warns + skips).
- On successful sync, append one JSONL row to `workspace/learnings/designate-team-runs.jsonl` capturing `bucket_url`, `cloud_uid`, `bucket_name`, and `manifest_upserted`.

End with:

- The company slug.
- Whether `company.yaml` changed.
- Whether `hq sync push` or legacy `hq sync --companies` ran, or whether sync was skipped because `hq` was missing.
- The bucket URL if one appeared in sync output.
