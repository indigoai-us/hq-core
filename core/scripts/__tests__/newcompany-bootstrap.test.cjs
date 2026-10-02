const assert = require("node:assert/strict");
const path = require("node:path");
const test = require("node:test");
const { FLAG_KEY, runCli } = require("../newcompany-bootstrap.cjs");

const input = {
  slug: "acme",
  companyName: "Acme Corp",
  destination: ["/tmp/hq-root", "companies", "acme"].join("/"),
  hqRoot: "/tmp/hq-root",
};
const renderer = path.join(__dirname, "..", "render-company-starter-files.mjs");
const hqCliBin = "/tmp/fake-hq";
const cloudPrefix = ["companies", input.slug, ""].join("/");
const rendererFromRoot = path.relative(input.hqRoot, renderer).split(path.sep).join("/");

test("flag off uses only the exact legacy renderer argv", async () => {
  const commands = [];
  let stdout = "";
  const stderr = "";
  const exitCode = await runCli([input.slug, input.companyName, input.destination, input.hqRoot], {
    readFlag: async (key) => {
      assert.equal(key, FLAG_KEY);
      return false;
    },
    env: { HQ_CLI_BIN: hqCliBin },
    run: (command, args, cwd) => commands.push({ command, args, cwd }),
    writeStdout: (text) => { stdout += text; },
    writeStderr: (text) => { stderr += text; },
  });

  assert.equal(exitCode, 0);
  assert.equal(stdout, "newcompany mode: newcompany\n");
  assert.equal(stderr, "");
  assert.deepEqual(commands, [{
    command: process.execPath,
    args: [renderer, input.slug, input.companyName, input.destination, "--mode", "newcompany"],
    cwd: input.hqRoot,
  }]);
});

test("flag on uses the exact cloud-first argv sequence", async () => {
  const commands = [];
  let stdout = "";
  let stderr = "";
  const env = { HQ_CLI_BIN: hqCliBin };
  let flagArgs;
  const exitCode = await runCli([input.slug, input.companyName, input.destination, input.hqRoot], {
    readFlag: async (...args) => {
      flagArgs = args;
      return true;
    },
    env,
    run: (command, args, cwd) => commands.push({ command, args, cwd }),
    writeStdout: (text) => { stdout += text; },
    writeStderr: (text) => { stderr += text; },
  });

  assert.equal(exitCode, 0);
  assert.deepEqual(flagArgs, [FLAG_KEY, env, "HQ newcompany cloud-first", { timeoutMs: 5000 }]);
  assert.equal(stdout, "newcompany mode: cloud-first\n");
  assert.equal(stderr, "");
  assert.deepEqual(commands, [
    {
      command: hqCliBin,
      args: [
        "onboard", "create-company", "--slug", input.slug,
        "--name", input.companyName, "--hq-root", input.hqRoot,
      ],
      cwd: input.hqRoot,
    },
    {
      command: hqCliBin,
      args: ["files", "get", cloudPrefix, "--hq-root", input.hqRoot],
      cwd: input.hqRoot,
    },
    {
      command: process.execPath,
      args: [renderer, input.slug, input.companyName, input.destination, "--mode", "newcompany-cloud-first"],
      cwd: input.hqRoot,
    },
  ]);
});

test("files-get failure prints a precise resume command and forbids rerunning newcompany", async () => {
  const commands = [];
  let stdout = "";
  let stderr = "";
  const exitCode = await runCli([input.slug, input.companyName, input.destination, input.hqRoot], {
      readFlag: async () => true,
      env: { HQ_CLI_BIN: hqCliBin },
      run: (command, args) => {
        commands.push({ command, args });
        if (args[0] === "files") throw new Error("download failed");
      },
      writeStdout: (text) => { stdout += text; },
      writeStderr: (text) => { stderr += text; },
    });

  assert.equal(exitCode, 1);
  assert.equal(stdout, "");
  assert.equal(stderr,
      `newcompany bootstrap failed: The cloud company "${input.slug}" already exists. Do not rerun /newcompany. ` +
      `Resume by running: '${hqCliBin}' files get '${cloudPrefix}' --hq-root '${input.hqRoot}'. ` +
      `Then finish rendering from the HQ root with: node '${rendererFromRoot}' '${input.slug}' ` +
      `'${input.companyName}' '${input.destination}' --mode newcompany-cloud-first\n`,
  );
  assert.deepEqual(commands, [
    {
      command: hqCliBin,
      args: [
        "onboard", "create-company", "--slug", input.slug,
        "--name", input.companyName, "--hq-root", input.hqRoot,
      ],
    },
    {
      command: hqCliBin,
      args: ["files", "get", cloudPrefix, "--hq-root", input.hqRoot],
    },
  ]);
});
