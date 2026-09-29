#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$SCRIPT_DIR/cli-hosted.yaml"
OUTPUT_ROOT="$HQ_ROOT"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      [ "$#" -ge 2 ] || { echo "--manifest requires a path" >&2; exit 64; }
      MANIFEST="$2"
      shift 2
      ;;
    --output-root)
      [ "$#" -ge 2 ] || { echo "--output-root requires a path" >&2; exit 64; }
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

case "$MANIFEST" in
  /*) ;;
  *) MANIFEST="$PWD/$MANIFEST" ;;
esac
case "$OUTPUT_ROOT" in
  /*) ;;
  *) OUTPUT_ROOT="$PWD/$OUTPUT_ROOT" ;;
esac
[ -r "$MANIFEST" ] || { printf 'cannot read manifest: %s\n' "$MANIFEST" >&2; exit 1; }

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hq-cli-hosted.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ROWS="$TEMP_DIR/rows.tsv"
if ! awk -f "$SCRIPT_DIR/lib/cli-hosted-manifest.awk" "$MANIFEST" > "$ROWS"; then
  exit 1
fi

while IFS="$(printf '\t')" read -r path command kind root interpreter min_cli state; do
  [ "$kind" = "generated" ] || continue
  [ "$state" = "forwarded" ] || continue

  case "$path" in
    *.sh) [ "$interpreter" = "bash" ] || { printf '%s: expected bash interpreter\n' "$path" >&2; exit 1; } ;;
    *.mjs) [ "$interpreter" = "node" ] || { printf '%s: expected node interpreter\n' "$path" >&2; exit 1; } ;;
    *) printf '%s: generated path must end in .sh or .mjs\n' "$path" >&2; exit 1 ;;
  esac
  if ! printf '%s\n' "$command" | awk '!/^[a-z0-9-]+( [a-z0-9-]+)?$/ { exit 1 }'; then
    printf '%s: unsafe command name\n' "$path" >&2
    exit 1
  fi

  note_file="$TEMP_DIR/note"
  awk -v wanted="$path" '
    /^  - path:[[:space:]]/ {
      current = $0
      sub(/^  - path:[[:space:]]*/, "", current)
      active = (current == wanted)
      in_note = 0
      next
    }
    active && /^    note:[[:space:]]*\|[[:space:]]*$/ {
      in_note = 1
      next
    }
    active && in_note && /^[[:space:]]*$/ {
      print ""
      next
    }
    active && in_note && /^      / {
      sub(/^      /, "")
      print
      next
    }
    active && in_note { exit }
  ' "$MANIFEST" > "$note_file"

  output="$OUTPUT_ROOT/$path"
  mkdir -p "$(dirname "$output")"
  script_name="$(basename "$path")"
  if [ "$interpreter" = "bash" ]; then
    {
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        '# FORWARDER — the implementation of this script now lives in the hq CLI.' \
        '#' \
        "# It ships at assets/scaffold/$path inside @indigoai-us/hq-cli and"
      printf '# runs as the hidden command \140hq core %s\140. This file stays behind so every\n' "$command"
      printf '%s\n' \
        '# existing caller — skills, other scripts, CI, and muscle memory — keeps working' \
        '# against the path it already knows.' \
        '#'
      while IFS= read -r note_line || [ -n "$note_line" ]; do
        if [ -n "$note_line" ]; then
          printf '# %s\n' "$note_line"
        else
          printf '#\n'
        fi
      done < "$note_file"
      printf '%s\n' \
        '#' \
        '# The ABI is preserved exactly: arguments are forwarded unchanged, stdin is never' \
        '# read by this file, stdout and stderr are inherited untouched, and the child' \
        '# replaces this process so its exit code and signal disposition become the' \
        "# caller's." \
        '' \
        'set -euo pipefail' \
        ''
      if [ "$root" = "live" ]; then
        printf '%s\n' \
          '# This forwarder sits in the tree it targets, so its own location IS the root.' \
          "HQ_ROOT=\"\${HQ_ROOT:-\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")/../..\" && pwd)}\"" \
          ''
      else
        printf '%s\n' \
          "# No root is injected: this script derived its root from the CALLER's cwd" \
          '# before it moved (git top level, a cwd walk, or a positional argument), and the' \
          '# CLI preserves that. Anything the caller already exported still applies.' \
          ''
      fi
      printf 'if ! command -v hq >/dev/null 2>&1; then\n'
      printf "  echo \"%s: requires the hq CLI — this script's implementation now ships with it.\" >&2\n" "$script_name"
      printf '%s\n' '  echo "Install it with: npm install -g @indigoai-us/hq-cli" >&2'
      printf '  exit 127\n'
      printf 'fi\n\n'
      printf '%s\n' "SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\""
      printf "if [ -f \"\$SCRIPT_DIR/lib/hq-cli-floor.sh\" ]; then\n"
      printf '  # shellcheck source=lib/hq-cli-floor.sh\n'
      printf "  . \"\$SCRIPT_DIR/lib/hq-cli-floor.sh\"\n"
      printf '  hq_cli_floor_check "%s" "%s"\n' "$script_name" "$min_cli"
      printf 'fi\n\n'
      if [ "$root" = "live" ]; then
        printf "exec hq %s --hq-root \"\$HQ_ROOT\" %s \"\$@\"\n" core "$command"
      else
        printf "exec hq %s %s \"\$@\"\n" core "$command"
      fi
    } > "$output"
  else
    command_json='["core"'
    for command_part in $command; do
      command_json="$command_json, \"$command_part\""
    done
    command_json="$command_json]"
    {
      printf '%s\n' \
        '#!/usr/bin/env node' \
        '// FORWARDER — the implementation of this script now lives in the hq CLI.' \
        '//' \
        "// It ships at assets/scaffold/$path inside @indigoai-us/hq-cli and"
      printf '// runs as the hidden command \140hq core %s\140. This file stays behind so every\n' "$command"
      printf '%s\n' \
        '// existing caller — skills, other scripts, CI, and muscle memory — keeps working' \
        '// against the path it already knows.' \
        '//'
      while IFS= read -r note_line || [ -n "$note_line" ]; do
        if [ -n "$note_line" ]; then
          printf '// %s\n' "$note_line"
        else
          printf '//\n'
        fi
      done < "$note_file"
      printf '%s\n' \
        '//' \
        '// The ABI is preserved exactly: arguments are forwarded unchanged, stdin is never' \
        '// read by this file, stdout and stderr are inherited untouched, and the child' \
        '// exit code and signal disposition are relayed to this process.' \
        ''
      printf '%s\n' \
        'import { spawn, spawnSync } from "node:child_process";' \
        'import * as fs from "node:fs";' \
        'import path from "node:path";' \
        'import { fileURLToPath } from "node:url";' \
        ''
      printf 'const scriptDir = path.dirname(fileURLToPath(import.meta.url));\n'
      printf 'const scriptName = "%s";\n' "$script_name"
      printf 'const minCli = "%s";\n' "$min_cli"
      printf 'const commandArgs = %s;\n' "$command_json"
      if [ "$root" = "live" ]; then
        printf 'const hqRoot = process.env.HQ_ROOT || path.resolve(scriptDir, "../..");\n'
        printf 'const rootArgs = ["--hq-root", hqRoot];\n\n'
      else
        printf 'const rootArgs = [];\n\n'
      fi
      printf '%s\n' \
        'function hqIsAvailable() {' \
        '  const directories = (process.env.PATH || "").split(path.delimiter);' \
        '  return directories.some((directory) => fs.existsSync(path.join(directory || ".", "hq")));' \
        '}' \
        '' \
        'function writeMissingCli() {' \
        "  process.stderr.write(scriptName + \": requires the hq CLI — this script's implementation now ships with it.\\n\");" \
        '  process.stderr.write("Install it with: npm install -g @indigoai-us/hq-cli\n");' \
        '}' \
        '' \
        'if (!hqIsAvailable()) {' \
        '  writeMissingCli();' \
        '  process.exit(127);' \
        '}' \
        ''
      printf 'const floorLibrary = path.join(scriptDir, "lib", "hq-cli-floor.sh");\n'
      printf '%s\n' \
        'if (fs.existsSync(floorLibrary)) {' \
        "  const floor = spawnSync(\"bash\", [\"-c\", '. \"\$1\"; hq_cli_floor_check \"\$2\" \"\$3\"', \"cli-hosted-floor\", floorLibrary, scriptName, minCli], { stdio: \"inherit\" });" \
        '  if (floor.error) {' \
        '    process.stderr.write(scriptName + ": could not run CLI version floor check: " + floor.error.message + "\n");' \
        '    process.exit(126);' \
        '  }' \
        '  if (floor.signal) process.kill(process.pid, floor.signal);' \
        '  if (floor.status !== 0) process.exit(floor.status === null ? 1 : floor.status);' \
        '}' \
        ''
      printf '%s\n' \
        'const args = ["core", ...rootArgs, ...commandArgs.slice(1), ...process.argv.slice(2)];' \
        'const child = spawn("hq", args, { stdio: "inherit" });' \
        'child.on("error", (error) => {' \
        '  if (error.code === "ENOENT") {' \
        '    writeMissingCli();' \
        '    process.exit(127);' \
        '  }' \
        '  process.stderr.write(scriptName + ": " + error.message + "\n");' \
        '  process.exit(1);' \
        '});' \
        'child.on("exit", (code, signal) => {' \
        '  if (signal) {' \
        '    process.kill(process.pid, signal);' \
        '    return;' \
        '  }' \
        '  process.exit(code === null ? 1 : code);' \
        '});'
    } > "$output"
  fi
  chmod +x "$output"
done < "$ROWS"
