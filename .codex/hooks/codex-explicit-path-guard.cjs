#!/usr/bin/env node
// Conservative Codex shell-path guard. Unknown shell syntax always fails open.
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const PATH_COMMANDS = new Set(['ls', 'cat', 'head', 'tail', 'wc', 'stat', 'tree', 'find', 'rg', 'grep']);
const VALUE_OPTIONS = {
  head: new Set(['-n', '--lines', '-c', '--bytes']),
  tail: new Set(['-n', '--lines', '-c', '--bytes']),
  rg: new Set(['-A', '-B', '-C', '--after-context', '--before-context', '--context', '--max-count', '--max-depth', '--glob', '-g', '--type', '-t', '--type-not', '-T', '--iglob', '--encoding', '--sort', '--threads']),
  grep: new Set(['-e', '--regexp', '-f', '--file', '-m', '--max-count', '-A', '-B', '-C', '--after-context', '--before-context', '--context', '--include', '--exclude']),
  stat: new Set(['-c', '--format', '--printf']),
  tree: new Set(['-L', '--level', '-P', '--pattern', '-I', '--ignore-case']),
  ls: new Set(['-w', '--width', '-T', '--tabsize', '--sort', '--time', '--time-style', '--format']),
};
const OPTIONAL_VALUE_OPTIONS = { ls: new Set(['--color', '--hyperlink']) };
const FAIL_OPEN_CHARS = new Set(['\\', '$', '`', '*', '?', '[', ']', '{', '}', '~', ';', '&', '|', '<', '>', '(', ')']);

function output(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function failOpen() {
  output({ deny: false });
}

function tokenize(command) {
  const tokens = [];
  let token = '';
  let active = false;
  let quote = null;
  for (const char of command) {
    if (char === '\n' || char === '\r' || char.charCodeAt(0) < 0x20) return null;
    if (quote) {
      if (['\\', '$', '`', '*', '?', '[', ']', '{', '}', '~'].includes(char)) return null;
      if (char === quote) quote = null;
      else token += char;
      active = true;
      continue;
    }
    if (FAIL_OPEN_CHARS.has(char)) return null;
    if (char === "'" || char === '"') {
      quote = char;
      active = true;
    } else if (/\s/.test(char)) {
      if (active) tokens.push(token);
      token = '';
      active = false;
    } else {
      token += char;
      active = true;
    }
  }
  if (quote) return null;
  if (active) tokens.push(token);
  return tokens.length ? tokens : null;
}

function parseCommand(command) {
  const tokens = tokenize(command);
  if (!tokens) return null;
  const executable = path.basename(tokens[0]);
  if (!PATH_COMMANDS.has(executable) && executable !== 'git') return null;
  if (tokens[0] !== executable && !tokens[0].endsWith(`/${executable}`)) return null;
  return { tokens, executable };
}

function pathOperandIndexes(tokens, executable) {
  const args = tokens.slice(1);
  if (executable === 'git') {
    if (args.some((arg) => ['-C', '--git-dir', '--work-tree'].includes(arg)
      || arg.startsWith('--git-dir=') || arg.startsWith('--work-tree='))) return { anchoredGit: true };
    return { positions: [] };
  }

  const positions = [];
  const positional = [];
  let patternSupplied = false;
  const optionsWithValues = VALUE_OPTIONS[executable] || new Set();
  let afterSeparator = false;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const tokenIndex = index + 1;
    if (afterSeparator) {
      positions.push(tokenIndex);
    } else if (arg === '--') {
      afterSeparator = true;
    } else if (arg.startsWith('-') && arg !== '-') {
      const option = arg.split('=', 1)[0];
      if (optionsWithValues.has(option) && !arg.includes('=')) {
        index += 1;
        if (index >= args.length) return null;
        if (executable === 'grep' && ['-e', '--regexp', '-f', '--file'].includes(option)) patternSupplied = true;
        if (executable === 'grep' && ['-f', '--file'].includes(option)) positions.push(index + 1);
      } else if (!optionsWithValues.has(option)
        && !(OPTIONAL_VALUE_OPTIONS[executable] || new Set()).has(option)
        && arg.startsWith('--') && !arg.includes('=')) {
        return null;
      }
    } else {
      positional.push(tokenIndex);
    }
  }

  if (executable === 'grep') positions.push(...(patternSupplied ? positional : positional.slice(1)));
  else if (executable === 'rg') positions.push(...positional.slice(1));
  else if (executable === 'find') {
    positions.length = 0;
    for (let index = 0; index < args.length; index += 1) {
      const arg = args[index];
      if (arg === '--') continue;
      if (arg.startsWith('-') || ['!', '(', ')'].includes(arg)) break;
      positions.push(index + 1);
    }
  } else positions.push(...positional);
  return { positions };
}

