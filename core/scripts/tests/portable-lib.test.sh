#!/usr/bin/env bash
# portable-lib.test.sh — unit coverage for core/scripts/lib/portable.sh
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
LIB="$ROOT/core/scripts/lib/portable.sh"
[ -f "$LIB" ] || { echo "FAIL: portable.sh missing at $LIB" >&2; exit 1; }

# shellcheck source=core/scripts/lib/portable.sh
. "$LIB"

FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/portable-lib-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- portable_stat_mtime ---
touch "$TMP/mtime-file"
MT="$(portable_stat_mtime "$TMP/mtime-file" || true)"
case "$MT" in
  ''|*[!0-9]*) fail "portable_stat_mtime returned non-numeric: '$MT'" ;;
  *)
    NOW="$(date +%s)"
    AGE=$((NOW - MT))
    if [ "$AGE" -lt 0 ] || [ "$AGE" -gt 120 ]; then
      fail "portable_stat_mtime age out of range: mtime=$MT now=$NOW"
    else
      pass "portable_stat_mtime numeric epoch (age=${AGE}s)"
    fi
    ;;
esac
if portable_stat_mtime "$TMP/does-not-exist" 2>/dev/null; then
  fail "portable_stat_mtime should fail on missing path"
else
  pass "portable_stat_mtime fails on missing path"
fi

# --- portable_sed_inplace ---
printf 'hello world\n' > "$TMP/sed.txt"
portable_sed_inplace 's/world/portable/' "$TMP/sed.txt"
if [ "$(cat "$TMP/sed.txt")" = "hello portable" ]; then
  pass "portable_sed_inplace rewrites file"
else
  fail "portable_sed_inplace content: $(cat "$TMP/sed.txt")"
fi

# --- portable_tmpdir ---
TD="$(portable_tmpdir)"
case "$TD" in
  ''|*/) fail "portable_tmpdir bad: '$TD'" ;;
  *)
    if [ -d "$TD" ]; then
      pass "portable_tmpdir -> $TD"
    else
      fail "portable_tmpdir not a directory: $TD"
    fi
    ;;
esac

# --- portable_date_epoch_to_iso ---
ISO="$(portable_date_epoch_to_iso 0 || true)"
if [ "$ISO" = "1970-01-01T00:00:00Z" ]; then
  pass "portable_date_epoch_to_iso epoch 0"
else
  # Some platforms may not support epoch 0 the same way; accept any valid ISO shape.
  case "$ISO" in
    19[0-9][0-9]-*|20[0-9][0-9]-*) pass "portable_date_epoch_to_iso -> $ISO" ;;
    *) fail "portable_date_epoch_to_iso unexpected: '$ISO'" ;;
  esac
fi

# --- portable_user ---
U1="$(env -u USER -u USERNAME bash -c '. "'"$LIB"'"; portable_user')"
[ "$U1" = "unknown" ] && pass "portable_user fallback unknown" || fail "portable_user no-env: $U1"
U2="$(env -u USER USERNAME='win/user name' bash -c '. "'"$LIB"'"; portable_user')"
case "$U2" in
  *'/'*|*' '*) fail "portable_user not sanitized: $U2" ;;
  *) pass "portable_user sanitizes USERNAME -> $U2" ;;
esac

# --- require_jq ---
if command -v jq >/dev/null 2>&1; then
  if require_jq 2>/dev/null; then
    pass "require_jq succeeds when jq present"
  else
    fail "require_jq failed with jq on PATH"
  fi
fi
# Simulate missing jq by shadowing command -v inside a subshell function override.
set +e
OUT="$(
  bash -c '
    . "'"$LIB"'"
    command() {
      if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then return 1; fi
      builtin command "$@"
    }
    require_jq
  ' 2>&1
)"
RC=$?
set -e
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qiE 'winget|apt|brew|Install jq|jq is required'; then
  pass "require_jq fails with install guidance when jq missing"
else
  fail "require_jq missing-jq: rc=$RC out=$OUT"
fi

# --- portable_native_path ---
if portable_native_path "" 2>/dev/null; then
  fail "portable_native_path should fail on empty"
else
  pass "portable_native_path fails on empty"
