#!/bin/bash
# hook-lib.sh — shared, python-free primitives for HQ hooks and scripts.
#
# SOURCED, never executed:  . "$HELPERS/hook-lib.sh"
# bash 3.2 safe; no heredocs nested inside $( ) (hooks-heredoc-syntax lint).
#
# HQ hooks must run on machines WITHOUT python3 — including Windows, where the
# Store alias stub resolves on PATH but cannot execute anything (so a bare
# `command -v python3` is not a usable capability probe). These primitives
# replace every inline `python3 -c` snippet the hooks used to carry.
#
# Engine order (locked 2026-07-15, Shahzaib):
#   - Hot-path primitives (hq_json_get / hq_json_encode / hq_normpath):
#     jq FIRST — jq ships with the HQ toolchain, is already a hard requirement
#     of the policy-trigger pipeline, and spawns fastest — then node (HQ is
#     npm-installed, so node exists on every HQ machine), else degrade to ""
#     so callers keep their existing fail-open behavior.
#   - Complex analyzers stay in their own hooks but follow node-first with an
#     awk fallback (see validate-policy-frontmatter.sh).
#
# Test override: HQ_HOOK_ENGINE=jq|node forces a single engine so parity
# suites can drive both implementations over the same payloads.

HQ_LIB_JQ="$(command -v jq 2>/dev/null || true)"
HQ_LIB_NODE="$(command -v node 2>/dev/null || true)"
case "${HQ_HOOK_ENGINE:-}" in
  jq)   HQ_LIB_NODE="" ;;
  node) HQ_LIB_JQ="" ;;
esac

# hq_json_get <dotted.key.path>
#   stdin: JSON document. stdout: the addressed value, or "" when the path is
#   missing, null, or resolves to an object/array. Numeric path segments index
#   arrays ("tool_input.edits.0.old_string").
hq_json_get() {
  if [ -n "$HQ_LIB_JQ" ]; then
    "$HQ_LIB_JQ" -r --arg p "$1" '
      try (getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end))
        | if . == null or type == "object" or type == "array" then "" else tostring end)
      catch ""' 2>/dev/null || echo ""
    return 0
  fi
  if [ -n "$HQ_LIB_NODE" ]; then
    "$HQ_LIB_NODE" -e '
      let d = "";
      process.stdin.on("data", c => d += c).on("end", () => {
        let v;
        try { v = JSON.parse(d); } catch (e) { console.log(""); return; }
        for (const k of process.argv[1].split(".")) {
          if (v && typeof v === "object") v = Array.isArray(v) ? v[Number(k)] : v[k];
          else { v = undefined; break; }
        }
        if (v === undefined || v === null || typeof v === "object") console.log("");
        else console.log(String(v));
      });' "$1" 2>/dev/null || echo ""
    return 0
  fi
  cat >/dev/null 2>&1 || true
  echo ""
}

# hq_json_encode
#   stdin: raw string. stdout: the string as a JSON literal (quoted, escaped).
hq_json_encode() {
  if [ -n "$HQ_LIB_JQ" ]; then
    "$HQ_LIB_JQ" -Rs . 2>/dev/null || echo '""'
    return 0
  fi
  if [ -n "$HQ_LIB_NODE" ]; then
    "$HQ_LIB_NODE" -e '
      let d = "";
      process.stdin.on("data", c => d += c).on("end", () => console.log(JSON.stringify(d)));' \
      2>/dev/null || echo '""'
    return 0
  fi
  cat >/dev/null 2>&1 || true
  echo '""'
}

# hq_normpath <path>
#   Lexical normalization (no filesystem access): backslashes -> "/", collapse
#   "//" and "/./", resolve "x/..", trim trailing "/" (keeps root). Both
#   engines produce IDENTICAL output, so equality checks between two
#   hq_normpath results are stable regardless of engine or platform.
hq_normpath() {
  printf '%s' "$1" | awk '
    {
      p = $0
      gsub(/\\/, "/", p)
      isabs = (p ~ /^\//) ? 1 : 0
      drive = ""
      if (p ~ /^[A-Za-z]:/) { drive = substr(p, 1, 2); p = substr(p, 3); isabs = (p ~ /^\//) ? 1 : 0 }
      n = split(p, seg, "/")
      out_n = 0
      for (i = 1; i <= n; i++) {
        s = seg[i]
        if (s == "" || s == ".") continue
        if (s == "..") {
          if (out_n > 0 && out[out_n] != "..") { out_n--; continue }
          if (isabs) continue
          out[++out_n] = ".."
        } else out[++out_n] = s
      }
      r = ""
      for (i = 1; i <= out_n; i++) r = r (i > 1 ? "/" : "") out[i]
      if (isabs) r = "/" r
      if (drive != "") r = drive r
      if (r == "") r = (isabs ? "/" : ".")
      print r
    }'
}
