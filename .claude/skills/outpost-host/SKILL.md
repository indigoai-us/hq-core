---
name: outpost-host
description: Host a full-stack or static app directly on the HQ Outpost / EC2 VM this session is running on, served through nginx. Finds a free port on the box, installs and configures nginx (static file serving or reverse-proxy to a running app), and returns the public URL. HARD-GATED — refuses to run anywhere that is not an HQ Outpost or EC2 instance and tells the user why. Use when the user says "host this app on the outpost", "serve this on the VM", "deploy my app to the outpost", "put this site on the box", or wants to expose a locally-running app from their Outpost. For sharing a generated artifact or vault file instead, use /deploy or /hq-share.
allowed-tools: Bash, Read, Glob, Grep, Bash(bash "$CLAUDE_PROJECT_DIR/.claude/skills/outpost-host/host-app.sh:*), AskUserQuestion
---

# /outpost-host — serve an app from the Outpost VM

Stand up a web server **on the cloud VM this session is running on** and serve whatever the user wants — a static site or a running full-stack app — behind nginx, then hand back the public URL.

This comes from the idea: *let people host apps on the VM the Outpost is running on, and ship an Outpost-specific command that finds a free host and deploys to it.* This skill is that command, scoped to the current box.

## Hard constraint: Outposts / EC2 only

This skill installs system packages, edits `/etc/nginx`, opens ports, and exposes an app to the internet. That is only safe on a disposable, already-public cloud VM — an **HQ Outpost** or a plain **EC2 instance**. It must never do this on an operator's laptop or any non-cloud host.

**Step 1, always, before anything else:** run the environment guard.

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/skills/outpost-host/host-app.sh" check
```

- Exit `0` → you are on an Outpost/EC2 box; continue.
- Exit `1` → **stop.** Print the guard's message to the user verbatim (it explains this skill only runs on an Outpost/EC2 and points them to `/deploy` and `/hq-share`). Do not install anything, do not retry, do not work around it.

The guard detects the environment offline (HQ Outpost `outpost-*` systemd units; EC2 DMI markers `sys_vendor=Amazon EC2` / `board_asset_tag=i-…`; Xen hypervisor uuid) and falls back to IMDSv2. It does not depend on the network being up.

## What you can serve

Ask the user which mode fits (use `AskUserQuestion` if unclear):

1. **Static** — a directory of files (built site, plain HTML/CSS/JS, exported app). nginx serves it directly.
2. **Proxy** — an app already running (or that you will start) on a local port (Next.js, an API, a Flask/Express server). nginx reverse-proxies to it, including WebSocket upgrade headers.

For a full-stack app, the usual flow is: start the app bound to `127.0.0.1:<appPort>` (e.g. via its own `npm start`/process manager), then use **proxy** mode pointed at that port. Keep the app process alive yourself (e.g. a systemd unit or `nohup`/`pm2`); nginx only fronts it.

## Process

### 1. Gate

Run `host-app.sh check`. On failure, relay the message and stop (see above).

### 2. Gather inputs

- `name` — a short slug for the app (`[a-z0-9-]`), used for the nginx site filename and `list`/`remove`.
- `mode` — `static` or `proxy`.
- For static: the `root` directory to serve.
- For proxy: the running app's `host:port` (usually `127.0.0.1:<port>`).
- Optional explicit public `--port`; otherwise a free port is chosen automatically.

### 3. Find a free host slot

```bash
host-app.sh free-port           # first free port in 8080-8099
```

The deploy step does this automatically when `--port` is omitted. Use port `80` only if the user explicitly wants the bare `http://<host>` URL and nothing else is on 80.

### 4. Deploy

This installs nginx if missing, writes `/etc/nginx/conf.d/outpost-<name>.conf`, validates with `nginx -t` (auto-reverting on failure), and reloads nginx.

```bash
# static site
host-app.sh deploy --name myapp --mode static --root /path/to/site

# reverse-proxy to a running app on port 3000
host-app.sh deploy --name myapp --mode proxy --upstream 127.0.0.1:3000
```

On success it prints `URL=…`. Surface that URL to the user in one plain line.

### 5. Open the firewall (tell the user)

nginx now listens on the chosen port, but the instance's **security group** must allow inbound TCP on that port for the URL to be reachable from outside. The skill cannot change AWS security groups safely on its own — tell the user which port to open (or use port 80 if their SG already allows it).

### 6. Manage / clean up

```bash
host-app.sh list                # what this skill is currently serving
host-app.sh remove --name myapp # tear down one app's nginx site and reload
```

## Safety notes (full prose — this exposes things publicly)

- **Exposing an app publicly is an outward-facing action.** Before deploying, confirm with the user that the app is meant to be public and contains nothing sensitive. An app on the Outpost can reach the box's local services and credentials, so only proxy apps you trust.
- The skill writes only to `/etc/nginx/conf.d/outpost-*.conf` and never edits the operator's other nginx config. `remove` deletes only the file it created.
- nginx config is always validated with `nginx -t` before reload; a bad config is reverted rather than left in place.
- Keep the upstream app process supervised yourself — nginx fronts it but does not start or restart it.

## Files

- `guard.sh` — environment gate (Outpost/EC2 detection; injectable inputs for testing).
- `host-app.sh` — install nginx, find a free port, deploy/list/remove sites, resolve the public URL.
- `test-guard.sh` — verifies the guard passes on an outpost-like env and refuses on a non-outpost env.
