// Probe P1 for V2-D12: which context channels arrive in which agent, at which moment.
// Usage: node probe.mjs <scratch-dir> [runs=3] [--only S|A|K|W]
// Each run builds a fresh repo and probe plugin with new nonces under <scratch-dir>, runs `claude -p` sessions,
// keeps the raw stream there, and writes the scored result (no paths) to results.json next to this script.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
if (!process.argv[2]) throw new Error('usage: node probe.mjs <scratch-dir> [runs] [--only S|A|K|W]');
const scratch = path.resolve(process.argv[2]);
const RUNS = Number(process.argv[3] ?? 3);
const ONLY = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1] : null;

const CODES = ['CM', 'IM', 'UR', 'PR', 'NC', 'PS', 'KS', 'SS', 'SC', 'SA', 'UP', 'MI', 'AM', 'NEG', 'W', 'WN'];
const NONCE_RE = /PRB-[A-Z]+-[0-9a-f]{6}/;
const SUBAGENTS = ['Explore', 'Plan', 'general-purpose', 'prb:lister'];
const LIST = 'every token in your context that begins with "PRB-", one per line, copied exactly, or "none"';

const PROMPT_S = `This is a test of which text is in your context. Follow the steps exactly and do nothing else.
Step 1. Without using any tool, write the heading START on its own line, then ${LIST}.
Step 2. Use the Read tool on src/a.ts.
Step 3. Without using any other tool, write the heading AFTER-READ on its own line, then ${LIST}.`;
// Subagents answer in one final message, so start and after-read are separate prompts. Each runs in its own session
// because path-activated state (skills) is shared within a session; the main session touches no file.
const SUB = {
  start: `This is a test of which text is in your context. Without using any tool, reply with ${LIST}. Do nothing else.`,
  read: `This is a test of which text is in your context. Use the Read tool on src/a.ts, then reply with ${LIST}. Do nothing else.`,
};
const promptA = (type, sub) => `Your only task: launch one agent with the Agent tool, subagent_type "${type}", giving it exactly the prompt between the two lines of dashes below, copied character for character, with nothing added or removed. Use no other tool. When it finishes, reply with the single word DONE.
-----
${sub}
-----`;
// Sent one turn at a time: a message queued mid-turn reaches the model as an attachment, not a prompt.
const TURNS_K = ['Use the Read tool on src/a.ts, then reply with only the number of lines in that file.', '/compact',
  `Without using any tool, write the heading AFTER-COMPACT on its own line, then ${LIST}.`];
const PROMPT_W = `Create the file src/components/Avatar.tsx: a minimal React component named Avatar that renders an img with src and alt props. Use the Write tool directly as your first tool call; do not read, list or search anything first. After writing, follow any instructions that apply to the file. Then, without using any tool, write the heading AFTER-WRITE on its own line, then ${LIST}.`;

const HOOK_SRC = `const N = require('./nonces.json'); const k = process.argv[2];
const ev = { SS: 'SessionStart', SC: 'SessionStart', SA: 'SubagentStart', UP: 'UserPromptSubmit' }[k];
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: 'Marker: ' + N[k] } }));
`;
const MCP_SRC = `const N = require('./nonces.json');
require('readline').createInterface({ input: process.stdin }).on('line', (l) => {
  let m; try { m = JSON.parse(l); } catch { return; }
  if (m.id === undefined) return;
  const r = {
    initialize: { protocolVersion: m.params && m.params.protocolVersion, capabilities: { tools: {} },
      serverInfo: { name: 'prb', version: '0.0.1' }, instructions: 'Marker: ' + N.MI },
    'tools/list': { tools: [{ name: 'ping', description: 'Returns pong.', inputSchema: { type: 'object', properties: {} } }] },
    'tools/call': { content: [{ type: 'text', text: 'pong' }] },
    ping: {},
  }[m.method];
  const out = r ? { jsonrpc: '2.0', id: m.id, result: r } : { jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'not found' } };
  process.stdout.write(JSON.stringify(out) + '\\n');
});
`;

const nonce = (code) => `PRB-${code}-${crypto.randomBytes(3).toString('hex')}`;
function put(root, rel, text) {
  const f = path.join(root, rel);
  fs.mkdirSync(path.dirname(f), { recursive: true });
  fs.writeFileSync(f, text);
}

