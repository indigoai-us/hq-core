#!/usr/bin/env python3
"""tuimon collector: prints one JSON line of machine stats every interval.

Runs on the machine being watched with the system Python 3 (standard library
only, Python 3.9 or newer, macOS or Linux). On another machine it is fed over
ssh on stdin and writes nothing to disk:

    ssh user@host python3 -u - < collector.py

It only reads: os.getloadavg, os.cpu_count, shutil.disk_usage, sysctl and
vm_stat (macOS), /proc (Linux), and ps. None of it needs sudo. Only process
names leave this script, never their arguments. It stops by itself when the
reader goes away (a failed write or a parent that exited).
"""
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time

INTERVAL = float(os.environ.get("TUIMON_INTERVAL", "2"))
MAC = sys.platform == "darwin"


def sh(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def sysctl(name):
    return sh(["/usr/sbin/sysctl", "-n", name]).strip()


# ---- CPU ---------------------------------------------------------------------
def linux_ticks():
    try:
        with open("/proc/stat") as f:
            parts = [int(x) for x in f.readline().split()[1:]]
        idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
        return sum(parts), idle
    except (OSError, ValueError, IndexError):
        return None


def cpu_pct(prev, cur, procs_cpu, ncpu):
    """Percent of the whole machine. Linux uses /proc/stat deltas; macOS sums ps."""
    if prev and cur and cur[0] > prev[0]:
        total, idle = cur[0] - prev[0], cur[1] - prev[1]
        return round(100.0 * (total - idle) / total, 1)
    return round(min(100.0, procs_cpu / max(1, ncpu)), 1)


# ---- memory, disk, uptime ----------------------------------------------------
def memory():
    if MAC:
        total = int(sysctl("hw.memsize") or 0)
        out = sh(["/usr/bin/vm_stat"])
        m = re.search(r"page size of (\d+)", out)
        page = int(m.group(1)) if m else 16384
        pages = {}
        for line in out.splitlines()[1:]:
            k, _, v = line.partition(":")
            try:
                pages[k.strip().strip('"')] = int(v.strip().rstrip("."))
            except ValueError:
                pass
        used = (pages.get("Anonymous pages", 0) + pages.get("Pages wired down", 0)
                + pages.get("Pages occupied by compressor", 0)) * page
        return {"total": total, "used": min(used, total) if total else used}
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                info[k] = int(v.split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    total = info.get("MemTotal", 0)
    return {"total": total, "used": max(0, total - info.get("MemAvailable", total))}


def disk():
    try:
        u = shutil.disk_usage("/System/Volumes/Data" if MAC and os.path.isdir("/System/Volumes/Data") else "/")
        return {"total": u.total, "free": u.free}
    except OSError:
        return {"total": 0, "free": 0}


def uptime():
    if MAC:
        m = re.search(r"sec = (\d+)", sysctl("kern.boottime"))
        return int(time.time()) - int(m.group(1)) if m else 0
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


# ---- processes ---------------------------------------------------------------
def processes():
    """Top programs by CPU, grouped by program name. Arguments never leave."""
    groups, total = {}, 0.0
    for line in sh(["ps", "-A", "-o", "pcpu=,rss=,comm="]).splitlines():
        f = line.split(None, 2)
        if len(f) < 3:
            continue
        try:
            cpu, rss = float(f[0]), int(f[1]) * 1024
        except ValueError:
            continue
        name = os.path.basename(f[2].strip())[:32] or "?"
        g = groups.setdefault(name, [0.0, 0, 0])
        g[0] += cpu
        g[1] += rss
        g[2] += 1
        total += cpu
    top = sorted(groups.items(), key=lambda kv: -kv[1][0])[:8]
    return total, [{"n": k, "cpu": round(v[0], 1), "rss": v[1], "c": v[2]} for k, v in top]


def main():
    ncpu = os.cpu_count() or 1
    static = {"host": socket.gethostname().split(".")[0],
              "os": ("macOS " + platform.mac_ver()[0]) if MAC else (platform.system() + " " + platform.release()),
              "ncpu": ncpu}
    prev = None if MAC else linux_ticks()
    time.sleep(min(1.0, INTERVAL))
    while True:
        t0 = time.time()
        cur = None if MAC else linux_ticks()
        procs_cpu, top = processes()
        sample = dict(static)
        sample.update({
            "t": t0, "up": uptime(), "load": [round(x, 2) for x in os.getloadavg()],
            "cpu": cpu_pct(prev, cur, procs_cpu, ncpu), "mem": memory(), "disk": disk(), "top": top,
        })
        prev = cur
        try:
            sys.stdout.write(json.dumps(sample, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            return
        if os.getppid() == 1:          # the reader went away and we were re-parented
            return
        time.sleep(max(0.2, INTERVAL - (time.time() - t0)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
