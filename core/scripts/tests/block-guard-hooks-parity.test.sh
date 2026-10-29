#!/usr/bin/env bash
# Replay every existing fixture suite and hook YAML case against pinned and
# candidate guard sources, comparing each invocation's input, exit, stdout, and
# stderr. The source test files remain unchanged.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
REAL_BASH="$(command -v bash)"
ORIGINAL_PATH="$PATH"
. "$ROOT/core/scripts/tests/hook-process-budget-common.sh"
c138c_init_process_budget

ln -s "$C138C_TMP/cwd/age" "$C138C_TMP/cwd/age-symlink"
ln -s "$C138C_TMP/cwd/plain" "$C138C_TMP/cwd/plain-symlink"

for variant in base candidate; do
  mkdir -p "$C138C_TMP/source/$variant/core/scripts"
  cp "$C138C_TMP/fixture/core/scripts/hook-lib.sh" \
    "$C138C_TMP/source/$variant/core/scripts/hook-lib.sh"
  cp "$C138C_TMP/fixture/core/scripts/install-deps.allow" \
    "$C138C_TMP/source/$variant/core/scripts/install-deps.allow"
done

mkdir -p "$C138C_TMP/wrapper"
cat > "$C138C_TMP/wrapper/bash" <<'WRAPPER'
#!/bin/bash
set -uo pipefail
real_bash="${HQ_PARITY_REAL_BASH:-/bin/bash}"
args=("$@")
target_index=-1
target_kind=""
for i in "${!args[@]}"; do
  case "${args[$i]##*/}" in
    block-unsafe-package-install.sh) target_index="$i"; target_kind=unsafe; break ;;
    block-core-writes-bash.sh) target_index="$i"; target_kind=core; break ;;
  esac
done
if [ "$target_index" -lt 0 ]; then
  exec "$real_bash" "$@"
fi

count_file="$HQ_PARITY_RECORD_ROOT/count"
count=0
if [ -f "$count_file" ]; then read -r count < "$count_file"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
record="$HQ_PARITY_RECORD_ROOT/$count"
mkdir -p "$record/base" "$record/candidate"
printf '%s\n' "$target_kind" > "$record/hook"
cat > "$record/input"
base_args=("${args[@]}")
candidate_args=("${args[@]}")
case "$target_kind" in
  unsafe)
    base_args[$target_index]="$HQ_PARITY_UNSAFE_BASE_HOOK"
    candidate_args[$target_index]="$HQ_PARITY_UNSAFE_CANDIDATE_HOOK"
    ;;
  core)
    base_args[$target_index]="$HQ_PARITY_CORE_BASE_HOOK"
    candidate_args[$target_index]="$HQ_PARITY_CORE_CANDIDATE_HOOK"
    ;;
esac
env HQ_TEST_OPERATION_LOG=/dev/null HQ_TEST_GREP_CALLS=/dev/null HQ_TEST_SED_CALLS=/dev/null \
  "$real_bash" "${base_args[@]}" < "$record/input" \
  > "$record/base/stdout" 2> "$record/base/stderr"
base_rc=$?
printf '%s\n' "$base_rc" > "$record/base/exit"
"$real_bash" "${candidate_args[@]}" < "$record/input" > "$record/candidate/stdout" 2> "$record/candidate/stderr"
candidate_rc=$?
printf '%s\n' "$candidate_rc" > "$record/candidate/exit"
invalid_release_age=0
if [ "$target_kind" = unsafe ] && python3 - "$record/input" <<'PY'
import json
import os
import re
import shlex
import sys
from pathlib import Path

def valid(value: str) -> bool:
    return value.isascii() and value.isdigit() and int(value) >= 1440

try:
    command = json.loads(open(sys.argv[1], encoding="utf-8").read())["tool_input"]["command"]
    tokens = shlex.split(command.replace("\\\n", " "))
    age_flags = [
        token.split("=", 1)[1]
        for token in tokens
        if token.startswith(("--config.minimumReleaseAge=", "--config.minimum-release-age="))
    ]
    invalid = any(not valid(value) for value in age_flags)
    release_age_present = bool(age_flags)
except (KeyError, TypeError, ValueError):
    invalid = False
    release_age_present = False

for name in ("npm_config_minimum_release_age", "NPM_CONFIG_MINIMUM_RELEASE_AGE"):
    if name in os.environ:
        release_age_present = True
        invalid = invalid or not valid(os.environ[name])

if not release_age_present:
    config_patterns = (
        (".npmrc", re.compile(r"^\s*minimum-release-age\s*=(.*)$")),
        ("pnpm-workspace.yaml", re.compile(r"^\s*minimumReleaseAge\s*:(.*)$")),
    )
    for directory in (Path.cwd(), *list(Path.cwd().parents)[:5]):
        for filename, pattern in config_patterns:
            config_path = directory / filename
            try:
                lines = config_path.read_text(encoding="utf-8").splitlines()
            except FileNotFoundError:
                continue
            for line in lines:
                match = pattern.match(line)
                if match:
                    value = match.group(1)
                    if filename == "pnpm-workspace.yaml":
                        value = re.split(r"\s+#", value, maxsplit=1)[0]
                    value = value.strip().strip("\"'")
                    invalid = invalid or not valid(value)
sys.exit(0 if invalid else 1)
PY
then
  invalid_release_age=1
fi

