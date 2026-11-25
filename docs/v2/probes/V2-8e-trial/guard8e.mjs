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

function runOne(i) {
  for (const [fx, kind, prompt] of SETS) {
    const r = path.join(scratch, `${fx}-${kind}-${i}`);
    fs.rmSync(r, { recursive: true, force: true });
    fs.cpSync(path.join(OUT, fx), r, { recursive: true });
    git(r, 'init', '-q');
    git(r, 'add', '-A');
    git(r, 'commit', '-qm', 'the fixture');
    const commits = git(r, 'rev-list', '--count', 'HEAD').trim();
    const s = spawnSync('claude', ['-p', `/second-brain:tailor ${prompt}`, '--model', 'claude-opus-5-5', '--setting-sources', 'project,local', '--strict-mcp-config', '--disallowedTools', 'WebFetch,WebSearch',
      '--permission-mode', 'acceptEdits', '--plugin-dir', path.resolve(process.env.S8E_PLUGIN), '--output-format', 'json'], { cwd: r, env: env(), encoding: 'utf8', timeout: 1_800_000 });
    // the session's reply, kept in the scratch folder only (never in results/), to tell why a run made what it made
    let reply = '';
    try { reply = String(JSON.parse(s.stdout).result ?? ''); } catch {}
    fs.writeFileSync(path.join(scratch, `${fx}-${kind}-${i}.reply.txt`), reply);
    // attempt 4's bar: the reply names evidence the repo holds (a map entry's id, a path that exists, or a file at the
    // root), and asks which to make
    const ids = (() => { try { return fs.readdirSync(path.join(r, '.project-map')).filter((f) => f.endsWith('.md')).flatMap((f) => [...fs.readFileSync(path.join(r, '.project-map', f), 'utf8').matchAll(/^- id:[ \t]*(\S+)/gm)].map((m) => m[1])); } catch { return []; } })();
    const replyPaths = [...reply.matchAll(/(?<![\w/:.-])((?:\.?[\w-]+\/)+[\w.-]+\.\w+)\b/g)].map((m) => m[1]);
    const roots = fs.readdirSync(r).filter((f) => f !== '.git' && fs.statSync(path.join(r, f)).isFile());
    const evidence = ids.some((id) => reply.includes(id)) || replyPaths.some((p) => fs.existsSync(path.join(r, p))) || roots.some((f) => reply.includes(f));
    // anything the session made or changed, anywhere in the repo, as git sees it (the decision-checker's finding: new
    // files under .claude/ alone missed a draft left in .project-map/drafts/)
    const made = git(r, 'status', '--porcelain', '--untracked-files=all', '-z').split('\0').filter(Boolean).map((l) => l.slice(3));
    const drafts = made.filter((f) => /^\.claude\/.*\.draft$/.test(f));
    const texts = made.filter((f) => f.startsWith('.claude/') && fs.existsSync(path.join(r, f))).map((f) => fs.readFileSync(path.join(r, f), 'utf8'));
    // every repo path a draft names exists: a token with a folder and an extension, not a URL, not under .claude/
    // (the second pilot: a folder such as .project-map was read as "map/…", so a dot and a dash now start a token too)
    const named = [...new Set(texts.flatMap((t) => [...t.matchAll(/(?<![\w/:.-])((?:\.?[\w-]+\/)+[\w.-]+\.(?:js|mjs|json|sql|txt|md|csv))\b/g)].map((m) => m[1])))].filter((p) => !p.startsWith('.claude/'));
    const agents = drafts.filter((f) => /^\.claude\/agents\/.*\.md\.draft$/.test(f)).map((f) => fs.readFileSync(path.join(r, f), 'utf8'));
    const mapTopic = (f) => /^\.project-map\/[\w-]+\.md$/.test(f) && !['.project-map/README.md', '.project-map/dreams.md'].includes(f);
    // a file beside a skill draft, in its folder
    const beside = (f) => { const m = /^\.claude\/skills\/([\w-]+)\//.exec(f); return Boolean(m) && drafts.includes(`.claude/skills/${m[1]}/SKILL.md.draft`); };
    const res = {
      fx, kind, run: i, finished: s.status === 0,
      made: made.length, drafts: drafts.length, agentDrafts: agents.length, mapEntries: made.filter(mapTopic).length, evidence, asks: reply.includes('?'),
      // drafts only: a .draft under .claude/, a file beside a skill draft, a case file or check under evals/, or a map
      // topic file, which is the plugin's own capture of a stated rule (D14), reviewed in the commit (the second pilot)
      draftsOnly: made.every((f) => drafts.includes(f) || beside(f) || f.startsWith('.project-map/evals/') || mapTopic(f)),
      committed: git(r, 'rev-list', '--count', 'HEAD').trim() !== commits,
      missingPaths: named.filter((p) => !fs.existsSync(path.join(r, p))),
      // one task per agent: one description line, and its body names no second job ("and also", "as well as")
      oneTask: agents.every((t) => (t.match(/^description:/gm) ?? []).length === 1 && !/\b(and also|as well as|additionally)\b/i.test(t.split('\n---').slice(-1)[0])),
    };
    fs.writeFileSync(path.join(scratch, `${fx}-${kind}-${i}.json`), JSON.stringify(res, null, 1));
    console.log(JSON.stringify(res));
  }
}

function summary(pilot = false) {
  // the counted runs are 1 to 3; run 0 is the pilot's
  const rows = fs.readdirSync(scratch).filter((f) => (pilot ? /^fixture2?-(gap|none)-0\.json$/ : /^fixture2?-(gap|none)-[1-9]\d*\.json$/).test(f)).map((f) => JSON.parse(fs.readFileSync(path.join(scratch, f), 'utf8')));
  const gap = rows.filter((x) => x.kind === 'gap'), none = rows.filter((x) => x.kind === 'none');
  const want = pilot ? 2 : 6;
  const every = (rs, f) => rs.length === want && rs.every(f);
  // 06, 8e, check 4's bars, fixed before any run, 3 of 3 per repo (as amended: a gap run must leave a draft, so the
  // paths and one-task bars cannot pass on an empty run; every session must finish)
  const out = { runs: rows.length, pass: {
    finished: rows.length === 2 * want && rows.every((x) => x.finished),
    nothingWithoutAGap: every(none, (x) => x.made === 0),
    draftsOnly: rows.length === 2 * want && rows.every((x) => x.draftsOnly),
    nothingCommitted: rows.length === 2 * want && rows.every((x) => !x.committed),
    pathsExist: every(gap, (x) => x.drafts > 0 && x.missingPaths.length === 0),
    oneTaskPerAgent: every(gap, (x) => x.drafts > 0 && x.oneTask),
    // attempt 4 (the user's word), fixed before its runs: with no task named, a survey that names evidence and asks
    surveyAsks: every(none, (x) => x.made === 0 && x.evidence && x.asks),
  }, rows };
  out.pass.all = Object.values(out.pass).every(Boolean);
  fs.mkdirSync(path.join(HERE, 'results'), { recursive: true });
  fs.writeFileSync(path.join(HERE, 'results', pilot ? 'check4-pilot.json' : 'check4.json'), `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify({ ...out, rows: undefined }));
}

// the pilot (06, 8e, as amended): one run of each request, run 0; it can only void the probe, never a bar
if (firstArg === 'summary') summary();
else if (firstArg === 'pilot') { runOne(0); summary(true); }
else for (let i = Number(firstArg); i <= Number(lastArg); i++) runOne(i);
