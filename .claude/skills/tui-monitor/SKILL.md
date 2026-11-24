---
name: tui-monitor
description: Build a live read-only terminal monitor (TUI) for machines or services. Stdlib Python, ssh collector, nothing installed remotely. Scaffolds a working template.
allowed-tools: Bash(bash .claude/skills/tui-monitor/scripts/scaffold.sh:*), Bash, Read, Write, Edit
---

# Build a terminal monitor (TUI)

This skill builds a live terminal monitor: one full-screen view that refreshes
every few seconds and shows the health of some machines or services at a
glance. It comes with a small working template (`template/`) that you copy and
then grow. The template monitors CPU, memory, disk and top programs on this
machine and any machines reachable over ssh.

Use it when the ask is a live view that someone leaves open in a terminal
window. For a one-off report, a chart or a web dashboard, use a different tool.

## 1. Scaffold

Pick a short lower-case name (for example `boxmon`) and a home for it. A monitor
for one person goes in `personal/tools/<name>/`. A monitor a team shares goes in
`companies/{company}/skills/<name>/scripts/`, with its own `SKILL.md` next to it
so teammates can open it by name. A monitor never goes in `core/`.

```bash
bash .claude/skills/tui-monitor/scripts/scaffold.sh personal/tools/boxmon boxmon
```

That copies the template and renames `tuimon` to your name everywhere:

| File | What it is |
|------|-----------|
| `<name>.py` | The renderer: threads, history, verdicts, layout, keys. |
| `collector.py` | Runs on each watched machine and prints one JSON line per interval. |
| `<name>` | Launcher. Resolves its own folder, so it runs from anywhere. |
| `<name>.command` | macOS double-click launcher that sizes its own Terminal window. |
| `hosts.example` | Example for `~/.config/<name>/hosts`. |
| `selftest.py` | The checks in section 10. |

Run `python3 <dest>/selftest.py` straight away. It must pass before you change
anything, so later failures are yours.

## 2. Collector and renderer are separate programs

The collector measures; the renderer draws. Keep them apart:

- The collector is one self-contained script with no imports outside the
  standard library and no local modules. It prints one JSON object per line,
  flushes, sleeps, repeats. It holds no state the renderer needs except what
  is in the line.
- The renderer starts one collector per machine as a child process (one thread
  each), reads lines, keeps the last sample and a short history per series
  (`collections.deque(maxlen=...)`), and redraws from that state on its own
  clock. A slow or dead machine never blocks the frame.
- Rates (bytes per second, CPU percent from tick counters) are computed in the
  collector from two of its own readings, so the renderer never needs two
  samples to show a number.
- The collector exits by itself when the reader goes away: a failed write
  (`BrokenPipeError`) or `os.getppid() == 1`.

For sources that are not machines (an HTTP endpoint, a database replica, a
cloud API), use the same split with tiers: one thread per source, each with its
own refresh interval, keeping the last good data and the last error. Slow or
costly tiers cache their last result on disk (for example
`~/.cache/<name>/<tier>.json`, written to a temp file then renamed) so a
restart shows data at once and marks it "(cached)". Show each tier's age in a
footer line. `r` wakes every tier now.

## 3. Standard library only, no sudo

- Python 3.9 or newer, standard library only, because that is what a stock
  macOS (`/usr/bin/python3`) and most Linux machines have. No `pip install`, no
  curses (the template draws with plain ANSI escapes, which is simpler to
  clip and test).
- No sudo, ever. If a number needs root (some temperature, power and per-process
  I/O readings do), find a source that does not (`sysctl`, `vm_stat`, the Linux proc filesystem,
  `ps`, `ioreg`, `pmset`, IOKit through `ctypes`), or leave it out and say
  "not readable" in the panel.
- Shell out with a list argv and a timeout (`subprocess.run([...], timeout=5)`),
  never `shell=True`.
- A monitor that needs a third-party package (a database driver, for example)
  gets it from its launcher with an isolated runner such as
  `uv run --with '<pkg>' python -I <name>.py`, never from a global install.

## 4. Remote machines over ssh, nothing installed

The collector is streamed to the remote Python on stdin:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    -- user@host "TUIMON_INTERVAL=2 python3 -u -" < collector.py
```

- `BatchMode=yes` so ssh fails instead of asking for a password inside the TUI.
  The person sets up key login once (`ssh user@host true` must work).
- `ServerAlive*` options so a machine that drops off the network turns offline
  within seconds.
- `--` before the target, and the renderer rejects targets that start with
  `-`, so a hosts-file line cannot become an ssh option.
- Nothing is copied to or written on the remote machine. When the renderer
  quits it kills each child's process group (`start_new_session=True` plus
  `os.killpg`); the remote collector then fails its next write and exits.
- If a machine goes away, mark it offline, keep its last sample greyed out or
  hidden, and reconnect every 5 seconds.

## 5. Hosts come from a config file

Never hardcode hostnames, usernames or IP addresses in the scripts. The
renderer reads targets in this order:

1. targets on the command line (`<name> user@host ...`);
2. the `<NAME>_HOSTS` environment variable (space separated);
3. `~/.config/<name>/hosts`, one ssh target per line, `#` starts a comment.

With none of them it shows this machine only. When someone asks to add a
machine, ask for its ssh target and add the line to their hosts file for them.
Friendly names for machines belong in that person's config too, never in the
script.

## 6. Verdicts and status

