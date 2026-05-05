---
id: hq-jq-with-entries-capture-key-variable
title: Capture `with_entries` key as a variable before piping into array filters
scope: global
trigger: When using `jq with_entries` to conditionally transform object fields where the predicate checks membership against a separate array
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

ALWAYS: In `jq`, capture the entry key as a variable before piping into another array filter:

```jq
# WRONG — rebinds `.` to the array, then `.key` fails
with_entries(if ($keys | index(.key)) then ... end)

# RIGHT — capture `.key` first, then pipe
with_entries(.key as $k | if ($keys | index($k)) then ... end)
```

The pipe `$keys | index(.key)` rebinds `.` to the array, so `.key` throws `Cannot index array with string key`.

## Rationale

Discovered while writing JSON redaction logic that needed to keep a set of known-safe keys and scrub everything else. The error message is misleading — jq reports it on the `.key` reference, but the root cause is the implicit `.` rebind inside the pipe. Capturing the key into a named variable makes the data flow explicit and makes the filter readable for future maintainers.