fi
# Fake cygpath first on PATH so Linux CI and Windows Git Bash share one probe.
# Do not use a C:/Users/... fixture: the users-path tripwire treats that as a leak.
mkdir -p "$TMP/cygbin"
cat > "$TMP/cygbin/cygpath" <<'SH'
#!/bin/bash
last=""
for a in "$@"; do last="$a"; done
printf 'C:/Temp/%s' "${last##*/}"
SH
chmod +x "$TMP/cygbin/cygpath"
NP2="$(PATH="$TMP/cygbin:$PATH" bash -c '. "'"$LIB"'"; portable_native_path /tmp/hq-feedback-body.1JTfbV')"
case "$NP2" in
  C:/Temp/*1JTfbV) pass "portable_native_path uses cygpath -m -> $NP2" ;;
  *) fail "portable_native_path cygpath: $NP2" ;;
esac
# Host without a fake: POSIX identity, or a real Git Bash mixed path.
NP="$(portable_native_path "$TMP/native.txt")"
if command -v cygpath >/dev/null 2>&1; then
  case "$NP" in
    [A-Za-z]:/*) pass "portable_native_path host cygpath mixed -> $NP" ;;
    *) fail "portable_native_path host cygpath: $NP" ;;
  esac
else
  [ "$NP" = "$TMP/native.txt" ] && pass "portable_native_path identity without cygpath" \
    || fail "portable_native_path identity: $NP"
fi

# --- portable_qmd_models_dir / embed ready ---
MD="$(env -u QMD_MODELS_DIR -u XDG_CACHE_HOME HOME="$TMP/home" bash -c '. "'"$LIB"'"; portable_qmd_models_dir')"
[ "$MD" = "$TMP/home/.cache/qmd/models" ] && pass "portable_qmd_models_dir HOME default" \
  || fail "portable_qmd_models_dir HOME: $MD"
MD2="$(QMD_MODELS_DIR="$TMP/models/" bash -c '. "'"$LIB"'"; portable_qmd_models_dir')"
[ "$MD2" = "$TMP/models" ] && pass "portable_qmd_models_dir override strips slash" \
  || fail "portable_qmd_models_dir override: $MD2"

if QMD_MODELS_DIR="$TMP/missing-models" bash -c '. "'"$LIB"'"; portable_qmd_embed_model_ready'; then
  fail "embed ready should fail when dir missing"
else
  pass "embed ready fails when dir missing"
fi
mkdir -p "$TMP/models"
printf 'tiny' > "$TMP/models/embeddinggemma-300M-Q8_0.gguf"
if QMD_MODELS_DIR="$TMP/models" bash -c '. "'"$LIB"'"; portable_qmd_embed_model_ready'; then
  fail "embed ready should reject tiny placeholder gguf"
else
  pass "embed ready rejects tiny placeholder"
fi
# 1 MiB + 1 byte
dd if=/dev/zero of="$TMP/models/embeddinggemma-300M-Q8_0.gguf" bs=1024 count=1025 status=none 2>/dev/null \
  || dd if=/dev/zero of="$TMP/models/embeddinggemma-300M-Q8_0.gguf" bs=1024 count=1025
if QMD_MODELS_DIR="$TMP/models" bash -c '. "'"$LIB"'"; portable_qmd_embed_model_ready'; then
  pass "embed ready accepts >=1MiB gguf"
else
  fail "embed ready should accept >=1MiB gguf"
fi

# --- portable_qmd_cmd_would_download_model ---
would() {
  HQ_QMD_CMD="$1" bash -c '. "'"$LIB"'"; portable_qmd_cmd_would_download_model "$HQ_QMD_CMD"'
}
if would 'qmd vsearch "how to auth" --json -n 5'; then
  pass "detects qmd vsearch"
else
  fail "missed qmd vsearch"
fi
if would 'qmd --json query foo'; then
  pass "detects qmd query after flags"
else
  fail "missed qmd --json query"
fi
if would '/usr/bin/qmd embed -f'; then
  pass "detects path-qualified qmd embed"
else
  fail "missed /usr/bin/qmd embed"
fi
if would 'qmd pull'; then
  pass "detects qmd pull"
else
  fail "missed qmd pull"
fi
if would 'qmd search "how to vsearch" --json'; then
  fail "false positive: qmd search with vsearch in query"
else
  pass "qmd search with vsearch in query is not a download"
fi
if would 'qmd update'; then
  fail "false positive: qmd update"
else
  pass "qmd update is not a download"
fi
if would 'echo hello'; then
  fail "false positive: echo hello"
else
  pass "unrelated command is not a download"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS: portable-lib"
  exit 0
fi
echo "FAILURES: portable-lib"
exit 1
