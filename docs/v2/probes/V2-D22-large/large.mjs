// 06, section 5, 5d (D22): a synthetic repo of the field report's shape (179 document directories, about 850
// documents) on A1's fixture, and the checks on it.
//   node large.mjs <scratch> size <control plugin> <candidate plugin>            check 2: coverage and size
//   D17_CLAUDE=<pinned CLI> node large.mjs <scratch> pull <control plugin> <candidate plugin> [runs]   check 3
// Two binding documents are planted: D1 in a directory 2.4.0's cut keeps, D2 in one it drops. Results go to
// results/<size|pull>.json beside this file: counts and flags, no transcript text.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(HERE, '..', 'V2-D17-eval', 'fixture');
const CLAUDE = process.env.D17_CLAUDE ?? 'claude';
const MODEL = 'claude-opus-5-5';
const TASK = 'Create a UserAvatar component.';
const D1 = ['docs/accounts/avatars/avatar-sources.md', '# Avatar sources\n\nAvatars never load from the CDN; they use the local file at /static/avatars/<id>.png.\n'];
const D2 = ['docs/standards/components/component-files.md', '# Component files\n\nEvery new component file starts with the line // owner: web-platform\n'];
const DOMAINS = ['accounts', 'analytics', 'api', 'billing', 'catalog', 'checkout', 'design', 'frontend', 'growth', 'infra', 'mobile', 'ops', 'platform', 'search', 'security', 'standards', 'support'];
const TOPICS = ['architecture', 'avatars', 'components', 'decisions', 'errors', 'guides', 'incidents', 'onboarding', 'reviews', 'runbooks', 'testing'];
const WORDS = ['policy', 'overview', 'checklist', 'migration', 'retry', 'limits', 'naming', 'ownership', 'rollout', 'notes', 'faq', 'glossary'];

const git = (cwd, ...a) => { const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }); if (r.status) throw new Error(r.stderr); return r.stdout; };
const put = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };

// 17 domains x up to 11 topics, cut to 179 directories; 4 or 5 documents each, about 850 in all; deterministic
function makeRepo(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(FIXTURE, dir, { recursive: true });
  const dirs = DOMAINS.flatMap((d) => TOPICS.map((t) => `docs/${d}/${t}`)).slice(0, 179);
  let n = 0;
  dirs.forEach((d, i) => {
    for (let j = 0; j < 4 + (i % 4 === 0 ? 1 : 0) + (i % 7 === 0 ? 1 : 0); j++) {
      const name = `${WORDS[(i + j) % WORDS.length]}-${WORDS[(i * 3 + j) % WORDS.length]}-${j}.md`;
      put(path.join(dir, d, name), `# ${name.replace(/\.md$/, '')}\n\nNotes for ${d.slice(5)}. Nothing here binds the UI.\n`);
      n++;
    }
  });
  for (const [p, s] of [D1, D2]) put(path.join(dir, p), s);
  put(path.join(dir, '.claude', 'settings.local.json'), '{ "autoMemoryEnabled": false }\n');
  git(dir, 'init', '-q'); git(dir, 'add', '-A'); git(dir, 'commit', '-q', '-m', 'base');
  return { dirs: dirs.length, docs: n + 2 };
}

const start = async (plugin, repo) => {
  const m = await import(pathToFileURL(path.join(plugin, 'scripts', 'map.mjs')).href + `?${encodeURIComponent(plugin)}`);
  return m.startText(m.index(repo));
};
const covers = (text, file) => text.includes(`\n${path.posix.dirname(file)}/`) || text.includes(`\n${file.split('/')[0]}/** (`);

const [scratchArg, mode, control, candidate, runsArg = '5'] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });

if (mode === 'size') {
  const repo = path.join(scratch, 'size-repo');
  const shape = makeRepo(repo);
  const out = { shape };
  for (const [arm, p] of [['control', control], ['candidate', candidate]]) {
    const s = await start(path.resolve(p), repo);
    out[arm] = { mode: s.mode ?? (s.listed < s.total ? 'cut' : 'full'), listed: s.listed, total: s.total, chars: s.text.length, D1: covers(s.text, D1[0]), D2: covers(s.text, D2[0]) };
  }
  out.pass = out.candidate.listed === out.candidate.total && out.candidate.chars <= 10_000 && out.candidate.chars < out.control.chars;
  fs.writeFileSync(path.join(HERE, 'results', 'size.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out, null, 1));
} else if (mode === 'pull') {
  const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const k of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[k]; return e; };
  const runs = [];
  for (let i = 1; i <= Number(runsArg); i++) {
    for (const [arm, p] of [['control', control], ['candidate', candidate]]) {
      const repo = path.join(scratch, `${arm}-${i}`);
      makeRepo(repo);
      const args = ['-p', '--model', MODEL, '--setting-sources', 'project,local', '--strict-mcp-config',
        '--disallowedTools', 'Bash,WebFetch,WebSearch,Skill', '--permission-mode', 'acceptEdits',
        '--output-format', 'stream-json', '--verbose', '--plugin-dir', path.resolve(p)];
      const r = spawnSync(CLAUDE, args, { cwd: repo, input: TASK, encoding: 'utf8', env: env(), timeout: 1_200_000, maxBuffer: 256 << 20 });
      const ev = r.stdout.split('\n').flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
      const res = ev.find((e) => e.type === 'result') ?? {};
      const reads = ev.filter((e) => e.type === 'assistant').flatMap((e) => e.message?.content ?? []).filter((c) => c.type === 'tool_use' && c.name === 'Read').map((c) => String(c.input?.file_path ?? '').replace(/\\/g, '/'));
      const made = git(repo, 'status', '--porcelain', '-uall').split('\n').filter((l) => l.startsWith('??') && /^src\/.*\.(tsx?|jsx?)$/.test(l.slice(3))).map((l) => l.slice(3));
      const code = made.map((f) => fs.readFileSync(path.join(repo, f), 'utf8')).join('\n');
      const comp = made.find((f) => /UserAvatar\.(tsx|jsx|ts|js)$/.test(f));
      const firstLine = comp ? fs.readFileSync(path.join(repo, comp), 'utf8').split('\n').find((l) => l.trim()) ?? '' : '';
      const rec = {
        arm, run: i, valid: res.subtype === 'success' && !res.is_error && Boolean(comp),
        D1: /\/static\/avatars\//.test(code) && !/cdn/i.test(code.replace(/\/\/.*$/gm, '')),
        D2: firstLine.trim() === '// owner: web-platform',
        readD1: reads.some((f) => f.endsWith(D1[0])), readD2: reads.some((f) => f.endsWith(D2[0])), reads: reads.length,
        costUsd: Math.round((res.total_cost_usd ?? 0) * 100) / 100,
      };
      runs.push(rec);
      console.log(JSON.stringify(rec));
    }
  }
  const sum = (arm) => { const rs = runs.filter((r) => r.arm === arm && r.valid); const n = (k) => rs.filter((r) => r[k]).length; return { valid: rs.length, D1: n('D1'), D2: n('D2'), readD1: n('readD1'), readD2: n('readD2') }; };
  const out = { model: MODEL, cli: spawnSync(CLAUDE, ['--version'], { encoding: 'utf8', env: env() }).stdout.trim(), control: sum('control'), candidate: sum('candidate'), runs };
  out.pass = out.candidate.D1 >= 4 && out.candidate.D2 >= out.control.D2;
  fs.writeFileSync(path.join(HERE, 'results', 'pull.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ control: out.control, candidate: out.candidate, pass: out.pass }));
}
