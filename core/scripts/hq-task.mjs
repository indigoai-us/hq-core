#!/usr/bin/env node
// hq-task.mjs — the global task list on an HQ board.
//
// Tasks live in `tasks[]` on a board file, not inside a project. Most tasks
// never belong to a project, and a `prd.json` is the wrong shape for one: it
// carries branchName, e2eTests, files and dependsOn, none of which mean
// anything for "renew the registration".
//
//   personal/board.json          the owner's own board (default)
//   companies/<slug>/board.json  a company board (--company <slug>)
//
// See core/knowledge/public/hq-core/goals-and-tasks-board.md for the concept.
//
// Node rather than python3: HQ's script layer must run on Windows machines
// where python3 is absent or is a Store-alias stub that fails every call
// (core/scripts/tests/hooks-no-python.test.sh).

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const STATUSES = ["open", "blocked", "done"];

const USAGE = `hq-task — the global task list on an HQ board

Usage:
  hq-task.sh list   [--company <slug>] [--all] [--goal <objective-id>]
  hq-task.sh add    [--company <slug>] --title "<short title>"
                    [--description "<context>"]
                    [--criteria "<one done-criterion>"]...
                    [--contact "Name <email>|role"]...
                    [--goal <objective-id>] [--priority <1-3>]
  hq-task.sh done   [--company <slug>] --id T-002
  hq-task.sh block  [--company <slug>] --id T-002 --reason "<what is in the way>"
  hq-task.sh reopen [--company <slug>] --id T-002
  hq-task.sh goals  [--company <slug>]

Default board: personal/board.json. With --company: companies/<slug>/board.json.`;

function hqRoot() {
  if (process.env.HQ_ROOT) return process.env.HQ_ROOT;
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}

function die(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const repeatable = new Set(["criteria", "contact"]);
  const bare = new Set(["all"]);
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) die(`Unexpected argument: ${token}\n\n${USAGE}`);
    const key = token.slice(2);
    if (bare.has(key)) {
      flags[key] = true;
      continue;
    }
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) {
      die(`Flag --${key} needs a value.\n\n${USAGE}`);
    }
    i += 1;
    if (repeatable.has(key)) (flags[key] ||= []).push(value);
    else flags[key] = value;
  }
  return flags;
}

// The owner's own scope is the `personal/` overlay at the HQ root, NOT
// `companies/personal/`. The personal vault's allowlist syncs `personal/`
// paths, so a board kept there is readable by an agent running under the
// owner's identity; the reserved company scope is absent from that vault.
function boardPath(flags) {
  const root = hqRoot();
  return flags.company
    ? path.join(root, "companies", flags.company, "board.json")
    : path.join(root, "personal", "board.json");
}

function load(flags) {
  const file = boardPath(flags);
  if (!fs.existsSync(file)) die(`No board at ${file}`);
  const board = JSON.parse(fs.readFileSync(file, "utf8"));
  board.tasks ||= [];
  return { file, board };
}

function save(file, board) {
  board.updated_at = new Date().toISOString().replace(/\.\d+Z$/, "Z");
  fs.writeFileSync(file, `${JSON.stringify(board, null, 2)}\n`);
}

function nextId(tasks) {
  let highest = 0;
  for (const task of tasks) {
    const match = /^T-(\d+)$/.exec(task.id || "");
    if (match) highest = Math.max(highest, Number(match[1]));
  }
  return `T-${String(highest + 1).padStart(3, "0")}`;
}

// Accept "Name <email>|role" with the email and role both optional.
function parseContact(raw) {
  let rest = raw;
  let role = null;
  const bar = rest.indexOf("|");
  if (bar !== -1) {
    role = rest.slice(bar + 1).trim();
    rest = rest.slice(0, bar).trim();
  }
  let email = null;
  const angle = /<([^>]+)>/.exec(rest);
  if (angle) {
    email = angle[1].trim();
    rest = rest.slice(0, angle.index).trim();
  }
  const contact = { name: rest };
  if (email) contact.email = email;
  if (role) contact.role = role;
  return contact;
}

const today = () => new Date().toISOString().slice(0, 10);

function findTask(board, id) {
  const task = board.tasks.find((t) => t.id === id);
  if (!task) die(`No task ${id} on that board.`);
  return task;
}

