// 06, section 8, 8k, group C: X-3 reproduced with the real claude and no model. A stand-in for the Messages API on
// 127.0.0.1 scripts the session's tool calls; every other host goes through a proxy on 127.0.0.1 that refuses it and
// names it. No login of the user's is read (a fresh home and config folder, a stand-in API key). Each plugin folder's
// own childArgs and childEnv start the session, with a user token set beside the login variables. The result names
// each call's outcome, with the work folder's path replaced. Result: results/x3-loopback-trial-<platform>.txt.
//   node x3-loopback-trial.mjs <claude executable> <plugin folder>...
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';

const [claude, ...plugins] = process.argv.slice(2).map((p) => path.resolve(p));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'x3-loopback-'));
const refused = [], other = [];
const proxy = http.createServer((q, s) => { refused.push(`HTTP ${q.url}`); s.writeHead(403); s.end(); });
proxy.on('connect', (q, sock) => { refused.push(`CONNECT ${q.url}`); sock.end('HTTP/1.1 403 Forbidden\r\n\r\n'); });
await new Promise((ok) => proxy.listen(0, '127.0.0.1', ok));
let script = [], results = new Map();
const msg = (block, stop) => [
  { type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'stand-in', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } },
  ...(block.type === 'tool_use'
    ? [{ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } }, { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } }]
    : [{ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }, { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: block.text } }]),
  { type: 'content_block_stop', index: 0 }, { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 1 } }, { type: 'message_stop' }];
const api = http.createServer((q, s) => {
  let body = '';
  q.on('data', (d) => (body += d));
  q.on('end', () => {
    const b = q.url.startsWith('/v1/messages') && !q.url.includes('count_tokens') ? JSON.parse(body || '{}') : null;
    if (!b?.tools?.length) { other.push(`${q.method} ${q.url.split('?')[0]}`); s.writeHead(200, { 'content-type': 'application/json' }); s.end('{"input_tokens":1}'); return; }
    for (const m of b.messages) for (const c of Array.isArray(m.content) ? m.content : []) if (c.type === 'tool_result') results.set(c.tool_use_id, { error: Boolean(c.is_error), text: JSON.stringify(c.content) });
    const next = script.shift();
    s.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const e of msg(next ? { type: 'tool_use', ...next } : { type: 'text', text: 'done' }, next ? 'tool_use' : 'end_turn')) s.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
    s.end();
  });
});
await new Promise((ok) => api.listen(0, '127.0.0.1', ok));
const home = path.join(work, 'home');
fs.mkdirSync(path.join(home, '.claude'), { recursive: true });
const via = `http://127.0.0.1:${proxy.address().port}`;
const base = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => /^(PATH|PATHEXT|SYSTEMROOT|SYSTEMDRIVE|WINDIR|COMSPEC|TEMP|TMP|TMPDIR)$/i.test(k))),
  HOME: home, USERPROFILE: home, APPDATA: path.join(home, 'Roaming'), LOCALAPPDATA: path.join(home, 'Local'), CLAUDE_CONFIG_DIR: path.join(home, '.claude'),
  ANTHROPIC_BASE_URL: `http://127.0.0.1:${api.address().port}`, ANTHROPIC_API_KEY: 'sk-ant-api03-stand-in', HTTPS_PROXY: via, HTTP_PROXY: via, ALL_PROXY: via, NO_PROXY: '127.0.0.1,localhost',
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1', DISABLE_AUTOUPDATER: '1',
  GITHUB_TOKEN: 'ghp-stand-in-user-token' };
const lines = [`platform ${process.platform}, claude ${path.basename(claude)}, loopback only`];
for (const [i, plugin] of plugins.entries()) {
  const T = await import(`${pathToFileURL(path.join(plugin, 'scripts', 'trial.mjs')).href}?${i}`);
  const cwd = path.join(work, `copy${i}`), outside = path.join(work, `outside${i}`);
  for (const d of [cwd, outside]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'OUTSIDE-LINE\n');
  fs.writeFileSync(path.join(cwd, 'inside.txt'), 'INSIDE-LINE\n');
  const saved = process.env;
  process.env = { ...base };
  const env = T.childEnv();
  process.env = saved;
  const args = T.childArgs('Do the task.', ['Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash(printenv GITHUB_TOKEN)']);
  script = [
    { id: 'write outside', name: 'Write', input: { file_path: path.join(outside, 'written.txt'), content: 'x\n' } },
    { id: 'read outside', name: 'Read', input: { file_path: path.join(outside, 'secret.txt') } },
    { id: 'edit outside', name: 'Edit', input: { file_path: path.join(outside, 'secret.txt'), old_string: 'OUTSIDE', new_string: 'EDITED' } },
    { id: 'glob outside', name: 'Glob', input: { pattern: '*.txt', path: outside } },
    { id: 'grep outside', name: 'Grep', input: { pattern: 'LINE', path: outside, output_mode: 'content' } },
    { id: 'write inside', name: 'Write', input: { file_path: path.join(cwd, 'made.txt'), content: 'x\n' } },
    { id: 'read inside', name: 'Read', input: { file_path: path.join(cwd, 'inside.txt') } },
    { id: 'edit inside', name: 'Edit', input: { file_path: path.join(cwd, 'inside.txt'), old_string: 'INSIDE', new_string: 'EDITED' } },
    { id: 'the token in the session', name: 'Bash', input: { command: 'printenv GITHUB_TOKEN', description: 'Print a variable' } },
  ].map((c) => ({ ...c, id: `toolu_${c.id.replace(/ /g, '_')}` }));
  results = new Map();
  const ids = script.map((c) => c.id);
  const code = await new Promise((done) => {
    const c = spawn(claude, args, { cwd, env, stdio: 'ignore', windowsHide: true });
    const t = setTimeout(() => c.kill(), 120_000);
    c.on('close', (k) => { clearTimeout(t); done(k); });
  });
  lines.push('', `plugin folder ${i + 1}, exit ${code}`, `  --tools ${args.slice(args.indexOf('--tools') + 1, args.includes('--allowedTools') ? args.indexOf('--allowedTools') : undefined).join(' ')}`,
    `  --allowedTools ${args.includes('--allowedTools') ? args.slice(args.indexOf('--allowedTools') + 1).join(' ') : '(none)'}`, `  user token in the session's environment: ${'GITHUB_TOKEN' in env}`);
  for (const [id, r] of ids.map((k) => [k, results.get(k) ?? { error: true, text: '(no result)' }])) lines.push(`  ${r.error ? 'error ' : 'ran   '}  ${id.slice(6).replace(/_/g, ' ')}: ${r.text.split(work).join('<work>').split(JSON.stringify(work).slice(1, -1)).join('<work>').slice(0, 110)}`);
  lines.push(`  on disk: outside written ${fs.existsSync(path.join(outside, 'written.txt'))}, outside edited ${fs.readFileSync(path.join(outside, 'secret.txt'), 'utf8').includes('EDITED')}, inside written ${fs.existsSync(path.join(cwd, 'made.txt'))}, inside edited ${fs.readFileSync(path.join(cwd, 'inside.txt'), 'utf8').includes('EDITED')}`);
}
lines.push('', `hosts refused by the proxy: ${refused.length ? refused.join(', ') : 'none'}; other API requests: ${other.length ? other.join(', ') : 'none'}`);
api.close(); proxy.close();
fs.rmSync(work, { recursive: true, force: true });
const out = path.join(path.dirname(fileURLToPath(import.meta.url)), 'results', `x3-loopback-trial-${process.platform}.txt`);
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${lines.join('\n')}\n`);
console.log(lines.join('\n'));
