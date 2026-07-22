# Wave 9B — Claude Code app/SDK hook gap

Feedback: `92d05940-949f-4dd6-b1e3-06ea57d03f77`

## Runtime gap

The affected Claude Code app/SDK runtime does not dispatch the command-hook
registrations in project `.claude/settings.json` for `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, or `PostToolUse`. The shell scripts are not
the fault: when invoked directly they emit the expected output. Consequently,
policy injection and lede voice injection do not run, nor do secret detection,
core-write and cross-company guards, autocommit, or journal capture. Terminal
Claude Code continues to dispatch these hooks, and the hook registrations have
not been removed.

This is a Claude Code product/runtime limitation. HQ cannot make an app/SDK
host dispatch lifecycle events it does not implement. Native instruction context
is a mitigation, not a mechanical replacement for hook enforcement.

## Durable native path

`.claude/CLAUDE.md` now natively imports `@personal-context.md`.
`.claude/personal-context.md` is user-editable and imports the existing
`personal/CLAUDE.md`, so personal voice and output hierarchy reach native Claude
context without `SessionStart` or `UserPromptSubmit`. It also keeps the critical
secret-handling, release-owned-core, cross-company, and irreversible-action
guidance in context.

`core/core.yaml` still replaces `.claude` during `/update-hq`, but now lists
`.claude/personal-context.md` in `replace_from_staging.preserve_subpaths`, next
to `.claude/settings.local.json`. The update flow backs it up before replacing
the tree and restores it afterwards. CLI write protection permits edits only to
this intentional user-owned context file, while retaining the protection for the
rest of `.claude`.

## Runtime-off warning

The native context contains an `HQ RUNTIME WARNING` that tells app/SDK users not
to treat the instructions as a security boundary. The hook-independent command

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger
```

now prints `HQ runtime enforcement: NOT OBSERVED` when a real session has not
written the policy-trigger ledger, and `OBSERVED` when it has. The command does
not run through the hook system, so it remains usable when lifecycle hooks are
dead. A missing ledger proves that the policy-trigger path did not dispatch; it
does not turn native context into an enforcement mechanism. Safety-critical work
in an affected host must use terminal Claude Code or equivalent host-side
enforcement.

SDK hosts can pass `--session-id <id>` to verify the current session rather than
accepting a stale ledger from an earlier terminal session.

## Verification

- `bash core/scripts/tests/hook-settings-release-contract.test.sh`
- `bash core/scripts/tests/hook-health-check.test.sh`
- `bash core/scripts/tests/block-core-writes-native-context.test.sh`
- `bash core/scripts/tests/block-core-writes-bash.test.sh`
- `bash core/scripts/tests/block-core-writes-repos-exempt.test.sh`
- `git diff --check`

## Delivery

- Implementation PR: [#409](https://github.com/indigoai-us/hq-core-staging/pull/409)
- CI: all `pr-checks` jobs and the separate `PR Audit` completed successfully.
- Merge: merged into `indigoai-us/hq-core-staging:main` at
  `2026-07-22T07:08:28Z` (merge commit `fe8db38ac7481c1336ea1bfdac0fd0ce21730aa9`).