function isUnderRoot(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

function missingOperands(tokens, executable, positions, root) {
  const missing = [];
  for (const position of positions) {
    const operand = tokens[position];
    if (operand === '-' || path.isAbsolute(operand)) continue;
    const candidate = path.resolve(root, operand);
    if (!isUnderRoot(candidate, root) || !fs.existsSync(candidate)) missing.push(operand);
  }
  return missing;
}

function codeModeExecCalls(source) {
  const calls = [];
  const marker = 'exec_command(';
  let index = source.indexOf(marker);
  while (index >= 0) {
    const open = source.indexOf('{', index + marker.length);
    if (open < 0 || source.slice(index + marker.length, open).trim()) break;
    let depth = 0;
    let inString = false;
    let escaped = false;
    let end = -1;
    for (let i = open; i < source.length; i += 1) {
      const ch = source[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === '\\') escaped = true;
        else if (ch === '"') inString = false;
      } else if (ch === '"') inString = true;
      else if (ch === '{') depth += 1;
      else if (ch === '}') {
        depth -= 1;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end < 0) break;
    try { calls.push(JSON.parse(source.slice(open, end + 1))); } catch { /* not a JSON literal; skip */ }
    index = source.indexOf(marker, end + 1);
  }
  return calls;
}

function latestTranscriptWorkdir(transcript, command) {
  if (!transcript) return null;
  let stat;
  try { stat = fs.statSync(transcript); } catch { return null; }
  if (!stat.isFile()) return null;
  const maxBytes = 4 * 1024 * 1024;
  const start = Math.max(0, stat.size - maxBytes);
  let fd;
  try {
    fd = fs.openSync(transcript, 'r');
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    let contents = buffer.toString('utf8');
    if (start > 0) {
      const newline = contents.indexOf('\n');
      if (newline < 0) return null;
      contents = contents.slice(newline + 1);
    }
    let found = null;
    for (const line of contents.split('\n')) {
      if (!line) continue;
      let record;
      try { record = JSON.parse(line); } catch { continue; }
      const payload = record && record.payload && typeof record.payload === 'object' ? record.payload : record;
      if (!payload) continue;
      let calls = [];
      if (payload.type === 'function_call' && ['exec_command', 'shell'].includes(payload.name)) {
        let args = payload.arguments;
        if (typeof args === 'string') {
          try { args = JSON.parse(args); } catch { continue; }
        }
        calls = [args];
      } else if (payload.type === 'custom_tool_call' && payload.name === 'exec' && typeof payload.input === 'string') {
        // Codex code mode records shell calls as JS: tools.exec_command({"cmd": ..., "workdir": ...}).
        calls = codeModeExecCalls(payload.input);
      }
      for (const args of calls) {
        if (!args || typeof args !== 'object') continue;
        const candidateCommand = args.cmd ?? args.command;
        if (candidateCommand === command) found = typeof args.workdir === 'string' && args.workdir.trim() ? args.workdir : null;
      }
    }
    return found;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function shellQuote(token) {
  if (/^[A-Za-z0-9_./:+,=@%-]+$/.test(token)) return token;
  return `'${token.replaceAll("'", "'\\''")}'`;
}

function render(tokens, placeholderIndexes = new Set()) {
  return tokens.map((token, index) => placeholderIndexes.has(index) ? token : shellQuote(token)).join(' ');
}

function main() {
  const candidateMode = process.argv[2] === '--candidate';
  if (process.argv.length !== (candidateMode ? 7 : 6)) return failOpen();
  const [, , rootArg, cwdArg, command, transcript] = candidateMode
    ? [process.argv[0], process.argv[1], ...process.argv.slice(3)]
    : process.argv;
  let root;
  let cwd;
  try {
    root = fs.realpathSync(rootArg);
    cwd = fs.realpathSync(cwdArg);
  } catch {
    return failOpen();
  }
  if (cwd !== root) return failOpen();
  const parsed = parseCommand(command);
  if (!parsed) return failOpen();
  const { tokens, executable } = parsed;
  const operands = pathOperandIndexes(tokens, executable);
  if (!operands || operands.anchoredGit) return failOpen();

  const missing = executable === 'git' ? null : missingOperands(tokens, executable, operands.positions, root);
  const isCandidate = executable === 'git' || missing.length > 0;
  if (candidateMode) return output({ candidate: isCandidate });
  if (!isCandidate) return failOpen();

  const workdir = latestTranscriptWorkdir(transcript, command);
  let relativeWorkdir = null;
  if (workdir) {
    const resolved = path.resolve(path.isAbsolute(workdir) ? workdir : path.join(root, workdir));
    try {
      const real = fs.realpathSync(resolved);
      if (!isUnderRoot(real, root) || !fs.statSync(real).isDirectory()) return failOpen();
      relativeWorkdir = path.relative(root, real) || '.';
    } catch {
      return failOpen();
    }
  }

  // A root workdir has no hidden-directory mismatch to correct.
  if (relativeWorkdir === '.') return failOpen();

  if (executable === 'git') {
    if (relativeWorkdir && relativeWorkdir !== '.') {
      const rewrite = [tokens[0], '-C', relativeWorkdir, ...tokens.slice(1)];
      return output({ deny: true, reason: reason(`Rewrite this command as: ${render(rewrite)}.`) });
    }
    return failOpen();
  }

  if (relativeWorkdir) {
    const rewritten = tokens.slice();
    for (const position of operands.positions) {
      const operand = rewritten[position];
      if (operand !== '-' && !path.isAbsolute(operand)) rewritten[position] = path.posix.normalize(path.posix.join(relativeWorkdir, operand));
    }
    return output({ deny: true, reason: reason(`Rewrite this command as: ${render(rewritten)}.`) });
  }

  const rewritten = tokens.slice();
  const placeholders = new Set();
  for (const position of operands.positions) {
    const operand = rewritten[position];
    if (operand !== '-' && !path.isAbsolute(operand)) {
      rewritten[position] = `<project-dir>/${operand}`;
      placeholders.add(position);
    }
  }
  const guidance = `Rewrite this command as: ${render(rewritten, placeholders)}. For Git commands use the explicit form: git -C <project-dir> status.`;
  return output({ deny: true, reason: reason(guidance) });
}

function reason(guidance) {
  return `Codex does not pass the tool workdir to PreToolUse hooks (openai/codex#32360). Relative paths are checked from the HQ root. ${guidance}`;
}

main();
