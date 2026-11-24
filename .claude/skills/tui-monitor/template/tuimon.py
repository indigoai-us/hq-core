#!/usr/bin/env python3
"""tuimon: live terminal monitor for this machine and other machines over ssh.

    tuimon                  this machine + the hosts in ~/.config/tuimon/hosts (or $TUIMON_HOSTS)
    tuimon user@host ...    this machine + the named hosts
    tuimon --local          this machine only
    tuimon --interval=5     refresh every 5 seconds (default 2)
    tuimon --once           print one frame and exit (no full-screen mode)

Keys: q quits, r reconnects offline hosts now.
Standard library only (Python 3.9+). Read-only on every machine; nothing is
installed or written on a remote machine.
"""
import collections
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time

try:                                    # termios and tty exist on macOS and Linux only
    import termios
    import tty
except ImportError:                     # pragma: no cover
    termios = tty = None

NAME = "tuimon"
HERE = os.path.dirname(os.path.abspath(__file__))
COLLECTOR = os.path.join(HERE, "collector.py")
HOSTS_FILE = os.path.expanduser("~/.config/%s/hosts" % NAME)
HOSTS_ENV = NAME.upper() + "_HOSTS"
REMOTE_PYTHON = os.environ.get(NAME.upper() + "_REMOTE_PYTHON", "python3")
HIST = 240                              # samples kept per series
NW = 18                                 # machine name column width
BW = 20                                 # bar width
MIN_COLS = 60

# ---- verdict thresholds (one place, so the README can quote them) ------------
LOAD_BUSY, LOAD_STRAINED = 1.5, 3.0     # 1-minute load per core
MEM_BUSY, MEM_STRAINED = 85.0, 95.0     # percent of memory in use
DISK_BUSY, DISK_STRAINED = 10.0, 5.0    # percent of disk free
STALE_INTERVALS = 4                     # no sample for this many intervals = offline

# ---- colour and drawing ------------------------------------------------------
TRUE = os.environ.get("COLORTERM", "") in ("truecolor", "24bit")
PLAIN = bool(os.environ.get("NO_COLOR"))
ANSI = re.compile(r"\x1b\[[0-9;]*m")
RESET = "" if PLAIN else "\x1b[0m"
BLOCKS = " ▁▂▃▄▅▆▇█"
INK, DIM, FAINT = (226, 230, 240), (128, 136, 156), (60, 66, 84)
ACCENT, GOOD, WARN, BAD = (125, 160, 255), (88, 214, 141), (245, 196, 82), (240, 98, 98)
CYAN, VIOLET = (92, 205, 220), (178, 140, 255)


def fg(c):
    if PLAIN:
        return ""
    r, g, b = c
    if TRUE:
        return "\x1b[38;2;%d;%d;%dm" % (r, g, b)
    return "\x1b[38;5;%dm" % (16 + 36 * round(r / 51) + 6 * round(g / 51) + round(b / 51))


def paint(text, c, bold=False):
    return ("\x1b[1m" if bold and not PLAIN else "") + fg(c) + text + RESET


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def heat(p):
    """0..100 -> green, yellow, red."""
    p = max(0.0, min(100.0, p)) / 100.0
    return mix(GOOD, WARN, p / 0.6) if p < 0.6 else mix(WARN, BAD, (p - 0.6) / 0.4)


def vlen(s):
    return len(ANSI.sub("", s))


def clip(s, w):
    """Cut a string holding colour codes to w visible columns, then pad to w."""
    out, n, i = [], 0, 0
    while i < len(s) and n < w:
        m = ANSI.match(s, i)
        if m:
            out.append(m.group(0))
            i = m.end()
        else:
            out.append(s[i])
            n += 1
            i += 1
    return "".join(out) + RESET + " " * (w - n)


def size(n):
    n = float(n)
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return ("%.0f%s" if n >= 100 or unit == "B" else "%.1f%s") % (n, unit)
        n /= 1024


def dur(s):
    d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
    return "%dd %dh" % (d, h) if d else ("%dh %02dm" % (h, m) if h else "%dm" % m)


