#!/usr/bin/env node
// Lint shell scripts for heredocs nested inside command/process substitution.
//
// macOS ships bash 3.2, whose parser mishandles a heredoc opened inside a
// `$( ... )` command substitution, a `<( ... )` / `>( ... )` process
// substitution, or a `` `...` `` backtick substitution. The body is read past
// the substitution and the parser reports a phantom "unexpected EOF while
// looking for matching quote" / unterminated-quote error. For a PreToolUse /
// PostToolUse hook that means EVERY tool call fails with a hook error.
//
// The fix is always the same: slurp the heredoc into a variable at the top
// level (a standalone heredoc, no enclosing substitution) and feed it to the
// inner command via an argument, e.g. `node -e "$var"`.
//
// This lint flags the dangerous shape directly, so it is caught on any bash
// version — including CI runners on bash 5, which do NOT reproduce the 3.2
// parse error. `bash -n` alone is therefore not enough.
//
// Usage:
//     lint-hook-heredoc-nesting.js FILE [FILE ...]
//
// Exit status 0 = clean, 1 = at least one violation (printed to stderr).

const fs = require("fs");

// Return a list of [lineNo, delimiter] heredocs opened while inside a
// command/process/backtick substitution.
function findViolations(path) {
  const lines = fs.readFileSync(path, "utf8").split(/\n/);

  const violations = [];
  // Context stack of frame types. Command contexts (where a heredoc operator
  // is meaningful) are: 'top', 'cmdsub', 'procsub', 'backtick'. Non-command
  // frames: 'squote', 'dquote', 'arith'.
  const stack = ["top"];
  // Heredoc delimiters whose bodies are still being consumed, in FIFO order
  // (bash fills the first-opened heredoc first). Each entry: [word, stripTabs].
  const active = [];

  // A heredoc is dangerous if any enclosing command frame is a substitution
  // (cmdsub/procsub/backtick). Plain quote/arith frames do not by themselves
  // make it dangerous, but a cmdsub *inside* a dquote is still on the stack
  // and counts.
  const inSubstitution = () =>
    stack.some((frame) => frame === "cmdsub" || frame === "procsub" || frame === "backtick");

  const isWordChar = (ch) => /[A-Za-z0-9_.+-]/.test(ch);

  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx].replace(/\r$/, "");
    const lineNo = idx + 1;

    // If we are consuming heredoc bodies, this whole physical line is data
    // until it matches the delimiter of the oldest open heredoc.
    if (active.length) {
      const [word, stripTabs] = active[0];
      const cmp = stripTabs ? line.replace(/^\t+/, "") : line;
      if (cmp === word) active.shift();
      continue;
    }

    let j = 0;
    const length = line.length;
    while (j < length) {
      const top = stack[stack.length - 1];
      const c = line[j];

      if (top === "squote") {
        if (c === "'") stack.pop();
        j += 1;
        continue;
      }

      if (top === "dquote") {
        if (c === "\\") { j += 2; continue; }
        if (c === '"') { stack.pop(); j += 1; continue; }
        if (c === "`") { stack.push("backtick"); j += 1; continue; }
        if (c === "$" && j + 1 < length && line[j + 1] === "(") {
          if (j + 2 < length && line[j + 2] === "(") { stack.push("arith"); j += 3; continue; }
          stack.push("cmdsub"); j += 2; continue;
        }
        j += 1;
        continue;
      }

      if (top === "arith") {
        // Arithmetic context ends at the matching '))'. Track nested parens
        // loosely; no heredoc/quote parsing needed inside.
        if (c === ")" && j + 1 < length && line[j + 1] === ")") { stack.pop(); j += 2; continue; }
        j += 1;
        continue;
      }

      // Command context: top, cmdsub, procsub, backtick.
      if (c === "\\") { j += 2; continue; }
      if (c === "#" && (j === 0 || line[j - 1] === " " || line[j - 1] === "\t")) break; // comment
      if (c === "'") { stack.push("squote"); j += 1; continue; }
      if (c === '"') { stack.push("dquote"); j += 1; continue; }
      if (c === "`") {
        if (top === "backtick") stack.pop(); else stack.push("backtick");
        j += 1;
        continue;
      }
      if (c === "$" && j + 1 < length && line[j + 1] === "(") {
        if (j + 2 < length && line[j + 2] === "(") { stack.push("arith"); j += 3; continue; }
        stack.push("cmdsub"); j += 2; continue;
      }
      if ((c === "<" || c === ">") && j + 1 < length && line[j + 1] === "(") {
        stack.push("procsub"); j += 2; continue;
      }
      if (c === "<" && j + 1 < length && line[j + 1] === "<") {
        if (j + 2 < length && line[j + 2] === "<") { j += 3; continue; } // here-string <<<
        let k = j + 2;
        let stripTabs = false;
        if (k < length && line[k] === "-") { stripTabs = true; k += 1; }
        while (k < length && (line[k] === " " || line[k] === "\t")) k += 1;
        let word = "";
        if (k < length && (line[k] === "'" || line[k] === '"')) {
          const quote = line[k];
          k += 1;
          while (k < length && line[k] !== quote) { word += line[k]; k += 1; }
          k += 1;
        } else {
          while (k < length && isWordChar(line[k])) { word += line[k]; k += 1; }
        }
        if (word) {
          if (inSubstitution()) violations.push([lineNo, word]);
          active.push([word, stripTabs]);
        }
        j = k;
        continue;
      }
      if (c === "(") {
        // plain subshell / grouping; only matters for paren balance
        stack.push("subshell");
        j += 1;
        continue;
      }
      if (c === ")") {
        if (top === "cmdsub" || top === "procsub" || top === "subshell") stack.pop();
        j += 1;
        continue;
      }
      j += 1;
    }
  }

  return violations;
}

function main(argv) {
  const paths = argv.slice(2);
  if (!paths.length) {
    process.stderr.write("usage: lint-hook-heredoc-nesting.js FILE [FILE ...]\n");
    return 2;
  }
  let bad = 0;
  for (const path of paths) {
    for (const [lineNo, word] of findViolations(path)) {
      bad += 1;
      process.stderr.write(
        path + ":" + lineNo + ": heredoc <<" + word + " opened inside a command/process " +
        "substitution; bash 3.2 mis-parses this as an unterminated " +
        "quote. Slurp it into a top-level variable and run via " +
        'an argument (e.g. node -e "$var").\n'
      );
    }
  }
  return bad ? 1 : 0;
}

process.exit(main(process.argv));
