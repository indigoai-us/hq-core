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

const fs = require("node:fs");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

const REPO_ROOT = path.join(__dirname, "..", "..", "..");
const EXPECTED_LOCAL_TREE = [
  "README.md",
  "board.json",
  "company.yaml",
  "data/.gitkeep",
  "knowledge/README.md",
  "knowledge/design-styles/packs/.gitkeep",
  "people/.gitkeep",
  "policies/.gitkeep",
  "projects/.gitkeep",
  "repos/.gitkeep",
  "settings/.gitkeep",
  "settings/auto-share.yaml",
  "settings/communication/preferences.yaml",
  "settings/knowledge/preferences.yaml",
  "skills/.gitkeep",
  "workers/.gitkeep",
  "workspace/.gitignore",
  "workspace/index.jsonl",
  "workspace/sessions/.gitkeep",
];

function filesUnder(directory, relative = "") {
  return fs.readdirSync(path.join(directory, relative), { withFileTypes: true })
    .flatMap((entry) => {
      const name = path.posix.join(relative, entry.name);
      return entry.isDirectory() ? filesUnder(directory, name) : [name];
    })
    .sort();
}

// Builds a throwaway HQ root holding only core/scripts and a fresh copy of the
// committed company template, then runs the copied bootstrap against it.
function temporaryHqRoot(t, removeFromTemplate = []) {
  const hqRoot = fs.mkdtempSync(path.join(os.tmpdir(), "newcompany-bootstrap-"));
  t.after(() => fs.rmSync(hqRoot, { recursive: true, force: true }));
  fs.cpSync(path.join(REPO_ROOT, "core", "scripts"), path.join(hqRoot, "core", "scripts"), { recursive: true });
  const template = path.join(hqRoot, "companies", "_template");
  fs.cpSync(path.join(REPO_ROOT, "companies", "_template"), template, { recursive: true, verbatimSymlinks: true });
  for (const relative of removeFromTemplate) {
    fs.rmSync(path.join(template, ...relative.split("/")), { recursive: true, force: true });
  }
  return hqRoot;
}

async function bootstrapInto(hqRoot, extraDependencies = {}) {
  const { runCli: copiedRunCli } = require(path.join(hqRoot, "core", "scripts", "newcompany-bootstrap.cjs"));
  const destination = path.join(hqRoot, "companies", "acme");
  let stdout = "";
  let stderr = "";
  const exitCode = await copiedRunCli([input.slug, input.companyName, destination, hqRoot], {
    readFlag: async () => false,
    writeStdout: (text) => { stdout += text; },
    writeStderr: (text) => { stderr += text; },
    ...extraDependencies,
  });
  return { exitCode, stdout, stderr, destination };
}