def bar(pct, w, color=None):
    pct = max(0.0, min(100.0, pct))
    n = int(pct / 100.0 * w)
    return paint("█" * n, color or heat(pct)) + paint("░" * (w - n), FAINT)


def spark(values, w, top=None, color=None):
    if w <= 0:
        return ""
    vals = list(values)[-w:]
    if not vals:
        return paint("·" * w, FAINT)
    top = top or max(max(vals), 1e-9)
    out = "".join(paint(BLOCKS[max(1, int(round(min(1.0, v / top) * 8)))], color or heat(100.0 * v / top))
                  for v in vals)
    return paint("·" * (w - len(vals)), FAINT) + out


def rule(title, w, note=""):
    head = " " + paint(title, ACCENT, True) + " "
    tail = (" " + paint(note, DIM) + " ") if note and vlen(head) + len(note) + 8 < w else ""
    return clip(head + paint("─" * max(1, w - vlen(head) - vlen(tail) - 1), FAINT) + tail, w)


# ---- one machine: collection over a pipe, history, verdict -------------------
def load_hosts():
    """ssh targets from the hosts file, one per line, # starts a comment."""
    try:
        with open(HOSTS_FILE) as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    return [ln.split("#", 1)[0].strip() for ln in lines if ln.split("#", 1)[0].strip()]


class Host:
    def __init__(self, target):
        self.target = target            # None means this machine
        self.s = None                   # last sample
        self.seen = 0.0
        self.state = "connecting"
        self.err = ""
        self.h = {k: collections.deque(maxlen=HIST) for k in ("cpu", "mem")}
        self.proc = None
        self.kick = threading.Event()

    def argv(self, interval):
        env = "%s_INTERVAL=%s" % (NAME.upper(), interval)
        if self.target is None:
            return [sys.executable, "-u", COLLECTOR], None, dict(os.environ, **{env.split("=")[0]: str(interval)})
        # BatchMode: never prompt for a password inside the TUI. The script goes
        # in on stdin, so nothing is copied to or left on the remote machine.
        return (["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                 "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                 "--", self.target, "%s %s -u -" % (env, REMOTE_PYTHON)],
                open(COLLECTOR, "rb"), None)

    def run(self, interval, stop):
        while not stop.is_set():
            argv, stdin, env = self.argv(interval)
            try:
                self.proc = subprocess.Popen(argv, stdin=stdin or subprocess.DEVNULL, stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
                for line in self.proc.stdout:
                    try:
                        s = json.loads(line)
                    except ValueError:
                        continue
                    self.s, self.seen, self.state, self.err = s, time.time(), "live", ""
                    self.h["cpu"].append(s["cpu"])
                    self.h["mem"].append(100.0 * s["mem"]["used"] / (s["mem"]["total"] or 1))
                err = (self.proc.stderr.read() or "").strip().splitlines()
                self.err = err[-1][:80] if err else "collector exited"
            except Exception as e:      # a broken host must never stop the monitor
                self.err = str(e)[:80]
            finally:
                if stdin:
                    stdin.close()
            if stop.is_set():
                return
            self.state = "offline"
            self.kick.wait(5)           # reconnect every 5 s, or now on r
            self.kick.clear()

    def kill(self):
        try:
            if self.proc and self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGTERM)
        except Exception:
            pass

    def name(self):
        if self.s:
            return self.s["host"]
        return self.target or "this machine"

    def health(self, interval):
        """(colour, verdict, reasons). Verdicts: connecting, offline, healthy, busy, strained."""
        if self.s is None:
            return (DIM, "connecting", []) if self.state == "connecting" else (BAD, "offline", [self.err])
        if self.state != "live" or time.time() - self.seen > max(8, interval * STALE_INTERVALS):
            return BAD, "offline", ["no data for %ds" % (time.time() - self.seen), self.err]
        s, level, why = self.s, 0, []

        def flag(lv, text):
            nonlocal level
            level = max(level, lv)
            why.append(text)
        per = s["load"][0] / float(s["ncpu"] or 1)
        if per > LOAD_BUSY:
            flag(2 if per > LOAD_STRAINED else 1, "load %.1f on %d cores" % (s["load"][0], s["ncpu"]))
        mp = 100.0 * s["mem"]["used"] / (s["mem"]["total"] or 1)
        if mp > MEM_BUSY:
            flag(2 if mp > MEM_STRAINED else 1, "memory %.0f%% used" % mp)
        free = 100.0 * s["disk"]["free"] / (s["disk"]["total"] or 1)
        if free < DISK_BUSY:
            flag(2 if free < DISK_STRAINED else 1, "disk %.0f%% free" % free)
        return [GOOD, WARN, BAD][level], ["healthy", "busy", "strained"][level], why


