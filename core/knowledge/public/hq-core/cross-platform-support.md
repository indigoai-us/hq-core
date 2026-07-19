# Cross-platform support (Linux, macOS, Windows Git Bash)

HQ's shell layer (hooks, core scripts, skill helpers) targets **bash** on:

| Platform | Supported baseline |
|----------|--------------------|
| Linux | bash 4+ (or bash 3.2+ where noted) |
| macOS | bash 3.2+ (system bash) / Homebrew bash |
| Windows | **Git Bash** (MINGW/MSYS) — not PowerShell-native |

PowerShell-native scripts are intentionally out of scope.

## Required dependencies

| Tool | Why | Install |
|------|-----|---------|
| bash | Hooks and scripts | Git for Windows includes Git Bash |
| git | Worktrees, index mode, HQ layout | [git-scm.com](https://git-scm.com) |
| node | HQ CLI, many hooks (via hook-lib fallback) | [nodejs.org](https://nodejs.org) or nvm/fnm/volta |
| jq | Policy pipeline, deploy skill, many scripts | see below |

### Install jq

```text
Windows (Git Bash):  winget install jqlang.jq
                     choco install jq
                     scoop install jq
Linux:               sudo apt install jq
                     sudo dnf install jq
macOS:               brew install jq
```

## Known limitations

- **`/deploy` identity** can parse tokens with **jq or node** (`identity-resolve.sh` → `hook-lib.sh`). If both are missing it returns `status=missing_dependency` (not a false login prompt).
- **Later deploy steps** in `deploy/SKILL.md` still call `jq` directly. Full upload path expects jq installed.
- Execute bits: every shipped `*.sh` should be git mode `100755`. CI enforces this; the shared hook launcher also attempts `chmod u+x` and falls back to `bash` for readable HQ-owned shell hooks.

## Runtime contract troubleshooting

HQ validates the same release contract for Claude, Codex, Grok, and Cowork:

- Shipped `SKILL.md` and generated `agents/openai.yaml` metadata must parse as YAML. This includes package-contributed Cowork skills.
- Concrete commands in shipped skills need narrow `allowed-tools` rules or an explicit approval-gated disposition.
- Hook adapters must execute a hook or emit bounded remediation. They must not silently skip a missing execute bit or failed launch.

### Validate skills and permissions locally

Install the maintained parser into a temporary dependency root, then run the validator:

```bash
node core/scripts/validate-agent-runtime-contracts.mjs install-parser --install-dir "${TMPDIR:-/tmp}/hq-agent-runtime-parser"
HQ_AGENT_RUNTIME_PARSER_ROOT="${TMPDIR:-/tmp}/hq-agent-runtime-parser" \
  node core/scripts/validate-agent-runtime-contracts.mjs
HQ_AGENT_RUNTIME_PARSER_ROOT="${TMPDIR:-/tmp}/hq-agent-runtime-parser" \
  node core/scripts/validate-agent-runtime-contracts.mjs validate-permissions
```

Run the hermetic four-runtime fixture matrix:

```bash
HQ_AGENT_RUNTIME_PARSER_ROOT="${TMPDIR:-/tmp}/hq-agent-runtime-parser" \
  bash core/scripts/tests/agent-runtime-contracts-e2e.test.sh
```

### Repair a hook permission failure

Runtime recovery is automatic when safe. If both chmod and the readable-shell fallback fail, HQ prints the repo-relative hook path, cause, and repair command without including the hook payload or secrets.

For an installed checkout:

```bash
chmod u+x "$HQ_ROOT/.claude/hooks/<hook>.sh"
```

For an HQ Core source checkout, preserve the mode in Git as well:

```bash
git update-index --chmod=+x -- .claude/hooks/<hook>.sh
```

If a skill is skipped with `invalid YAML`, quote descriptions containing `: ` or use a YAML block scalar. The validator reports the exact file, field, line, and remediation.

## Contributor conventions

### OS portability — `core/scripts/lib/portable.sh`

Source this for:

- `portable_stat_mtime` — dual stat with numeric probe (not naive `stat -f \|\| stat -c`)
- `portable_sed_inplace` — GNU/BSD in-place sed
- `portable_tmpdir` — `${TMPDIR:-/tmp}`
- `portable_date_epoch_to_iso`
- `portable_user` — `USER` / `USERNAME` fallback
- `require_jq` — hard-fail with multi-OS install guidance

### JSON — `core/scripts/hook-lib.sh`

Do **not** reimplement JSON engines in portable.sh. Use:

- `hq_json_get` / `hq_json_encode` — **jq first, then node**

### Lint

New scripts must pass:

```bash
bash core/scripts/lint-shell-portability.sh
```

CI also runs ShellCheck (warning severity), the Claude/Codex/Grok/Cowork contract matrix, and a Windows/macOS smoke subset of portability tests.

## Related

- Policy: `indigo-hq-core-staging-pr-mechanics` (wire new tests into `pr-checks.yml`)
- Deploy skill: `.claude/skills/deploy/SKILL.md` (`missing_dependency` status)