# feedback_a041edbc: the candidate denies package installs launched through a
# wrapper (mise exec, env, npx, sudo, nice, xargs, ...) that the pinned
# baseline let through. Accept exactly that divergence: baseline allowed,
# candidate denied with the supply-chain message, and the segment that holds
# the install starts with a known launcher. A bare install segment anywhere in
# the command disqualifies the allowance.
launcher_wrapper_block=0
if [ "$target_kind" = unsafe ] && [ "$base_rc" -eq 0 ] && [ "$candidate_rc" -eq 2 ] \
  && grep -Fq 'BLOCKED — supply-chain guard' "$record/candidate/stderr" \
  && python3 - "$record/input" <<'PY'
import json
import re
import sys

LAUNCHERS = {
    "mise", "env", "npx", "bunx", "command", "exec", "nohup", "time", "sudo",
    "doas", "nice", "timeout", "stdbuf", "caffeinate", "xargs", "corepack",
    "ionice", "chrt", "taskset", "volta", "pnpx",
}
INSTALL = re.compile(r"(^|[\s'\"\\])(npm|yarn|bun|pnpm)(@\S*)?[\s'\"]+(install|i|add)\b")
XARGS_INSTALL = re.compile(r"\bxargs\b.*\b(npm|yarn|bun|pnpm)\b")
MANAGER_LAUNCH = re.compile(r"^(pnpm|yarn)\s+dlx\b|^(pnpm|yarn|npm|bun)\s+exec\b|^(bun|npm|pnpm)\s+x\b")
try:
    command = json.loads(open(sys.argv[1], encoding="utf-8").read())["tool_input"]["command"]
except (KeyError, TypeError, ValueError):
    sys.exit(1)
wrapped = False
for segment in re.split(r"&&|\|\||[;|\n]", command):
    segment = segment.strip()
    while re.match(r"^[A-Za-z_][A-Za-z0-9_]*=\S*\s", segment):
        segment = segment.split(None, 1)[1].strip()
    words = segment.split()
    if not words:
        continue
    if not (INSTALL.search(segment) or XARGS_INSTALL.search(segment)):
        continue
    first = words[0].strip("\"'\\").rsplit("/", 1)[-1]
    if (MANAGER_LAUNCH.match(segment) or first in LAUNCHERS
            or (words[0][:1] in "\"'\\" and first in {"npm", "pnpm", "yarn", "bun"})
            or (first == "yarn" and len(words) > 1 and words[1] in {"npx", "pnpx", "bunx", "npm", "pnpm", "bun"})
            or (first in {"npm", "pnpm"} and len(words) > 1 and words[1] == "x")):
        wrapped = True
    elif re.match(r"^(npm|yarn|bun|pnpm)\s+(install|i|add)\b", segment):
        sys.exit(1)
sys.exit(0 if wrapped else 1)
PY
then
  launcher_wrapper_block=1
fi

# feedback_03770784: the candidate checks every command unit with a
# quote-aware split, so installs after a leading text command, inside $( ) /
# backticks / unquoted heredoc bodies, or in bash -c / eval / `| bash` scripts
# are denied where the pinned baseline allowed them. Accept exactly that
# divergence: baseline allowed, candidate denied with the supply-chain message,
# and an independent quote-aware parse finds a unit that runs
# `<pm> install|i|add <package>`.
segment_install_block=0
if [ "$target_kind" = unsafe ] && [ "$base_rc" -eq 0 ] && [ "$candidate_rc" -eq 2 ] \
  && grep -Fq 'BLOCKED — supply-chain guard' "$record/candidate/stderr" \
  && python3 - "$record/input" <<'PY'
import json
import re
import shlex
import sys

# feedback_03770784: the candidate checks every command unit, including units
# after a leading text command, units inside $( ) / backticks / unquoted
# heredoc bodies, and the scripts of bash -c, eval, find -exec, watch, and
# shells fed through a pipe, here-string or heredoc. Accept base 0 ->
# candidate 2 only when this independent quote-aware parse finds a unit that
# really runs `<pm> <install alias> <package>`, or when substitutions nest
# past the parser limit around package-manager text (the candidate fails
# closed there).
PMS = {"npm", "pnpm", "yarn", "bun"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "fish", "tcsh", "csh"}
KEYWORDS = {"{", "!", "if", "then", "elif", "else", "while", "until", "do", "coproc", "time"}
LAUNCHERS = {"env", "command", "exec", "nohup", "sudo", "doas", "nice", "xargs", "time",
             "stdbuf", "timeout", "ionice", "chrt", "taskset", "caffeinate", "busybox",
             "arch", "chronic", "unbuffer"}
VALUE_OPTS = {"-u", "-g", "-C", "-D", "-n", "-o", "-e", "-i", "-s", "-k", "-c", "-p",
              "--signal", "--kill-after", "--user", "--group"}
INSTALL_SUBS = {"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta",
                "isntal", "isntall", "it", "install-test", "add"}
PM_TEXT = re.compile(r"npm|yarn|bun")
MAX_NEST = 60


