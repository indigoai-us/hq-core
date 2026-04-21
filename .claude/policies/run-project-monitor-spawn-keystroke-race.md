---
id: run-project-monitor-spawn-keystroke-race
title: Monitor-window spawn must use .command file, not AppleScript do script
scope: command
trigger: spawn_cmux_monitor, osascript do script, Terminal.app monitor
enforcement: hard
version: 1
created: 2026-04-16
updated: 2026-04-16
source: user-correction
command: run-project
---

## Rule

The `spawn_cmux_monitor` routine in `scripts/run-project.sh` must launch the monitor window via a temporary `.command` file opened with `open -a Terminal`. It must NOT use AppleScript `do script` because that path is vulnerable to keystroke-injection races: when a frontmost Terminal window has buffered input (e.g. the user pressed a key while the window was unfocused), `do script` can prepend those stray characters to the injected command, producing errors like:

```
zsh: command not found: kcd
```

(observed literal corruption: `cd '/Users/...'` → `kcd '/Users/...'`)

