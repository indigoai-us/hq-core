#!/usr/bin/env node
"use strict";

const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { readHqFlag } = require("./setup-path-flag.cjs");

const FLAG_KEY = "core.setup.newcompany-cloud-first";
const RENDERER = path.join(__dirname, "render-company-starter-files.mjs");

function run(command, args, cwd, dependencies = {}) {
  const result = (dependencies.spawnSync ?? spawnSync)(command, args, {
    cwd,
    encoding: "utf8",
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} exited with ${result.status ?? "no status"}`);
  }
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

async function bootstrapNewcompany(input, dependencies = {}) {
  const root = path.resolve(input.hqRoot);
  const env = dependencies.env ?? process.env;
  const flagReader = dependencies.readFlag ?? readHqFlag;
  const enabled = await flagReader(FLAG_KEY, env, "HQ newcompany cloud-first", { timeoutMs: 5000 });
  const execute = dependencies.run ?? run;
  const hqCliBin = env.HQ_CLI_BIN || "hq";
  const renderArgs = [RENDERER, input.slug, input.companyName, input.destination];

  if (enabled === true) {
    execute(hqCliBin, [
      "onboard", "create-company", "--slug", input.slug,
      "--name", input.companyName, "--hq-root", root,
    ], root);
    const cloudPrefix = ["companies", input.slug, ""].join("/");
    const filesGetArgs = ["files", "get", cloudPrefix, "--hq-root", root];
    try {
      execute(hqCliBin, filesGetArgs, root);
    } catch (error) {
      const resumeCommand = `${shellQuote(hqCliBin)} files get ${shellQuote(cloudPrefix)} --hq-root ${shellQuote(root)}`;
      const rendererScript = path.relative(root, RENDERER).split(path.sep).join("/");
      const renderCommand = `node ${shellQuote(rendererScript)} ${shellQuote(input.slug)} ${shellQuote(input.companyName)} ${shellQuote(input.destination)} --mode newcompany-cloud-first`;
      throw new Error(
        `The cloud company "${input.slug}" already exists. Do not rerun /newcompany. Resume by running: ${resumeCommand}. ` +
          `Then finish rendering from the HQ root with: ${renderCommand}`,
        { cause: error },
      );
    }
    execute(process.execPath, [...renderArgs, "--mode", "newcompany-cloud-first"], root);
    return { cloudFirst: true };
  }

  execute(process.execPath, [...renderArgs, "--mode", "newcompany"], root);
  return { cloudFirst: false };
}

async function runCli(argv, dependencies = {}) {
  const [slug, companyName, destination, hqRoot = process.cwd()] = argv;
  const writeStdout = dependencies.writeStdout ?? ((text) => process.stdout.write(text));
  const writeStderr = dependencies.writeStderr ?? ((text) => process.stderr.write(text));
  if (!slug || !companyName || !destination) {
    writeStderr("Usage: node core/scripts/newcompany-bootstrap.cjs <slug> <display-name> <destination> [hq-root]\n");
    return 2;
  }

  try {
    const { cloudFirst } = await bootstrapNewcompany({ slug, companyName, destination, hqRoot }, dependencies);
    writeStdout(`newcompany mode: ${cloudFirst ? "cloud-first" : "newcompany"}\n`);
    return 0;
  } catch (error) {
    writeStderr(`newcompany bootstrap failed: ${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

if (require.main === module) {
  runCli(process.argv.slice(2)).then((exitCode) => {
    process.exitCode = exitCode;
  });
}

module.exports = { FLAG_KEY, bootstrapNewcompany, runCli };
