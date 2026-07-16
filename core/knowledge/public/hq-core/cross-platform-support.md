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
- Execute bits: every shipped `*.sh` should be git mode `100755`. CI enforces this; `hook-gate.sh` also self-heals a missing `+x` at runtime.

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

CI also runs shellcheck (warning severity) and a Windows/macOS smoke subset of portability tests.

## Related

- Policy: `indigo-hq-core-staging-pr-mechanics` (wire new tests into `pr-checks.yml`)
- Deploy skill: `.claude/skills/deploy/SKILL.md` (`missing_dependency` status)
