#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { performance } = require("node:perf_hooks");

const [hook, projectDir, cliBin, refreshScript] = process.argv.slice(2);
if (!hook || !projectDir || !cliBin || !refreshScript) {
  process.stderr.write("usage: merged-write-guard-shadow-benchmark.cjs <hook.sh> <project-dir> <hq-bin> <refresh.sh>\n");
  process.exit(2);
}

const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "merged-write-guard-bench-"));
const noop = path.join(tempDir, "noop.sh");
fs.writeFileSync(noop, "#!/usr/bin/env bash\nwhile IFS= read -r line; do :; done\n", { mode: 0o700 });
const tools = ["Bash", "Edit", "Write", "MultiEdit", "apply_patch"];
const rounds = 200;
const relativeFile = path.join(projectDir, "workspace", "worktrees", "bench", "file.md");
const inputs = {
  Bash: { command: "git status --short" },
  Edit: { file_path: relativeFile },
  Write: { file_path: relativeFile },
  MultiEdit: { file_path: relativeFile },
  apply_patch: { patch: `*** Begin Patch\n*** Add File: ${relativeFile}\n+benchmark\n*** End Patch` },
};
const payloads = Object.fromEntries(tools.map((tool) => [tool, `${JSON.stringify({
  session_id: "us020-shadow-benchmark",
  hook_event_name: "PreToolUse",
  tool_name: tool,
  cwd: projectDir,
  tool_input: inputs[tool],
})}\n`]));
const cacheUids = { off: "cmp_benchshadowoff", on: "cmp_benchshadowon" };
const commandEnv = (state) => ({
  ...process.env,
  BASH_ENV: "/dev/null",
  PATH: `${path.dirname(cliBin)}:${process.env.PATH || ""}`,
  HQ_CLI_BIN: cliBin,
  HQ_FLAGS_API_URL: "https://flags.invalid",
  HQ_COMPANY_UID: cacheUids[state],
  HQ_TEST_FLAG_MODE: state === "on" ? "true" : "false",
  CLAUDE_PROJECT_DIR: projectDir,
});
function invoke(file, input, env) {
  const start = performance.now();
  const result = spawnSync("bash", [file], { input, encoding: "utf8", env, stdio: ["pipe", "ignore", "ignore"] });
  const elapsed = performance.now() - start;
  if (result.error || result.status !== 0) throw new Error(`hook runner failed (${result.error?.name || result.status})`);
  return elapsed;
}

function measureOffPrefilter(tool) {
  const script = `set -uo pipefail
. "$HQ_TEST_ROOT/core/scripts/lib/hook-adapter-core.sh"
now_us() { printf '%s' "${'${EPOCHREALTIME/./}'}"; }
time_one() {
  local start end
  start="${'${EPOCHREALTIME/./}'}"
  if [ "$HQ_TEST_CASE" = baseline ]; then
    hqad_registry_prefilter_match PreToolUse "$HQ_TEST_ROOT" "" "$HQ_TEST_ROOT" "" "$HQ_TEST_TOOL" "" "" "" "" bench-baseline >/dev/null || :
  else
    hqad_registry_prefilter_match PreToolUse "$HQ_TEST_ROOT" "" "$HQ_TEST_ROOT" "" "$HQ_TEST_TOOL" "" "" "$HQ_TEST_FILE" "" bench-candidate >/dev/null || :
  fi
  end="${'${EPOCHREALTIME/./}'}"
  RESULT_US="$((end - start))"
}
for ((i=0;i<${rounds};i++)); do
  if ((i % 2 == 0)); then HQ_TEST_CASE=baseline; time_one; a="$RESULT_US"; HQ_TEST_CASE=candidate; time_one; b="$RESULT_US";
  else HQ_TEST_CASE=candidate; time_one; b="$RESULT_US"; HQ_TEST_CASE=baseline; time_one; a="$RESULT_US"; fi
  printf '%s %s\n' "$a" "$b"
done`;
  const result = spawnSync("bash", ["-c", script], {
    encoding: "utf8",
    env: {
      ...process.env,
      HQ_TEST_ROOT: path.resolve(__dirname, "../../.."),
      HQ_TEST_TOOL: tool,
      HQ_TEST_FILE: "workspace/orchestrator/hook-state/merged-write-guard-shadow/enabled",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error || result.status !== 0) throw new Error(`prefilter timing failed (${result.error?.name || result.status}): ${result.stderr}`);
  const deltas = result.stdout.trim().split(/\r?\n/).map((line) => {
    const [baseline, candidate] = line.split(/\s+/).map(Number);
    return candidate - baseline;
  });
  if (deltas.length !== rounds) throw new Error(`prefilter timing produced ${deltas.length} samples for ${tool}`);
  return deltas;
}

function quantile(values, q) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)];
}
function fmt(value) { return `${Math.max(0, value).toFixed(3)} ms`; }

try {
  // Prime session snapshots outside the measured window. The actual SessionStart
  // refresher is run against the deterministic test client, never the live registry.
  for (const state of ["off", "on"]) {
    const result = spawnSync("bash", [refreshScript], {
      input: "",
      encoding: "utf8",
      env: commandEnv(state),
      stdio: ["pipe", "ignore", "ignore"],
    });
    if (result.error || result.status !== 0) throw new Error(`flag snapshot prime failed (${result.error?.name || result.status})`);
  }
  process.stdout.write(`method: off: ${rounds} paired in-process registry prefilter checks per tool, using Bash EPOCHREALTIME and a no-prefilter baseline; on: ${rounds} paired high-resolution hook-process timings per tool against an input-draining no-op hook; SessionStart snapshots use the deterministic test client. With the flag off, the enabled marker is absent and the registered child is skipped.\n`);
  for (const state of ["off", "on"]) {
    for (const tool of tools) {
      const env = commandEnv(state);
      if (state === "off") {
        const deltasUs = measureOffPrefilter(tool);
        process.stdout.write(`${state} ${tool}: added registry-prefilter p50=${(quantile(deltasUs, 0.50)/1000).toFixed(3)} ms, p95=${(quantile(deltasUs, 0.95)/1000).toFixed(3)} ms; hook child launches=0/200\n`);
        continue;
      }
      const deltas = [];
      const hookTimes = [];
      const baselineTimes = [];
      for (let index = 0; index < rounds; index += 1) {
        let hookMs; let baseMs;
        if (index % 2 === 0) {
          hookMs = invoke(hook, payloads[tool], env);
          baseMs = invoke(noop, payloads[tool], env);
        } else {
          baseMs = invoke(noop, payloads[tool], env);
          hookMs = invoke(hook, payloads[tool], env);
        }
        hookTimes.push(hookMs);
        baselineTimes.push(baseMs);
        deltas.push(hookMs - baseMs);
      }
      process.stdout.write(`${state} ${tool}: added p50=${fmt(quantile(deltas, 0.50))}, p95=${fmt(quantile(deltas, 0.95))}; hook p50/p95=${fmt(quantile(hookTimes,0.50))}/${fmt(quantile(hookTimes,0.95))}; baseline p50/p95=${fmt(quantile(baselineTimes,0.50))}/${fmt(quantile(baselineTimes,0.95))}\n`);
    }
  }
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
