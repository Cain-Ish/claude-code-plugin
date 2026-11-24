// 06, section 8, 8e, check 4: tailor's guardrails, in 7a's two fixture repos (probes/V2-D34-repo-artifacts/outcome/
// fixture and fixture2), through the shipped skill in headless sessions with the candidate plugin. Per repo, 3 runs of
// a request with a gap and 3 of one with none. Checked by script, counts only.
//   S8E_PLUGIN=<plugin> node guard8e.mjs <scratch> <first> <last>   then   node guard8e.mjs <scratch> summary
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, '..', 'V2-D34-repo-artifacts', 'outcome');
// 7a's two requests (run.mjs's REQUEST, written out here, since importing run.mjs would run its own probe)
const REQUEST = 'Make a skill or an agent for this repo that adds a database migration the way this project does it.';
const { PROCEDURE } = await import(pathToFileURL(path.join(OUT, 'grade2.mjs')).href);
const [scratchArg, firstArg, lastArg] = process.argv.slice(2);
const scratch = path.resolve(scratchArg);
const env = () => { const e = { ...process.env, MSYS_NO_PATHCONV: '1' }; for (const v of ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT']) delete e[v]; return e; };
const git = (cwd, ...a) => spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...a], { cwd, encoding: 'utf8' }).stdout ?? '';
const SETS = [
  ['fixture', 'gap', REQUEST],
  ['fixture2', 'gap', `Make a skill or an agent for this repo that does our pricing check: ${PROCEDURE}`],
  ['fixture', 'none', 'Make agents for this repo.'],
  ['fixture2', 'none', 'Make agents for this repo.'],
];
const walk = (d, base = d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.name === '.git' ? [] : e.isDirectory() ? walk(path.join(d, e.name), base) : [path.relative(base, path.join(d, e.name)).split(path.sep).join('/')]));

function runOne(i) {
  for (const [fx, kind, prompt] of SETS) {
    const r = path.join(scratch, `${fx}-${kind}-${i}`);
    fs.rmSync(r, { recursive: true, force: true });
    fs.cpSync(path.join(OUT, fx), r, { recursive: true });
    git(r, 'init', '-q');
    git(r, 'add', '-A');
    git(r, 'commit', '-qm', 'the fixture');
    const before = new Set(walk(r));
    const commits = git(r, 'rev-list', '--count', 'HEAD').trim();
    const s = spawnSync('claude', ['-p', `/second-brain:tailor ${prompt}`, '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
      '--permission-mode', 'acceptEdits', '--plugin-dir', path.resolve(process.env.S8E_PLUGIN), '--output-format', 'json'], { cwd: r, env: env(), encoding: 'utf8', timeout: 1_800_000 });
    const made = walk(r).filter((f) => !before.has(f) && f.startsWith('.claude/'));
    const texts = made.map((f) => fs.readFileSync(path.join(r, f), 'utf8'));
    // every repo path a draft names exists: a token with a folder and an extension, not a URL, not under .claude/
    const named = [...new Set(texts.flatMap((t) => [...t.matchAll(/(?<![\w/:.])((?:[\w-]+\/)+[\w.-]+\.(?:js|json|sql|txt|md|csv))\b/g)].map((m) => m[1])))].filter((p) => !p.startsWith('.claude/'));
    const agents = made.filter((f) => /^\.claude\/agents\/.*\.md\.draft$/.test(f)).map((f) => fs.readFileSync(path.join(r, f), 'utf8'));
    const res = {
      fx, kind, run: i, finished: s.status === 0,
      made: made.length,
      draftsOnly: made.every((f) => f.endsWith('.draft') || /^\.claude\/skills\/[\w-]+\/(?!SKILL\.md$)[\w.-]+$/.test(f)),
      committed: git(r, 'rev-list', '--count', 'HEAD').trim() !== commits,
      missingPaths: named.filter((p) => !fs.existsSync(path.join(r, p))),
      // one task per agent: one description line, and its body names no second job ("and also", "as well as")
      oneTask: agents.every((t) => (t.match(/^description:/gm) ?? []).length === 1 && !/\b(and also|as well as|additionally)\b/i.test(t.split('\n---').slice(-1)[0])),
    };
    fs.writeFileSync(path.join(scratch, `${fx}-${kind}-${i}.json`), JSON.stringify(res, null, 1));
    console.log(JSON.stringify(res));
  }
}

function summary() {
  const rows = fs.readdirSync(scratch).filter((f) => /^fixture2?-(gap|none)-\d+\.json$/.test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8')));
  const gap = rows.filter((x) => x.kind === 'gap'), none = rows.filter((x) => x.kind === 'none');
  const every = (rs, f) => rs.length === 6 && rs.every(f);
  // 06, 8e, check 4's bars, fixed before any run, 3 of 3 per repo
  const out = { runs: rows.length, pass: {
    nothingWithoutAGap: every(none, (x) => x.made === 0),
    draftsOnly: every(rows.filter((x) => x.kind === 'gap').concat(none).slice(0, 12), (x) => x.draftsOnly) && rows.length === 12,
    nothingCommitted: rows.length === 12 && rows.every((x) => !x.committed),
    pathsExist: every(gap, (x) => x.missingPaths.length === 0),
    oneTaskPerAgent: every(gap, (x) => x.oneTask),
  }, rows };
  out.pass.all = Object.values(out.pass).every(Boolean);
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', 'check4.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, rows: undefined }));
}

if (firstArg === 'summary') summary();
else for (let i = Number(firstArg); i <= Number(lastArg); i++) runOne(i);