# ---- layout: one section per category, one row per machine -------------------
def namecell(h, interval):
    return paint("●", h.health(interval)[0]) + " " + paint("%-*s" % (NW - 2, h.name()[:NW - 3]), INK, True)


def pending(h):
    if h.state == "offline":
        return paint("offline", BAD) + (paint("  " + h.err, DIM) if h.err else "")
    return paint("waiting for %s" % (h.target or "this machine"), DIM)


def section(title, hosts, interval, w, fn, note=""):
    rest = w - 2 - NW
    out = [rule(title, w, note)]
    for h in hosts:
        out.append(clip("  " + namecell(h, interval) + (fn(h, rest) if h.s else pending(h)), w))
    return out


def sparkw(rest, fixed, cap=60):
    """Sparklines take whatever width is left after the fixed parts of a row."""
    return max(0, min(cap, rest - fixed))


def g_machine(h, rest, interval):
    color, verdict, why = h.health(interval)
    s = h.s
    bits = [paint("%-10s" % verdict, color, True), paint("%-22s" % s["os"][:22], DIM),
            paint("up %-8s" % dur(s["up"]), DIM)]
    bits.append(paint("; ".join(x for x in why if x), color) if why else paint("nothing to flag", DIM))
    return "  ".join(bits)


def g_cpu(h, rest):
    s = h.s
    tail = paint("  load ", DIM) + paint("%5.1f %5.1f %5.1f" % tuple(s["load"]), INK) \
        + paint("  %d cores" % s["ncpu"], DIM)
    return bar(s["cpu"], BW) + paint(" %3.0f%%  " % s["cpu"], INK, True) \
        + spark(h.h["cpu"], sparkw(rest, BW + 7 + vlen(tail)), 100) + tail


def g_mem(h, rest):
    m = h.s["mem"]
    mp = 100.0 * m["used"] / (m["total"] or 1)
    tail = paint("  %s of %s" % (size(m["used"]), size(m["total"])), INK)
    return bar(mp, BW) + paint(" %3.0f%%  " % mp, INK, True) \
        + spark(h.h["mem"], sparkw(rest, BW + 7 + vlen(tail)), 100, ACCENT) + tail


def g_disk(h, rest):
    d = h.s["disk"]
    used = 100.0 * (d["total"] - d["free"]) / (d["total"] or 1)
    return bar(used, BW) + paint(" %3.0f%%  " % used, INK, True) \
        + paint("%s free of %s" % (size(d["free"]), size(d["total"])), INK)


