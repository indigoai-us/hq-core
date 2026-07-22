# Wave 10-D — nested `git init` hook carve-out

Feedback: `1b242f16-eb7f-4c35-86d5-9d32f81b11ab`

## Previous resolution logic

`.claude/hooks/block-hq-root-git-mutation.sh` reads the Bash command and the
harness-reported cwd, honors the audited `HQ_ALLOW_HQ_ROOT_GIT=1` environment
or inline bypass first, and classifies `git init` as a mutation because unknown
Git subcommands default to mutation (`.claude/hooks/block-hq-root-git-mutation.sh:51-57`,
`:76-94`, `:112-124`).

For a Git mutation, the hook extracts the first explicit `git -C` anchor; if
none exists, it looks for a preceding `cd` anchor (`:135-158`). An unanchored
mutation is allowed only when `git -C <tool-cwd> rev-parse --show-toplevel`
returns a repository other than HQ root. An explicit anchor is normalized,
resolved relative to HQ root when necessary, and similarly checked with
`rev-parse --show-toplevel` (`:346-374`).

That logic is correct for existing nested repositories but wrong before a new
repository has `.git`: Git walks upward from a new child under `repos/private/`
or `repos/public/`, finds the HQ root repository, and the hook blocks `init` as
an HQ-root mutation.

## Carve-out

The exception is in `.claude/hooks/block-hq-root-git-mutation.sh:196-315` and
runs before the existing upward-anchor decision:

- It applies only when the classified Git subcommand is exactly `init`, no
  mutating `gh` command is present, and the command is one standalone Git
  invocation. Newlines and shell control, substitution, grouping, and
  redirection operators are rejected, so a compound command cannot inherit the
  allowance.
- `git_init_target` parses global `-C` options in order, parses `git init`
  options that take values, and uses the optional directory argument when one
  was supplied. Otherwise, it uses the effective `-C` directory or the
  harness-reported cwd. `--separate-git-dir` and unknown option shapes do not
  qualify.
- The normalized target's parent must be exactly
  `<HQ_ROOT>/repos/private` or `<HQ_ROOT>/repos/public`. The target must be
  absent or a directory and must not contain a `.git` entry.
- Existing bare repositories are also rejected: because they have no `.git`
  child, the hook compares `rev-parse --absolute-git-dir` with the HQ git dir
  that a genuinely uninitialized child inherits upward. A different git dir
  means the target already resolves to a nested repository.

All failures to match this narrow predicate fall through to the original guard.
Consequently, `git init` at HQ root, deeper descendants, existing target repos,
other subcommands, compound commands, and the existing anchored/cwd behavior
remain unchanged.

## Regression coverage

`core/scripts/tests/block-hq-root-git-mutation.test.sh:21-26` builds regular,
bare, and uninitialized nested fixtures. Assertions at `:61-77` cover:

- `git init repos/private/newthing` with no `.git`: allowed;
- `git init` at HQ root: blocked;
- bare `git init` and `git init --bare` from a new direct child: allowed;
- `git -C repos/public/x init` against a new direct child: allowed;
- `git init --bare repos/private/newbare`: allowed;
- path-targeted init of existing regular and bare repositories: blocked;
- existing nested-repo cwd and `git -C` behavior: unchanged;
- deeper targets and a compound `git init && git push`: blocked.

The original assertions were retained. The focused suite reports 40 passed and
0 failed; the real Codex adapter/gate/hook suite reports 11 passed and 0 failed.
The no-Python suite reports 22 passed and 0 failed, and hook runtime diagnostics
and `git diff --check` also pass.

## Sanctioned bypass and classifier scope

Both sanctioned hook bypass forms remain at
`.claude/hooks/block-hq-root-git-mutation.sh:56-57` and are exercised at
`core/scripts/tests/block-hq-root-git-mutation.test.sh:114-126`: inline
`HQ_ALLOW_HQ_ROOT_GIT=1 git ...` and hook-environment
`HQ_ALLOW_HQ_ROOT_GIT=1` both allow genuine HQ-internal Git operations.

The reported permission-classifier denial is not implemented by this hook, and
no repository-owned permission classifier for that environment variable exists
in this checkout. HQ's policy describes Auto mode's classifier as an opaque
host-side policy engine. This change therefore does not broaden or work around
that classifier; the target-aware exception removes the need for the bypass in
the new nested-repository case.

## Delivery

- Implementation PR: [#411](https://github.com/indigoai-us/hq-core-staging/pull/411)
- CI: all 41 executed `pr-checks` jobs and the separate `PR Audit` completed
  successfully on head `ec2cfc4b63aa6fd97da1330377a4e259326c1405` (42 successful
  checks total; 2 path-gated checks skipped; 0 failures).
- Merge: merged into `indigoai-us/hq-core-staging:main` at
  `2026-07-22T08:55:25Z` (merge commit
  `1ba250351f9e9f608ba7bb089088bc5ff34d7b6f`).