def split_units(text, depth):
    """Return a list of (kind, payload) records for one command list."""
    if depth > MAX_NEST:
        return [("deep", text)]
    out = []
    n = len(text)
    i = 0
    start = 0
    heredocs = []
    line_first = 0

    def close(end):
        unit = text[start:end].strip()
        if unit:
            out.append(("unit", unit))

    def subst(j, closer):
        k = j
        level = 0
        while k < n:
            ch = text[k]
            if ch == "\\":
                k += 2
                continue
            if ch == "'" and closer == ")":
                end = text.find("'", k + 1)
                k = n if end < 0 else end + 1
                continue
            if ch == '"' and closer == ")":
                k = dquote(k + 1)
                continue
            if closer == ")" and ch == "(":
                level += 1
            elif ch == closer and (closer == "`" or level == 0):
                out.extend(split_units(text[j:k], depth + 1))
                return k + 1
            elif closer == ")" and ch == ")":
                level -= 1
            k += 1
        out.extend(split_units(text[j:], depth + 1))
        return n

    def dquote(k):
        while k < n:
            ch = text[k]
            if ch == "\\":
                k += 2
                continue
            if ch == '"':
                return k + 1
            if ch == "`":
                k = subst(k + 1, "`")
                continue
            if text.startswith("$((", k):
                end = text.find("))", k)
                k = n if end < 0 else end + 2
                continue
            if text.startswith("$(", k):
                k = subst(k + 2, ")")
                continue
            k += 1
        return n

    while i < n:
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "'":
            end = text.find("'", i + 1)
            i = n if end < 0 else end + 1
            continue
        if text.startswith("$'", i):
            k = i + 2
            while k < n and text[k] != "'":
                k += 2 if text[k] == "\\" else 1
            i = k + 1
            continue
        if ch == '"':
            i = dquote(i + 1)
            continue
        if text.startswith("$((", i) or (text.startswith("((", i) and not text[start:i].strip()):
            end = text.find("))", i)
            i = n if end < 0 else end + 2
            continue
        if text.startswith("$(", i):
            i = subst(i + 2, ")")
            continue
        if ch == "`":
            i = subst(i + 1, "`")
            continue
        if ch == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            close(i)
            end = text.find("\n", i)
            i = n if end < 0 else end
            start = i
            continue
        if text.startswith("<<<", i):
            i += 3
            continue
        if text.startswith("<<", i):
            m = re.match(r"<<-?[ \t]*\$'((?:[^'\\]|\\.)*)'", text[i:])
            if m:
                # ANSI-C quoted delimiter: bash matches the decoded text.
                heredocs.append((ansi_decode(m.group(1)), True))
                i += m.end()
                continue
            m = re.match(r"<<-?[ \t]*(\$?)(['\"]?)(\\?)([A-Za-z0-9_.-]+)\2", text[i:])
            if m:
                quoted = bool(m.group(2) or m.group(3))
                heredocs.append((m.group(4), quoted))
                i += m.end()
                continue
        if ch == "&" and ((i > 0 and text[i - 1] in "<>") or text[i + 1:i + 2] == ">"):
            i += 1
            continue
        if ch in ";|&()\n":
            close(i)
            if ch == "|" and i + 1 < n and text[i + 1] != "|":
                out.append(("pipe", ""))
            i += 1
            start = i
            if ch == "\n":
                if heredocs:
                    # A body is a script only when a shell on this line reads stdin.
                    fed = any(kind == "unit" and stdin_shell(words_of(payload))
                              for kind, payload in out[line_first:])
                    for delim, quoted in heredocs:
                        body_start = i
                        body = text[body_start:]
                        while i < n:
                            end = text.find("\n", i)
                            line = text[i:] if end < 0 else text[i:end]
                            if line.lstrip("\t").rstrip("\r") == delim:
                                body = text[body_start:i]
                                i = n if end < 0 else end + 1
                                break
                            i = n if end < 0 else end + 1
                        else:
                            i = n
                        if fed:
                            out.append(("script", body))
                        if not quoted:
                            for sm in re.finditer(r"\$\(([^()]*)\)|`([^`]*)`", body):
                                out.extend(split_units(sm.group(1) or sm.group(2) or "", depth + 1))
                    heredocs = []
                    start = i
                line_first = len(out)
            continue
        i += 1
    close(n)
    return out


def ansi_decode(body):
    try:
        return body.encode("latin-1", "backslashreplace").decode("unicode_escape")
    except (UnicodeDecodeError, ValueError):
        return body


def words_of(unit):
    unit = unit.replace("\\\n", "")
    unit = re.sub(r"\$'((?:[^'\\]|\\.)*)'", lambda m: shlex.quote(ansi_decode(m.group(1))), unit)
    try:
        return shlex.split(unit, comments=False, posix=True)
    except ValueError:
        return unit.split()


def strip_launchers(words):
    while words:
        base = words[0].rsplit("/", 1)[-1]
        if words[0] in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words = words[1:]
        elif words[0] == "function" and len(words) > 1:
            words = words[2:]
        elif base in LAUNCHERS:
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[2:] if words[0] in VALUE_OPTS else words[1:]
            if base in ("timeout", "chrt", "taskset"):
                words = words[1:]
        else:
            break
    return words


def stdin_shell(words):
    words = strip_launchers(words)
    if not words or words[0].rsplit("/", 1)[-1] not in SHELLS:
        return False
    return len(words) == 1 or words[1].startswith(("-", "+", "<"))


def shell_script(rest, shell):
    seen_c = False
    k = 0
    while k < len(rest):
        w = rest[k]
        if w == "--":
            k += 1
            break
        if w.startswith("--command="):
            return w.split("=", 1)[1]
        if w == "--command" or re.fullmatch(r"-[A-Za-z]*c[A-Za-z]*", w):
            seen_c = True
        elif w in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file", "--init-command") \
                or (shell == "fish" and w == "-C"):
            k += 1
        elif not w.startswith(("-", "+")):
            break
        k += 1
    if seen_c and k < len(rest):
        return rest[k]
    if "<<<" in rest and rest.index("<<<") + 1 < len(rest):
        return rest[rest.index("<<<") + 1]
    return None


