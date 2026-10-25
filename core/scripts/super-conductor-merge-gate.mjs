#!/usr/bin/env node
// super-conductor-merge-gate.mjs — a merge from a /super-conductor session
// needs an answered decision row for that repo, PR and head.
//
// A session is gated when it is on a conduct link (workspace/lanes-links/
// by-session/<session id>) whose link has a decision queue
// (workspace/reports/conduct/<link>-decisions.jsonl): the conductor itself and
// every lane it conducts. In a gated session:
//   - `gh pr merge` must name the repo (-R owner/repo, or a PR URL), the PR by
//     number or URL, and the head (--match-head-commit <sha>);
//   - the queue must hold an answered or relayed row whose ref is
//     "merge <owner/repo> <pr> <sha>" (sha prefixes of 7+ match) and whose
//     answer is a go (Merge, Go, Yes, Approve, Ship), not a hold;
//   - `gh api .../pulls/<n>/merge` is refused (use gh pr merge).
// Sessions on no link, or on a link with no decision queue, are not gated.
//
//   node core/scripts/super-conductor-merge-gate.mjs check --root <hq> --session <id> --command <text>
//     exit 0 allow; exit 3 refuse, with the reason on stdout.
//   node core/scripts/super-conductor-merge-gate.mjs hook [<hq root>]
//     PreToolUse JSON on stdin; prints a deny decision, or nothing to allow.
import fs from 'node:fs';
import path from 'node:path';
import { isMain } from './lib/super-conductor-scope.mjs';
import { readRows, fold } from './super-conductor-decisions.mjs';

const SAFE = /^[A-Za-z0-9._-]{1,200}$/;

export function gatedLink(root, sid) {
  if (!SAFE.test(sid || '')) return null;
  let link;
  try { link = fs.readFileSync(path.join(root, 'workspace', 'lanes-links', 'by-session', sid), 'utf8').trim().split(/\s+/)[1]; } catch { return null; }
  if (!SAFE.test(link || '')) return null;
  const queue = path.join(root, 'workspace', 'reports', 'conduct', `${link}-decisions.jsonl`);
  return fs.existsSync(queue) ? { link, queue } : null;
}

const VALUE_FLAGS = new Set(['-R', '--repo', '--match-head-commit', '-b', '--body', '-F', '--body-file', '-t', '--subject', '-A', '--author-email', '-X', '--method', '-H', '--header', '-f', '--raw-field', '--field', '--hostname', '-q', '--jq', '--template']);

// Text-processing commands. The words after one of these are text (a grep
// pattern, a sed script, an echo line), not a command to run. The exemption
// is decided for the whole command, not per segment, and only holds when
// nothing in the command can run or export that text: every segment's
// command word is a text command (or cd), there is no substitution,
// subshell, redirection or brace group anywhere ($ ` ( ) < > { }), no alias,
// function, exec, eval or source word, sed has no e or w flag or command,
// awk has no system, getline or in-place, and printf has no -v. Anything
// else — a launcher such as env, sudo, timeout 60, hq secrets exec ... --,
// a pipe into sh, a wrapper this list has never heard of — keeps the gate,
// so unknown shapes fail closed.
const TEXT_COMMANDS = new Set(['grep', 'rg', 'sed', 'awk', 'echo', 'printf', 'cat']);