function goalTitle(board, id) {
  const objective = (board.objectives || []).find((o) => o.id === id);
  return objective ? objective.title : null;
}

const MARK = { open: " ", blocked: "!", done: "x" };

function cmdList(flags) {
  const { board } = load(flags);
  let tasks = board.tasks.filter((t) => flags.all || t.status !== "done");
  if (flags.goal) tasks = tasks.filter((t) => t.objective_id === flags.goal);
  if (tasks.length === 0) {
    process.stdout.write("No open tasks.\n");
    return;
  }
  process.stdout.write(
    `${flags.company || "personal"} — ${flags.all ? "all tasks" : "open tasks"} (${tasks.length})\n\n`,
  );
  tasks.sort(
    (a, b) =>
      (a.priority ?? 99) - (b.priority ?? 99) ||
      String(a.id).localeCompare(String(b.id)),
  );
  for (const task of tasks) {
    process.stdout.write(
      `  [${MARK[task.status] ?? " "}] ${task.id}  ${task.title || ""}\n`,
    );
    const goal = task.objective_id && goalTitle(board, task.objective_id);
    if (goal) process.stdout.write(`         goal: ${goal}\n`);
    if (task.status === "blocked" && task.blockedReason) {
      process.stdout.write(`         blocked: ${task.blockedReason}\n`);
    }
    for (const contact of task.contacts || []) {
      const trail = [contact.email, contact.phone].filter(Boolean).join(" · ");
      process.stdout.write(
        `         ${contact.name}${trail ? ` — ${trail}` : ""}\n`,
      );
    }
  }
}

function cmdGoals(flags) {
  const { board } = load(flags);
  const objectives = board.objectives || [];
  if (objectives.length === 0) {
    process.stdout.write("No goals on that board.\n");
    return;
  }
  for (const objective of objectives) {
    const open = board.tasks.filter(
      (t) => t.objective_id === objective.id && t.status !== "done",
    ).length;
    process.stdout.write(
      `${objective.id}  ${objective.title}  (${open} open task${open === 1 ? "" : "s"})\n`,
    );
    for (const kr of objective.key_results || []) {
      process.stdout.write(
        `    ${kr.title} — ${kr.current ?? 0}/${kr.target} ${kr.unit || ""}\n`,
      );
    }
  }
}

function cmdAdd(flags) {
  if (!flags.title) die(`add needs --title.\n\n${USAGE}`);
  const { file, board } = load(flags);
  if (flags.goal && !goalTitle(board, flags.goal)) {
    die(`No goal ${flags.goal} on that board. Run 'hq-task.sh goals' to list them.`);
  }
  const task = {
    id: nextId(board.tasks),
    title: flags.title,
    description: flags.description || flags.title,
    status: "open",
    priority: flags.priority ? Number(flags.priority) : 2,
    objective_id: flags.goal || null,
    criteria: flags.criteria || [`${flags.title} — completed.`],
    contacts: (flags.contact || []).map(parseContact),
    createdAt: today(),
  };
  board.tasks.push(task);
  save(file, board);
  process.stdout.write(`Added ${task.id}: ${task.title}\n`);
}

function setStatus(flags, status, extra = {}) {
  const { file, board } = load(flags);
  if (!flags.id) die(`${status} needs --id.\n\n${USAGE}`);
  const task = findTask(board, flags.id);
  task.status = status;
  if (status === "done") task.closedAt = today();
  else delete task.closedAt;
  if (status === "blocked") task.blockedReason = extra.reason || "";
  else delete task.blockedReason;
  save(file, board);
  process.stdout.write(`${task.id} → ${status}: ${task.title}\n`);
}

const COMMANDS = {
  list: cmdList,
  goals: cmdGoals,
  add: cmdAdd,
  done: (f) => setStatus(f, "done"),
  reopen: (f) => setStatus(f, "open"),
  block: (f) => {
    if (!f.reason) die(`block needs --reason.\n\n${USAGE}`);
    setStatus(f, "blocked", { reason: f.reason });
  },
};

function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (!command || command === "--help" || command === "-h") {
    process.stdout.write(`${USAGE}\n`);
    process.exit(command ? 0 : 1);
  }
  const handler = COMMANDS[command];
  if (!handler) die(`Unknown command: ${command}\n\n${USAGE}`);
  handler(parseArgs(rest));
}

main();

export { STATUSES };
