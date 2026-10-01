#!/usr/bin/env node
"use strict";

const fs = require("node:fs");

function summarize(text) {
  const lines = text.split(/\r?\n/).filter((line) => line.length > 0);
  let agreements = 0;
  const disagreements = [];
  for (let index = 0; index < lines.length; index += 1) {
    let row;
    try {
      row = JSON.parse(lines[index]);
    } catch (error) {
      throw new Error(`invalid JSON on line ${index + 1}: ${error instanceof Error ? error.name : "UnknownError"}`);
    }
    const guards = row.old_guards && typeof row.old_guards === "object" ? Object.values(row.old_guards) : [];
    const oldDecision = guards.includes("deny") ? "deny" : "allow";
    if (row.merged_decision === oldDecision) agreements += 1;
    else {
      disagreements.push({
        line: index + 1,
        tool: typeof row.tool === "string" ? row.tool : "unknown",
        merged: row.merged_decision,
        old: oldDecision,
        rule_id: typeof row.rule_id === "string" ? row.rule_id : "unknown",
      });
    }
  }
  const pct = lines.length ? ((agreements * 100) / lines.length).toFixed(1) : "0.0";
  const output = [`agreement rate: ${agreements}/${lines.length} (${pct}%)`];
  output.push(`disagreements: ${disagreements.length}`);
  for (const item of disagreements) {
    output.push(`disagreement line=${item.line} tool=${item.tool} merged=${item.merged} old=${item.old} rule=${item.rule_id}`);
  }
  return output.join("\n") + "\n";
}

if (require.main === module) {
  const file = process.argv[2];
  if (!file) {
    process.stderr.write("usage: merged-write-guard-shadow-summary.cjs <shadow-log.jsonl>\n");
    process.exitCode = 2;
  } else {
    try {
      process.stdout.write(summarize(fs.readFileSync(file, "utf8")));
    } catch (error) {
      process.stderr.write(`merged-write-guard-shadow-summary failed (${error instanceof Error ? error.name : "UnknownError"}).\n`);
      process.exitCode = 1;
    }
  }
}

module.exports = { summarize };
