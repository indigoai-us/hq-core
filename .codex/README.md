# Codex Hooks

HQ enables Codex lifecycle hooks through `.codex/config.toml` and routes them
through `.codex/hooks/hq-codex-hook-adapter.sh`.

The adapter keeps hook policy centralized in `.claude/hooks/`:

- `SessionStart` injects HQ policy context.
- `PreToolUse` enforces Bash secret detection, active-run coordination, and
  protected-core checks for `apply_patch` edits.
- `PostToolUse` forwards checkpoint and registry-capture nudges back to Codex
  as hook context, then silently autosaves non-repo HQ edits.
- `Stop` runs observation and cleanup hooks, and preserves eligible checkpoint
  gate blocks as Codex-native continuation decisions.
- `.codex/output-style.md` bridges the active Claude output style into a
  Codex-readable file. The root `AGENTS.md` includes the compact always-on
  behavior; the bridge preserves the full source style for humans and tools.

### Windows

On Windows, Codex runs each hook's `commandWindows` instead of the POSIX
`command`, through the session shell: `pwsh -NoProfile -Command` (or Windows
PowerShell) when the shell is PowerShell, which is the default, and
`cmd.exe /C` otherwise. Every HQ hook sets `commandWindows` to a polyglot that
works in both shells:

```
cmd /d /s /c ' ver >nul 2>nul & <batch> & rem '; <PowerShell exit mapping>
```

PowerShell passes the single-quoted batch to a child `cmd.exe` and then maps
its exit code. For `PreToolUse`, any result other than 0 becomes 2, so a parse
error, a failure to start `cmd.exe`, or an adapter error denies the tool call.
Other events pass their exit code through, and a failure to start becomes 1.
Under `cmd.exe /C`, the leading `cmd /d /s /c '` fails silently, the batch runs
in that `cmd.exe`, and `& rem` comments out the PowerShell part. The batch
cannot contain `'`, so `config.toml` stores each value as a `'''` multiline
literal string. A Git Bash session shell is not supported for hooks.

The batch calls `.codex/hooks/hq-codex-hook.cmd`. It looks for the launcher in
`HQ_ROOT`, then the git top level, then the current folder, the same order as
the POSIX command. The launcher finds Git Bash (`HQ_BASH_EXE`, Git for Windows,
or the `git.exe` on `PATH`) and runs the same adapter with the hook's stdin. It
never uses the WSL `bash.exe` in `System32`, and it ignores an `HQ_BASH_EXE`
under the Windows folder with a warning. `PreToolUse` fails closed: if the
launcher or Git Bash is missing, or the adapter exits 1 or 3 or higher, it
exits 2 with the reason on stderr, so Codex denies the tool call. Every other
event is advisory: it prints a warning and exits 1, which Codex reports without
blocking. An adapter exit 2 reaches Codex as exit code 2. Changing
`commandWindows` changes each hook's hash, so Codex asks the user to trust the
hooks again after an update; `hq reindex` re-trusts HQ's own hooks.

### Hook security limits

Codex hook coverage is a guardrail, not a complete security boundary. Codex can
intercept Bash, `apply_patch`, and MCP tool calls, but not every possible tool
path. Keep critical policies in deterministic scripts and CI gates as well.

## Default permissions and opting into a sandbox

The shipped `.codex/config.toml` sets `sandbox_mode = "danger-full-access"`
and `approval_policy = "never"`. Codex runs model shell commands without a
filesystem or network sandbox and does not stop to ask for approval. Commands
can read and write anything your account can, including files outside the HQ
folder, and can reach the network.

This is the default because HQ hooks, work across multiple repositories, and
lane automation need those permissions. See
[the hook security limits](#hook-security-limits).

For one run, use either of these commands:

```sh
codex --sandbox workspace-write --ask-for-approval on-request
codex --sandbox read-only --ask-for-approval on-request
```

`workspace-write` limits writes to the active workspace. Commands that need to
write outside it or use the network may require approval. Network access is off
in `workspace-write` unless configuration enables it. HQ's
`.codex/config.toml` sets `[sandbox_workspace_write] network_access = true`;
that setting applies only when `workspace-write` is selected. Some HQ flows
that span repositories or use the network may need extra approvals or may not
work in the sandbox. See the [Codex sandbox documentation](https://learn.chatgpt.com/docs/agent-approvals-security)
for the current mode behavior.

You can also save these settings in `$CODEX_HOME/sandboxed.config.toml` (by
default, `~/.codex/sandboxed.config.toml`):

```toml
sandbox_mode = "workspace-write"
approval_policy = "on-request"
```

Select the profile and state the desired sandbox options on the command line
for that run:

```sh
codex --profile sandboxed --sandbox workspace-write --ask-for-approval on-request
```

The Codex CLI 0.160.0 help confirms that `--profile` loads
`$CODEX_HOME/<name>.config.toml` on top of the base user config and that
`--config` overrides a value loaded from `~/.codex/config.toml`. It does not
specify how profiles rank against project configuration, so this guide does
not claim that ordering. State the sandbox options on the command line when
you need to select them for a particular run.

Editing the project's `.codex/config.toml` directly is temporary because
`/update-hq` replaces it. Use the command-line flags or your profile instead.
