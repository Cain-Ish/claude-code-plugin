// 06, section 8, 8a, check 5: H1 live. One headless session on the candidate, in a scratch repo whose map holds an
// uncommitted entry, runs three Bash commands; the session's own transcript shows which got map labels.
//   node live8a.mjs <candidate plugin> <scratch folder>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const [plugin, scratch] = process.argv.slice(2).map((p) => path.resolve(p));
const repo = path.join(scratch, 'live8a-repo');
fs.rmSync(repo, { recursive: true, force: true });
fs.mkdirSync(path.join(repo, '.project-map'), { recursive: true });
const g = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: repo, encoding: 'utf8' });
const entry = (h, q) => `### ${h}\n> ${q}\n\n- source: the lead developer, 2026-11-08\n- when: ["work"]\n`;
g('init', '-q');
fs.writeFileSync(path.join(repo, '.project-map', 'decisions.md'), entry('dates', 'Dates show as DD.MM.YYYY across the app.'));
fs.writeFileSync(path.join(repo, 'README.md'), '# r\n');
g('add', '-A');
g('commit', '-qm', 'base');
fs.appendFileSync(path.join(repo, '.project-map', 'decisions.md'), `\n${entry('pricing', 'Prices round half up to whole cents.')}`);
const CMDS = ['echo $(date +%Y)', 'cat .project-map/decisions.md', "echo \"$(printf '### pricing\\n> Prices round half up to whole cents.')\""];
const prompt = `Run exactly these three Bash commands, one per Bash call, in this order, and nothing else. Then reply "done".\n1. ${CMDS[0]}\n2. ${CMDS[1]}\n3. ${CMDS[2]}`;
const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete env[k];
const r = spawnSync('claude', ['-p', prompt, '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch,PowerShell',
  '--permission-mode', 'acceptEdits', '--allowedTools', 'Bash', '--plugin-dir', plugin, '--output-format', 'json'], { cwd: repo, env, encoding: 'utf8', timeout: 900_000 });
const sid = JSON.parse(r.stdout || '{}').session_id;
const tdir = path.join(os.homedir(), '.claude', 'projects', fs.realpathSync.native(repo).replace(/[^A-Za-z0-9]/g, '-'));
const recs = fs.readFileSync(path.join(tdir, `${sid}.jsonl`), 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const calls = recs.filter((x) => x.type === 'assistant').flatMap((x) => (x.message?.content ?? []).filter((c) => c.type === 'tool_use' && c.name === 'Bash').map((c) => ({ id: c.id, command: c.input.command })));
const labelsFor = (id) => recs.filter((x) => JSON.stringify(x).includes(id) && JSON.stringify(x).includes('[project map]')).map((x) => JSON.stringify(x));
const rows = calls.map((c) => { const l = labelsFor(c.id).join(' '); return { command: c.command, labelled: l.length > 0, pricing: l.includes('pricing'), dates: l.includes('dates') }; });
const result = {
  sessionOk: Boolean(sid), calls: rows.length,
  echoDate: rows.find((x) => x.command.includes('date +%Y')),
  catMap: rows.find((x) => x.command.startsWith('cat .project-map')),
  printfEntry: rows.find((x) => x.command.includes('printf')),
};
// 06, 8a: a run counts only with exactly the three registered commands, in order; otherwise it is invalid, not failed
result.valid = rows.length === 3 && rows.every((x, i) => x.command === CMDS[i]);
result.pass = result.valid && Boolean(result.echoDate && !result.echoDate.labelled && result.catMap?.pricing && result.printfEntry?.pricing && !result.printfEntry?.dates);
fs.mkdirSync(path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), 'results'), { recursive: true });
fs.writeFileSync(path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), 'results', 'live8a.json'), `${JSON.stringify(result, null, 1)}\n`);
console.log(JSON.stringify(result, null, 1));