def installs(text, depth=0):
    if depth > 8:
        return False
    piped_text = []
    in_pipe = False
    for kind, payload in split_units(text, depth):
        if kind == "deep":
            if PM_TEXT.search(payload):
                return True
            continue
        if kind == "pipe":
            in_pipe = True
            continue
        if kind == "script":
            if installs(payload, depth + 1):
                return True
            continue
        words = strip_launchers(words_of(payload))
        if not words:
            piped_text, in_pipe = [], False
            continue
        first = words[0].rsplit("/", 1)[-1]
        if first == "busybox" and len(words) > 1:
            words = words[1:]
            first = words[0].rsplit("/", 1)[-1]
        if first == "eval" and installs(" ".join(words[1:]), depth + 1):
            return True
        if first == "watch":
            rest = words[1:]
            while rest and rest[0].startswith("-"):
                rest = rest[2:] if rest[0] in ("-n", "--interval", "-q", "--equexit") else rest[1:]
            if rest and installs(" ".join(rest), depth + 1):
                return True
        if first in ("flock", "script", "parallel"):
            rest = words[1:]
            while rest and rest[0].startswith("-") and rest[0] not in ("-c", "--command"):
                rest = rest[2:] if rest[0] in ("-w", "--timeout", "-E", "-t", "-T", "-F", "-j", "--jobs", "-S") else rest[1:]
            if rest and rest[0] in ("-c", "--command"):
                if len(rest) > 1 and installs(rest[1], depth + 1):
                    return True
            else:
                if first != "parallel":
                    rest = rest[1:]
                if rest and rest[0] in ("-c", "--command") and len(rest) > 1:
                    if installs(rest[1], depth + 1):
                        return True
                cmd = [w for w in rest if w not in (":::", "::::", ":::+")]
                if cmd and installs(" ".join(shlex.quote(c) for c in cmd), depth + 1):
                    return True
        if first == "find":
            cmd = []
            collecting = False
            for w in words[1:] + [";"]:
                if collecting and w in (";", "+"):
                    if cmd and installs(" ".join(shlex.quote(c) for c in cmd), depth + 1):
                        return True
                    cmd, collecting = [], False
                elif collecting:
                    cmd.append(w)
                elif w in ("-exec", "-execdir", "-ok", "-okdir"):
                    collecting = True
        if first in SHELLS:
            script = shell_script(words[1:], first)
            if script is not None and installs(script, depth + 1):
                return True
            if script is None and stdin_shell(words) and in_pipe and piped_text:
                if installs(" ".join(w for w in piped_text if not w.startswith("-")), depth + 1):
                    return True
        if first in PMS:
            k = 1
            while k < len(words) and words[k].startswith("-"):
                k += 1
                if k < len(words) and words[k - 1] in ("--prefix", "--registry", "--dir", "-C", "--cache"):
                    k += 1
            if k < len(words) and words[k] in INSTALL_SUBS:
                if not (first == "yarn" and words[k] != "add"):
                    if any(not w.startswith("-") for w in words[k + 1:]):
                        return True
        piped_text = (piped_text if in_pipe else []) + words[1:]
        in_pipe = False
    return False


try:
    command = json.loads(open(sys.argv[1], encoding="utf-8").read())["tool_input"]["command"]
except (KeyError, TypeError, ValueError):
    sys.exit(1)
sys.exit(0 if installs(command) else 1)
PY
then
  segment_install_block=1
fi

# PR 1674 and its review: the candidate blocks installs that override the
# package source even for first-party or allow-listed packages, and inspects
# `yarn global add`. Overrides are registry / config-file / CA / TLS / proxy
# flags (including npm's unambiguous prefixes such as --reg=, case variants
# and globbed names), package-manager env vars anywhere in the command,
# HOME / XDG_CONFIG_HOME / proxy / CA env vars only when exported or prefixed
# to the install segment, writes to .npmrc / etc/npmrc / .yarnrc / .yarnrc.yml
# / bunfig.toml (cp/mv/ln/install/rsync only when the rc file is the
# destination; also curl -o / wget -O), `<pm> config set|edit`, indirect
# export/declare, and
# a standalone HOME=...; style statement before the install. The
# pinned baseline allowed them. Accept only base 0 -> candidate 2 with the
# supply-chain message when an independent parse finds an install segment
# (`<pm> install|i|add <pkg>` or `yarn global add <pkg>`) and either override
# evidence in the command or a `yarn global add` segment. Never the reverse.
source_override_block=0
if [ "$target_kind" = unsafe ] && [ "$base_rc" -eq 0 ] && [ "$candidate_rc" -eq 2 ] \
  && grep -Fq 'BLOCKED — supply-chain guard' "$record/candidate/stderr" \
  && python3 - "$record/input" <<'PY'
import json
import re
import sys

try:
    command = json.loads(open(sys.argv[1], encoding="utf-8").read())["tool_input"]["command"]
except (KeyError, TypeError, ValueError):
    sys.exit(1)
INSTALL = re.compile(r"(^|\s)(npm|pnpm|yarn|bun)(\s+-\S+(\s+[^-\s]\S*)?)*?\s+(install|i|add)\s+(.*\s)?[^-\s]")
YARN_GLOBAL = re.compile(r"(^|\s)yarn(\s+\S+)*?\s+global\s+add\s+(.*\s)?[^-\s]")
FLAG = re.compile(r"(^|\s)--?(no-)?(reg|regi|regis|regist|registr|registry|userc|userco|usercon|userconf|userconfi|userconfig|globalc|globalco|globalcon|globalconf|globalconfi|globalconfig|caf|cafi|cafile|ca|strict-s|strict-ss|strict-ssl|re|prox|proxy|https|https-|https-p|https-pr|https-pro|https-prox|https-proxy|config\.\S*registry\S*|@\S*:registry)(=|\s|$)"
                  r"|(^|\s)--?(no-)?r\w*[\[\]?*{]", re.I)
