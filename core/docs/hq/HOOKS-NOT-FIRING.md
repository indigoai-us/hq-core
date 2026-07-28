# HQ hooks not firing in Claude Desktop or an SDK runtime

HQ safety, voice, and policy hooks live in the project's
`.claude/settings.json`. Claude Code terminal sessions can work while the
affected Claude Code app/SDK runtime silently runs none of those command hooks,
even when that settings file is present and its shell scripts work when invoked
by hand.

In that runtime, the command-hook registrations for `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, and `PostToolUse` are not dispatched. This
leaves policy injection, per-turn voice injection, secret detection, core-write
and cross-company guards, autocommit, and journal capture inactive. This is a
Claude Code product/runtime limitation: HQ cannot make a host dispatch a hook
event that the host does not implement.

HQ now mitigates the gap with a native import in `.claude/CLAUDE.md`:
`@personal-context.md`. The imported `.claude/personal-context.md` is preserved
by `/update-hq`, imports `personal/CLAUDE.md`, carries the minimum secret,
core-write, and cross-company guidance, and warns directly in context when an
app/SDK host may not run hooks. It is not a mechanical security boundary. Use
the terminal CLI or host-side enforcement for work that requires a guaranteed
block.

## Diagnose without relying on hooks

From the HQ root, run:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD"
```

The checker confirms valid `.claude/settings.json` plus non-empty
`SessionStart` and `PreToolUse` command hooks, that every `$CLAUDE_PROJECT_DIR`
reference in those commands is quoted, and that the script each command actually
runs exists. It applies the same command scan to `.claude/settings.local.json`
when that optional overlay is present, since Claude Code loads its hooks too. It
is an ordinary shell command, so it works even when every lifecycle hook is
unavailable.

The scan splits each command the way `/bin/sh` would rather than matching text,
so it reports only the references the shell would really split, and it reads a
path through its closing quote so a directory name containing a space is named
in full. A path the command does not execute — a guarded optional hook, a data
argument, a file the hook writes at runtime — is not required to exist.

## An install path containing a space

Hook commands are executed by `/bin/sh`. An unquoted `$CLAUDE_PROJECT_DIR` is
word-split, so on a root such as `/Users/you/Documents/SENDER HQ` the shell
tries to execute `/Users/you/Documents/SENDER` and every hook fails with
`No such file or directory`. Those failures are non-blocking, so nothing is
surfaced in the session: policy injection, secret detection, the core-write and
cross-company guards, autocommit, and journal capture are all inactive while
the session looks normal.

Both `"$CLAUDE_PROJECT_DIR/..."` and `"${CLAUDE_PROJECT_DIR}/..."` are safe; only
an unquoted reference splits. The released `.claude/settings.json` quotes every
one of them. A settings file can still drift out of that shape through an old
install, a hand edit, a merge, or a hook added to
`.claude/settings.local.json`. The checker reports that condition by name and
says which file it came from. For the shipped file, the targeted rescue below
restores the released, quote-safe copy:

```bash
hq rescue -y --paths .claude
```

`.claude/settings.local.json` is machine-local: `core/core.yaml` excludes it
from the release payload and preserves it across updates, so a rescue will not
rewrite it. Quote any `$CLAUDE_PROJECT_DIR` reference in that overlay by hand.

After starting an actual Desktop or SDK session, verify that the policy trigger
was observed as well:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger
```

On a brand-new HQ root, run the first command before the ledger check: no
ledger exists until a session has had an opportunity to run. If the second
command prints `HQ runtime enforcement: NOT OBSERVED`, it has made the missing
dispatch loud without relying on a hook to run the diagnostic.

An SDK host with the current session ID can make this conclusive for that
runtime rather than accepting a prior CLI session's evidence:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --session-id "$SESSION_ID"
```

## Restore the released project settings

If the checker fails, restore the release-owned `.claude` tree. This replaces
the missing project settings while retaining the machine-local
`.claude/settings.local.json` override:

```bash
hq rescue -y --paths .claude
bash core/scripts/check-hq-hooks.sh --root "$PWD"
```

`/update-hq` runs this postcheck automatically and repeats the targeted rescue
when needed.

## Make Desktop and SDK load the project

In Claude Desktop, open the HQ root folder itself as the project. Do not launch
from a parent directory or an unrelated child directory; start a new session
after selecting the root.

For an SDK runtime, pass both values on every launch to load the native project
context:

```ts
const hqRoot = "/absolute/path/to/HQ";

query({
  prompt: "...",
  options: {
    cwd: hqRoot,
    settingSources: ["project"]
  }
});
```

`cwd: hqRoot` locates the project and `settingSources: ["project"]` permits
the runtime to load native project context such as the durable
`personal-context.md` import. In the affected app/SDK runtime, neither option
causes command-hook events to dispatch. Restart the session after changing
either value, then rerun the `--require-ledger` check; a `NOT OBSERVED` result
means use the terminal CLI or host-side enforcement for safety-critical work.
