// V2-D12, build step 0 (pre-registered in DECISIONS.md): do plugin SessionStart on `clear` and `resume` reach the main
// session, and does a plugin PostToolUse after a Read reach a subagent that made the Read? D12's method: a fresh repo
// and probe plugin per run, a new nonce per channel, Haiku, user settings excluded, search tools and the web denied.
//   node step0.mjs <scratch-dir> [runs]
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
if (!process.argv[2]) throw new Error('usage: node step0.mjs <scratch-dir> [runs]');
const scratch = path.resolve(process.argv[2]);
const RUNS = Number(process.argv[3] ?? 3);
const LIST = 'every token in your context that begins with "PRB-", one per line, copied exactly, or "none"';
const nonce = (code) => `PRB-${code}-${crypto.randomBytes(3).toString('hex')}`;
const HOOK_SRC = `const N = require('./nonces.json'); const k = process.argv[2];
const ev = { SS: 'SessionStart', CL: 'SessionStart', RE: 'SessionStart', PT: 'PostToolUse' }[k];
process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: ev, additionalContext: 'Marker: ' + N[k] } }));
`;
const put = (root, rel, text) => { const f = path.join(root, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };

function fixture(dir, N) {
  const repo = path.join(dir, 'repo');
  const plugin = path.join(dir, 'plugin');
  put(repo, 'CLAUDE.md', `# Project notes\n\nMarker: ${N.CM}\n`);
  put(repo, 'docs/unused.md', `Unused note. Marker: ${N.NEG}\n`);
  put(repo, 'src/a.ts', 'export const a = 1;\n');
  spawnSync('git', ['init', '-q'], { cwd: repo });
  const hook = (k) => ({ type: 'command', command: `node "\${CLAUDE_PLUGIN_ROOT}/hook.cjs" ${k}` });
  put(plugin, '.claude-plugin/plugin.json', JSON.stringify({ name: 'prb', version: '0.0.1', description: 'Channel probe' }));
  put(plugin, 'nonces.json', JSON.stringify(N));
  put(plugin, 'hook.cjs', HOOK_SRC);
  put(plugin, 'hooks/hooks.json', JSON.stringify({ hooks: {
    SessionStart: [{ matcher: 'startup', hooks: [hook('SS')] }, { matcher: 'clear', hooks: [hook('CL')] }, { matcher: 'resume', hooks: [hook('RE')] }],
    PostToolUse: [{ matcher: 'Read', hooks: [hook('PT')] }],
  } }, null, 2));
  return { repo, plugin };
}

const ARGS = (plugin, extra = []) => ['-p', '--model', 'haiku', '--setting-sources', 'project,local', '--plugin-dir', plugin,
  '--disallowedTools', 'Bash,Grep,Glob,WebFetch,WebSearch', '--permission-mode', 'acceptEdits', '--output-format', 'stream-json', '--verbose', ...extra];
const ENV = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; delete e.CLAUDECODE; delete e.CLAUDE_CODE_ENTRYPOINT; return e; };
const parse = (s) => s.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
const claude = (fx, prompt, raw, extra = []) => {
  const r = spawnSync('claude', ARGS(fx.plugin, extra), { cwd: fx.repo, input: prompt, encoding: 'utf8', env: ENV(), timeout: 900_000, maxBuffer: 256 << 20 });
  fs.writeFileSync(raw, (r.stdout ?? '') + (r.stderr ? `\n#stderr ${r.stderr}` : ''));
  return parse(r.stdout ?? '');
};
const claudeTurns = (fx, turns, raw) => new Promise((resolve) => {
  const child = spawn('claude', [...ARGS(fx.plugin), '--input-format', 'stream-json'], { cwd: fx.repo, env: ENV() });
  let out = ''; let buf = ''; let i = 0;
  const send = () => { if (i < turns.length) child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: turns[i++] } })}\n`); else child.stdin.end(); };
  child.stdout.on('data', (d) => {
    out += d; buf += d;
    for (let n = buf.indexOf('\n'); n >= 0; n = buf.indexOf('\n')) { const line = buf.slice(0, n); buf = buf.slice(n + 1); if (parse(line)[0]?.type === 'result') send(); }
  });
  child.stderr.on('data', (d) => { out += `\n#stderr ${d}`; });
  const timer = setTimeout(() => child.kill(), 900_000);
  child.on('close', () => { clearTimeout(timer); fs.writeFileSync(raw, out); resolve(parse(out)); });
  send();
});
// assistant text by thread: main (no parent) or the subagent's (parent set)
const said = (ev, sub) => ev.filter((e) => e.type === 'assistant' && (sub ? !!e.parent_tool_use_id : !e.parent_tool_use_id))
  .flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('\n');
