// 06, section 6, check 3: the setup skill on a repo set up by 2.3.0. The rule and the review skill are 2.3.0's
// templates; the map's README is 2.3.0's with one line of the repo's own, all committed. Each run: /second-brain:setup
// in -p from the candidate copy, then the same session resumed with "yes".
//   node upgrade.mjs <scratch> <candidate plugin> [runs]
// Writes results/upgrade.json beside this file: flags per run, no transcript text.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EARLIER = path.join(HERE, '..', '..', '..', '..', 'plugin', 'test', 'earlier', '2.3.0');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
const OWN = 'Entries about the public API go in api.md.';
const [scratch, candidate, runsArg = '3'] = process.argv.slice(2);
const plugin = path.resolve(candidate);
const FILES = [['claude/rules/project-map.md', '.claude/rules/project-map.md'], ['claude/skills/map-review/SKILL.md', '.claude/skills/map-review/SKILL.md'], ['project-map/README.md', '.project-map/README.md']];

const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const read = (f) => fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
const template = (from) => read(path.join(plugin, 'templates', from));

function session(dir, input, resume) {
  const r = spawnSync(CLAUDE, ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
    '--allowedTools', 'Bash(git diff:*)', '--permission-mode', 'acceptEdits', '--plugin-dir', plugin, '--output-format', 'json', ...(resume ? ['--resume', resume] : [])],
  { cwd: dir, input, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 64 << 20 });
  let res = {};
  try { res = JSON.parse(r.stdout); } catch {}
  return { ok: res.subtype === 'success' && !res.is_error, text: String(res.result ?? ''), sid: res.session_id ?? null, usd: res.total_cost_usd ?? 0 };
}

function run(i) {
  const dir = path.join(path.resolve(scratch), `upgrade-${i}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  git(dir, 'init', '-q');
  fs.writeFileSync(path.join(dir, 'README.md'), '# r\n');
  for (const [from, to] of FILES) { fs.mkdirSync(path.dirname(path.join(dir, to)), { recursive: true }); fs.copyFileSync(path.join(EARLIER, from), path.join(dir, to)); }
  const readme = path.join(dir, '.project-map', 'README.md');
  fs.appendFileSync(readme, `\n${OWN}\n`);
  fs.writeFileSync(path.join(dir, '.claude', 'settings.local.json'), '{ "autoMemoryEnabled": false }\n'); // keeps the user's own memory folders out
  git(dir, 'add', '-A'); git(dir, 'commit', '-q', '-m', 'set up by 2.3.0');
  const own = read(readme);
  const a = session(dir, '/second-brain:setup');
  const updated = FILES.slice(0, 2).every(([from, to]) => read(path.join(dir, to)) === template(from));
  const untouched = read(readme) === own;
  // the lines the README lacks: the placement table's heading is one of them
  const shown = a.ok && /Where it belongs/.test(a.text);
  const asked = a.ok && /\?/.test(a.text);
  const b = a.sid ? session(dir, 'yes', a.sid) : { ok: false, usd: 0 };
  const after = read(readme).split('\n').map((l) => l.trimEnd());
  const merged = b.ok && template('project-map/README.md').split('\n').filter((l) => l.trim()).every((l) => after.includes(l.trimEnd())) && after.includes(OWN);
  return { run: i, valid: a.ok && b.ok, updated, untouched, shown, asked, merged, usd: Math.round((a.usd + b.usd) * 100) / 100 };
}

fs.mkdirSync(path.resolve(scratch), { recursive: true });
const results = [];
for (let i = 1; i <= Number(runsArg); i++) { results.push(run(i)); console.log(JSON.stringify(results.at(-1))); }
const n = (k) => results.filter((r) => r[k]).length;
const summary = { runs: results.length, valid: n('valid'), updated: n('updated'), untouched: n('untouched'), shown: n('shown'), asked: n('asked'), merged: n('merged') };
summary.pass = ['valid', 'updated', 'untouched', 'shown', 'asked', 'merged'].every((k) => summary[k] === results.length);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
fs.writeFileSync(path.join(HERE, 'results', 'upgrade.json'), `${JSON.stringify({ plugin: path.basename(plugin), model: MODEL, results, summary }, null, 2)}\n`);
console.log(JSON.stringify(summary));
