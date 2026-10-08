---
title: HQ Anywhere runtime protocol and registry
description: Local hqd socket messages and the per-user folder-to-company registry format.
public: true
---

# HQ Anywhere runtime protocol and registry

HQ Anywhere adds a global CLI install and the hqd local daemon. A per-user
registry links folders to companies. The `hq-anywhere-runtime` flag is an
operator kill switch: absent, archived, or unreadable registry rows default on,
while an explicit false row or local `HQ_FLAG_HQ_ANYWHERE_RUNTIME=false|0`
override turns it off. The flag controls
these features and is off by default. The socket and registry stay in the
user's home directory. They are local to that host and are not stored in a
project or synced HQ folder.

## Global install and daemon

Run `hq install --global` from an HQ checkout to register HQ hooks for the
agent runtime. The install records the HQ root in `~/.hq/root`. When the
runtime flag is enabled, hooks can send work to hqd. Install and check the
daemon with `hq daemon install` and `hq daemon status`.

Run `hq link <company>` from a repository to associate its normalized Git
remote, or its canonical folder path when it has no recognized remote, with a
company. The link is stored in the local registry described below. A repository
without a registry match uses personal context.

## hqd socket

On Unix, hqd listens on `~/.hq/hqd.sock` by default. `HQ_REGISTRY_DIR` changes
the parent directory, and `HQ_HQD_SOCKET` can set the socket path directly.
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