function fixture(dir, N) {
  const repo = path.join(dir, 'repo');
  const plugin = path.join(dir, 'plugin');
  const paths = (g) => `---\npaths:\n  - "${g}"\n---\n`;
  put(repo, 'CLAUDE.md', `# Project notes\n\nMarker: ${N.CM}\n\n@docs/imported.md\n`);
  put(repo, 'docs/imported.md', `Imported note. Marker: ${N.IM}\n`);
  put(repo, 'docs/unused.md', `Unused note. Marker: ${N.NEG}\n`); // negative control: nothing loads it
  put(repo, '.claude/rules/general.md', `General rule. Marker: ${N.UR}\n`);
  put(repo, '.claude/rules/src.md', `${paths('src/**')}Source rule. Marker: ${N.PR}\n`);
  put(repo, '.claude/rules/components.md',
    `${paths('src/components/**')}Every new file under src/components/ must start with this exact first line:\n// ${N.W}\n`);
  put(repo, 'src/CLAUDE.md', `Source folder notes. Marker: ${N.NC}\n`);
  put(repo, 'src/components/CLAUDE.md', `Every new file in this folder must end with this exact last line:\n// ${N.WN}\n`);
  put(repo, 'src/a.ts', 'export const a = 1;\n');
  put(repo, '.claude/skills/src-helper/SKILL.md',
    `---\nname: src-helper\ndescription: Helper for files under src. Marker ${N.PS}\npaths:\n  - "src/**"\n---\nNothing to do.\n`);
  put(repo, '.mem/MEMORY.md', `- Memory note. Marker: ${N.AM}\n`);
  put(repo, '.claude/settings.local.json', JSON.stringify({ autoMemoryDirectory: path.join(repo, '.mem') }, null, 2));
  spawnSync('git', ['init', '-q'], { cwd: repo });

  const hook = (k) => ({ type: 'command', command: `node "\${CLAUDE_PLUGIN_ROOT}/hook.cjs" ${k}` });
  put(plugin, '.claude-plugin/plugin.json', JSON.stringify({ name: 'prb', version: '0.0.1', description: 'Channel probe' }));
  put(plugin, 'nonces.json', JSON.stringify(N));
  put(plugin, 'hook.cjs', HOOK_SRC);
  put(plugin, 'mcp.cjs', MCP_SRC);
  put(plugin, 'hooks/hooks.json', JSON.stringify({
    hooks: {
      SessionStart: [{ matcher: 'startup', hooks: [hook('SS')] }, { matcher: 'compact', hooks: [hook('SC')] }],
      SubagentStart: [{ hooks: [hook('SA')] }],
      UserPromptSubmit: [{ hooks: [hook('UP')] }],
    },
  }, null, 2));
  put(plugin, '.mcp.json', JSON.stringify({ mcpServers: { prb: { command: 'node', args: ['${CLAUDE_PLUGIN_ROOT}/mcp.cjs'] } } }));
  put(plugin, 'agents/lister.md',
    '---\nname: lister\ndescription: Follows test instructions about context markers.\ntools: Read\n---\nFollow the user\'s instructions exactly.\n');
  put(plugin, 'skills/comp-helper/SKILL.md',
    `---\nname: comp-helper\ndescription: Helper for source files. Marker ${N.KS}\npaths:\n  - "src/**"\n---\nNothing to do.\n`);
  return { repo, plugin };
}

const ARGS = (plugin) => ['-p', '--model', 'haiku', '--setting-sources', 'project,local', '--plugin-dir', plugin,
  '--disallowedTools', 'Bash,Grep,Glob,WebFetch,WebSearch', '--permission-mode', 'acceptEdits',
  '--output-format', 'stream-json', '--verbose'];
function ENV() {
  const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
  delete env.CLAUDECODE;
  delete env.CLAUDE_CODE_ENTRYPOINT;
  return env;
}
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });

function claude(fx, prompt, rawFile) {
  const r = spawnSync('claude', ARGS(fx.plugin), { cwd: fx.repo, input: prompt, encoding: 'utf8', env: ENV(), timeout: 900_000, maxBuffer: 256 << 20 });
  fs.writeFileSync(rawFile, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
}

// One process, one user message per turn: the next is sent only after the previous turn's result event.
function claudeTurns(fx, turns, rawFile) {
  return new Promise((resolve) => {
    const child = spawn('claude', [...ARGS(fx.plugin), '--input-format', 'stream-json'], { cwd: fx.repo, env: ENV() });
    let raw = '';
    let buf = '';
    let i = 0;
    const send = () => {
      if (i < turns.length) child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: turns[i++] } })}\n`);
      else child.stdin.end();
    };
    child.stdout.on('data', (d) => {
      raw += d;
      buf += d;
      for (let n = buf.indexOf('\n'); n >= 0; n = buf.indexOf('\n')) {
        const line = buf.slice(0, n);
        buf = buf.slice(n + 1);
        if (parse(line)[0]?.type === 'result') send();
      }
    });
    child.stderr.on('data', (d) => { raw += `\n#stderr ${d}`; });
    const timer = setTimeout(() => child.kill(), 900_000);
    child.on('close', () => { clearTimeout(timer); fs.writeFileSync(rawFile, raw); resolve(parse(raw)); });
    send();
  });
}

