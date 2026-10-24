---
title: HQ Anywhere setup, runtime protocol, and registry
description: How to set up HQ Anywhere with hq install --global, plus the local hqd socket messages and folder-to-company registry format.
public: true
---

# HQ Anywhere

HQ Anywhere makes HQ skills such as `/handoff` available in any folder, not
only inside your HQ folder. It is available to everyone.

## Set up

From your HQ folder, run:

```bash
hq install --global
```

That is the whole setup. Open Claude Code in any folder and HQ skills work
there. Skills are linked into `~/.claude/skills`. For Codex, run
`hq install --global --runtime codex` instead; skills go to
`$CODEX_HOME/skills`. If Codex reports untrusted hooks, approve them with
`/hooks` in Codex. The
install records your HQ folder in `~/.hq/root`.

The hqd daemon is optional (`hq daemon install`, `hq daemon status`). When it
is installed for this HQ folder, hooks route through it. Skills work without
it.

## Kill switch

The `hq-anywhere-runtime` flag is an operator kill switch. It is on unless its
registry row is set to false or `HQ_FLAG_HQ_ANYWHERE_RUNTIME=false|0` is set
locally. It does not block `hq install --global` for Claude or Codex: skills,
hooks, and `~/.hq/root` still install. When the flag is off, the install skips
the `~/.hq/bin` provider wrappers. The socket and registry described below stay in your home directory
and are not stored in a project or synced HQ folder.

## Folder links

Run `hq link <company>` from a repository to associate its normalized Git
remote, or its canonical folder path when it has no recognized remote, with a
company. The link is stored in the local registry described below. A repository
without a registry match uses personal context.

## hqd socket

On Unix, hqd listens on `~/.hq/daemon/hqd.sock` by default. When
`HQ_REGISTRY_DIR` is set, the socket is `$HQ_REGISTRY_DIR/daemon/hqd.sock`.
`HQ_HQD_SOCKET` sets the socket path directly and takes precedence over both.
The hook shim and `master-hook.sh` resolve the path in the same order.
The socket has owner-only permissions. On Windows, clients use a named pipe
scoped to the current user. The server also creates private runtime
directories with owner-only permissions.

The socket carries newline-delimited JSON. Each request has an `id`, an `op`,
and optional object-valued `args`. A request looks like this:

```json
{"id":"req-1","op":"ping","args":{}}
```

A successful response has the same `id`, `ok: true`, and a `result` value:

```json
{"id":"req-1","ok":true,"result":{}}
```

An error response has the same `id`, `ok: false`, and an `error` object with
`code` and `message` fields. Replies can arrive out of order, so clients match
each response to its request by `id`. A request line is limited to 1 MiB.

The default request timeout is two seconds. The protocol operations include
`ping`, `resolve`, session open/get/close, policy check/index, journal append,
memory get/put, mesh presence, MCP call, and shutdown.

## Folder-to-company registry

The registry is `~/.hq/registry.json`. Set `HQ_REGISTRY_DIR` to use another
directory. Its top-level object has `version: 1` and an `entries` object. Each
entry maps a lookup key to a company, the source of the link, and its timestamp.
For example:

```json
{
  "version": 1,
  "entries": {
    "remote:github.com/example/project": {
      "company": "indigo",
      "source": "link",
      "linkedAt": "2026-10-02T12:00:00.000Z"
    }
  }
}
```

Keys use either `remote:<normalized-git-remote>` or
`path:<canonical-absolute-folder>`.
The supported `source` values are `link`, `manifest`, and `prompt`. When more
than one entry matches, `link` outranks `prompt`, which outranks `manifest`.
Entries with the same source rank use the more specific folder key. A folder
without a matching entry resolves to personal context. The resolver does not
guess a company.

## Source

- `hq-cli/src/lib/daemon/protocol.ts` defines the socket path, newline JSON
  messages, request and response fields, size limit, timeout, and operation
  names.
- `hq-cli/src/lib/daemon/server.ts` binds the socket under an owner-only umask
  and sets its permissions to `0600` on Unix.
- `hq-cli/src/lib/daemon/paths.ts` defines the host-local daemon paths and
  owner-only directory and file permissions.
- `hq-cli/src/lib/registry/registry.ts` defines the registry location, entry
  fields, key formats, validation, and resolution precedence.
