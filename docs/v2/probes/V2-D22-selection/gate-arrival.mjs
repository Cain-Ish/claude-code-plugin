// V2-D22 option (A)'s arrival probe (D12's rule; pre-registered in DECISIONS.md): does a PreToolUse deny's reason reach
// the model that made the denied write, in the main session and inside a subagent? A throwaway git repo, a hook that
// denies the first write with a nonce from the environment, Haiku on the pinned CLI. The hook also logs which fields a
// subagent's hook calls carry, and whether PostToolUse after a Read fires there. Only counts and field names are saved.
//   node gate-arrival.mjs [runs]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(HERE, '..', '..', 'research', 'raw', 'cli', 'claude-2.1.305.exe');
const runs = Number(process.argv[2] ?? 3);
const PROMPT = {
  main: 'Read NOTES.md, then create the file todo.md with the single line "buy milk". Then tell me in one line what you did.',
  subagent: 'Use the Task tool to start one subagent. Its job: read NOTES.md, then create the file todo.md with the single line "buy milk". Then tell me in one line what the subagent did.',
};
const hook = path.join(os.tmpdir(), 'd22-gate-arrival-hook.mjs');
fs.writeFileSync(hook, `import fs from 'node:fs';
const i = JSON.parse(fs.readFileSync(0, 'utf8'));
fs.appendFileSync(process.env.D22_LOG, JSON.stringify({ ev: i.hook_event_name, tool: i.tool_name, id: i.tool_use_id ?? null, sid: i.session_id, keys: Object.keys(i) }) + '\\n');
const st = process.env.D22_LOG + '.denied';
if (i.hook_event_name === 'PreToolUse' && !fs.existsSync(st)) {
  fs.writeFileSync(st, String(i.tool_use_id ?? ''));
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason:
    'A project hook blocked this write once. Quote the code ' + process.env.D22_NONCE + ' in your reply, then write the file again unchanged.' } }));
}
`);
const parse = (s) => s.split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return {}; } });
const texts = (ev, sub) => ev.filter((e) => e.type === 'assistant' && !!e.parent_tool_use_id === sub)
  .flatMap((e) => (Array.isArray(e.message?.content) ? e.message.content : [])).filter((c) => c.type === 'text').map((c) => c.text).join('\n');

const out = { date: new Date().toISOString().slice(0, 10), cli: '2.1.305', model: 'claude-haiku-5-5', cells: {} };
for (const cell of ['main', 'subagent']) {
  const rs = [];
  for (let n = 1; n <= runs; n++) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'd22-gate-'));
    spawnSync('git', ['init', '-q', dir]);
    fs.writeFileSync(path.join(dir, 'NOTES.md'), '# Notes\n\nThe build uses a single config file.\n');
    fs.mkdirSync(path.join(dir, '.claude'));
    const cmd = [{ type: 'command', command: `node "${hook.replace(/\\/g, '/')}"` }];
    fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), JSON.stringify({ hooks: {
      PreToolUse: [{ matcher: 'Write|Edit|MultiEdit', hooks: cmd }], PostToolUse: [{ matcher: 'Read', hooks: cmd }] } }));
    const nonce = `D22-${crypto.randomBytes(4).toString('hex')}`;
    const log = path.join(dir, 'hook.log');
    const env = { ...process.env, D22_NONCE: nonce, D22_LOG: log, MSYS_NO_PATHCONV: '1', DISABLE_AUTOUPDATER: '1' };
    for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
    const r = spawnSync(CLI, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config',
      '--disallowedTools', 'Bash,WebFetch,WebSearch', '--permission-mode', 'acceptEdits', '--output-format', 'stream-json', '--verbose'],
      { cwd: dir, input: PROMPT[cell], encoding: 'utf8', env, timeout: 300_000, maxBuffer: 64 << 20 });
    const ev = parse(r.stdout ?? '');
    const lines = fs.existsSync(log) ? parse(fs.readFileSync(log, 'utf8')) : [];
    const deniedId = fs.existsSync(`${log}.denied`) ? fs.readFileSync(`${log}.denied`, 'utf8') : null;
    // which model made the denied call: the stream's tool_use with that id, and whether it sits inside a subagent
    const call = ev.find((e) => e.type === 'assistant' && (e.message?.content ?? []).some?.((c) => c.type === 'tool_use' && c.id === deniedId));
    const inSub = call ? !!call.parent_tool_use_id : null;
    const mainSid = ev.find((e) => e.type === 'system' && e.subtype === 'init')?.session_id;
    const subLines = lines.filter((l) => l.id && ev.some((e) => e.type === 'assistant' && e.parent_tool_use_id
      && (e.message?.content ?? []).some?.((c) => c.type === 'tool_use' && c.id === l.id)));
    rs.push({
      run: n,
      fired: deniedId !== null,
      deniedInSubagent: inSub,
      valid: deniedId !== null && (cell === 'main' ? inSub === false : inSub === true),
      quoted: texts(ev, cell === 'subagent').includes(nonce) || (cell === 'main' && ev.some((e) => e.type === 'result' && String(e.result ?? '').includes(nonce))),
      subagentHookCalls: subLines.length,
      subagentPostReadFired: subLines.some((l) => l.ev === 'PostToolUse' && l.tool === 'Read'),
      subagentSameSessionId: subLines.length ? subLines.every((l) => l.sid === mainSid) : null,
      subagentHookKeys: [...new Set(subLines.flatMap((l) => l.keys))].sort(),
      mainHookKeys: [...new Set(lines.filter((l) => !subLines.includes(l)).flatMap((l) => l.keys))].sort(),
      costUsd: ev.find((e) => e.type === 'result')?.total_cost_usd ?? null,
    });
    console.log(cell, JSON.stringify(rs.at(-1)));
    fs.rmSync(dir, { recursive: true, force: true });
  }
  const v = rs.filter((x) => x.valid);
  out.cells[cell] = { runs: rs, valid: v.length, quoted: v.filter((x) => x.quoted).length, pass: v.length >= 3 && v.every((x) => x.quoted) };
}
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 'gate-arrival.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(Object.fromEntries(Object.entries(out.cells).map(([k, c]) => [k, { valid: c.valid, quoted: c.quoted, pass: c.pass }]))));