const parentOf = (e) => e.parent_tool_use_id ?? null;
const blocks = (ev, type, parent) => ev.filter((e) => e.type === 'assistant' && (parent === undefined || parentOf(e) === parent))
  .flatMap((e) => (e.message?.content ?? []).filter((c) => c.type === type));
const text = (ev, parent) => blocks(ev, 'text', parent).map((b) => b.text).join('\n');
const resultText = (ev, id) => ev.filter((e) => e.type === 'user').flatMap((e) => e.message?.content ?? [])
  .filter((c) => c.type === 'tool_result' && c.tool_use_id === id)
  .map((c) => (typeof c.content === 'string' ? c.content : (c.content ?? []).map((x) => x.text ?? '').join('\n'))).join('\n');
const after = (t, h) => { const i = t.indexOf(h); return i < 0 ? null : [t.slice(0, i), t.slice(i)]; };
const seen = (t, N) => (t == null ? null : Object.fromEntries(CODES.map((c) => [c, t.includes(N[c])])));
const filePaths = (ev, name) => blocks(ev, 'tool_use').filter((b) => b.name === name)
  .map((b) => String(b.input?.file_path ?? '').replace(/\\/g, '/'));
const FILE_TOOLS = ['Read', 'Write', 'Edit', 'NotebookEdit'];

function sessionS(fx, N, dir) {
  const ev = claude(fx, PROMPT_S, path.join(dir, 'S.jsonl'));
  const main = after(text(ev, null), 'AFTER-READ');
  return {
    ev,
    cells: { 'main.start': seen(main?.[0], N), 'main.afterRead': seen(main?.[1], N) },
    invalid: main ? [] : ['S: no AFTER-READ heading'],
  };
}

function sessionA(fx, N, dir, type, phase) {
  const cell = `${type}.${phase === 'start' ? 'start' : 'afterRead'}`;
  const ev = claude(fx, promptA(type, SUB[phase]), path.join(dir, `A-${type.replace(':', '-')}-${phase}.jsonl`));
  const tools = blocks(ev, 'tool_use', null);
  const a = tools.find((b) => (b.name === 'Agent' || b.name === 'Task') && b.input?.subagent_type === type);
  if (!a) return { ev, cells: {}, invalid: [`${cell}: not launched`] };
  const invalid = [];
  const before = tools.slice(0, tools.indexOf(a)).filter((b) => FILE_TOOLS.includes(b.name));
  if (before.length) invalid.push(`${cell}: main used ${before[0].name} first`);
  if (NONCE_RE.test(a.input?.prompt ?? '')) invalid.push(`${cell}: nonce in its prompt`);
  const subTools = blocks(ev, 'tool_use', a.id).filter((b) => FILE_TOOLS.includes(b.name));
  if (phase === 'start' && subTools.length) invalid.push(`${cell}: subagent used ${subTools.map((b) => b.name).join(', ')}`);
  const ok = (b) => ev.some((e) => e.type === 'user' && (e.message?.content ?? []).some((c) => c.type === 'tool_result' && c.tool_use_id === b.id && !c.is_error));
  if (phase === 'read' && !subTools.some((b) => b.name === 'Read' && ok(b))) invalid.push(`${cell}: subagent read failed or missing`);
  const t = `${text(ev, a.id)}\n${resultText(ev, a.id)}`;
  if (!/PRB-|none/i.test(t)) invalid.push(`${cell}: no answer`);
  return { ev, cells: { [cell]: seen(t, N) }, invalid };
}

async function sessionK(fx, N, dir) {
  const ev = await claudeTurns(fx, TURNS_K, path.join(dir, 'K.jsonl'));
  const invalid = [];
  if (!ev.some((e) => e.type === 'system' && e.subtype === 'compact_boundary')) invalid.push('K: no compact boundary');
  const t = after(text(ev, null), 'AFTER-COMPACT');
  if (!t) invalid.push('K: no AFTER-COMPACT heading');
  if (t && NONCE_RE.test(t[0])) invalid.push('K: nonce quoted before compaction');
  return { ev, cells: { 'main.afterCompact': seen(t?.[1], N) }, invalid };
}

