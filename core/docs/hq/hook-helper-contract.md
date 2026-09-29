# Wave 8 hook-helper call-site contract

This inventory pins the current hook behavior for the twelve helpers that are
planned to move to `hq core`. Hook behavior is unchanged by this story. A
forwarder failure is the same helper failure as any other non-zero exit unless
the caller already distinguishes it.

## Mechanical call-site search

The inventory was derived from this tracked-source search, including every
registered hook directory and hook library:

```sh
git -C "$ROOT" grep -nE 'derive-trigger-facts|eval-trigger|session-title|session-title-config|session-project|session-journal|share-suggestion-state|repo-run-registry|detect-stale-review-base|register-project|migrate-policy-triggers|work-mesh-live-rebind' -- '.claude/hooks' '.codex/hooks' '.grok/hooks' 'core/hooks' 'core/scripts/lib' 'core/scripts/migrate-policy-triggers.sh' ':!.claude/hooks/tests' ':!core/scripts/tests' ':!core/scripts/__tests__'
```

The scan finds comments, registration records, and path guards as well as
commands. The table below records executable calls and guards that affect
whether a hook runs. The Codex and Grok adapters do not directly invoke any of
these helpers; they dispatch the registered Claude hooks.

## Call-site contract

| Registered hook or entry | Helper | Call form | Missing or not executable | Non-zero exit, including 127 | Prints nothing |
| --- | --- | --- | --- | --- | --- |
| `.claude/hooks/block-on-active-run.sh` | `repo-run-registry.sh` | `exec`: direct executable, `owner-of`; stderr is discarded and `[]` is used on failure. | Missing or non-executable is detected first; writes the “active-run guard skipped” warning to stderr and exits 0 (fail open). | Uses the empty-list fallback and exits 0. No CLI-floor message reaches the hook. | Empty result allows the tool call. |
| `.claude/hooks/check-repo-active-runs.sh` | `repo-run-registry.sh` | `exec`: direct executable, `check`; combined output is captured. | Missing or non-executable exits 0 silently. | The failed check is treated as no warning; exits 0. | No banner is emitted. |
| `.claude/hooks/hq-auto-acl-suggest.sh` | `share-suggestion-state.sh` | `exec`: direct executable, `is-suppressed` then `enqueue`; piped JSON on enqueue. | A missing file logs `missing state helper` to stderr and exits 0. A non-executable file passes the `-f` check; invocation errors are handled as failures. | The suppression probe is ignored; enqueue failure logs `unable to enqueue suggestion`; hook exits 0. The forwarder message can reach stderr. | Suppression probe is treated as false; enqueue still runs when a payload exists. |
| `.claude/hooks/inject-policy-on-trigger.sh` | `derive-trigger-facts.sh` | `bash`: stdin redirected or piped; failure is followed by `|| true`. | An absent file prevents the shared evaluator block from running. A non-executable file is still interpreted by `bash`. | Stderr is inherited, stdout becomes an empty facts record, and policy injection continues with `|| true`. | Empty facts mean no facts from this helper. |
| `.claude/hooks/inject-policy-on-trigger.sh` | `eval-trigger.sh` | `guard`: existence guard only; the hook evaluates expressions with its inline parser and does not execute this helper. | An absent file prevents the policy-evaluation block from running. A present non-executable file satisfies the `-f` guard. | Not observed: this path is not invoked. | Not observed: this path is not invoked. |
| `.claude/hooks/journal-due.sh` | `session-journal.sh` | `exec`: direct executable in command substitutions and standalone calls. | The initial `dir-path` call's stderr is redirected away; without a session/tool milestone the hook continues and exits 0. | Failures are not checked; later milestone calls also ignore their status. | Empty `dir-path` continues into the hook’s empty-directory handling. |
| `.claude/hooks/journal-precompact.sh` | `session-journal.sh` | `exec`: direct executable in `index-path` command substitution, followed by `|| echo ""`. | Missing or non-executable is suppressed by the command’s stderr redirection; the hook continues and exits 0. | Failure is ignored; the journal reminder is still printed. | An empty path is used in the reminder. |
| `.claude/hooks/native-plan-project-sync.sh` | `session-project.sh` | `exec`: direct executable with piped JSON; stdout/stderr discarded and failure followed by `|| true`. | Missing or non-executable exits 0 before reading the active-project pointer. | Failure is ignored; no sync is recorded. | No sync is recorded. |
| `.claude/hooks/repair-stale-review-base.sh` | `detect-stale-review-base.sh` | `bash`: runs through `bash` for `--check`, report, and `--fix`; output is captured or redirected. | Missing file exits 0 before the calls. A non-executable file is still interpreted by `bash`. | Check/fix failures are ignored or converted to an empty report; the hook exits 0. | The report is treated as empty and no repair is applied. |
| `.claude/hooks/session-title.sh` | `session-title.sh` | `exec`: direct executable in command substitution; stderr redirected and failure followed by `|| true`. | Missing or non-executable exits 0 before title processing. | Failure is ignored and the hook continues with an empty computed title. | The title remains empty; later hook behavior still runs. |
| `.claude/hooks/session-title.sh` | `session-title-config.sh` | `guard`: file-presence guard only. The hook parses the YAML settings inline; it never executes this helper. | Missing skips the inline settings parse. A non-executable file still passes the `-f` guard and the YAML parse runs. | Not observed: this path is not invoked. | Not observed: this path is not invoked. |
| `.claude/hooks/validate-policy-frontmatter.sh` | `eval-trigger.sh` | `bash`: runs through `bash` in a command substitution and captures stderr with stdout. | Missing or non-executable calls `block_missing_evaluator`, which blocks the write with exit 2. | Any evaluator failure, including 127, calls `block_missing_evaluator` and blocks with exit 2. | An empty or malformed result also blocks with exit 2. |
| `core/scripts/migrate-policy-triggers.sh` (registered SessionStart entry) | `migrate-policy-triggers.sh` | `exec`: the registry invokes this executable hook entry; the availability check maps the entry to itself. | Missing or non-executable entry cannot be dispatched. | A generated forwarder's CLI floor failure prevents the entry from starting. | No migration occurs. |
| `core/scripts/migrate-policy-triggers.sh` (registered SessionStart entry) | `eval-trigger.sh` | `bash`: runs through `bash` from `when_parses` to validate each synthesized expression. | A missing file makes `when_parses` return success without validation. A non-executable file is still interpreted by `bash`. | A non-zero evaluator result rejects that synthesized expression; its stderr is inherited. | An empty evaluator response fails the `ok` check. |
| `core/hooks/SessionStart/35-work-mesh-session-start.sh` | `register-project.sh` | `bash`: starts `bash` with `--retry-pending` in a detached child; child output goes to the per-company log. | Missing file skips the retry. A non-executable file is still run by `bash`. | The retry wrapper ignores failure; no helper output reaches the hook. | No registration is recorded by that retry. |
| `core/hooks/Stop/40-auto-acl-share-suggestion.sh` | `share-suggestion-state.sh` | `exec`: direct executable, `peek`; stdout is captured and failure followed by `|| true`. | Missing file exits 0 silently. | Failure is ignored; helper stderr can reach the hook. | No reminder is emitted. |
| `core/hooks/Stop/50-after-turn-suggestions.sh` | `share-suggestion-state.sh` | `exec`: direct executable, `peek`; stdout is captured and failure followed by `|| true`. | Missing file skips the pending-share check. | Failure is ignored; helper stderr can reach the hook and the hook continues with other suggestions. | The hook continues with other suggestions. |

`work-mesh-live-rebind.sh` has no direct hook invocation in this tree. The
SessionStart and UserPromptSubmit Work Mesh hooks source
`core/scripts/lib/work-mesh-live-rebind.sh`, which remains a scaffold library;
the top-level command path also appears in user-facing clarification text. The
library reference is not a call to the moved top-level command.

`migrate-policy-triggers.sh` is itself a registered SessionStart entry, rather
than a caller of a second helper. The helper checker verifies that registered
entry's file and CLI floor in addition to the executable call sites in the
table.

Non-hook callers found: `core/scripts/lint-policy-triggers.sh` runs
`eval-trigger.sh`; `core/scripts/policy-benchmark.sh` uses it in its synthetic
injector corpus. The migration script is itself the registered SessionStart
entry and also calls the evaluator. No direct helper call was found in
`core/scripts/lib/hook-adapter-core.sh`.

`check-hq-hooks.sh` reports a separate failing line for each registered
hook/helper pair when the helper is missing. It checks executable mode only for
`exec` call forms; helpers invoked by `bash` need only exist, and presence-only
`guard` forms need only exist. For `exec` and `bash` forms it sources the F1
library and checks a generated `hq_cli_floor_check` without executing the
helper.
