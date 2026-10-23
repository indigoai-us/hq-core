// hq-core: public
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../../..');
export const hash = value => createHash('sha256').update(value).digest('hex');
const candidates = ['synthetic-neutral-zzzz', 'git', 'hq', 'npm', 'core/skills/', 'qmd', 'companies/example/settings/',
  'merge', 'view_image', '.claude/plans/', 'agent-browser screenshot', 'companies/', 'core', 'deploy', 'env',
  'gh pr create', 'git commit', 'policies/', 'prd.json', 'repos/private/example/', 'Bearer synthetic', 'skills/',
  'sleep', 'timeout', 'workspace/threads/'];
function matches(re, value) {
  // Preserve regex quotes across Windows CreateProcess/MSYS argument parsing.
  // Environment values reach Bash intact, as registry values do at runtime.
  const r = spawnSync('bash', ['-c', 'shopt -s nocasematch; [[ "$HQ_CORPUS_VALUE" =~ $HQ_CORPUS_REGEX ]]'],
    { encoding: 'utf8', timeout: 10000, env: {...process.env, BASH_ENV: '/dev/null',
      HQ_CORPUS_REGEX: re, HQ_CORPUS_VALUE: value} });
  if (r.error || ![0, 1].includes(r.status)) throw new Error('Invalid corpus regex or Bash unavailable');
  return r.status === 0;
}
const witnesses = new Map();
function witness(re, wanted) {
  const key = `${wanted}:${re}`;
  if (!witnesses.has(key)) {
    const value = candidates.find(text => matches(re, JSON.stringify({command: text, file_path: text})) === wanted);
    if (value === undefined) throw new Error(`No ${wanted ? 'matching' : 'non-matching'} synthetic witness for regex hash ${hash(re)}; extend candidates`);
    witnesses.set(key, value);
  }
  return witnesses.get(key);
}
export function generate() {
  const registryText = readFileSync(join(root, '.claude/hooks/hook-registry.json'), 'utf8');
  const registry = JSON.parse(registryText);
  const policies = readdirSync(join(root, 'core/policies')).filter(name => name.endsWith('.md')).sort().map(name => {
    const text = readFileSync(join(root, 'core/policies', name), 'utf8');
    const frontmatter = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
    const when = frontmatter?.[1].match(/^when:\s*(.+)$/m)?.[1] || '';
    const on = frontmatter?.[1].match(/^on:\s*(.+)$/m)?.[1] || '';
    // Hash only the dispatch fields, so editing a policy's body or other
    // frontmatter never changes the committed corpus.
    return { path: `core/policies/${name}`, trigger_sha256: hash(`when: ${when}\non: ${on}\n`), when, on };
  });
  // Exercise policy_vocab with real lexical frontmatter, without private bodies.
  const policy = policies.find(p => /^[a-z][a-z0-9_-]*$/.test(p.when) &&
    !['always', 'company', 'repo', 'shared_branch', 'file_path', 'output', 'synthetic'].includes(p.when) && p.on.includes('PreToolUse') && p.on.includes('PostToolUse'));
  if (!policy) throw new Error('No lexical tool-event policy for vocabulary fixtures');
  const rows = [];
  for (const [event, groups] of Object.entries(registry.hooks)) {
    for (const [groupIndex, group] of groups.entries()) for (const [hookIndex, hook] of group.hooks.entries()) {
      const entry = `${event}/${groupIndex}/${hookIndex}`;
      const pf = hook.prefilter || {};
      for (const key of Object.keys(pf)) if (!['re','env','file','policy_vocab'].includes(key)) throw new Error(`Unsupported prefilter ${key}`);
      const rules = ['entry', ...Object.keys(pf).map(key => `prefilter.${key}`)];
      for (const rule of rules) for (const matching of [true, false]) for (const runtime of ['claude', 'codex']) {
        let input = pf.re ? witness(pf.re, true) : pf.policy_vocab ? policy.when : candidates[0];
        let dispatchEvent = event;
        let tool = group.matcher && group.matcher !== '*' ? group.matcher.split(/[|,]/)[0] : 'Bash';
        const env = {};
        const files = {};
        if (pf.env) env[pf.env] = 'synthetic';
        // {session_id} in a file prefilter expands to the payload's session.
        const pfFile = pf.file ? pf.file.replaceAll('{session_id}', 'synthetic-corpus') : '';
        if (pfFile) files[pfFile] = '{}\n';
        if (pf.policy_vocab) {
          files[policy.path] = `---\nwhen: ${policy.when}\non: ${policy.on}\n---\nSynthetic corpus policy.\n`;
          files['workspace/orchestrator/policy-trigger-state/synthetic-corpus.txt'] = '';
        }
        if (!matching) {
          if (rule === 'entry') {
            if (['PreToolUse','PostToolUse'].includes(event) && group.matcher && group.matcher !== '*') tool = 'SyntheticNonMatchingTool';
            else dispatchEvent = 'SyntheticUnregisteredEvent';
          } else if (rule === 'prefilter.re') input = witness(pf.re, false);
          else if (rule === 'prefilter.env') env[pf.env] = '';
          else if (rule === 'prefilter.file') delete files[pfFile];
          else if (rule === 'prefilter.policy_vocab') input = candidates[0];
        }
        const payload = {session_id: 'synthetic-corpus', cwd: '$FIXTURE', hook_event_name: dispatchEvent,
          transcript_path: '$FIXTURE/transcript.jsonl'};
        if (['PreToolUse','PostToolUse'].includes(dispatchEvent)) Object.assign(payload, {
          tool_name: tool, tool_input: { command: input, file_path: input },
          tool_use_id: runtime === 'codex' ? 'exec-synthetic' : 'toolu_synthetic',
          ...(dispatchEvent === 'PostToolUse' ? { tool_response: { output: 'synthetic' } } : {}),
        });
        if (dispatchEvent === 'UserPromptSubmit') payload.prompt = input;
        // The vocabulary scans serialized keys as well as values. An absent
        // command field exercises the no-match side of a command-token policy.
        if (rule === 'prefilter.policy_vocab' && !matching) payload.tool_input = {file_path: input};
        if (dispatchEvent === 'PreCompact') payload.trigger = group.matcher || 'auto';
        if (dispatchEvent === 'SessionStart') payload.source = group.matcher || 'startup';
        if (runtime === 'codex') payload.turn_id = 'synthetic-turn';
        rows.push({ hook_id: hook.id, entry, rule, runtime, matching, event: dispatchEvent,
          registry: {hooks: {[event]: [{matcher: group.matcher, hooks: [{...hook, gated: false}]}]}},
          env, files, payload });
      }
    }
  }
  return {schema_version: 'hq-hook-corpus.v1', version: 1,
    registry_sha256: hash(registryText), policies, vocabulary_policy: policy.path, cases: rows};
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const corpus = JSON.stringify(generate(), null, 2) + '\n';
  const output = join(here, 'corpus.json');
  if (process.argv.includes('--check')) {
    if (readFileSync(output, 'utf8') !== corpus) throw new Error('Corpus stale; run generate-corpus.mjs');
    console.log('Corpus is current');
  } else {
    writeFileSync(output, corpus);
    console.log(`Generated ${JSON.parse(corpus).cases.length} synthetic cases`);
  }
}