# Package-manager env vars count anywhere in the command.
ENV = re.compile(r"(npm_config_\w*(registry|userconfig|globalconfig|cafile|strict_ssl)\w*|npm_config_ca|npm_config_@\S*registry|npm_config_(https_|http_)?proxy|corepack_\w*registr\w*|yarn_\w*(registry|ca_file_path|cafile|strict_ssl|rc_filename|scopes)\w*|bun_config_\w*registr\w*|bun_install_\w*registr\w*)\s*:?=", re.I)
# General env vars count only when exported/declared, or as a prefix of the
# install segment (checked per segment below).
GENERAL = r"(https?_proxy|all_proxy|node_extra_ca_certs|node_tls_reject_unauthorized|ssl_cert_file|ssl_cert_dir|home|xdg_config_home)"
GEN_EXPORT = re.compile(r"(^|[^\w])(export|declare|typeset|readonly)(\s+-[a-z]+)*\s+([^;&|]*\s)?\"?" + GENERAL + r"\s*=", re.I)
GEN_PREFIX = re.compile(r"^[\"']?" + GENERAL + "=", re.I)
RC = r"(\.npmrc|/npmrc|\.yarnrc|\.yarnrc\.yml|bunfig\.toml|(\.[ny\[]|/n|bunf)[^\s;&|/]*[\[\]?*{])"
RCFILE = re.compile(r"(>\|?\s*\S*|(^|\W)tee\s[^;&|]*|sed\s[^;&|]*-i[^;&|]*|of=\S*|(curl|wget)\s[^;&|]*(-o|--output|--output-document)(=|\s*)\S*)" + RC, re.I)
CONFIG_SET = re.compile(r"(^|\W)(npm|pnpm|yarn|bun)(\s+\S+)*?\s+(config|c)\s+(\S+\s+)*?(set|edit)([^\w-]|$)|(^|\W)(npm|pnpm)\s+set\s", re.I)
INDIRECT = re.compile(r"(^|\W)(export|declare|typeset|readonly|local)(\s+-[a-z]+)*\s+([^;&|]*\s)?\"?\w*\$(\([^)]*\)|[^=\s])*=", re.I)
STANDALONE = re.compile(r"(^|[;&|({]|then|do|else)\s*" + GENERAL + r"=[^\s;&|]*\s*([;&|)}]|$)", re.I)
RC_NAMES = {".npmrc", "npmrc", ".yarnrc", ".yarnrc.yml", "bunfig.toml"}


def rc_base(path):
    base = path.rstrip("/").rsplit("/", 1)[-1].lower()
    return base in RC_NAMES or (re.search(r"[\[\]?*{]", base) is not None and re.search(RC, base, re.I) is not None)


def copy_writes_rc(seg):
    words = seg.split()
    k = 0
    while k < len(words) and (words[k] in ("sudo", "doas", "command", "exec", "nohup", "env", "time")
                              or words[k].startswith("-") or "=" in words[k]):
        k += 1
    if k >= len(words) or words[k].rsplit("/", 1)[-1] not in ("cp", "mv", "ln", "install", "rsync", "gcp", "gmv", "ditto"):
        return False
    tool = words[k].rsplit("/", 1)[-1]
    ops, tdir, want_t = [], None, False
    for w in words[k + 1:]:
        if want_t:
            tdir, want_t = w, False
        elif w in ("-t", "--target-directory"):
            want_t = True
        elif w.startswith("--target-directory="):
            tdir = w.split("=", 1)[1]
        elif w.startswith("-t") and len(w) > 2:
            tdir = w[2:]
        elif not w.startswith("-"):
            ops.append(w)
    dirlike = False
    if tdir is not None:
        dest, dirlike = tdir, True
    elif len(ops) >= 2:
        dest = ops.pop()
    elif len(ops) == 1 and tool == "ln":
        dest, dirlike = ".", True
    else:
        return False
    if rc_base(dest):
        return True
    if dest.lower() in ("~", "~/", ".", "./", "$home", "${home}", "$home/", "${home}/") or dest.endswith("/"):
        dirlike = True
    return dirlike and any(rc_base(src) for src in ops)


dequoted = re.sub(r"[\"'\\]", "", command.replace("$'", "'"))
segments = [seg.strip() for seg in re.split(r"&&|\|\||[;|&\n]", command)]
yarn_global = any(YARN_GLOBAL.search(seg) for seg in segments)
install = yarn_global or any(INSTALL.search(seg) for seg in segments)
evidence = any(rx.search(text) for text in (command, dequoted)
               for rx in (FLAG, ENV, RCFILE, CONFIG_SET, INDIRECT, GEN_EXPORT, STANDALONE))
for seg in re.split(r"&&|\|\||[;|&\n]", dequoted.lower()):
    if copy_writes_rc(seg.strip()):
        evidence = True
for seg in segments:
    if INSTALL.search(seg):
        for word in seg.split():
            if word.rsplit("/", 1)[-1] in ("npm", "pnpm", "yarn", "bun"):
                break
            if GEN_PREFIX.search(word):
                evidence = True
sys.exit(0 if install and (evidence or yarn_global) else 1)
PY
then
  source_override_block=1
fi

# US-008: the candidate exempts a single-line hq-pr-create.sh invocation (via
# bash, sh, or direct execution) the same way it exempts `gh pr create`, so PR
# body text is not parsed as install commands. The pinned baseline predates the
# wrapper and blocks it. Shell operators outside quotes disqualify the command.
pr_create_wrapper=0
if [ "$target_kind" = unsafe ] && [ "$base_rc" -eq 2 ] && [ "$candidate_rc" -eq 0 ] \
  && python3 - "$record/input" <<'PY'
