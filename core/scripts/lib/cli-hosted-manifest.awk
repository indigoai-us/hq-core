# Parse the restricted YAML mapping list in cli-hosted.yaml.
# This stays in POSIX awk so the manifest remains usable with Bash 3.2.
function report(message) {
  printf "cli-hosted.yaml:%d: %s\n", FNR, message > "/dev/stderr"
  invalid = 1
}

function emit_entry(    valid) {
  if (path == "") return
  valid = 1
  if (seen[path]++) {
    report("duplicate path " path)
    valid = 0
  }
  if (path !~ /^(\.claude\/hooks|core\/scripts)\/[A-Za-z0-9._\/-]+$/ || path ~ /(^|\/)\.\.(\/|$)/) {
    report("invalid path " path)
    valid = 0
  }
  if (command !~ /^[a-z0-9-]+( [a-z0-9-]+)?$/) {
    report("invalid command for " path)
    valid = 0
  }
  if (kind != "generated" && kind != "hybrid") {
    report("invalid kind for " path)
    valid = 0
  }
  if (root != "live" && root != "live-project" && root != "cwd") {
    report("invalid root mode for " path)
    valid = 0
  }
  if (interpreter != "bash" && interpreter != "node") {
    report("invalid interpreter for " path)
    valid = 0
  }
  if (min_cli !~ /^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$/) {
    report("invalid min_cli for " path)
    valid = 0
  }
  if (state != "forwarded" && state != "retired" && state != "deleted") {
    report("invalid state for " path)
    valid = 0
  }
  if (path == "" || command == "" || kind == "" || root == "" || interpreter == "" || min_cli == "" || state == "" || path_operands == "") {
    report("missing required field for " path)
    valid = 0
  }
  if (path_operands != "none" &&
      path_operands !~ /^(position:[0-9]+|first-nonoption|all-nonoptions|options:--[a-z0-9-]+(,--[a-z0-9-]+)*|comma:--[a-z0-9-]+)(;(position:[0-9]+|first-nonoption|all-nonoptions|options:--[a-z0-9-]+(,--[a-z0-9-]+)*|comma:--[a-z0-9-]+))*$/) {
    report("invalid path_operands for " path)
    valid = 0
  }
  if (valid) {
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", path, command, kind, root, interpreter, min_cli, state, path_operands
  }
}

/^  - path:[[:space:]]/ {
  emit_entry()
  path = $0
  sub(/^  - path:[[:space:]]*/, "", path)
  command = ""
  kind = ""
  root = ""
  interpreter = ""
  min_cli = ""
  state = ""
  path_operands = ""
  next
}

/^    command:[[:space:]]/ {
  command = $0
  sub(/^    command:[[:space:]]*/, "", command)
  next
}

/^    kind:[[:space:]]/ {
  kind = $0
  sub(/^    kind:[[:space:]]*/, "", kind)
  next
}

/^    root:[[:space:]]/ {
  root = $0
  sub(/^    root:[[:space:]]*/, "", root)
  next
}

/^    interpreter:[[:space:]]/ {
  interpreter = $0
  sub(/^    interpreter:[[:space:]]*/, "", interpreter)
  next
}

/^    min_cli:[[:space:]]/ {
  min_cli = $0
  sub(/^    min_cli:[[:space:]]*/, "", min_cli)
  next
}

/^    state:[[:space:]]/ {
  state = $0
  sub(/^    state:[[:space:]]*/, "", state)
  next
}

/^    path_operands:[[:space:]]/ {
  path_operands = $0
  sub(/^    path_operands:[[:space:]]*/, "", path_operands)
  next
}

END {
  emit_entry()
  if (invalid) exit 1
}