Every machine (or source) gets one word and one colour, computed in one
function from the latest sample:

| Verdict | Colour | Meaning |
|---------|--------|---------|
| connecting | grey | no sample yet |
| healthy | green | nothing crossed a threshold |
| busy | yellow | at least one soft threshold crossed |
| strained | red | at least one hard threshold crossed |
| offline | red | the collector exited, or no sample for 4 intervals |

- Put the thresholds in named constants at the top of the renderer and quote
  them in the README, so a reader can check why a machine is yellow. The
  template's: load per core over 1.5 busy, over 3 strained; memory over 85%
  busy, over 95% strained; disk under 10% free busy, under 5% strained.
- Return the reasons with the verdict ("load 36 on 18 cores", "disk 4% free")
  and print them next to it. A colour without a reason is not useful.
- The header carries one coloured dot per machine, so the whole fleet's state
  reads in one line. A summary verdict for several sources is the worst of
  them.
- Keep verdict text plain: "memory tight", not a raw kernel level number.

## 7. Layout and width

- Group by category, one row per machine: MACHINES, CPU, MEMORY, DISK, then
  a TOP PROGRAMS block with one column per machine. Comparing machines is
  then a vertical read. (A layout with one boxed panel per machine also works;
  macOS monitors that show many readings per machine have used both.)
- Every line is built to exactly the terminal width with a `clip(s, w)` helper
  that counts visible characters and skips ANSI codes, then pads. Nothing
  wraps.
- Fixed-width parts first (name column, bar, percent, figures), then give the
  remaining width to sparklines, capped so they do not stretch absurdly.
- Columns side by side when they fit (the template allows about 44 columns
  each), stacked when they do not. Below the minimum width (60), render at the
  minimum and let the terminal cut it.
- A short terminal drops the blank spacer rows first, then shortens the
  longest list, then cuts at the bottom.
- History as sparklines (`▁▂▃▄▅▆▇█`) and current values as bars (`█` filled,
  `░` empty), coloured green to yellow to red by level. Respect `NO_COLOR`.
  Use 24-bit colour when `COLORTERM` says so, else the 256-colour cube.
- Times relative and short ("3m ago"); sizes in K, M, G, T with one decimal
  under 100.

## 8. Flags, keys and launchers

Flags every monitor supports:

| Flag | Does |
|------|------|
| `--once` | Wait until each machine has a sample or is offline, print one frame to stdout and exit. Width from `COLUMNS`. Used by tests and by agents that want a snapshot. |
| `--local` | This machine only; ignore the hosts file. |
| `--interval=N` | Seconds between samples (minimum 1). |
| `-h`, `--help` | Print the module docstring. |

Keys in the live view: `q`, Esc or Ctrl-C quits; `r` reconnects offline
machines (or refreshes every tier) now. Add page keys (`s` for a second page,
`m` back, tab to switch) when the monitor grows a second page.

The full-screen loop: put stdin in cbreak mode, switch to the alternate screen
and hide the cursor, redraw from the top (`\x1b[H`, then `\x1b[K` at the end of
each line and `\x1b[J` after the last) every half second, read keys with
`select` and a timeout. In a `finally` block: stop the threads, kill the
collectors, restore the terminal settings, show the cursor, leave the
alternate screen. Turn SIGTERM into the same exit path. Without a terminal and
without `--once`, exit with a message that says to use `--once`.

Launchers resolve their own folder (`$(cd "$(dirname "${BASH_SOURCE[0]}")" &&
pwd -P)`) and call the renderer by that path, so they work from any directory
and contain no absolute paths. The macOS `.command` launcher sizes the window
(`printf '\033[8;<rows>;<cols>t'`) and sets the title before handing over.
Size it so the default layout fits without wrapping. Sync tools do not always
keep the executable bit, so tell people to open it with
`chmod +x <name> <name>.command && open <name>.command` the first time. A
launcher that needs secrets injects them with `hq secrets exec --only
<NAMES> -- ...` and never prints them.

## 9. Read-only and private

- The monitor and its collectors only read. They never kill, restart, clean
  up or change anything on a watched machine, even when a verdict is red. A fix
  is a separate, explicit action the person asks for.
- Network sources use GET or read-only database roles with a statement
  timeout. Cloud reads use read-only credentials.
- Only what the panel shows leaves the collector. Process names leave, their
  arguments do not (arguments can hold tokens and file paths). Never put
  secrets, hostnames or personal paths in a sample's text.
- Files the monitor reads from HQ are found relative to the script or through
  an environment variable, never through an absolute home path.

## 10. Test before you hand it over

`selftest.py` runs these checks; run it after every change and give the
result when you report:

1. `--once` at 60, 100 and 180 columns exits 0, every line fits the width, and
   each section heading is present.
2. A full-screen run in a pseudo-terminal draws a frame, quits on `q` with exit
   code 0, and restores the terminal (leaves the alternate screen, shows the
   cursor).
3. Afterwards no collector is running on this machine, and with
   `selftest.py user@host` none is left on the remote either.

Also look at one `--once` frame yourself at a narrow and a wide width with the
colour codes stripped (`sed 's/\x1b\[[0-9;]*m//g'`): columns should line up and
no reading should say something misleading. Then point an unreachable host at
it (`<name> --once nobody@invalid.invalid`) and confirm it shows offline with
the ssh error rather than hanging.

When it passes, open it for the person with the `.command` launcher (macOS) or
the plain launcher, rather than asking them to type the command.