function assertExpectedTree(destination) {
  assert.deepEqual(filesUnder(destination), EXPECTED_LOCAL_TREE);
  for (const directory of ["sources/_index", "sources/meetings"]) {
    assert.equal(fs.statSync(path.join(destination, directory)).isDirectory(), true, `${directory} exists`);
  }
  assert.match(fs.readFileSync(path.join(destination, "README.md"), "utf8"), /^# Acme Corp$/m);
}

test("bootstrap renders the expected company tree from a fresh template copy", async (t) => {
  const hqRoot = temporaryHqRoot(t);
  const result = await bootstrapInto(hqRoot);
  assert.equal(result.exitCode, 0, result.stderr);
  assert.equal(result.stdout, "newcompany mode: newcompany\n");
  assertExpectedTree(result.destination);
});

test("bootstrap succeeds when an installed template lost its workspace and repos folders", async (t) => {
  const hqRoot = temporaryHqRoot(t, ["workspace", "repos", ".hq-seed/golden/acme/workspace", ".hq-seed/golden/acme/repos"]);
  const result = await bootstrapInto(hqRoot);
  assert.equal(result.exitCode, 0, result.stderr);
  assertExpectedTree(result.destination);

  const committed = path.join(REPO_ROOT, "companies", "_template");
  for (const relative of ["workspace/.gitignore", "workspace/index.jsonl", "workspace/sessions/.gitkeep", "repos/.gitkeep"]) {
    assert.deepEqual(
      fs.readFileSync(path.join(result.destination, relative)),
      fs.readFileSync(path.join(committed, relative)),
      `${relative} matches the committed template bytes`,
    );
  }
});

test("bootstrap names a missing non-structural template file", async (t) => {
  const hqRoot = temporaryHqRoot(t, ["board.json"]);
  let rendererStderr = "";
  // Same renderer subprocess as production, with its stderr captured instead of inherited.
  const run = (command, args, cwd) => {
    const child = spawnSync(command, args, { cwd, encoding: "utf8" });
    rendererStderr += child.stderr;
    if (child.status !== 0) throw new Error(`${command} exited with ${child.status}`);
  };
  const result = await bootstrapInto(hqRoot, { run });
  assert.equal(result.exitCode, 1);
  assert.match(rendererStderr, /Company template file is missing: companies\/_template\/board\.json\./);
  assert.match(result.stderr, /^newcompany bootstrap failed: /);
  assert.equal(fs.existsSync(result.destination), false, "nothing is rendered");
});

// Same renderer subprocess as production, with its output captured instead of inherited.
function capturingRun() {
  const captured = { stdout: "", stderr: "" };
  const run = (command, args, cwd) => {
    const child = spawnSync(command, args, { cwd, encoding: "utf8" });
    captured.stdout += child.stdout;
    captured.stderr += child.stderr;
    if (child.status !== 0) throw new Error(`${command} exited with ${child.status}`);
  };
  return { captured, run };
}

test("running the bootstrap again leaves every customized file unchanged", async (t) => {
  const hqRoot = temporaryHqRoot(t);
  const first = await bootstrapInto(hqRoot, { run: capturingRun().run });
  assert.equal(first.exitCode, 0, first.stderr);

  const customized = new Map(EXPECTED_LOCAL_TREE.map((relative) => [relative, `customized ${relative}\n`]));
  customized.set("board.json", JSON.stringify({ columns: ["Custom"], stories: [{ id: "s-1" }] }));
  customized.set("workspace/index.jsonl", '{"session":"kept"}\n');
  for (const [relative, contents] of customized) {
    fs.writeFileSync(path.join(first.destination, ...relative.split("/")), contents);
  }

  const { captured, run } = capturingRun();
  const second = await bootstrapInto(hqRoot, { run });
  assert.equal(second.exitCode, 0, second.stderr);
  for (const [relative, contents] of customized) {
    assert.equal(
      fs.readFileSync(path.join(second.destination, ...relative.split("/")), "utf8"),
      contents,
      `${relative} is unchanged`,
    );
  }
  assert.deepEqual(filesUnder(second.destination), EXPECTED_LOCAL_TREE);
  assert.match(captured.stdout, /^Rendered 0 company starter files for acme \(newcompany\)$/m);
  assert.match(captured.stdout, new RegExp(`^Kept ${EXPECTED_LOCAL_TREE.length} existing files unchanged: `, "m"));
  assert.match(captured.stdout, /board\.json/);
  assert.match(captured.stdout, /workspace\/index\.jsonl/);
});

test("running the bootstrap again writes only the files that are missing", async (t) => {
  const hqRoot = temporaryHqRoot(t);
  const first = await bootstrapInto(hqRoot, { run: capturingRun().run });
  assert.equal(first.exitCode, 0, first.stderr);
  const boardPath = path.join(first.destination, "board.json");
  fs.writeFileSync(boardPath, '{"custom":true}\n');
  fs.rmSync(path.join(first.destination, "workspace"), { recursive: true });

  const { captured, run } = capturingRun();
  const second = await bootstrapInto(hqRoot, { run });
  assert.equal(second.exitCode, 0, second.stderr);
  assert.equal(fs.readFileSync(boardPath, "utf8"), '{"custom":true}\n');
  assertExpectedTree(second.destination);
  assert.match(captured.stdout, /^Rendered 3 company starter files for acme \(newcompany\)$/m);
  assert.equal(captured.stderr, "");
});

test("the bootstrap does not write through a folder link that leaves the company", async (t) => {
  const hqRoot = temporaryHqRoot(t);
  const destination = path.join(hqRoot, "companies", "acme");
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "newcompany-outside-"));
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.mkdirSync(destination, { recursive: true });
  fs.symlinkSync(outside, path.join(destination, "repos"), "dir");

  const { captured, run } = capturingRun();
  const result = await bootstrapInto(hqRoot, { run });
  assert.equal(result.exitCode, 0, result.stderr);
  assert.deepEqual(fs.readdirSync(outside), [], "nothing is written outside the company");
  assert.match(captured.stdout, /Kept 1 existing files unchanged: repos\/\.gitkeep/);
});

test("each built-in default prints one warning that names the missing template file", async (t) => {
  const hqRoot = temporaryHqRoot(t, ["workspace", "repos", ".hq-seed/golden/acme/workspace", ".hq-seed/golden/acme/repos"]);
  const { captured, run } = capturingRun();
  const result = await bootstrapInto(hqRoot, { run });
  assert.equal(result.exitCode, 0, result.stderr);
  const warnings = captured.stderr.split("\n").filter(Boolean);
  assert.deepEqual(warnings, [
    "repos/.gitkeep",
    "workspace/.gitignore",
    "workspace/index.jsonl",
    "workspace/sessions/.gitkeep",
  ].map((relative) =>
    `Warning: companies/_template/${relative} is missing, so the built-in default was used. Run /update-hq to restore the template.`));
});

test("a complete template renders without warnings", async (t) => {
  const hqRoot = temporaryHqRoot(t);
  const { captured, run } = capturingRun();
  const result = await bootstrapInto(hqRoot, { run });
  assert.equal(result.exitCode, 0, result.stderr);
  assert.equal(captured.stderr, "");
});

test("structural defaults match the committed template files", async () => {
  const { STRUCTURAL_DEFAULTS, structuralDefault, loadSeedManifest } = await import(
    path.join(REPO_ROOT, "core", "scripts", "render-company-starter-files.mjs")
  );
  const template = path.join(REPO_ROOT, "companies", "_template");
  const manifest = loadSeedManifest(template);
  for (const [relative, contents] of Object.entries(STRUCTURAL_DEFAULTS)) {
    assert.ok([...manifest.seed, ...manifest.newcompany_only].includes(relative), `${relative} is rendered`);
    assert.equal(fs.readFileSync(path.join(template, relative), "utf8"), contents, `${relative} default is current`);
  }
  for (const relative of [...manifest.seed, ...manifest.newcompany_only]) {
    const fallback = structuralDefault(relative);
    if (fallback === undefined) continue;
    assert.equal(fs.readFileSync(path.join(template, relative), "utf8"), fallback, `${relative} default is current`);
  }
  assert.equal(structuralDefault("board.json"), undefined);
  assert.equal(structuralDefault("company.yaml"), undefined);
});
