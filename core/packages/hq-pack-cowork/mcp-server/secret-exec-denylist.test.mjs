import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const SERVER_DIR = dirname(fileURLToPath(import.meta.url));
const SERVER_ENTRY = join(SERVER_DIR, "index.mjs");
const WINDOWS_DANGEROUS_COMMANDS = [
  "cmd.exe",
  "CMD.EXE",
  "C:\\Windows\\System32\\cmd.exe",
  "powershell.exe",
  "pwsh",
  "pwsh.exe",
  "wsl.exe",
  "cscript.exe",
  "wscript.exe",
  "certutil.exe",
  "mshta.exe",
  "bash.exe",
  "bash.cmd",
  "bash.vbs",
  "C:\\scripts\\pwsh.bat",
];

function hostCallCount(callLogPath) {
  if (!existsSync(callLogPath)) return 0;
  return readFileSync(callLogPath, "utf8").split("\n").filter(Boolean).length;
}

async function startMcpServer({ windows = false } = {}) {
  const tempRoot = mkdtempSync(join(tmpdir(), "hq-us102-mcp-"));
  const runnerPath = join(tempRoot, "hq");
  const callLogPath = join(tempRoot, "host-calls.log");
  const windowsPreloadPath = join(tempRoot, "force-windows.cjs");
  writeFileSync(
    runnerPath,
    "#!/usr/bin/env node\n" +
      "require('node:fs').appendFileSync(process.env.US102_CALL_LOG, 'called\\n');\n" +
      "process.stdout.write('stub hq result');\n",
    { mode: 0o700 },
  );
  chmodSync(runnerPath, 0o700);
  writeFileSync(
    windowsPreloadPath,
    "Object.defineProperty(process, 'platform', { configurable: true, value: 'win32' });\n",
    { mode: 0o600 },
  );

  const child = spawn(
    process.execPath,
    windows ? ["--require", windowsPreloadPath, SERVER_ENTRY] : [SERVER_ENTRY],
    {
      cwd: tempRoot,
      env: {
        HOME: tempRoot,
        HQ_ROOT: tempRoot,
        HQ_BIN: runnerPath,
        PATH: process.env.PATH || "/usr/bin:/bin",
        PATHEXT: ".COM;.EXE;.BAT;.CMD;.VBS",
        TMPDIR: tempRoot,
        US102_CALL_LOG: callLogPath,
        US102_SYNTHETIC_SECRET: "synthetic-test-value-only",
      },
      stdio: ["pipe", "pipe", "pipe"],
    },
  );

  let outputBuffer = "";
  let errorOutput = "";
  let nextId = 1;
  const pending = new Map();
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    outputBuffer += chunk;
    let newline;
    while ((newline = outputBuffer.indexOf("\n")) !== -1) {
      const line = outputBuffer.slice(0, newline);
      outputBuffer = outputBuffer.slice(newline + 1);
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        for (const waiter of pending.values()) {
          clearTimeout(waiter.timeout);
          waiter.reject(new Error(`MCP emitted invalid JSON: ${error.message}`));
        }
        pending.clear();
        continue;
      }
      const waiter = pending.get(message.id);
      if (!waiter) continue;
      clearTimeout(waiter.timeout);
      pending.delete(message.id);
      waiter.resolve(message);
    }
  });
  child.stderr.on("data", (chunk) => {
    errorOutput += chunk;
  });
  child.on("exit", (code, signal) => {
    for (const waiter of pending.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error(`MCP server exited (${code ?? signal}): ${errorOutput}`));
    }
    pending.clear();
  });

  const request = (method, params) => {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Timed out waiting for MCP ${method}: ${errorOutput}`));
      }, 5000);
      pending.set(id, { resolve, reject, timeout });
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  };

  try {
    await request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "us102-regression-test", version: "1.0.0" },
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
  } catch (error) {
    child.kill("SIGTERM");
    rmSync(tempRoot, { recursive: true, force: true });
    throw error;
  }

  return {
    callLogPath,
    callTool: (name, args) => request("tools/call", { name, arguments: args }),
    hostCallCount: () => hostCallCount(callLogPath),
    async close() {
      if (child.exitCode === null && child.signalCode === null) {
        const exited = new Promise((resolve) => child.once("exit", resolve));
        child.kill("SIGTERM");
        await exited;
      }
      rmSync(tempRoot, { recursive: true, force: true });
    },
  };
}

function toolArguments(name, command) {
  if (name === "hq_secrets_exec") {
    return { keys: ["US102_SYNTHETIC_SECRET"], cmd: [command, "-c", "echo synthetic"] };
  }
  return { cmd: [command, "-c", "echo synthetic"] };
}

for (const toolName of ["hq_secrets_exec", "hq_run"]) {
  test(`${toolName} refuses mshta.exe before invoking hq`, async () => {
    const server = await startMcpServer({ windows: true });
    try {
      const response = await server.callTool(toolName, toolArguments(toolName, "mshta.exe"));
      assert.equal(server.hostCallCount(), 0, `${toolName} invoked the host runner for mshta.exe`);
      assert.equal(response.result?.isError, true, `${toolName} accepted mshta.exe`);
      assert.match(response.result.content?.[0]?.text || "", /refuses to run/);
    } finally {
      await server.close();
    }
  });
}

for (const toolName of ["hq_secrets_exec", "hq_run"]) {
  test(`${toolName} refuses Windows shells and value-printers before invoking hq`, async () => {
    const server = await startMcpServer({ windows: true });
    try {
      for (const command of WINDOWS_DANGEROUS_COMMANDS) {
        const previousCalls = server.hostCallCount();
        const response = await server.callTool(toolName, toolArguments(toolName, command));
        assert.equal(
          server.hostCallCount(),
          previousCalls,
          `${toolName} invoked the host runner for ${command}`,
        );
        assert.equal(
          response.result?.isError,
          true,
          `${toolName} accepted the Windows command ${command}`,
        );
        assert.match(response.result.content?.[0]?.text || "", /refuses to run/);
      }
    } finally {
      await server.close();
    }
  });
}

test("Unix command behavior still allows a consumer and refuses a shell", async () => {
  const server = await startMcpServer();
  try {
    const allowed = await server.callTool(
      "hq_secrets_exec",
      toolArguments("hq_secrets_exec", "git"),
    );
    assert.equal(allowed.result?.isError, undefined);
    assert.equal(server.hostCallCount(), 1, "allowed Unix consumer reached the host runner");

    const refused = await server.callTool(
      "hq_secrets_exec",
      toolArguments("hq_secrets_exec", "bash"),
    );
    assert.equal(refused.result?.isError, true);
    assert.equal(server.hostCallCount(), 1, "denied Unix shell did not reach the host runner");
  } finally {
    await server.close();
  }
});


test("plugin manifests identify the guarded security version", () => {
  const plugin = JSON.parse(
    readFileSync(join(SERVER_DIR, "..", ".claude-plugin", "plugin.json"), "utf8"),
  );
  const marketplace = JSON.parse(
    readFileSync(join(SERVER_DIR, "..", ".claude-plugin", "marketplace.json"), "utf8"),
  );
  assert.equal(plugin.version, "0.1.1");
  assert.equal(
    marketplace.plugins.find((entry) => entry.name === "hq-cowork")?.version,
    "0.1.1",
  );
});
