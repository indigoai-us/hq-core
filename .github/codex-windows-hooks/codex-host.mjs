// Drives a real Codex app-server against a local Responses API fixture (no
// credentials, no network) with the HQ root as the trusted project, so Codex
// itself runs the hooks in HQ's .codex/config.toml. The fake model asks for one
// exec_command call; the result records what Codex sent back as the tool output.
// Usage: node codex-host.mjs <codex.exe> <hqRoot> <case> <command> <output.json> <codexHome>
// Env: CWH_COMPANY binds that company slug to the session before the tool call.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const [codex, hqRoot, caseName, command, output, codexHome] = process.argv.slice(2);
const company = process.env.CWH_COMPANY || '';
mkdirSync(codexHome, { recursive: true });
const started = Date.now();
const requestBodies = [];

// Bind the probe company for every session HQ knows about, right before the
// model asks for the tool call (SessionStart/UserPromptSubmit already ran).
function bindCompany(threadId) {
  if (!company) return [];
  const dir = join(hqRoot, 'workspace', 'sessions');
  const ids = new Set(existsSync(dir) ? readdirSync(dir, { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name) : []);
  if (threadId) ids.add(threadId);
  for (const id of ids) {
    const meta = join(dir, id, 'meta.yaml');
    mkdirSync(join(dir, id), { recursive: true });
    let text = existsSync(meta) ? readFileSync(meta, 'utf8') : `session_id: ${id}\n`;
    text = text.split(/\r?\n/).filter(l => !/^company_slug:/.test(l) && l !== '').join('\n') + `\ncompany_slug: ${company}\n`;
    writeFileSync(meta, text);
  }
  return [...ids];
}

let threadId = '';
let boundSessions = [];
let calls = 0;
const server = createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    calls++;
    requestBodies.push(body);
    if (calls === 1) boundSessions = bindCompany(threadId);
    const item = calls === 1
      ? { type: 'function_call', id: 'fc_probe', call_id: 'call_probe', name: 'exec_command', arguments: JSON.stringify({ cmd: command, yield_time_ms: 5000 }) }
      : { type: 'message', id: 'msg_probe', role: 'assistant', content: [{ type: 'output_text', text: 'probe complete', annotations: [] }] };
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const data of [
      { type: 'response.created', response: { id: 'resp_' + calls, object: 'response', status: 'in_progress', output: [] } },
      { type: 'response.output_item.done', output_index: 0, item },
      { type: 'response.completed', response: { id: 'resp_' + calls, object: 'response', status: 'completed', output: [item], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } },
    ]) res.write('event: ' + data.type + '\ndata: ' + JSON.stringify(data) + '\n\n');
    res.end();
  });
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const lit = s => "'" + s + "'";
writeFileSync(join(codexHome, 'config.toml'), [
  'model = "probe"',
  'model_provider = "probe"',
  'approval_policy = "never"',
  'sandbox_mode = "danger-full-access"',
  '[model_providers.probe]',
  'name = "probe"',
  `base_url = "http://127.0.0.1:${port}/v1"`,
  'wire_api = "responses"',
  `[projects.${lit(hqRoot)}]`,
  'trust_level = "trusted"',
  '',
].join('\n'));

const env = { ...process.env, CODEX_HOME: codexHome, HQ_TOKEN_KEYCHAIN: '0' };
delete env.OPENAI_API_KEY; delete env.CHATGPT_ACCESS_TOKEN; delete env.HQ_ROOT;
const child = spawn(codex, ['app-server'], { cwd: hqRoot, env, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
const exited = new Promise(r => child.once('exit', r));
let id = 0, stderr = '', finished;
const notifications = [];
const pending = new Map();
const completion = new Promise(r => { finished = r; });
const lines = createInterface({ input: child.stdout });
lines.on('line', line => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.method) notifications.push({ t: Date.now() - started, ...m });
  if (m.id !== undefined && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); }
  if (m.method === 'turn/completed') finished(m.params);
});
child.stderr.on('data', d => { stderr += d; });
const request = (method, params) => new Promise((resolve, reject) => { const key = ++id; pending.set(key, { resolve, reject }); child.stdin.write(JSON.stringify({ id: key, method, params }) + '\n'); });
let abort;
const failure = new Promise((_, reject) => { abort = reject; });
const timer = setTimeout(() => abort(new Error('Codex run timed out after 240s')), 240000);
child.once('error', e => abort(e));
child.once('exit', code => abort(new Error('Codex exited before the run completed, code ' + code)));

const result = { case: caseName, command, hqRoot, codexPid: child.pid };
try {
  await Promise.race([failure, (async () => {
    await request('initialize', { clientInfo: { name: 'hq_probe', version: '1' } });
    child.stdin.write(JSON.stringify({ method: 'initialized', params: {} }) + '\n');
    const listed = await request('hooks/list', { cwds: [hqRoot] });
    const hooks = listed.data.flatMap(row => row.hooks ?? []);
    result.hooksListed = hooks.map(h => ({ key: h.key, event: h.eventName ?? h.event, source: h.source }));
    if (hooks.length === 0) throw new Error('Codex listed no HQ hooks for the project: ' + JSON.stringify(listed));
    await request('config/batchWrite', { edits: [{ keyPath: 'hooks.state', value: Object.fromEntries(hooks.map(h => [h.key, { enabled: true, trusted_hash: h.currentHash }])), mergeStrategy: 'upsert' }], reloadUserConfig: true });
    const thread = await request('thread/start', { cwd: hqRoot, model: 'probe', modelProvider: 'probe', approvalPolicy: 'never', sandbox: 'danger-full-access' });
    threadId = thread.thread.id;
    result.threadId = threadId;
    const turnStart = Date.now();
    await request('turn/start', { threadId, input: [{ type: 'text', text: 'Run the probe command once.', text_elements: [] }] });
    const done = await completion;
    result.turnMs = Date.now() - turnStart;
    result.turnStatus = done.turn?.status;
  })()]);
} catch (error) {
  result.error = String(error && error.stack || error);
} finally {
  clearTimeout(timer);
  result.requests = calls;
  result.boundSessions = boundSessions;
  // The tool result Codex sent back to the model on the second request.
  result.functionCallOutput = null;
  for (const body of requestBodies.slice(1)) {
    try {
      const parsed = JSON.parse(body);
      const out = (parsed.input || []).filter(i => i.type === 'function_call_output');
      if (out.length) result.functionCallOutput = out.map(o => typeof o.output === 'string' ? o.output : JSON.stringify(o.output)).join('\n');
    } catch { }
  }
  result.hookNotifications = notifications.filter(n => /hook/i.test(n.method));
  result.notificationMethods = [...new Set(notifications.map(n => n.method))];
  result.itemNotifications = notifications.filter(n => /^item\//.test(n.method)).map(n => ({ t: n.t, method: n.method, item: n.params?.item ? { type: n.params.item.type, status: n.params.item.status, command: n.params.item.command, exitCode: n.params.item.exitCode, aggregatedOutput: n.params.item.aggregatedOutput } : undefined }));
  result.codexStderrTail = stderr.slice(-6000);
  result.wallMs = Date.now() - started;
  writeFileSync(output, JSON.stringify(result, null, 2));
  lines.close(); child.stdin.end(); child.kill();
  if (child.exitCode === null && child.signalCode === null) await exited;
  server.closeAllConnections();
  await new Promise(r => server.close(r));
}
process.exit(result.error ? 1 : 0);
