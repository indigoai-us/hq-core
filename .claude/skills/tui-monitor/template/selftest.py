#!/usr/bin/env python3
"""Self-test for tuimon. Standard library only.

    python3 selftest.py                 local checks
    python3 selftest.py user@host       also check one remote host

Checks:
  1. --once prints one frame at 60, 100 and 180 columns, every line fits the
     width, and the frame names the sections.
  2. A full-screen run in a pseudo-terminal draws, quits on q with exit 0, and
     restores the terminal (leaves the alternate screen, shows the cursor).
  3. No collector process is left running afterwards, locally or on the remote.
"""
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import time

NAME = "tuimon"
HERE = os.path.dirname(os.path.abspath(__file__))
MONITOR = os.path.join(HERE, NAME + ".py")
COLLECTOR = os.path.join(HERE, "collector.py")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")
FAILS = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


def once(cols, extra):
    env = dict(os.environ, COLUMNS=str(cols))
    r = subprocess.run([sys.executable, MONITOR, "--once"] + extra, capture_output=True, text=True,
                       env=env, timeout=60)
    lines = [ANSI.sub("", ln) for ln in r.stdout.splitlines()]
    widest = max((len(ln) for ln in lines), default=0)
    check(r.returncode == 0, "--once exits 0 at %d columns" % cols)
    check(widest <= max(60, cols), "--once at %d columns: widest line %d fits" % (cols, widest))
    check(all(s in r.stdout for s in ("MACHINES", "CPU", "MEMORY", "DISK")), "--once at %d columns names the sections" % cols)


def pty_run(extra, cols=120, rows=40):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
        os.execv(sys.executable, [sys.executable, MONITOR] + extra)
    import fcntl
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    buf, start, sent = b"", time.time(), False
    status = None
    while time.time() - start < 40:
        if select.select([fd], [], [], 0.3)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            buf += chunk
        if not sent and b"MEMORY" in buf and time.time() - start > 3:
            os.write(fd, b"q")
            sent = True
        done, st = os.waitpid(pid, os.WNOHANG)
        if done:
            status = st
            break
    if status is None:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    try:
        while select.select([fd], [], [], 0.1)[0]:
            more = os.read(fd, 65536)
            if not more:
                break
            buf += more
    except OSError:
        pass
    check(sent, "pty run drew a frame")
    check(status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, "pty run quit on q with exit 0")
    check(b"\x1b[?1049l" in buf and b"\x1b[?25h" in buf, "pty run restored the terminal")


def leftovers(remote):
    time.sleep(1.5)
    ps = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout
    mine = [ln for ln in ps.splitlines() if COLLECTOR in ln]
    check(not mine, "no local collector left running")
    if remote:
        r = subprocess.run(["ssh", "-o", "BatchMode=yes", "--", remote, "ps -Ao command= | grep -c '[p]ython3 -u -' || true"],
                           capture_output=True, text=True, timeout=30)
        check(r.stdout.strip() in ("0", ""), "no collector left running on %s" % remote)


def main():
    remote = [a for a in sys.argv[1:] if not a.startswith("-")][:1]
    extra = remote if remote else ["--local"]
    for cols in (60, 100, 180):
        once(cols, extra)
    pty_run(extra)
    leftovers(remote[0] if remote else None)
    print("\n%s" % ("all checks passed" if not FAILS else "%d check(s) failed" % len(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
