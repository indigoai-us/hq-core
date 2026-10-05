# Cross-platform support (Linux, macOS, Windows Git Bash)

HQ's shell layer (hooks, core scripts, skill helpers) targets **bash** on:

| Platform | Supported baseline |
|----------|--------------------|
| Linux | bash 4+ (or bash 3.2+ where noted) |
| macOS | bash 3.2+ (system bash) / Homebrew bash |
| Windows | **Git Bash** (MINGW/MSYS) — not PowerShell-native |

PowerShell-native scripts are intentionally out of scope.

## Line endings (LF everywhere)

HQ text is **LF in git and on disk on every OS**, including Windows.

Root `.gitattributes` sets `* text=auto eol=lf` (with explicit `binary` rules for images/fonts/archives). That stops Git for Windows `core.autocrlf` from checking out CRLF under locked paths (`.claude/`, `core/`, …).

Why it matters:

- Shell hooks and scripts assume Unix newlines.
- Desktop **Core Drift** compares local bytes to upstream git blobs (LF). A CRLF working tree looks like hundreds of "Modified" files even when content matches.

After a **fresh** clone/checkout on Windows, text files should show LF only.

### Repair existing Windows worktrees (CRLF already on disk)

Pulling the `.gitattributes` change does **not** rewrite unchanged files that already have CRLF on disk — `git status` stays clean while bytes stay CRLF. Desktop Core Drift (pre-0.10.24) and bash hooks still see those bytes.

With a **clean** worktree (commit or stash first):

```bash
bash core/scripts/normalize-eol-lf.sh
# or:
bash core/scripts/normalize-eol-lf.sh /path/to/hq-root
```

That force-rechecks out every tracked path so `eol=lf` lands LF on disk. Safe no-op on macOS/Linux when files are already LF. `/update-hq` runs the same script after a successful `hq rescue` when the script is present.

If an editor rewrites CRLF later, re-run the script (or restore the file from git). Do not leave locked core files edited only for line endings.

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
- Execute bits: every shipped `*.sh` should be git mode `100755`. CI enforces this. On Linux/macOS the shared hook launcher attempts `chmod u+x` and falls back to `bash` for readable HQ-owned shell hooks. **Do not `chmod` HQ files in Git Bash** — MSYS rewrites NTFS ACLs with DENY ACEs and can make the owner unable to read the file (POSIX `ls` still shows `-rw-r--r--`). Windows launch uses `bash file.sh` instead of `chmod`. If core files are unreadable, run `bash core/scripts/repair-windows-core-acls.sh`.

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

On Linux/macOS:

```bash
chmod u+x "$HQ_ROOT/.claude/hooks/<hook>.sh"
```

On Windows Git Bash, do not chmod. Reset NTFS ACLs instead:

```bash
bash core/scripts/repair-windows-core-acls.sh --root "$HQ_ROOT"
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
- `portable_native_path` — `cygpath -m` so native Windows binaries can open Git Bash `/tmp` paths
- `portable_qmd_models_dir` / `portable_qmd_embed_model_ready` / `portable_qmd_cmd_would_download_model` — refuse in-turn GGUF pulls
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