function splitTokens(seg) {
  // Braces split too, so BEGIN{gh ... (awk) and { gh ...; } expose gh.
  return seg.trim().split(/[\s{}]+/).filter(Boolean).map((t) => t.replace(/^[({`$]+/, '').replace(/[)}`]+$/, '')).filter(Boolean);
}
function commandWord(tok) {
  return tok.find((t) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) || '';
}
function textOnlyCommand(text, parts) {
  if (/[$`()<>{}]/.test(text)) return false;
  if (/\b(alias|function|exec|eval|source)\b/.test(text)) return false;
  for (let p = 0; p < parts.length; p += 2) {
    const tok = splitTokens(parts[p]);
    if (tok.length === 0) continue;
    const name = path.basename(commandWord(tok));
    if (name === 'cd') continue;
    if (!TEXT_COMMANDS.has(name)) return false;
    if (name === 'sed' && tok.some((t) => /(^|[^a-z])e[a-z]*$/.test(t) || /\/[a-zA-Z0-9#]*[eEwW]/.test(t))) return false;
    if (name === 'awk' && /system|getline|inplace|(^|\s)-i/.test(parts[p])) return false;
    if (name === 'printf' && tok.includes('-v')) return false;
  }
  return true;
}

// Every `gh ... pr merge` and `gh api .../pulls/<n>/merge` in a command, read
// from a copy with shell quotes and backslashes removed (so g'h' and "pr"
// cannot slip past), split on ; & | and newlines.
export function findMerges(command) {
  const text = String(command || '').replace(/["'\\]/g, '');
  const out = [];
  const parts = text.split(/([;&|\n]+)/);
  const textOnly = textOnlyCommand(text, parts);
  for (let p = 0; p < parts.length; p += 2) {
    const seg = parts[p];
    const tok = splitTokens(seg);
    // No guessing at the subcommand position (a value flag before it, as in
    // gh -R owner/repo pr merge or gh -X PUT api, would shift it). After any
    // gh token: the words "pr merge" in sequence anywhere make it a PR merge;
    // otherwise an "api" word with a /pulls/<n>/merge path makes it an API
    // merge. A false match (the words inside a --body) is refused, never let
    // through.
    const g = tok.findIndex((t) => path.basename(t) === 'gh');
    if (g < 0) continue;
    // In a text-only command, gh is a word in a text command's text, not the
    // command being run.
    if (textOnly && commandWord(tok) !== tok[g]) continue;
    let k = -1;
    for (let i = g + 1; i < tok.length - 1; i++) if (tok[i] === 'pr' && tok[i + 1] === 'merge') { k = i; break; }
    if (k < 0) {
      if (tok.slice(g + 1).includes('api') && /\/pulls\/\d+\/merge\b/.test(tok.slice(g + 1).join(' '))) out.push({ api: true });
      continue;
    }
    // Flags are read from every word after gh (so -R before "pr" counts); the
    // PR is the first plain word after "merge".
    const m = { repo: '', pr: '', sha: '', target: '' };
    for (let i = g + 1; i < tok.length; i++) {
      if (i === k || i === k + 1) continue;
      let t = tok[i];
      let v;
      const eq = t.indexOf('=');
      if (t.startsWith('-') && eq > 0) { v = t.slice(eq + 1); t = t.slice(0, eq); }
      if (VALUE_FLAGS.has(t)) {
        if (v === undefined) v = tok[++i] || '';
        if (t === '-R' || t === '--repo') m.repo = v;
        if (t === '--match-head-commit') m.sha = v;
        continue;
      }
      if (t.startsWith('-')) continue;
      if (i > k + 1 && !m.target) m.target = t;
    }
    const url = /github\.com\/([^/\s]+\/[^/\s]+)\/pull\/(\d+)/.exec(m.target);
    if (url) { m.repo = m.repo || url[1]; m.pr = url[2]; } else if (/^#?\d+$/.test(m.target)) m.pr = m.target.replace('#', '');
    m.repo = m.repo.replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '').toLowerCase();
    m.sha = m.sha.toLowerCase();
    out.push(m);
  }
  return out;
}

const GO = /\b(merge|go|yes|approve[ds]?|ship)\b/i;
const NOGO = /\b(hold|wait|no|not|don'?t|do not|skip|stop|later)\b/i;
const shaMatch = (a, b) => /^[0-9a-f]{7,40}$/.test(a) && /^[0-9a-f]{7,40}$/.test(b) && (a.startsWith(b) || b.startsWith(a));

export function covered(rows, m) {
  return fold(rows).some((r) => {
    if (!['answered', 'relayed'].includes(r.status)) return false;
    const ref = /^merge\s+(\S+)\s+#?(\d+)\s+([0-9a-fA-F]{7,40})$/.exec(String(r.ref || '').trim());
    if (!ref) return false;
    const answer = String(r.answer || '');
    return ref[1].toLowerCase() === m.repo && ref[2] === m.pr && shaMatch(ref[3].toLowerCase(), m.sha)
      && GO.test(answer) && !NOGO.test(answer);
  });
}

// Returns '' to allow, or the reason to refuse.
export function check(root, sid, command) {
  const merges = findMerges(command);
  if (!merges.length) return '';
  const g = gatedLink(root, sid);
  if (!g) return '';
  const rows = readRows(g.queue);
  for (const m of merges) {
    if (m.api) return `super-conductor merge gate (link ${g.link}): merge through gh pr merge with -R and --match-head-commit, not gh api, so the decision row can be checked.`;
    if (!m.repo) return `super-conductor merge gate (link ${g.link}): name the repo with -R <owner/repo> (or merge by PR URL).`;
    if (!m.pr) return `super-conductor merge gate (link ${g.link}): name the PR by number or URL.`;
    if (!/^[0-9a-f]{7,40}$/.test(m.sha)) return `super-conductor merge gate (link ${g.link}): add --match-head-commit <head sha>; a merge is approved for one head.`;
    if (!covered(rows, m)) return `super-conductor merge gate (link ${g.link}): no answered owner go for "merge ${m.repo} ${m.pr} ${m.sha}". Queue it with super-conductor-decisions.mjs add --ref "merge ${m.repo} ${m.pr} <full head sha>" and wait for the desk's answer (or a standing rule set with --irreversible).`;
  }
  return '';
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'check') {
    const o = {};
    for (let i = 0; i < rest.length; i += 2) o[rest[i].replace(/^--/, '')] = rest[i + 1];
    if (!o.root || o.command === undefined) { process.stderr.write('usage: check --root <hq> --session <id> --command <text>\n'); process.exit(2); }
    const why = check(o.root, o.session || '', o.command);
    if (why) { process.stdout.write(`${why}\n`); process.exit(3); }
    return;
  }
  if (cmd === 'hook') {
    let input;
    try { input = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return; }
    if (!input || input.tool_name !== 'Bash' || typeof input.tool_input?.command !== 'string') return;
    const root = rest[0] || process.env.CLAUDE_PROJECT_DIR || process.cwd();
    const why = check(root, String(input.session_id || ''), input.tool_input.command);
    if (why) process.stdout.write(`${JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: why } })}\n`);
    return;
  }
  process.stderr.write('usage: check|hook\n');
  process.exit(2);
}

if (isMain(import.meta.url)) main();