import json
import re
import shlex
import sys

try:
    command = json.loads(open(sys.argv[1], encoding="utf-8").read())["tool_input"]["command"]
    if "\n" in command:
        sys.exit(1)
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except (KeyError, TypeError, ValueError):
    sys.exit(1)
if not tokens or any(token and set(token) <= set("();<>|&") for token in tokens):
    sys.exit(1)
script = tokens[1] if tokens[0] in ("bash", "sh") and len(tokens) > 1 else tokens[0]
sys.exit(0 if re.fullmatch(r"(\S*/)?core/scripts/hq-pr-create\.sh", script) else 1)
PY
then
  pr_create_wrapper=1
fi

cmp -s "$record/base/stdout" "$record/candidate/stdout" || {
  printf 'FAIL: %s guard differs on fixture invocation %s (stdout)\n' "$target_kind" "$count" >&2
  exit 1
}
intentional_release_age_block=0
if [ "$pr_create_wrapper" -eq 1 ]; then
  grep -Fq 'BLOCKED' "$record/base/stderr" \
    && [ ! -s "$record/candidate/stdout" ] && [ ! -s "$record/candidate/stderr" ] \
    || { printf 'FAIL: US-008 hq-pr-create.sh exemption has unexpected output\n' >&2; exit 1; }
elif [ "$launcher_wrapper_block" -eq 1 ]; then
  :
elif [ "$segment_install_block" -eq 1 ]; then
  :
elif [ "$source_override_block" -eq 1 ]; then
  :
elif [ "$base_rc" -ne "$candidate_rc" ]; then
  if [ "$target_kind" != unsafe ] || [ "$invalid_release_age" -ne 1 ] \
    || [ "$base_rc" -ne 0 ] || [ "$candidate_rc" -ne 2 ]; then
    printf 'FAIL: %s guard exit differs on fixture invocation %s (base %s, candidate %s)\n' \
      "$target_kind" "$count" "$base_rc" "$candidate_rc" >&2
    exit 1
  fi
  grep -Fq 'BLOCKED — supply-chain guard' "$record/candidate/stderr" \
    && grep -Fq 'minimum-release-age=1440' "$record/candidate/stderr" \
    || { printf 'FAIL: US-107 release-age denial has unexpected candidate message\n' >&2; exit 1; }
  intentional_release_age_block=1
fi

for field in stdout stderr exit; do
  if { [ "$intentional_release_age_block" -eq 1 ] || [ "$pr_create_wrapper" -eq 1 ] \
      || [ "$launcher_wrapper_block" -eq 1 ] || [ "$segment_install_block" -eq 1 ] \
      || [ "$source_override_block" -eq 1 ]; } \
    && { [ "$field" = stderr ] || [ "$field" = exit ]; }; then
    continue
  fi
  cmp -s "$record/base/$field" "$record/candidate/$field" || {
    printf 'FAIL: %s guard differs on fixture invocation %s (%s)\n' "$target_kind" "$count" "$field" >&2
    exit 1
  }
done
cat "$record/candidate/stdout"
cat "$record/candidate/stderr" >&2
exit "$candidate_rc"
WRAPPER
chmod +x "$C138C_TMP/wrapper/bash"

run_fixture_suites() {
  local test_file rc
  local record_root="$C138C_TMP/records"
  local bin="$C138C_TMP/bin"
  local tmp="$C138C_TMP/suite-tmp"
  mkdir -p "$bin" "$record_root" "$tmp"
  PATH="$bin:$PATH"
  ln -sf "$C138C_TMP/wrapper/bash" "$bin/bash"
  export PATH
  export BASH_ENV=/dev/null
  export HQ_PARITY_REAL_BASH="$REAL_BASH"
  export HQ_PARITY_RECORD_ROOT="$record_root"
  export HQ_PARITY_UNSAFE_BASE_HOOK="$C138C_TMP/source/base/.claude/hooks/block-unsafe-package-install.sh"
  export HQ_PARITY_UNSAFE_CANDIDATE_HOOK="$C138C_TMP/source/candidate/.claude/hooks/block-unsafe-package-install.sh"
  export HQ_PARITY_CORE_BASE_HOOK="$C138C_TMP/source/base/.claude/hooks/block-core-writes-bash.sh"
  export HQ_PARITY_CORE_CANDIDATE_HOOK="$C138C_TMP/source/candidate/.claude/hooks/block-core-writes-bash.sh"
  export TMPDIR="$tmp"

  for test_file in \
    .claude/hooks/tests/block-unsafe-package-install.test.sh \
    core/scripts/tests/block-unsafe-package-install.test.sh \
    core/scripts/tests/block-core-writes-bash.test.sh \
    core/scripts/tests/block-core-writes-bash-fast-path.test.sh \
    core/scripts/tests/block-core-writes-bash-fanout.test.sh; do
    if timeout 180s "$REAL_BASH" "$ROOT/$test_file" \
        > "$C138C_TMP/${test_file##*/}.out" \
        2> "$C138C_TMP/${test_file##*/}.err"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 0 ] || {
      printf 'FAIL: %s fixture suite exited %s\n' "$test_file" "$rc" >&2
      cat "$C138C_TMP/${test_file##*/}.err" >&2
      cat "$C138C_TMP/${test_file##*/}.out" >&2
      return 1
    }
  done

  # US-008 negative cases: chained wrapper commands fall outside the
  # hq-pr-create.sh carve-out. Since feedback_03770784 the candidate checks
  # every unit and denies them like the baseline, so the wrapper must pass the
  # denial through (exit 2, supply-chain message) and never exempt them.
  local negative negative_err payload
  negative_err="$C138C_TMP/negative.err"
  mkdir -p "$C138C_TMP/negative-records" "$C138C_TMP/negative-cwd"
  for negative in \
    'bash core/scripts/hq-pr-create.sh --title t && npm install left-pad' \
    'core/scripts/hq-pr-create.sh --title t; npm install left-pad' \
    'bash core/scripts/hq-pr-create.sh --title t | npm install left-pad'; do
    payload="$(jq -cn --arg cmd "$negative" '{tool_name:"Bash",tool_input:{command:$cmd}}')"
    if ( cd "$C138C_TMP/negative-cwd" && printf '%s' "$payload" \
        | HQ_PARITY_RECORD_ROOT="$C138C_TMP/negative-records" HQ_ROOT="$C138C_TMP/negative-cwd" \
          HQ_ALLOW_UNSAFE_INSTALL=0 bash "$HQ_PARITY_UNSAFE_CANDIDATE_HOOK" \
          > /dev/null 2> "$negative_err" ); then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 2 ] || ! grep -Fq 'BLOCKED — supply-chain guard' "$negative_err"; then
      printf 'FAIL: US-008 carve-out accepted a chained wrapper command (exit %s): %s\n' \
        "$rc" "$negative" >&2
      cat "$negative_err" >&2
      return 1
    fi
  done
}

