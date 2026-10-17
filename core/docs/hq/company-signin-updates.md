# Company sign-in watcher updates

`company-jobs-install.sh` refreshes the long-running
`hq-company-signin.service` after installing a changed core release. The
installed digest includes `core/core.yaml`, the watcher unit, and every file
under `core/scripts/lib`, so a same-version repair of an imported module also
triggers an update. The company-jobs reconciler and retry helper are oneshots;
they load fresh code on each timer run and do not need restarting.

The installer runs the restart helper before enabling the watcher. An inactive
watcher starts normally. For an existing watcher, the helper uses
`systemctl try-restart` only when its installed digest differs. The digest is
saved only after success; failures stay pending for the retry timer.

## When a restart waits

A box sitting at the sign-in link always has a `claude auth login` child. That
child is not, by itself, a sign-in in progress. The watcher records one of two
phases in `/var/lib/hq-job-runner/state/signin-phase`, mode 600, with no URL,
code, or credential:

- `awaiting_person <epoch ms>` — a link has been posted and no login code has
  been returned for it. The timestamp is when that link was posted.
- `code_entry <epoch ms>` — a login-code fetch returned a code and the watcher
  typed it. This phase stays until that login exits, sign-in completes, or a
  regenerate replaces the login.

The helper pauses the Node parent, then reads the phase file and the child
list. Pausing the parent closes the race where a new login or phase write
could start between inspection and restart. The login child keeps running
until the helper actually restarts the service. The helper never reads
terminal output, URLs, codes, or credentials.

Defer the restart only when:

- the phase is `code_entry` and a login child is still alive, or
- the phase is `awaiting_person` and the posted link is younger than 10
  minutes, or
- there is no phase file (a watcher from before this rule) and a login child
  is younger than 10 minutes, or its age cannot be read.

An `awaiting_person` link older than 10 minutes is restarted even though the
login child is still running. A legacy watcher with no phase file is restarted
when every login child is older than 10 minutes. That legacy clock is the
child's start time, which is when the login began, not when a person submitted
a code. A code submitted in the last few seconds on a legacy box can be
dropped; the replacement watcher posts a new link so the person is not left
on a dead one. Once the updated watcher is running, a received code sets
`code_entry` and the restart waits until that attempt ends. There is no age
cap on `code_entry`.

Missing or unreadable process status fails closed. A corrupt phase file fails
closed: the helper does not restart, and the timer tries again. The helper's
`finally` and the unit's `ExecStopPost` resume the parent on failure, including
helper termination or timeout.

`hq-company-signin-restart.timer` retries every 30 seconds. The digest is saved
only after a successful restart, so a deferred update stays pending. The retry
service emits only `unchanged`, `inactive`, `deferred`, `restarted`, or
`failed_retry_pending`. Operators can inspect it with
`journalctl -u hq-company-signin-restart.service`. Turning off box sign-in
disables the timer.

A failing helper during install does not stop the rest of
`company-jobs-install.sh`. The watcher unit is still enabled. The fixed log
line is `company-signin restart helper failed; timer will retry`. It contains
no URL, code, or credential. The timer retries the helper.

## Admin experience

After an idle restart, the new watcher process posts a new link with the
existing `login-url` action. The HQ console and `hq outposts status` show that
new link because they read the link the watcher just posted. No new admin
command or screen is required. `regenerate-pending` is unchanged: the new
process still polls it and replaces the login when a regenerate is waiting.

An admin who has already had a code delivered to the watcher keeps that
attempt. The update waits until the login exits. An admin looking at a link
that nobody has entered a code for keeps that link for 10 minutes from the
time it was posted, then gets a new one. A link posted less than 10 minutes
ago is not replaced just because an update is pending. The existing
awaiting-box state remains while the watcher prepares sign-in; this change
does not add a progress indicator or guarantee a link when the provider or
network is unavailable. The retry journal distinguishes a deferred update from
one that has been applied.

Regression coverage includes an idle sign-in past the 10-minute bound, a code
entry that must not restart, a fresh link inside the bound, legacy watchers
with no phase file, a failing install helper that still enables the watcher,
version changes, unchanged installs, inspection and restart failures, and
unit/module changes. A disposable Linux CI runner also exercises the
installer-generated units against real systemd, including a young login child
and the automatic deferred retry. No customer box is changed by these tests.
