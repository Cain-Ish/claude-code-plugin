// 06, section 8, 8c, check 3: on a real repo's transcripts, read only, 8c's counter (the candidate's digestFrom) and
// D34's usage.mjs give the same number of sessions with a call, for each of that repo's own skills and agents. Typed
// /<name> uses, which usage.mjs does not count, are reported beside. Counts only; the artifacts are numbered, never
// named, and neither the repo nor its folder is written anywhere.
//   node fieldcount.mjs <candidate plugin> <repo path> <its folder under ~/.claude/projects>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const [plugin, repo, folder] = process.argv.slice(2);
const { digestFrom } = await import(pathToFileURL(path.join(path.resolve(plugin), 'scripts', 'dream.mjs')).href);
const tdir = path.join(os.homedir(), '.claude', 'projects', folder);
const own = (d, f) => { try { return fs.readdirSync(path.join(repo, '.claude', d), { withFileTypes: true }).flatMap(f); } catch { return []; } };
const skills = own('skills', (e) => (e.isDirectory() && fs.existsSync(path.join(repo, '.claude', 'skills', e.name, 'SKILL.md')) ? [e.name] : []));
const agents = own('agents', (e) => (e.isFile() && e.name.endsWith('.md') ? [e.name.slice(0, -3)] : []));

// 8c's counter: sessions with a call (and, beside, a typed use) per name, over every transcript from its start
const calls = { skill: new Map(), agent: new Map() }, typed = new Map();
let sessions = 0;
for (const f of fs.readdirSync(tdir).filter((x) => x.endsWith('.jsonl'))) {
  const dg = await digestFrom(path.join(tdir, f), 0, () => true);
  sessions++;
  for (const k of new Set(dg.uses.filter((u) => u.via === 'call').map((u) => `${u.kind}\0${u.name}`))) { const [kind, n] = k.split('\0'); calls[kind].set(n, (calls[kind].get(n) ?? 0) + 1); }
  for (const n of new Set(dg.uses.filter((u) => u.via === 'typed').map((u) => u.name))) typed.set(n, (typed.get(n) ?? 0) + 1);
}
// usage.mjs, run as it is, on the same folder
const u = spawnSync('node', [path.join(HERE, '..', 'V2-D34-repo-artifacts', 'usage.mjs'), folder], { encoding: 'utf8' }).stdout;
const parse = (label) => new Map((/(?:skills|agents) \(sessions\): (.*)/.exec(u.split('\n').find((l) => l.includes(label)) ?? '')?.[1] ?? '').split(', ').filter(Boolean).map((x) => { const i = x.lastIndexOf('='); return [x.slice(0, i), Number(x.slice(i + 1))]; }));
const ref = { skill: parse('sessions using a skill'), agent: parse('sessions using an agent') };
const rows = [...skills.map((n) => ['skill', n]), ...agents.map((n) => ['agent', n])].map(([kind, n], i) => ({
  artifact: `${kind} ${i + 1}`, usageMjs: ref[kind].get(n) ?? 0, eightC: calls[kind].get(n) ?? 0, typedBeside: kind === 'skill' ? typed.get(n) ?? 0 : null,
}));
const out = { date: new Date().toISOString().slice(0, 10), transcripts: sessions, artifacts: rows.length, rows, pass: rows.length > 0 && rows.every((r) => r.usageMjs === r.eightC) };
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 'fieldcount.json'), `${JSON.stringify(out, null, 1)}\n`);
console.log(JSON.stringify(out));