run_fixture_suites
PATH="$ORIGINAL_PATH"
export PATH
unset HQ_PARITY_REAL_BASH HQ_PARITY_RECORD_ROOT HQ_PARITY_UNSAFE_BASE_HOOK \
  HQ_PARITY_UNSAFE_CANDIDATE_HOOK HQ_PARITY_CORE_BASE_HOOK HQ_PARITY_CORE_CANDIDATE_HOOK

fixture_count="$(cat "$C138C_TMP/records/count")"

# Check adversarial command shapes against the same pinned/candidate pair. The
# helper compares exit, stdout, and stderr for every pair; cases with an
# explicit exit also prove the expected deny or allow remains in place.
adversarial_count=0
run_adversarial_pair() {
  c138c_measure_pair "$@"
  adversarial_count=$((adversarial_count + 1))
}

prefix_quoted="$C138C_TMP/prefix with space/\"quoted\""
prefix_real="$C138C_TMP/prefix-real"
prefix_symlink="$C138C_TMP/prefix symlink with space/\"target\""
env_prefix="$C138C_TMP/env prefix with space/\"quoted\""
mkdir -p "$prefix_quoted" "$prefix_real"
mkdir -p "${prefix_symlink%/*}"
ln -s "$prefix_real" "$prefix_symlink"

run_adversarial_pair unsafe adversarial_prefix_quoted_space_and_quote \
  "npm install -g --prefix '$prefix_quoted' left-pad" 2 plain
run_adversarial_pair unsafe adversarial_prefix_equals_quoted_space_and_quote \
  "npm install -g --prefix='$prefix_quoted' left-pad" 2 plain
run_adversarial_pair unsafe adversarial_prefix_symlink \
  "pnpm add --dir '$prefix_symlink' left-pad" 2 plain
run_adversarial_pair unsafe adversarial_env_assignment_untrusted \
  'FOO=bar npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_env_assignment_quoted_prefix \
  "NPM_CONFIG_PREFIX='$env_prefix' npm install left-pad" parity plain
# feedback_a041edbc: the pinned baseline missed installs behind launcher
# wrappers; the candidate denies them.
run_adversarial_pair unsafe adversarial_env_wrapper_untrusted \
  'env FOO=bar pnpm add left-pad' tightened plain
run_adversarial_pair unsafe adversarial_env_assignment_first_party \
  'FOO=bar npm install -g @indigoai-us/hq-cli@5.109.8' 0 plain
run_adversarial_pair unsafe adversarial_and_chain \
  'npm install left-pad && echo complete' 2 plain
# Use true/false first segments so the text-wrapper fast path does not bypass
# separator parsing before the later install is checked.
run_adversarial_pair unsafe adversarial_later_segment_and \
  'true && npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_semicolon_chain \
  'npm install left-pad; echo complete' 2 plain
run_adversarial_pair unsafe adversarial_later_segment_semicolon \
  'true; npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_leading_semicolon \
  ';npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_or_chain \
  'npm install left-pad || echo complete' 2 plain
run_adversarial_pair unsafe adversarial_later_segment_or \
  'false || npm install left-pad' 2 plain
run_adversarial_pair unsafe adversarial_pipe_chain \
  'npm install left-pad | cat' 2 plain
# feedback_03770784: subshells and command substitutions are now checked.
run_adversarial_pair unsafe adversarial_subshell \
  '( npm install left-pad )' tightened plain
run_adversarial_pair unsafe adversarial_command_substitution \
  'echo "$(npm install left-pad)"' tightened plain
run_adversarial_pair unsafe adversarial_heredoc_literal \
  $'cat <<\'EOF\'\nnpm install left-pad\nEOF' parity plain
run_adversarial_pair unsafe adversarial_symlink_cwd_age_gate \
  'pnpm add left-pad' 0 age-symlink
run_adversarial_pair unsafe adversarial_symlink_cwd_without_age_gate \
  'pnpm add left-pad' 2 plain-symlink

