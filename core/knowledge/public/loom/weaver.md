---
type: reference
domain: [engineering]
status: canonical
tags: [loom, weaver, kubernetes, remote-execution, ephemeral-pods]
relates_to: []
---

# Weaver (Remote Execution)

Weavers are ephemeral Kubernetes pods for running remote Loom REPL sessions.

**Source**: `crates/loom-weaver-*/`, `crates/loom-wgtunnel-*/`

## Architecture

```
┌─────────────┐     WebSocket     ┌─────────────┐     K8s API      ┌─────────────┐
│  loom-cli   │ ──────────────────▶│ loom-server │ ───────────────▶ │   K8s Pod   │
│             │                    │             │                  │   (Weaver)  │
│  attach     │ ◀─────────────────│  /weavers   │ ◀────────────────│             │
└─────────────┘     Terminal I/O  └─────────────┘    WireGuard     └─────────────┘
```

## CLI Commands

```bash
# Login first
loom --server-url https://loom.ghuntley.com login

# Create new weaver
loom --server-url https://loom.ghuntley.com new --image <image>

# List weavers
loom --server-url https://loom.ghuntley.com weaver ps

# Attach to weaver
loom --server-url https://loom.ghuntley.com attach <weaver-id>

# Delete weaver
loom --server-url https://loom.ghuntley.com weaver delete <weaver-id>
```

## K8s Namespace

Weavers run in `loom-weavers` namespace:

```bash
# List pods
sudo kubectl get pods -n loom-weavers

# Describe pod
sudo kubectl describe pod <pod-name> -n loom-weavers

# Pod logs
sudo kubectl logs <pod-name> -n loom-weavers

# Delete stuck pod
sudo kubectl delete pod <pod-name> -n loom-weavers
```

## Crates

| Crate | Purpose |
|-------|---------|
| `loom-weaver-audit-sidecar` | Audit logging sidecar |
| `loom-weaver-ebpf` | eBPF syscall tracing |
| `loom-weaver-ebpf-common` | Shared eBPF types |
| `loom-weaver-secrets` | Secret injection |
| `loom-wgtunnel-common` | WireGuard common types |
| `loom-wgtunnel-conn` | Connection handling |
| `loom-wgtunnel-derp` | DERP relay support |
| `loom-wgtunnel-engine` | Tunnel engine |
| `loom-server-wgtunnel` | Server integration |
| `loom-server-weaver` | Server weaver management |

## Features

### WireGuard Tunneling
Secure tunnel between client and weaver pod via WireGuard with DERP relay fallback.

### eBPF Audit
`loom-weaver-ebpf` traces syscalls for security auditing:
- File operations
- Network activity
- Process spawning

### Secret Injection
`loom-weaver-secrets` injects secrets into weaver environment without exposing them in pod spec.

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| ErrImagePull | Image doesn't exist or is private | Check `kubectl describe pod` |
| Succeeded immediately | Container has no long-running entrypoint | Weaver images must run persistent process |
| 401 Unauthorized | Not logged in | Run `loom login` first |

## Server Logs

```bash
# Weaver-related logs
journalctl -u loom-server -f
```