// text after the last result before the final turn: the final turn's own answer
const lastTurn = (ev) => { const r = ev.map((e, i) => (e.type === 'result' ? i : -1)).filter((i) => i >= 0); return ev.slice(r.length > 1 ? r.at(-2) + 1 : 0); };

const results = { date: new Date().toISOString().slice(0, 10), runs: RUNS, cells: { CL: [], RE: [], 'PT-sub:Explore': [], 'PT-sub:general-purpose': [] } };
for (let run = 1; run <= RUNS; run++) {
  const dir = path.join(scratch, `run${run}`);
  fs.rmSync(dir, { recursive: true, force: true });
  const N = Object.fromEntries(['CM', 'NEG', 'SS', 'CL', 'RE', 'PT'].map((k) => [k, nonce(k)]));
  const fx = fixture(dir, N);
  const has = (t, k) => t.includes(N[k]);

  // CL: reply OK, /clear, then list
  const cl = await claudeTurns(fx, ['Reply with the single word OK.', '/clear', `Without using any tool, list ${LIST}.`], path.join(dir, 'cl.jsonl'));
  const clText = said(lastTurn(cl), false);
  results.cells.CL.push({ run, arrived: has(clText, 'CL'), startupAfterClear: has(clText, 'SS'), positive: has(clText, 'CM'), negative: has(clText, 'NEG'),
    clearSource: cl.some((e) => e.type === 'system' && /clear/i.test(JSON.stringify(e).slice(0, 400))) });

  // RE: one process, then --resume it
  const a = claude(fx, 'Reply with the single word OK.', path.join(dir, 're1.jsonl'));
  const id = a.find((e) => e.session_id)?.session_id;
  const b = id ? claude(fx, `Without using any tool, list ${LIST}.`, path.join(dir, 're2.jsonl'), ['--resume', id]) : [];
  const reText = said(b, false);
  results.cells.RE.push({ run, sessionId: !!id, arrived: has(reText, 'RE'), positive: has(reText, 'CM'), negative: has(reText, 'NEG') });

  // PT-sub: a subagent reads src/a.ts and lists
  for (const type of ['Explore', 'general-purpose']) {
    const p = `Your only task: launch one agent with the Agent tool, subagent_type "${type}", giving it exactly this prompt: "Use the Read tool on src/a.ts. Then, without any other tool, reply with ${LIST}." Use no other tool yourself. When it finishes, reply with the single word DONE.`;
    const ev = claude(fx, p, path.join(dir, `pt-${type}.jsonl`));
    const subText = said(ev, true);
    // scored as D12 scores: the model quoting the nonce; raw presence in the subagent's input is reported beside it
    const subInput = ev.filter((e) => e.type !== 'assistant' && e.parent_tool_use_id).map((e) => JSON.stringify(e)).join('\n');
    const readBySub = ev.some((e) => e.type === 'assistant' && e.parent_tool_use_id && (e.message?.content ?? []).some((c) => c.type === 'tool_use' && c.name === 'Read'));
    results.cells[`PT-sub:${type}`].push({ run, subRead: readBySub, inSubagent: has(subText, 'PT'), rawInSubagentInput: has(subInput, 'PT'),
      inMainText: has(said(ev, false), 'PT'), negative: has(subText, 'NEG') });
  }
  console.log(`run ${run}:`, JSON.stringify(Object.fromEntries(Object.entries(results.cells).map(([k, v]) => [k, v.at(-1)]))));
}
const verdict = (rows, key) => { const n = rows.filter((r) => r[key]).length; return n === rows.length ? 'arrives' : n === 0 ? 'does not arrive' : 'unreliable'; };
results.verdicts = { CL: verdict(results.cells.CL, 'arrived'), RE: verdict(results.cells.RE, 'arrived'),
  'PT-sub:Explore': verdict(results.cells['PT-sub:Explore'], 'inSubagent'), 'PT-sub:general-purpose': verdict(results.cells['PT-sub:general-purpose'], 'inSubagent') };
fs.writeFileSync(path.join(HERE, 'results-step0.json'), `${JSON.stringify(results, null, 1)}\n`);
console.log(JSON.stringify(results.verdicts));