core_target_single_quote="$C138C_TMP/fixture/core/adversarial space/'single'.txt"
core_target_double_quote="$C138C_TMP/fixture/core/adversarial space/\"double\".txt"
core_target="$C138C_TMP/fixture/core/adversarial-target.txt"
outside_target="$C138C_TMP/fixture/outside-target"
mkdir -p "$outside_target"
ln -s "$outside_target" "$C138C_TMP/fixture/core/linked-outside"
ln -s "$C138C_TMP/fixture/core" "$C138C_TMP/fixture/core-via-symlink"
core_linked_outside="$C138C_TMP/fixture/core/linked-outside/file.txt"
core_linked_inside="$C138C_TMP/fixture/core-via-symlink/file.txt"

run_adversarial_pair core adversarial_quoted_space_and_single_quote \
  "touch \"$core_target_single_quote\"" 2 plain
run_adversarial_pair core adversarial_quoted_space_and_double_quote \
  "touch '$core_target_double_quote'" 2 plain
run_adversarial_pair core adversarial_symlink_inside_core_to_outside \
  "touch '$core_linked_outside'" 2 plain
run_adversarial_pair core adversarial_symlink_outside_to_core \
  "touch '$core_linked_inside'" parity plain
run_adversarial_pair core adversarial_env_assignment_prefix \
  "FOO=bar touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_env_wrapper_prefix \
  "env FOO=bar touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_env_empty_environment \
  'env -i rm core/adversarial-target.txt' 2 fixture
run_adversarial_pair core adversarial_and_chain \
  "echo before && touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_semicolon_chain \
  "echo before; touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_or_chain \
  "false || touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_sudo_prefix \
  "sudo touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_command_prefix \
  "command touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_pipe_chain \
  "printf x | tee '$core_target'" 2 plain
run_adversarial_pair core adversarial_subshell \
  "( touch '$core_target' )" parity plain
run_adversarial_pair core adversarial_command_substitution \
  "echo \"\$(touch '$core_target')\"" parity plain
run_adversarial_pair core adversarial_heredoc_literal \
  $'cat <<\'EOF\'\ntouch core/adversarial-target.txt\nEOF' parity plain
run_adversarial_pair core adversarial_heredoc_then_write \
  $'cat <<\'EOF\'\nbody\nEOF\ntouch core/adversarial-target.txt' parity plain
run_adversarial_pair core adversarial_prefix_spaced_value_chain \
  "npm install --prefix '$prefix_quoted' left-pad && touch '$core_target'" 2 plain
run_adversarial_pair core adversarial_prefix_equals_value_chain \
  "npm install --prefix='$prefix_quoted' left-pad; touch '$core_target'" 2 plain

# Replay each declarative YAML hook case too. These are the complete current
# case sets in core/hook-tests for the two guards.
c138c_measure_pair unsafe yaml_blocks_npm_package 'npm install lodash' 2 plain
c138c_measure_pair unsafe yaml_allows_hydration 'npm install' 0 plain
c138c_measure_pair unsafe yaml_allows_npm_ci 'npm ci' 0 plain
c138c_measure_pair core yaml_blocks_agents_redirect 'echo pwned > AGENTS.md' 2 plain
c138c_measure_pair core yaml_blocks_core_redirect 'echo pwned > core/FAILOPEN-PROBE.txt' 2 plain
c138c_measure_pair core yaml_allows_benign 'echo hello world' 0 plain

# The manager-owned c138e cases are parity-only against current main. All
# preceding denial expectations use the pinned pre-optimization baseline.
# Compare only the c138e known-gap cases with the current PR base; keep
# process-budget suites on their pinned c138c baseline.
C138D_BASE_SHA="$(git -C "$ROOT" rev-parse refs/remotes/origin/main)"
timeout 20s git -C "$ROOT" cat-file -e "$C138D_BASE_SHA^{commit}" \
  || { echo "FAIL: current PR base is unavailable: $C138D_BASE_SHA" >&2; exit 1; }
for relative in \
  .claude/hooks/block-unsafe-package-install.sh \
  .claude/hooks/block-core-writes-bash.sh; do
  timeout 20s git -C "$ROOT" show "$C138D_BASE_SHA:$relative" \
    > "$C138C_TMP/source/base/$relative" \
    || { echo "FAIL: current PR base is missing $relative" >&2; exit 1; }
done
timeout 20s git -C "$ROOT" show "$C138D_BASE_SHA:core/scripts/hook-lib.sh" \
  > "$C138C_TMP/fixture/core/scripts/hook-lib.sh" \
  || { echo 'FAIL: current PR base is missing core/scripts/hook-lib.sh' >&2; exit 1; }
timeout 20s git -C "$ROOT" show "$C138D_BASE_SHA:core/scripts/install-deps.allow" \
  > "$C138C_TMP/fixture/core/scripts/install-deps.allow" \
  || { echo 'FAIL: current PR base is missing core/scripts/install-deps.allow' >&2; exit 1; }

# Manager-owned c138e gap: preserve and record current-main parity for these
# env-unset forms. They intentionally carry no base-deny expectation here.
run_adversarial_pair core KNOWN_GAP_c138e_env_u_FOO \
  'env -u FOO rm core/adversarial-target.txt' parity fixture
run_adversarial_pair core KNOWN_GAP_c138e_env_assignment_then_u_BAR \
  'env FOO=1 -u BAR rm core/adversarial-target.txt' parity fixture

printf 'block-guard-hooks-parity: PASS (%s existing hook invocations, %s adversarial cases, and six YAML cases)\n' \
  "$fixture_count" "$adversarial_count"