function sessionW(fx, N, dir) {
  const ev = claude(fx, PROMPT_W, path.join(dir, 'W.jsonl'));
  const invalid = [];
  const tools = blocks(ev, 'tool_use', null).filter((b) => FILE_TOOLS.includes(b.name));
  const first = tools.find((b) => b.name === 'Write' && /Avatar\.tsx$/.test(b.input?.file_path ?? ''));
  if (!first) invalid.push('W: no Write of Avatar.tsx');
  if (first && tools.indexOf(first) !== 0) invalid.push(`W: first file tool was ${tools[0].name}`);
  const file = path.join(fx.repo, 'src/components/Avatar.tsx');
  const t = after(text(ev, null), 'AFTER-WRITE');
  return {
    ev,
    cells: {
      'write.inFirstWrite': first ? seen(first.input.content ?? '', N) : null,
      'write.inFinalFile': fs.existsSync(file) ? seen(fs.readFileSync(file, 'utf8'), N) : null,
      'write.listedAfter': seen(t?.[1], N),
    },
    invalid,
  };
}

const sessions = [['S', sessionS],
  ...SUBAGENTS.flatMap((t) => ['start', 'read'].map((p) => [`A:${t}:${p}`, (f, n, d) => sessionA(f, n, d, t, p)])),
  ['K', sessionK], ['W', sessionW]];
const version = spawnSync('claude', ['--version'], { encoding: 'utf8', env: ENV() }).stdout.trim();
const runs = [];
for (let i = 1; i <= RUNS; i++) {
  const dir = path.join(scratch, `run${i}`);
  fs.rmSync(dir, { recursive: true, force: true });
  const N = Object.fromEntries(CODES.map((c) => [c, nonce(c)]));
  const fx = fixture(dir, N);
  const run = { run: i, cells: {}, invalid: [], badCells: [] };
  for (const [name, fn] of sessions) {
    if (ONLY && !name.startsWith(ONLY)) continue;
    const r = await fn(fx, N, dir);
    const bad = [...r.invalid];
    // Only the trigger file may be read; W may re-read the file it wrote.
    const stray = filePaths(r.ev, 'Read').filter((p) => !p.endsWith('src/a.ts') && !(name === 'W' && p.endsWith('Avatar.tsx')));
    if (stray.length) bad.push(`${name}: direct read of ${stray.map((p) => path.basename(p)).join(', ')}`);
    if (JSON.stringify(r.ev).includes(N.NEG)) bad.push(`${name}: negative control quoted`);
    const mcp = (r.ev.find((e) => e.type === 'system' && e.subtype === 'init')?.mcp_servers ?? []).find((s) => s.name.includes('prb'));
    if (mcp?.status !== 'connected') bad.push(`${name}: probe MCP server ${mcp?.status ?? 'missing'}`);
    Object.assign(run.cells, r.cells);
    run.invalid.push(...bad);
    if (bad.length) run.badCells.push(...Object.keys(r.cells)); // a faulty session voids only its own cells
  }
  // Without the positive control the listing method itself failed, so the whole run is void.
  if (run.cells['main.start'] && !run.cells['main.start'].CM) {
    run.invalid.push('S: positive control (CLAUDE.md) not quoted');
    run.badCells.push(...Object.keys(run.cells));
  }
  runs.push(run);
  console.log(`run ${i}: ${run.invalid.length ? run.invalid.join('; ') : 'valid'}`);
}

// Per cell and channel: hits over the runs valid for that cell. 3/3 arrives, 0/3 does not, else unreliable (PM2);
// a cell with fewer than 3 valid runs fails the check.
const summary = {};
for (const cell of new Set(runs.flatMap((r) => Object.keys(r.cells)))) {
  const ok = runs.filter((r) => r.cells[cell] && !r.badCells.includes(cell));
  summary[cell] = Object.fromEntries(CODES.map((c) => [c, `${ok.filter((r) => r.cells[cell][c]).length}/${ok.length}`]));
}
const validRuns = runs.filter((r) => r.invalid.length === 0).length;
const out = { date: new Date().toISOString().slice(0, 10), cli: version, model: 'haiku', runs: RUNS, validRuns, summary, perRun: runs };
fs.writeFileSync(path.join(HERE, ONLY ? `results-${ONLY}.json` : 'results.json'), `${JSON.stringify(out, null, 2)}\n`);
for (const [cell, row] of Object.entries(summary)) console.log(cell.padEnd(28), Object.entries(row).map(([c, v]) => `${c}=${v}`).join(' '));