def top_columns(hosts, interval, w, rows_left):
    """Top programs, one column per machine side by side when they fit, else stacked."""
    n = len(hosts)
    per = max(1, min(n, (w - 2) // 44))
    cw = min(72, (w - 2 - 2 * (per - 1)) // per)
    top = max(3, min(8, rows_left)) if rows_left else 8
    out = [rule("TOP PROGRAMS", w, "by cpu, percent of one core")]
    for start in range(0, n, per):
        cols = []
        for h in hosts[start:start + per]:
            # the head lines up with the row below: count 5, cpu 8, memory 9 columns
            col = [namecell(h, interval) + paint("%*s" % (max(0, cw - NW), "count     cpu   memory"), DIM)]
            if not h.s:
                col.append(pending(h))
            else:
                nw = max(8, cw - 22)
                for p in h.s["top"][:top]:
                    col.append(paint("%-*s" % (nw, p["n"][:nw]), INK) + paint("%5s" % ("×%d" % p["c"]), DIM)
                               + paint("%7.0f%%" % p["cpu"], heat(min(100.0, p["cpu"])))
                               + paint("%9s" % size(p["rss"]), INK))
            cols.append([clip(x, cw) for x in col])
        for i in range(max(len(c) for c in cols)):
            out.append(clip("  " + "  ".join(c[i] if i < len(c) else " " * cw for c in cols), w))
    return out


def header(hosts, interval, cols):
    left = " " + paint(NAME, ACCENT, True) + paint("  machine health", DIM)
    chips = "   ".join(paint("●", h.health(interval)[0]) + " " + paint(h.name(), INK) for h in hosts)
    right = paint(time.strftime("%H:%M:%S") + "  every %gs  r reconnect  q quit " % interval, DIM)
    if vlen(left) + vlen(chips) + vlen(right) + 6 > cols:
        chips = ""                      # narrow terminal: the MACHINES section still shows every host
    gap = cols - vlen(left) - vlen(chips) - vlen(right) - 4
    return clip(left + "    " + chips + " " * max(1, gap) + right, cols)


def frame(hosts, interval, cols, rows):
    """List of lines, each exactly max(MIN_COLS, cols) visible columns. rows=0 means no limit."""
    w = max(MIN_COLS, cols)
    blocks = [
        section("MACHINES", hosts, interval, w, lambda h, r: g_machine(h, r, interval)),
        section("CPU", hosts, interval, w, g_cpu, "use, history, load over 1, 5, 15 min"),
        section("MEMORY", hosts, interval, w, g_mem),
        section("DISK", hosts, interval, w, g_disk),
    ]
    fixed = 2 + sum(len(b) for b in blocks)
    spacers = len(blocks)
    rows_left = 0
    if rows:
        rows_left = rows - fixed - 2 - spacers
        if rows_left < 3:               # short terminal: drop the blank spacer rows first
            spacers, rows_left = 0, rows - fixed - 2
    out = [header(hosts, interval, w), " " * w]
    for b in blocks:
        out += b
        if spacers:
            out.append(" " * w)
    out += top_columns(hosts, interval, w, rows_left)
    return out[:rows] if rows else out


# ---- main: --once, full-screen loop, keys, clean exit ------------------------
def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    flags = [a for a in sys.argv[1:] if a.startswith("-")]
    if "-h" in flags or "--help" in flags:
        print(__doc__)
        return 0
    interval = 2.0
    for f in flags:
        if f.startswith("--interval="):
            interval = max(1.0, float(f.split("=", 1)[1]))
    once = "--once" in flags
    remotes = [] if "--local" in flags else (args or os.environ.get(HOSTS_ENV, "").split() or load_hosts())
    hosts = [Host(None)] + [Host(t) for t in remotes if not t.startswith("-")]
    stop = threading.Event()
    for h in hosts:
        threading.Thread(target=h.run, args=(interval, stop), daemon=True).start()

    def shutdown():
        stop.set()
        for h in hosts:
            h.kick.set()
            h.kill()

    if once:
        deadline = time.time() + 25
        while time.time() < deadline and not all(len(h.h["cpu"]) >= 2 or h.state == "offline" for h in hosts):
            time.sleep(0.2)
        cols = int(os.environ.get("COLUMNS", 0)) or shutil.get_terminal_size((120, 40)).columns
        print("\n".join(frame(hosts, interval, cols, 0)))
        shutdown()
        return 0
    if termios is None or not sys.stdout.isatty() or not sys.stdin.isatty():
        shutdown()
        sys.exit("%s needs a terminal. Use --once to print a single frame." % NAME)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        tty.setcbreak(fd)
        sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[2J")      # alternate screen, hide cursor
        while True:
            ts = shutil.get_terminal_size((120, 40))
            lines = frame(hosts, interval, ts.columns, ts.lines)
            sys.stdout.write("\x1b[H" + "\x1b[K\n".join(lines) + "\x1b[K\x1b[J")
            sys.stdout.flush()
            if select.select([sys.stdin], [], [], 0.5)[0]:
                key = os.read(fd, 8)[:1]
                if key in (b"q", b"Q", b"\x1b", b"\x03"):
                    break
                if key in (b"r", b"R"):
                    for h in hosts:
                        h.kick.set()
    except KeyboardInterrupt:
        pass
    finally:
        shutdown()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\x1b[?25h\x1b[?1049l")              # show cursor, leave alternate screen
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
