// 06, section 4, 4b, check 2 (registered before it ran): in a fresh repo whose only instruction file is a committed
// .claude/CLAUDE.md, /second-brain:setup in -p, from a copy of plugin/. Pass per run: no root CLAUDE.md; .claude/CLAUDE.md
// holds "## Team memory" exactly once; nothing committed.
//   D17_CLAUDE=<pinned 2.1.305> node smoke4b.mjs <scratch folder> [runs]
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const PLUGIN = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..', 'plugin');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const scratch = path.resolve(process.argv[2]);
const runs = Number(process.argv[3] ?? 3);
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
const copy = path.join(scratch, 'plugin');
fs.rmSync(copy, { recursive: true, force: true });
fs.cpSync(PLUGIN, copy, { recursive: true, filter: (s) => !s.split(path.sep).includes('test') });
const results = [];
for (let i = 1; i <= runs; i++) {
  const repo = path.join(scratch, `repo${i}`);
  fs.rmSync(repo, { recursive: true, force: true });
  fs.mkdirSync(path.join(repo, '.claude'), { recursive: true });
  const git = (...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd: repo, encoding: 'utf8' });
  git('init', '-q');
  fs.writeFileSync(path.join(repo, 'README.md'), '# Demo\n');
  fs.writeFileSync(path.join(repo, '.claude', 'CLAUDE.md'), '# Project guide\n\nRun the tests with `npm test`.\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'base');
  const head = git('rev-parse', 'HEAD').stdout.trim();
  const r = spawnSync(CLAUDE, ['-p', '--model', 'claude-haiku-5-5', '--setting-sources', 'project,local', '--strict-mcp-config',
    '--disallowedTools', 'WebFetch,WebSearch', '--permission-mode', 'acceptEdits', '--plugin-dir', copy, '--output-format', 'json'],
  { cwd: repo, input: '/second-brain:setup', encoding: 'utf8', env: env(), timeout: 900_000, maxBuffer: 64 << 20 });
  let reply = '';
  try { reply = String(JSON.parse(r.stdout).result ?? ''); } catch {}
  const inner = fs.readFileSync(path.join(repo, '.claude', 'CLAUDE.md'), 'utf8');
  const item = {
    run: i,
    exit: r.status,
    noRootClaudeMd: !fs.existsSync(path.join(repo, 'CLAUDE.md')),
    teamMemoryOnce: (inner.match(/^## Team memory$/gm) ?? []).length === 1,
    nothingCommitted: git('rev-parse', 'HEAD').stdout.trim() === head && git('rev-list', '--count', 'HEAD').stdout.trim() === '1',
    reply: reply.slice(0, 600),
  };
  item.pass = item.noRootClaudeMd && item.teamMemoryOnce && item.nothingCommitted;
  results.push(item);
  console.log(JSON.stringify(item));
}
fs.writeFileSync(path.join(scratch, 'smoke4b.json'), `${JSON.stringify(results, null, 1)}\n`);
console.log(`pass ${results.filter((x) => x.pass).length} of ${results.length}`);
